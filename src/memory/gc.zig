// Garbage collector: vendor py/gc.c's heap design, conservative roots
// (ADR 019).
//
// The heap is a list of areas, each a pool of BYTES_PER_BLOCK-byte
// blocks plus an allocation table (ATB) of 2 bits per block: FREE, HEAD
// (first block of an allocation), TAIL (the rest), MARK (a HEAD reached
// during the current collection). As vendor with MICROPY_GC_SPLIT_HEAP_AUTO,
// the heap grows by adding areas: INITIAL_AREA first, then each new area
// as large as the heap so far.
//
// Roots are not registered. A collection scans conservatively the
// executable's writable data segment (every Zig and C global, mp_state_ctx
// included) and the C stack, from the registers setjmp spills up to
// MP_STATE_THREAD(stack_top). Any word pointing into an allocated block
// marks its allocation, interior pointers included (vendor only follows
// pointers to a HEAD). Marked allocations are scanned the same way.
//
// Collection happens when an allocation finds no room. If more than half
// the heap is still in use afterwards, a new area is added so collections
// stay proportional to allocation. NPY_GC_STRESS=N also collects every N
// allocations, to hunt for missing roots.
//
// wasm cannot scan its stack: values held in wasm locals are invisible
// (ADR 019 §2). It collects only at safe points, when the outermost entry
// into Python returns (enterPython/leavePython) and no Python frame is
// live; the data segment, shadow stack included, is then the whole root
// set. Until then a full heap grows, and the collection it wanted waits;
// a safe point also collects once half the heap has been allocated since
// the last collection. A browser page collects between JS callbacks; a
// single wasmtime script never reaches a safe point before it ends.
//
// Finalisers, as vendor with MICROPY_ENABLE_FINALISER: an allocation made
// with GC_ALLOC_FLAG_HAS_FINALISER (m_malloc_with_finaliser) sets a bit in
// the area's finaliser table (FTB). After marking, before sweeping, every
// unmarked flagged object gets its `__del__` called, protected (an
// exception is printed, not raised). Only native types use it (files,
// sockets); like vendor, user classes' `__del__` is never called. Vendor
// keeps the GC locked meanwhile, which fails allocation; here gc_lock still
// allows it, so blocks allocated by a finaliser are created marked and
// survive the sweep that follows.
//
// __qstr_shadow_begin__
// MP_QSTR___del__
// __qstr_shadow_end__
//
// m_malloc_fail is polled (sets pending_exc + returns, no longjmp). The
// per-allocation cap defends against macOS's virtual-memory overcommit
// (memoryerror.py and friends).

const std = @import("std");
const builtin = @import("builtin");
const state = @import("../runtime/mpstate.zig");
const pyerr = @import("../pyerr.zig");
const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("setjmp.h");
});
const mp = @cImport({
    @cInclude("py/qstr.h");
});

extern fn m_malloc_fail(num_bytes: usize) callconv(.c) void;
extern fn mp_load_method_maybe(base: usize, attr: usize, dest: *[2]usize) callconv(.c) void;
extern fn mp_call_function_1_protected(fun: usize, arg: usize) callconv(.c) usize;

const GC_ALLOC_FLAG_HAS_FINALISER: c_uint = 1;

const MAX_ALLOC: usize = 16 * 1024 * 1024;
const BYTES_PER_BLOCK: usize = 4 * @sizeOf(usize); // MICROPY_BYTES_PER_GC_BLOCK
const INITIAL_AREA: usize = 1024 * 1024;
const MAX_AREAS = 64; // areas double: unreachable before the address space runs out
const is_wasm = builtin.cpu.arch.isWasm();
const gpa = std.heap.c_allocator; // the mark stack lives outside the heap

const Kind = enum(u2) { free = 0, head = 1, tail = 2, mark = 3 };

const Area = struct {
    atb: [*]u8,
    ftb: [*]u8, // finaliser table: 1 bit per block
    // One past the pool's last byte. The pool start is not stored, so the
    // area table itself (scanned as part of the data segment) does not
    // retain the area's first allocation.
    end: usize,
    n_blocks: usize,

    inline fn pool(a: *const Area) usize {
        return a.end - a.n_blocks * BYTES_PER_BLOCK;
    }
    inline fn kind(a: *const Area, b: usize) Kind {
        return @enumFromInt(@as(u2, @truncate(a.atb[b >> 2] >> @intCast((b & 3) * 2))));
    }
    inline fn setKind(a: *Area, b: usize, k: Kind) void {
        const shift: u3 = @intCast((b & 3) * 2);
        a.atb[b >> 2] = (a.atb[b >> 2] & ~(@as(u8, 3) << shift)) | (@as(u8, @intFromEnum(k)) << shift);
    }
    inline fn hasFinaliser(a: *const Area, b: usize) bool {
        return a.ftb[b >> 3] & (@as(u8, 1) << @intCast(b & 7)) != 0;
    }
    inline fn setFinaliser(a: *Area, b: usize, on: bool) void {
        const bit = @as(u8, 1) << @intCast(b & 7);
        a.ftb[b >> 3] = if (on) a.ftb[b >> 3] | bit else a.ftb[b >> 3] & ~bit;
    }
    inline fn addr(a: *const Area, b: usize) usize {
        return a.pool() + b * BYTES_PER_BLOCK;
    }
    /// Blocks in the allocation whose head is `b`.
    fn length(a: *const Area, b: usize) usize {
        var e = b + 1;
        while (e < a.n_blocks and a.kind(e) == .tail) e += 1;
        return e - b;
    }
    fn freeFrom(a: *Area, b: usize, n: usize) void {
        for (b..b + n) |i| a.setKind(i, .free);
    }
};

var areas: [MAX_AREAS]Area = undefined;
var n_areas: usize = 0;
// Below the lowest pool, not its first block: the data-segment scan reads
// this variable too, and must not see a pointer to a live allocation.
var heap_below: usize = std.math.maxInt(usize);
var heap_hi: usize = 0;
var total_blocks: usize = 0;
// Next fit: allocation searches from where the last one ended and wraps
// around once. First fit from the lowest hole, vendor's choice, rescans
// every allocation since that hole on each multi-block request.
var cursor_area: usize = 0;
var cursor_block: usize = 0;
var lock_depth: usize = 0;
var stress_every: usize = 0;
var alloc_count: usize = 0;
var python_depth: usize = 0;
var collect_wanted = false; // wasm: a collection waiting for a safe point
var allocated_blocks: usize = 0; // since the last collection
var finalising = false; // finalisers running: new blocks are created marked

fn addArea(min_bytes: usize) bool {
    if (n_areas == MAX_AREAS) return false;
    const bytes = std.mem.alignForward(usize, @max(min_bytes, INITIAL_AREA, total_blocks * BYTES_PER_BLOCK), BYTES_PER_BLOCK);
    const n_blocks = bytes / BYTES_PER_BLOCK;
    const atb_len = (n_blocks + 3) / 4;
    const ftb_len = (n_blocks + 7) / 8;
    // calloc: a zeroed ATB is all FREE, a zeroed FTB has no finalisers, and
    // the pages stay untouched until used.
    const raw: [*]u8 = @ptrCast(c.calloc(1, atb_len + ftb_len + BYTES_PER_BLOCK + bytes) orelse return false);
    const pool = std.mem.alignForward(usize, @intFromPtr(raw) + atb_len + ftb_len, BYTES_PER_BLOCK);
    areas[n_areas] = .{ .atb = raw, .ftb = raw + atb_len, .end = pool + bytes, .n_blocks = n_blocks };
    n_areas += 1;
    heap_below = @min(heap_below, pool - 1);
    heap_hi = @max(heap_hi, pool + bytes);
    total_blocks += n_blocks;
    return true;
}

/// The area holding address `p`, if any.
fn areaOf(p: usize) ?*Area {
    if (p <= heap_below or p >= heap_hi) return null;
    for (areas[0..n_areas]) |*a| {
        if (p >= a.pool() and p < a.end) return a;
    }
    return null;
}

// ─── lifecycle ──────────────────────────────────────────────────────────

pub export fn gc_init(start: ?*anyopaque, end: ?*anyopaque) void {
    // The pool the embed-init path passes is unused: areas come from
    // calloc so the heap can grow.
    _ = start;
    _ = end;
    // Vendor gc_init (sandbox/micropython/py/gc.c:220) sets the auto-
    // collect flag to 1 here. Without this, gc.isenabled() returns
    // False on startup (BSS-default 0) instead of True. CPython +
    // MicroPython both start with gc enabled.
    state.memState().gc_auto_collect_enabled = 1;
    if (!is_wasm) {
        if (c.getenv("NPY_GC_STRESS")) |s| stress_every = std.fmt.parseInt(usize, std.mem.span(s), 10) catch 0;
    }
}

// Locking only defers collection; allocation stays allowed, as before
// this collector existed (vendor returns NULL from gc_alloc while locked).
pub export fn gc_lock() void {
    lock_depth += 1;
}
pub export fn gc_unlock() void {
    lock_depth -= 1;
}
pub export fn gc_is_locked() bool {
    return lock_depth != 0;
}

pub export fn gc_collect() void {
    if (lock_depth != 0) return;
    if (is_wasm and python_depth != 0) {
        collect_wanted = true; // gc.collect() from Python: Python frames are live
    } else collect();
}

/// Brackets each entry into Python from outside: a script, a REPL line,
/// a .mpy run, a JS callback. Entries nest when Python calls JS that
/// calls back into Python.
pub fn enterPython() void {
    python_depth += 1;
}
pub fn leavePython() void {
    python_depth -= 1;
    // wasm cannot collect when the heap fills mid-entry, only grow; so it
    // also collects here once half the heap was allocated since the last
    // collection, and grows only for an entry that alone fills half of it.
    if (is_wasm and python_depth == 0 and lock_depth == 0 and
        (collect_wanted or allocated_blocks * 2 > total_blocks)) collect();
}
pub export fn gc_collect_start() void {}
pub export fn gc_collect_end() void {}
pub export fn gc_collect_root(ptrs: ?[*]?*anyopaque, len: usize) void {
    _ = ptrs;
    _ = len;
}
pub export fn gc_sweep_all() void {}

/// Vendor gc_info_t (py/gc.h): total/used/free in bytes, the rest in blocks.
const Info = extern struct {
    total: usize,
    used: usize,
    free: usize,
    max_free: usize,
    num_1block: usize,
    num_2block: usize,
    max_block: usize,
};

pub export fn gc_info(info: *Info) void {
    info.* = std.mem.zeroes(Info);
    for (areas[0..n_areas]) |*a| {
        var b: usize = 0;
        while (b < a.n_blocks) {
            const free = a.kind(b) == .free;
            var e = b + 1;
            while (e < a.n_blocks and (a.kind(e) == .free) == free and (free or a.kind(e) == .tail)) e += 1;
            const len = e - b;
            if (free) {
                info.free += len;
                info.max_free = @max(info.max_free, len);
            } else {
                info.used += len;
                info.max_block = @max(info.max_block, len);
                info.num_1block += @intFromBool(len == 1);
                info.num_2block += @intFromBool(len == 2);
            }
            b = e;
        }
    }
    info.used *= BYTES_PER_BLOCK;
    info.free *= BYTES_PER_BLOCK;
    info.total = info.used + info.free;
}

// ─── collection ─────────────────────────────────────────────────────────

noinline fn collect() void {
    collect_wanted = false;
    allocated_blocks = 0;
    if (is_wasm) return collectFrom(null);
    // No stack bounds yet (no mp_stack_set_top): stack-only objects would be
    // freed, so don't collect; the heap grows instead.
    if (state.threadState().stack_top == null) return;
    // Spill callee-saved registers into a stack buffer the scan covers.
    var jb: c.jmp_buf = undefined;
    _ = c.setjmp(&jb);
    collectFrom(@intFromPtr(&jb));
}

/// `stack_lo` null: no stack to scan (wasm, at a safe point).
noinline fn collectFrom(stack_lo: ?usize) void {
    var work: std.ArrayListUnmanaged(usize) = .empty;
    defer work.deinit(gpa);
    const data = dataSegments();
    for (data.ranges[0..data.len]) |r| scanRange(&work, r.lo, r.hi);
    if (stack_lo) |lo| scanRange(&work, lo, @intFromPtr(state.threadState().stack_top));
    while (work.pop()) |p| {
        const a = areaOf(p).?;
        const b = (p - a.pool()) / BYTES_PER_BLOCK;
        scanRange(&work, p, p + a.length(b) * BYTES_PER_BLOCK);
    }
    runFinalisers();
    // Sweep: unmarked heads and their tails become free, marks become heads.
    for (areas[0..n_areas]) |*a| {
        var freeing = false;
        for (0..a.n_blocks) |b| {
            switch (a.kind(b)) {
                .head => {
                    a.setKind(b, .free);
                    freeing = true;
                },
                .mark => {
                    a.setKind(b, .head);
                    freeing = false;
                },
                .tail => if (freeing) a.setKind(b, .free),
                .free => {},
            }
        }
    }
    cursor_area = 0;
    cursor_block = 0;
}

/// Calls `__del__` on every unmarked object allocated with a finaliser.
/// The objects are intact until the sweep that follows.
fn runFinalisers() void {
    finalising = true;
    lock_depth += 1; // no collection from inside a finaliser
    // A collection can start while an exception is pending (allocating its
    // message, say); the finaliser call must neither see nor clear it.
    const pending = pyerr.pending_exc;
    pyerr.pending_exc = 0;
    defer {
        pyerr.pending_exc = pending;
        lock_depth -= 1;
        finalising = false;
    }
    const n = n_areas; // a finaliser may add areas; theirs are all marked
    for (areas[0..n]) |*a| {
        for (0..(a.n_blocks + 7) / 8) |i| {
            if (a.ftb[i] == 0) continue; // vendor's shortcut: 8 blocks without finalisers
            for (i * 8..@min(i * 8 + 8, a.n_blocks)) |b| {
                if (a.kind(b) != .head or !a.hasFinaliser(b)) continue;
                a.setFinaliser(b, false);
                const obj = a.addr(b);
                if (@as(*const usize, @ptrFromInt(obj)).* == 0) continue; // no type yet
                var dest: [2]usize = .{ 0, 0 };
                mp_load_method_maybe(obj, mp.MP_QSTR___del__, &dest);
                if (dest[0] != 0) _ = mp_call_function_1_protected(dest[0], dest[1]);
            }
        }
    }
}

fn scanRange(work: *std.ArrayListUnmanaged(usize), lo: usize, hi: usize) void {
    var p = std.mem.alignForward(usize, lo, @sizeOf(usize));
    while (p + @sizeOf(usize) <= hi) : (p += @sizeOf(usize)) {
        const w = @as(*const usize, @ptrFromInt(p)).*;
        const a = areaOf(w) orelse continue;
        var b = (w - a.pool()) / BYTES_PER_BLOCK;
        // Walk an interior pointer back to its allocation's head.
        while (a.kind(b) == .tail) b -= 1;
        if (a.kind(b) != .head) continue; // free, or already marked
        a.setKind(b, .mark);
        work.append(gpa, a.addr(b)) catch @panic("gc: mark stack OOM");
    }
}

const Range = struct { lo: usize, hi: usize };
const Ranges = struct {
    ranges: [8]Range = undefined,
    len: usize = 0,

    fn one(lo: usize, hi: usize) Ranges {
        var rs: Ranges = .{};
        rs.ranges[0] = .{ .lo = lo, .hi = hi };
        rs.len = 1;
        return rs;
    }
};

/// The executable's writable data: initialised data and bss. Scanned
/// range by range: the gaps between segments may be unmapped.
fn dataSegments() Ranges {
    switch (builtin.os.tag) {
        .macos => {
            // getsegmentdata returns NULL on current macOS, and
            // `_mh_execute_header` resolves to zeroed storage under Zig's
            // linker: walk the load commands of image 0 (the executable).
            const getHeader = @extern(*const fn (u32) callconv(.c) *const std.macho.mach_header_64, .{ .name = "_dyld_get_image_header" });
            const mh = getHeader(0);
            var lc: [*]const u8 = @ptrCast(@as([*]const std.macho.mach_header_64, @ptrCast(mh)) + 1);
            var text: u64 = 0;
            var data: ?*const std.macho.segment_command_64 = null;
            for (0..mh.ncmds) |_| {
                const cmd: *const std.macho.load_command = @ptrCast(@alignCast(lc));
                if (cmd.cmd == .SEGMENT_64) {
                    const seg: *const std.macho.segment_command_64 = @ptrCast(@alignCast(lc));
                    if (std.mem.eql(u8, seg.segName(), "__TEXT")) text = seg.vmaddr;
                    if (std.mem.eql(u8, seg.segName(), "__DATA")) data = seg;
                }
                lc += cmd.cmdsize;
            }
            const seg = data orelse return .{};
            const lo: usize = @intCast(seg.vmaddr - text + @intFromPtr(mh));
            return Ranges.one(lo, lo + @as(usize, @intCast(seg.vmsize)));
        },
        .linux => {
            // The first object dl_iterate_phdr reports is the executable;
            // its writable PT_LOAD segments hold .data and .bss (and RELRO).
            var rs: Ranges = .{};
            std.posix.dl_iterate_phdr(&rs, error{Done}, struct {
                fn cb(info: *std.posix.dl_phdr_info, _: usize, out: *Ranges) error{Done}!void {
                    for (info.phdr[0..info.phnum]) |ph| {
                        if (ph.type != .LOAD or !ph.flags.W) continue;
                        if (out.len == out.ranges.len) @panic("gc: too many writable segments");
                        out.ranges[out.len] = .{ .lo = info.addr + ph.vaddr, .hi = info.addr + ph.vaddr + ph.memsz };
                        out.len += 1;
                    }
                    return error.Done;
                }
            }.cb) catch {};
            return rs;
        },
        .wasi => {
            // Linear memory below __heap_base: data, bss and the shadow
            // stack. The heap areas are above it, from malloc.
            return Ranges.one(0, @intFromPtr(@extern(*const u8, .{ .name = "__heap_base" })));
        },
        else => return .{},
    }
}

// ─── alloc / free / realloc ─────────────────────────────────────────────

/// Next fit across areas; marks the blocks HEAD/TAIL and zeroes them.
fn allocBlocks(n: usize, finaliser: bool) ?*anyopaque {
    if (n_areas == 0) return null;
    // Step k scans area (cursor_area + k) % n_areas: from the cursor on the
    // first step, whole areas after, and up to the cursor on the last.
    for (0..n_areas + 1) |k| {
        const ai = (cursor_area + k) % n_areas;
        const a = &areas[ai];
        const lo = if (k == 0) cursor_block else 0;
        const hi = if (k == n_areas) @min(cursor_block + n - 1, a.n_blocks) else a.n_blocks;
        var run: usize = 0;
        var b = lo;
        while (b < hi) : (b += 1) {
            if (a.kind(b) != .free) {
                run = 0;
                continue;
            }
            run += 1;
            if (run < n) continue;
            const start = b + 1 - n;
            a.setKind(start, if (finalising) .mark else .head);
            a.setFinaliser(start, finaliser);
            for (start + 1..b + 1) |i| a.setKind(i, .tail);
            cursor_area = ai;
            cursor_block = b + 1;
            allocated_blocks += n;
            const p = a.addr(start);
            @memset(@as([*]u8, @ptrFromInt(p))[0 .. n * BYTES_PER_BLOCK], 0);
            return @ptrFromInt(p);
        }
    }
    return null;
}

fn usedBlocks() usize {
    var used: usize = 0;
    for (areas[0..n_areas]) |*a| {
        for (0..a.n_blocks) |b| used += @intFromBool(a.kind(b) != .free);
    }
    return used;
}

fn autoCollect() bool {
    return lock_depth == 0 and state.memState().gc_auto_collect_enabled != 0;
}

/// Zeroed allocation without calling m_malloc_fail.
pub fn allocMaybe(n_bytes: usize) ?*anyopaque {
    return allocWith(n_bytes, false);
}

/// allocMaybe, optionally flagging the object for its `__del__`.
pub fn allocWith(n_bytes: usize, finaliser: bool) ?*anyopaque {
    if (n_bytes > MAX_ALLOC) return null;
    if (n_areas == 0 and !addArea(0)) return null; // first allocation: nothing to collect yet
    const n = @max(1, (n_bytes + BYTES_PER_BLOCK - 1) / BYTES_PER_BLOCK);
    if (stress_every != 0 and autoCollect()) { // native only (gc_init)
        alloc_count += 1;
        if (alloc_count % stress_every == 0) collect();
    }
    if (allocBlocks(n, finaliser)) |p| return p;
    if (autoCollect() and is_wasm) {
        collect_wanted = true; // grow now, collect at the next safe point
    } else if (autoCollect()) {
        collect();
        // ponytail: usedBlocks() walks the whole ATB; vendor tracks it incrementally.
        if (usedBlocks() * 2 > total_blocks) _ = addArea(0);
        if (allocBlocks(n, finaliser)) |p| return p;
    }
    if (!addArea(n * BYTES_PER_BLOCK)) return null;
    return allocBlocks(n, finaliser);
}

/// Resizes in place when the next blocks allow it; otherwise moves if
/// `allow_move`, else returns null. Never calls m_malloc_fail.
pub fn reallocMaybe(ptr: ?*anyopaque, n_bytes: usize, allow_move: bool) ?*anyopaque {
    const p = ptr orelse return if (allow_move) allocMaybe(n_bytes) else null;
    if (n_bytes > MAX_ALLOC) return null;
    const a = areaOf(@intFromPtr(p)).?;
    const b = (@intFromPtr(p) - a.pool()) / BYTES_PER_BLOCK;
    const have = a.length(b);
    const want = @max(1, (n_bytes + BYTES_PER_BLOCK - 1) / BYTES_PER_BLOCK);
    if (want <= have) {
        a.freeFrom(b + want, have - want);
        return p;
    }
    const grow_in_place = b + want <= a.n_blocks and for (b + have..b + want) |i| {
        if (a.kind(i) != .free) break false;
    } else true;
    if (grow_in_place) {
        for (b + have..b + want) |i| a.setKind(i, .tail);
        const bytes: [*]u8 = @ptrCast(p);
        @memset(bytes[have * BYTES_PER_BLOCK .. want * BYTES_PER_BLOCK], 0);
        return p;
    }
    if (!allow_move) return null;
    const q = allocWith(n_bytes, a.hasFinaliser(b)) orelse return null; // may collect: p is still on our stack
    @memcpy(@as([*]u8, @ptrCast(q))[0 .. have * BYTES_PER_BLOCK], @as([*]const u8, @ptrCast(p))[0 .. have * BYTES_PER_BLOCK]);
    a.freeFrom(b, have);
    return q;
}

pub export fn gc_alloc(n_bytes: usize, alloc_flags: c_uint) ?*anyopaque {
    if (n_bytes == 0) return null;
    return allocWith(n_bytes, alloc_flags & GC_ALLOC_FLAG_HAS_FINALISER != 0) orelse {
        m_malloc_fail(n_bytes);
        return null;
    };
}

pub export fn gc_free(ptr: ?*anyopaque) void {
    const p = @intFromPtr(ptr orelse return);
    const a = areaOf(p) orelse return;
    const b = (p - a.pool()) / BYTES_PER_BLOCK;
    if (a.kind(b) != .head) return; // vendor asserts; a stale free is ignored
    a.freeFrom(b, a.length(b));
}

pub export fn gc_realloc(ptr: ?*anyopaque, n_bytes: usize, allow_move: bool) ?*anyopaque {
    if (ptr == null) return gc_alloc(n_bytes, 0);
    if (n_bytes == 0) {
        gc_free(ptr);
        return null;
    }
    return reallocMaybe(ptr, n_bytes, allow_move) orelse {
        if (allow_move) m_malloc_fail(n_bytes);
        return null;
    };
}

pub export fn gc_nbytes(ptr: ?*const anyopaque) usize {
    const p = @intFromPtr(ptr orelse return 0);
    const a = areaOf(p) orelse return 0;
    const b = (p - a.pool()) / BYTES_PER_BLOCK;
    if (a.kind(b) != .head) return 0;
    return a.length(b) * BYTES_PER_BLOCK;
}
