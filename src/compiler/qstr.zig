// Compiler-track qstr (interned-string) subsystem — pure Zig.
//
// Replaces vendor py/qstr.c + the runtime-coupled src/runtime/qstr.zig.
// Key divergences from the zigonly port:
//
//   1. Dynamic-pool state lives in a `QstrContext` struct, NOT file-scope
//      globals. The compiler driver may be invoked multiple times per
//      process (REPL, test harness, future build-server) and global
//      mutable state silently leaks ids across compile sessions — which
//      would break byte-identical .mpy emission on the second run.
//   2. No C-ABI exports (no `pub export fn ...`). The compiler track has
//      no _shim.c layer; consumers are pure-Zig callers in src/compiler/.
//   3. `qstr` aliased to `u16` (not vendor's `usize` typedef) — the qstr
//      id range fits comfortably and the .mpy vlen encoder/decoder in
//      mpy.zig already uses u16 widths.
//   4. Length check before hash check in qstr_find_strn (cheap u8
//      compare disambiguates faster than hash on the common miss).
//
// The comptime QDEF parser is ported verbatim from runtime/qstr.zig
// because that ~150 LOC is production-validated by the entire 541/541
// corpus pass. The data layout (StaticStrings/Hashes/Lengths) is the
// same; only the dynamic side is restructured.
//
// Build wiring: reuses build.zig's existing `qstrdefs_h` anonymous
// import. The compiler module gains qstr.zig by sharing that import.

const std = @import("std");
const mpy = @import("mpy.zig");

// ── Vendor constants ──────────────────────────────────────────────────────
//
// N_STATIC and N_MAIN come from the QDEF0/QDEF1 partition in
// vendor/micropython_embed/genhdr/qstrdefs.generated.h. They are asserted
// at comptime below — a vendor regen that changes either count will fail
// the build with a clear message.

pub const qstr = u16;
pub const byte = u8;

/// Number of QDEF0 entries — the "static" pool (compile-time, unsorted).
/// Ids 0..N_STATIC-1.
pub const N_STATIC: u16 = 228;

/// Number of QDEF1 entries — the "main" pool (compile-time, sorted).
/// Ids N_STATIC..N_STATIC+N_MAIN-1.
///
/// ADR-006 J1 — bumped from 216 to 227 (+11) to absorb the qstrs the
/// `_nanopython_js` module shadow declares (`_nanopython_js`,
/// `_bridge_present`, `_get_global`, `_get_attr`, `_set_attr`, `_call`,
/// `_release`, `_create_string`, `_create_int`, `_to_string`, `_to_int`).
/// J5a — bumped from 227 to 229 (+2) for `_create_callback` +
/// `_set_dispatcher` (Python callback marshaling).
/// These land in the QDEF1 table whether or not -Dfeature-js is on
/// because the qstr scanner reads the shadow .c unconditionally; the
/// runtime gating only affects whether the module object itself is
/// linked, not the qstr table.
/// ADR 019 — 357 (+1) for `__del__` (finalisers, memory/gc.zig).
/// 358 (+1) for `os_path` (`os.path` via os.__getattr__, modules/modos.zig).
/// 359 (+1) for `gcd` (math.gcd, modules/modmath.zig).
/// 362 (+3) for `__cause__`, `__context__`, `__suppress_context__` (PEP 3134).
/// 366 (+4) for `lseek`, `SEEK_SET`, `SEEK_CUR`, `SEEK_END` (modules/modos.zig).
/// 367 (+1) for `_json` (modules/modjson.zig).
pub const N_MAIN: u16 = 382;

/// Total compile-time qstr count. Dynamic pool ids start here.
pub const N_TOTAL: u16 = N_STATIC + N_MAIN;

/// Boundary used by .mpy persistentcode encoding (vendor
/// persistentcode.c:48 `#define QSTR_LAST_STATIC MP_QSTR_zip`). Qstrs
/// with id <= QSTR_LAST_STATIC are encoded inline as `.static`
/// references; everything else is emitted as `.new` (inline bytes).
///
/// 165 == zero-based index of MP_QSTR_zip among QDEF0 entries (verified
/// against genhdr/qstrdefs.generated.h line 168 / QDEF0 #166).
pub const QSTR_LAST_STATIC: u16 = 165;

// Compile-time consistency check: keep this constant in lockstep with
// mpy.zig's local copy. (mpy.zig duplicates the constant so it stays
// format-only — importing qstr.zig from mpy.zig would create a cycle.)
comptime {
    if (mpy.QSTR_LAST_STATIC != QSTR_LAST_STATIC) {
        @compileError("mpy.QSTR_LAST_STATIC out of sync with qstr.QSTR_LAST_STATIC");
    }
}

// ── Comptime QDEF parser ──────────────────────────────────────────────────
//
// Verbatim port from src/runtime/qstr.zig:43-184. Parses the embedded
// genhdr/qstrdefs.generated.h once at comptime, splitting QDEF0 (static)
// and QDEF1 (main) lines into separate slices. Ids are assigned by file
// order — the same way the vendor's `MP_QSTR_*` enum is.

const QstrDef = struct {
    str: []const u8, // bytes only; trailing NUL is added by StaticStrings
    hash: u16,
    len: u8,
};

const ParsedDefs = struct {
    statics: []const QstrDef,
    mains: []const QstrDef,
};

const parsed: ParsedDefs = blk: {
    @setEvalBranchQuota(2_000_000);
    const src = @embedFile("qstrdefs_h");

    // First pass: count entries so we can size the comptime arrays.
    var n_static: usize = 0;
    var n_main: usize = 0;
    {
        var it = std.mem.splitScalar(u8, src, '\n');
        while (it.next()) |line| {
            if (std.mem.startsWith(u8, line, "QDEF0(")) n_static += 1 else if (std.mem.startsWith(u8, line, "QDEF1(")) n_main += 1;
        }
    }

    var statics: [n_static]QstrDef = undefined;
    var mains: [n_main]QstrDef = undefined;

    var si: usize = 0;
    var mi: usize = 0;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        const is0 = std.mem.startsWith(u8, line, "QDEF0(");
        const is1 = std.mem.startsWith(u8, line, "QDEF1(");
        if (!is0 and !is1) continue;
        const entry = parseLine(line);
        if (is0) {
            statics[si] = entry;
            si += 1;
        } else {
            mains[mi] = entry;
            mi += 1;
        }
    }

    const sfinal = statics;
    const mfinal = mains;
    break :blk .{ .statics = &sfinal, .mains = &mfinal };
};

/// Parse `QDEFx(MP_QSTR_<name>, <hash>, <len>, "<str>")` → QstrDef.
/// We ignore the name (the enum index = file order is the qstr id).
fn parseLine(line: []const u8) QstrDef {
    const open = std.mem.indexOfScalar(u8, line, '(') orelse @compileError("bad QDEF line");
    const close = std.mem.lastIndexOfScalar(u8, line, ')') orelse @compileError("bad QDEF line");
    const body = line[open + 1 .. close];

    var i: usize = 0;
    // skip MP_QSTR_<name> field
    i = std.mem.indexOfScalarPos(u8, body, i, ',') orelse @compileError("bad QDEF line");
    i += 1;
    // hash field
    const hash_start = skipSpaces(body, i);
    const hash_end = std.mem.indexOfScalarPos(u8, body, hash_start, ',') orelse @compileError("bad QDEF line");
    const hash = std.fmt.parseInt(u16, std.mem.trim(u8, body[hash_start..hash_end], " \t"), 10) catch
        @compileError("bad hash");
    i = hash_end + 1;
    // len field
    const len_start = skipSpaces(body, i);
    const len_end = std.mem.indexOfScalarPos(u8, body, len_start, ',') orelse @compileError("bad QDEF line");
    const len_decl = std.fmt.parseInt(u8, std.mem.trim(u8, body[len_start..len_end], " \t"), 10) catch
        @compileError("bad len");
    i = len_end + 1;
    // quoted string field
    const str_start = skipSpaces(body, i);
    if (body[str_start] != '"') @compileError("expected quoted string");
    const str_inner_start = str_start + 1;
    const str_inner_end = std.mem.lastIndexOfScalar(u8, body, '"') orelse @compileError("unterminated");
    if (str_inner_end <= str_inner_start) {
        return .{ .str = "", .hash = hash, .len = 0 };
    }
    const raw = body[str_inner_start..str_inner_end];
    const decoded = decodeCString(raw);
    if (decoded.len != len_decl) @compileError("declared len mismatch");
    return .{ .str = decoded, .hash = hash, .len = len_decl };
}

fn skipSpaces(s: []const u8, from: usize) usize {
    var i = from;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
    return i;
}

/// Decode C string-literal escapes. The corpus only uses \xNN; the
/// extra cases are cheap insurance against future regenerations.
fn decodeCString(raw: []const u8) []const u8 {
    var out: [raw.len]u8 = undefined;
    var oi: usize = 0;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '\\') {
            out[oi] = raw[i];
            oi += 1;
            i += 1;
            continue;
        }
        i += 1;
        if (i >= raw.len) @compileError("trailing backslash");
        switch (raw[i]) {
            'n' => {
                out[oi] = '\n';
                oi += 1;
                i += 1;
            },
            't' => {
                out[oi] = '\t';
                oi += 1;
                i += 1;
            },
            'r' => {
                out[oi] = '\r';
                oi += 1;
                i += 1;
            },
            '0' => {
                out[oi] = 0;
                oi += 1;
                i += 1;
            },
            '\\' => {
                out[oi] = '\\';
                oi += 1;
                i += 1;
            },
            '"' => {
                out[oi] = '"';
                oi += 1;
                i += 1;
            },
            '\'' => {
                out[oi] = '\'';
                oi += 1;
                i += 1;
            },
            'x' => {
                if (i + 2 >= raw.len) @compileError("short \\x escape");
                const hex = raw[i + 1 .. i + 3];
                const v = std.fmt.parseInt(u8, hex, 16) catch @compileError("bad \\x escape");
                out[oi] = v;
                oi += 1;
                i += 3;
            },
            else => @compileError("unhandled C escape"),
        }
    }
    const final = out[0..oi].*;
    const sized: [oi]u8 = final;
    return &sized;
}

// Comptime fingerprint: catch a vendor qstrdefs regen at build time.
comptime {
    if (parsed.statics.len != N_STATIC) @compileError("qstrdefs.generated.h QDEF0 count drift — bump N_STATIC");
    if (parsed.mains.len != N_MAIN) @compileError("qstrdefs.generated.h QDEF1 count drift — bump N_MAIN");
}

// ── Static-pool data (comptime-built rodata arrays) ───────────────────────

/// NUL-terminated strings for every const qstr. Layout:
///   ids 0..N_STATIC-1    -> parsed.statics[i]
///   ids N_STATIC..N_TOTAL-1 -> parsed.mains[i - N_STATIC]
const StaticStrings: [N_TOTAL][:0]const u8 = blk: {
    @setEvalBranchQuota(2_000_000);
    var arrs: [N_TOTAL][:0]const u8 = undefined;
    var i: usize = 0;
    while (i < N_STATIC) : (i += 1) arrs[i] = makeZeroTerm(parsed.statics[i].str);
    var j: usize = 0;
    while (j < N_MAIN) : (j += 1) arrs[N_STATIC + j] = makeZeroTerm(parsed.mains[j].str);
    break :blk arrs;
};

const StaticHashes: [N_TOTAL]u16 = blk: {
    var arr: [N_TOTAL]u16 = undefined;
    var i: usize = 0;
    while (i < N_STATIC) : (i += 1) arr[i] = parsed.statics[i].hash;
    var j: usize = 0;
    while (j < N_MAIN) : (j += 1) arr[N_STATIC + j] = parsed.mains[j].hash;
    break :blk arr;
};

const StaticLengths: [N_TOTAL]u8 = blk: {
    var arr: [N_TOTAL]u8 = undefined;
    var i: usize = 0;
    while (i < N_STATIC) : (i += 1) arr[i] = parsed.statics[i].len;
    var j: usize = 0;
    while (j < N_MAIN) : (j += 1) arr[N_STATIC + j] = parsed.mains[j].len;
    break :blk arr;
};

fn makeZeroTerm(comptime s: []const u8) [:0]const u8 {
    var buf: [s.len + 1]u8 = undefined;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    const final = buf;
    return final[0..s.len :0];
}

// ── Hash function ─────────────────────────────────────────────────────────
//
// djb2 — must match vendor qstr.c:64-76 byte-for-byte so that
// vendor-precomputed hashes in StaticHashes line up with runtime hashes
// for the same string. Result is masked to 16 bits and bumped to 1 if
// it would otherwise be 0 (vendor uses 0 as "hash not computed").

pub fn qstr_compute_hash(data: []const u8) u16 {
    var hash: u32 = 5381;
    for (data) |b| hash = ((hash << 5) +% hash) ^ b; // hash*33 ^ byte
    hash &= 0xffff;
    if (hash == 0) hash = 1;
    return @intCast(hash);
}

// ── Dynamic pool: QstrContext ─────────────────────────────────────────────
//
// One context = one compile session. The driver creates it with
// `init(gpa)`, calls `qstr_from_str(...)` during parsing, then
// `deinit()` at the end. `reset()` lets a test harness clear the
// dynamic side without re-allocating the context itself.

const DynamicEntry = struct {
    ptr: [*]const u8, // points into a chunk; len bytes are valid, then NUL
    hash: u16,
    len: u8,
};

const CHUNK_INIT: usize = 128; // matches MICROPY_ALLOC_QSTR_CHUNK_INIT

pub const QstrContext = struct {
    entries: std.ArrayListUnmanaged(DynamicEntry) = .empty,
    chunks: std.ArrayListUnmanaged([]u8) = .empty,
    chunk_used: usize = 0,
    allocator: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) QstrContext {
        return .{ .allocator = gpa };
    }

    pub fn deinit(self: *QstrContext) void {
        for (self.chunks.items) |slab| self.allocator.free(slab);
        self.chunks.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.chunk_used = 0;
    }

    /// Drop all dynamic state but keep the context usable. Newly
    /// interned qstrs will re-start numbering at N_TOTAL.
    pub fn reset(self: *QstrContext) void {
        for (self.chunks.items) |slab| self.allocator.free(slab);
        self.chunks.clearAndFree(self.allocator);
        self.entries.clearAndFree(self.allocator);
        self.chunk_used = 0;
    }

    /// Allocate `n` bytes from the current chunk, growing if needed.
    /// Returned slice is uninitialized; caller writes the qstr bytes
    /// (and the trailing NUL).
    fn dynAlloc(self: *QstrContext, n: usize) std.mem.Allocator.Error![]u8 {
        const need_new = self.chunks.items.len == 0 or
            self.chunk_used + n > self.chunks.items[self.chunks.items.len - 1].len;
        if (need_new) {
            const size = if (n > CHUNK_INIT) n else CHUNK_INIT;
            const slab = try self.allocator.alloc(u8, size);
            try self.chunks.append(self.allocator, slab);
            self.chunk_used = 0;
        }
        const last = self.chunks.items[self.chunks.items.len - 1];
        const start = self.chunk_used;
        self.chunk_used += n;
        return last[start .. start + n];
    }
};

// ── Lookup + interning ────────────────────────────────────────────────────

/// Search all pools for a string. Returns 0 (MP_QSTRnull) on miss.
/// Special case: empty input returns 1 (MP_QSTR_), matching vendor.
///
/// Search order: dynamic (newest first, so LIFO dedup), then static,
/// then main. The dynamic-first order matches vendor's
/// MP_STATE_VM(last_pool) chain walk in qstr.c:262-306.
pub fn qstr_find_strn(ctx: *const QstrContext, s: []const u8) qstr {
    if (s.len == 0) return 1; // MP_QSTR_
    if (s.len > 255) return 0; // u8 length cap — can't be in any pool
    const want_len: u8 = @intCast(s.len);
    const want_hash = qstr_compute_hash(s);

    // 1) dynamic pool, newest-first
    var di: usize = ctx.entries.items.len;
    while (di > 0) {
        di -= 1;
        const e = ctx.entries.items[di];
        // Length check first: cheaper than hash, disambiguates the common miss.
        if (e.len == want_len and e.hash == want_hash) {
            if (std.mem.eql(u8, e.ptr[0..want_len], s)) {
                return @intCast(N_TOTAL + di);
            }
        }
    }

    // 2 + 3) static + main pools, linear. (vendor bsearches the sorted
    // main pool; not worth the complexity until profiling demands.)
    var i: usize = 0;
    while (i < N_TOTAL) : (i += 1) {
        if (StaticLengths[i] == want_len and StaticHashes[i] == want_hash) {
            if (std.mem.eql(u8, StaticStrings[i][0..want_len], s)) return @intCast(i);
        }
    }
    return 0; // MP_QSTRnull
}

/// Intern a string. Returns the existing id on hit; allocates a new
/// dynamic entry on miss. New dynamic ids start at N_TOTAL.
pub fn qstr_from_strn(ctx: *QstrContext, s: []const u8) std.mem.Allocator.Error!qstr {
    const found = qstr_find_strn(ctx, s);
    if (found != 0) return found;
    if (s.len > 255) return error.OutOfMemory; // u8 length limit on entries

    const n_bytes = s.len + 1; // include trailing NUL
    const dst = try ctx.dynAlloc(n_bytes);
    @memcpy(dst[0..s.len], s);
    dst[s.len] = 0;

    try ctx.entries.append(ctx.allocator, .{
        .ptr = dst.ptr,
        .hash = qstr_compute_hash(s),
        .len = @intCast(s.len),
    });
    return @intCast(N_TOTAL + ctx.entries.items.len - 1);
}

/// Convenience wrapper for NUL-terminated input.
pub fn qstr_from_str(ctx: *QstrContext, s: [*:0]const u8) std.mem.Allocator.Error!qstr {
    const len = std.mem.len(s);
    return qstr_from_strn(ctx, s[0..len]);
}

// ── Accessors ─────────────────────────────────────────────────────────────

/// Return the bytes for `id`, NUL-terminated for cheap C-interop.
/// Length is `qstr_len(ctx, id)`.
pub fn qstr_str(ctx: *const QstrContext, id: qstr) [:0]const u8 {
    if (id < N_TOTAL) return StaticStrings[id];
    const idx = id - N_TOTAL;
    std.debug.assert(idx < ctx.entries.items.len);
    const e = ctx.entries.items[idx];
    return e.ptr[0..e.len :0];
}

pub fn qstr_len(ctx: *const QstrContext, id: qstr) u8 {
    if (id < N_TOTAL) return StaticLengths[id];
    const idx = id - N_TOTAL;
    std.debug.assert(idx < ctx.entries.items.len);
    return ctx.entries.items[idx].len;
}

pub fn qstr_hash(ctx: *const QstrContext, id: qstr) u16 {
    if (id < N_TOTAL) return StaticHashes[id];
    const idx = id - N_TOTAL;
    std.debug.assert(idx < ctx.entries.items.len);
    return ctx.entries.items[idx].hash;
}

// ── Boundary helper for mpy.zig integration ───────────────────────────────
//
// The .mpy emitter wants a `mpy.QstrEntry` per qstr id in the file's
// qstr table. Encoding rule (vendor persistentcode.c:574): ids
// <= QSTR_LAST_STATIC are emitted as `.static` (cheap vlen reference);
// everything else is `.new` (inline bytes). For dynamic ids the bytes
// live in the context, so the slice borrows from the chunk and is only
// valid for the lifetime of the QstrContext.

pub fn qstrToEntry(ctx: *const QstrContext, id: qstr) mpy.QstrEntry {
    if (id <= QSTR_LAST_STATIC) return .{ .static = id };
    if (id < N_TOTAL) {
        // Compile-time qstrs above the .mpy "static" cutoff: emit bytes
        // inline (matches what vendor's mpy-cross does).
        return .{ .new = StaticStrings[id][0..StaticLengths[id]] };
    }
    const idx = id - N_TOTAL;
    std.debug.assert(idx < ctx.entries.items.len);
    const e = ctx.entries.items[idx];
    return .{ .new = e.ptr[0..e.len] };
}

// ── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

test "comptime: pool fingerprint matches vendor" {
    try testing.expectEqual(@as(u16, 228), N_STATIC);
    try testing.expectEqual(@as(u16, 382), N_MAIN);
    try testing.expectEqual(@as(u16, 610), N_TOTAL);
}

test "comptime: well-known qstr ids match vendor" {
    // These ids are pinned to the vendor qstrdefs.generated.h commit
    // currently checked in. Any drift here means the vendor was bumped
    // without updating consumers — surface it loudly.
    try testing.expectEqualSlices(u8, "__init__", StaticStrings[17][0..StaticLengths[17]]);
    try testing.expectEqualSlices(u8, "__main__", StaticStrings[21][0..StaticLengths[21]]);
    try testing.expectEqualSlices(u8, "__name__", StaticStrings[23][0..StaticLengths[23]]);
    try testing.expectEqualSlices(u8, "int", StaticStrings[94][0..StaticLengths[94]]);
    try testing.expectEqualSlices(u8, "print", StaticStrings[123][0..StaticLengths[123]]);
    try testing.expectEqualSlices(u8, "str", StaticStrings[151][0..StaticLengths[151]]);
    try testing.expectEqualSlices(u8, "zip", StaticStrings[QSTR_LAST_STATIC][0..StaticLengths[QSTR_LAST_STATIC]]);
    try testing.expectEqual(@as(u16, 165), QSTR_LAST_STATIC);
}

test "djb2: runtime hashes match vendor-precomputed StaticHashes" {
    // Three known vectors. If djb2 drifts, qstr_find_strn would miss
    // every static lookup — easier to catch here.
    try testing.expectEqual(StaticHashes[17], qstr_compute_hash("__init__"));
    try testing.expectEqual(StaticHashes[123], qstr_compute_hash("print"));
    try testing.expectEqual(StaticHashes[QSTR_LAST_STATIC], qstr_compute_hash("zip"));
}

test "qstr_find_strn: empty + miss + static hit" {
    var ctx = QstrContext.init(testing.allocator);
    defer ctx.deinit();
    try testing.expectEqual(@as(qstr, 1), qstr_find_strn(&ctx, ""));
    try testing.expectEqual(@as(qstr, 0), qstr_find_strn(&ctx, "__no_such_qstr_xyzzy__"));
    try testing.expectEqual(@as(qstr, 17), qstr_find_strn(&ctx, "__init__"));
    try testing.expectEqual(@as(qstr, QSTR_LAST_STATIC), qstr_find_strn(&ctx, "zip"));
}

test "qstr_from_strn: new entry gets id N_TOTAL and dedups" {
    var ctx = QstrContext.init(testing.allocator);
    defer ctx.deinit();
    const a = try qstr_from_strn(&ctx, "my_new_identifier");
    try testing.expectEqual(@as(qstr, N_TOTAL), a);

    // Second call: same id, no new entry.
    const a2 = try qstr_from_strn(&ctx, "my_new_identifier");
    try testing.expectEqual(a, a2);
    try testing.expectEqual(@as(usize, 1), ctx.entries.items.len);

    // Different string: next id.
    const b = try qstr_from_strn(&ctx, "another_one");
    try testing.expectEqual(@as(qstr, N_TOTAL + 1), b);
}

test "accessors: dynamic round-trip" {
    var ctx = QstrContext.init(testing.allocator);
    defer ctx.deinit();
    const id = try qstr_from_strn(&ctx, "hello_world");
    try testing.expectEqual(@as(u8, 11), qstr_len(&ctx, id));
    try testing.expectEqualSlices(u8, "hello_world", qstr_str(&ctx, id)[0..qstr_len(&ctx, id)]);
    try testing.expectEqual(qstr_compute_hash("hello_world"), qstr_hash(&ctx, id));
}

test "reset: dynamic ids renumber from N_TOTAL" {
    var ctx = QstrContext.init(testing.allocator);
    defer ctx.deinit();
    _ = try qstr_from_strn(&ctx, "first");
    _ = try qstr_from_strn(&ctx, "second");
    try testing.expectEqual(@as(usize, 2), ctx.entries.items.len);

    ctx.reset();
    try testing.expectEqual(@as(usize, 0), ctx.entries.items.len);

    const id = try qstr_from_strn(&ctx, "third");
    try testing.expectEqual(@as(qstr, N_TOTAL), id);
}

test "qstrToEntry: static cutoff + new fall-back" {
    var ctx = QstrContext.init(testing.allocator);
    defer ctx.deinit();

    // id <= QSTR_LAST_STATIC -> .static
    const e_zip = qstrToEntry(&ctx, QSTR_LAST_STATIC);
    try testing.expect(e_zip == .static);
    try testing.expectEqual(QSTR_LAST_STATIC, e_zip.static);

    // QSTR_LAST_STATIC < id < N_TOTAL -> .new (inline static bytes)
    const above = QSTR_LAST_STATIC + 5;
    const e_above = qstrToEntry(&ctx, above);
    try testing.expect(e_above == .new);
    try testing.expectEqualSlices(u8, StaticStrings[above][0..StaticLengths[above]], e_above.new);

    // dynamic -> .new (inline dynamic bytes)
    const dyn_id = try qstr_from_strn(&ctx, "dynamic_q");
    const e_dyn = qstrToEntry(&ctx, dyn_id);
    try testing.expect(e_dyn == .new);
    try testing.expectEqualSlices(u8, "dynamic_q", e_dyn.new);
}

test "long string: 255 ok, 256 rejected" {
    var ctx = QstrContext.init(testing.allocator);
    defer ctx.deinit();
    const buf255 = [_]u8{'x'} ** 255;
    const id = try qstr_from_strn(&ctx, &buf255);
    try testing.expectEqual(@as(u8, 255), qstr_len(&ctx, id));

    const buf256 = [_]u8{'y'} ** 256;
    try testing.expectError(error.OutOfMemory, qstr_from_strn(&ctx, &buf256));
}
