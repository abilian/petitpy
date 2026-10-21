// zigonly Phase 2 — qstr (interned string) subsystem.
//
// Replaces vendor py/qstr.c. The C build's strategy was:
//   * compile-time const pool from py/qstrdefs.generated.h (228 "static" +
//     216 "main" entries linked into the rodata pool structs)
//   * dynamic pools chained behind them via MP_STATE_VM(last_pool)
//   * djb2 hash, optional binary search on the sorted main pool
//
// Phase 1 nuked all C compilation, so we transcribe the static data at
// comptime by `@embedFile`-ing genhdr/qstrdefs.generated.h and parsing its
// QDEF0/QDEF1 lines. The qstr IDs emitted by the parser MUST match the
// MP_QSTR_* enum the rest of the runtime expects — see qstrdefs.generated.h:
// MP_QSTRnull=0, MP_QSTR_=1, … (228 statics) then the sorted main set.
//
// We don't use MP_STATE_VM yet — nothing else reads our pool state, so the
// dynamic-side state lives in this module's file-scope globals. When the
// mpstate port lands, swap the three globals for MP_STATE_VM(...) reads.
//
// Wired into build.zig via `mod.addAnonymousImport("qstrdefs_h", ...)`
// (plain `@embedFile("../vendor/...")` is rejected as outside the package
// root).
//
// Exported symbols come in two families:
//   * Plain `qstr_*` — the public C ABI from vendor py/qstr.h. Called by
//     parse.zig (cImport) and by extern-fn decls in objstr.zig / objtype/*.
//     Signatures use `qstr = usize` (= size_t). On amd64, callers that
//     declared `extern fn qstr_from_strn(...) u16` still work — the value
//     lives in the low 16 bits of RAX and current qstr IDs all fit.
//   * `npy_*_qstr_*` — thin shim wrappers that the C-shim layer used to
//     provide (memory/qstr_shim.c, frontend/compile_shim.c, etc.). They
//     forward straight to the plain qstr_* functions. Kept here so we can
//     delete the corresponding stubs in mp_layout_check.zig.

const std = @import("std");

// ---- C-ABI types matching py/qstr.h --------------------------------------

const qstr = usize; // py/qstr.h:60 typedef size_t qstr
const byte = u8;

// ---- Comptime-parsed static data ------------------------------------------

const QstrEntry = struct {
    str: []const u8, // not NUL-terminated in slice; we add a trailing 0 when materialising
    hash: u16,
    len: u8,
};

/// Parse the embedded qstrdefs.generated.h, splitting into the two pools.
/// QDEF0 lines populate the static pool (IDs 0..N_static), QDEF1 lines the
/// main pool (IDs N_static..N_total). Order is the file order — that's what
/// the C enum assigns IDs by.
const ParsedDefs = struct {
    statics: []const QstrEntry,
    mains: []const QstrEntry,
};

const parsed: ParsedDefs = blk: {
    @setEvalBranchQuota(2_000_000);
    const src = @embedFile("qstrdefs_h");

    // First pass: count.
    var n_static: usize = 0;
    var n_main: usize = 0;
    {
        var it = std.mem.splitScalar(u8, src, '\n');
        while (it.next()) |line| {
            if (std.mem.startsWith(u8, line, "QDEF0(")) n_static += 1 else if (std.mem.startsWith(u8, line, "QDEF1(")) n_main += 1;
        }
    }

    var statics: [n_static]QstrEntry = undefined;
    var mains: [n_main]QstrEntry = undefined;

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

/// QDEFx(MP_QSTR_<name>, <hash>, <len>, "<str>") → QstrEntry.
/// We don't need the name; we trust the hash/len/str fields. The string is
/// the C string literal (with \xNN escapes possible — currently only \x0a).
fn parseLine(line: []const u8) QstrEntry {
    // Find opening '(' and trailing ')'.
    const open = std.mem.indexOfScalar(u8, line, '(') orelse @compileError("bad QDEF line");
    const close = std.mem.lastIndexOfScalar(u8, line, ')') orelse @compileError("bad QDEF line");
    const body = line[open + 1 .. close];

    // body = " MP_QSTR_x, HASH, LEN, \"STR\" "
    // Comma-split first three fields, then the rest is the quoted string.
    var i: usize = 0;
    // skip name
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
    // string field
    const str_start = skipSpaces(body, i);
    if (body[str_start] != '"') @compileError("expected quoted string");
    const str_inner_start = str_start + 1;
    // Find closing quote (the file does not use escaped quotes so a plain
    // rfind of '"' is correct).
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

/// Decode C string-literal escapes. The corpus currently uses only \xNN; we
/// support the common ones for safety.
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

const N_STATIC: usize = parsed.statics.len; // 228
const N_MAIN: usize = parsed.mains.len; // 216
const N_TOTAL: usize = N_STATIC + N_MAIN; // 444

/// NUL-terminated storage for every const qstr. Built at comptime so the
/// strings live in rodata. Layout: storage[i] is the bytes of qstr i with a
/// trailing 0 (so qstr_str can return a valid C string).
const StaticStrings = blk: {
    @setEvalBranchQuota(2_000_000);
    var arrs: [N_TOTAL][:0]const u8 = undefined;
    var i: usize = 0;
    while (i < N_STATIC) : (i += 1) {
        const e = parsed.statics[i];
        arrs[i] = makeZeroTerm(e.str);
    }
    var j: usize = 0;
    while (j < N_MAIN) : (j += 1) {
        const e = parsed.mains[j];
        arrs[N_STATIC + j] = makeZeroTerm(e.str);
    }
    const final = arrs;
    break :blk final;
};

fn makeZeroTerm(comptime s: []const u8) [:0]const u8 {
    var buf: [s.len + 1]u8 = undefined;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    const final = buf;
    return final[0..s.len :0];
}

const StaticHashes = blk: {
    var arr: [N_TOTAL]u16 = undefined;
    var i: usize = 0;
    while (i < N_STATIC) : (i += 1) arr[i] = parsed.statics[i].hash;
    var j: usize = 0;
    while (j < N_MAIN) : (j += 1) arr[N_STATIC + j] = parsed.mains[j].hash;
    const final = arr;
    break :blk final;
};

const StaticLengths = blk: {
    var arr: [N_TOTAL]u8 = undefined;
    var i: usize = 0;
    while (i < N_STATIC) : (i += 1) arr[i] = parsed.statics[i].len;
    var j: usize = 0;
    while (j < N_MAIN) : (j += 1) arr[N_STATIC + j] = parsed.mains[j].len;
    const final = arr;
    break :blk final;
};

// ---- Dynamic-pool state ---------------------------------------------------
//
// Eventually MP_STATE_VM-owned; for now we keep them file-local. When
// runtime/mpstate lands the mirror, swap these three globals for
// MP_STATE_VM(...) reads — the only writers are dynAlloc and qstr_init.

const DynamicEntry = struct {
    str: [*]const u8, // points into chunk storage; the +len byte is 0
    hash: u16,
    len: u8,
};

var dynamic_entries: std.ArrayListUnmanaged(DynamicEntry) = .empty;
var dynamic_chunks: std.ArrayListUnmanaged([]u8) = .empty;
var chunk_used: usize = 0; // bytes used in the last chunk
const CHUNK_INIT: usize = 128; // matches MICROPY_ALLOC_QSTR_CHUNK_INIT

fn dynAlloc(n: usize) [*]u8 {
    if (dynamic_chunks.items.len == 0 or chunk_used + n > dynamic_chunks.items[dynamic_chunks.items.len - 1].len) {
        const size = if (n > CHUNK_INIT) n else CHUNK_INIT;
        const slab = std.heap.c_allocator.alloc(u8, size) catch @panic("qstr: chunk alloc OOM");
        dynamic_chunks.append(std.heap.c_allocator, slab) catch @panic("qstr: chunk list OOM");
        chunk_used = 0;
    }
    const last = dynamic_chunks.items[dynamic_chunks.items.len - 1];
    const p = last.ptr + chunk_used;
    chunk_used += n;
    return p;
}

// ---- Public C ABI exports (plain qstr_* — vendor py/qstr.h) --------------

/// Initialise the qstr subsystem. The const pools are already populated at
/// comptime, so we just reset the dynamic side. Safe to call multiple times
/// (mp_init may be re-entered by the test harness).
pub export fn qstr_init() void {
    // Tear down any previous run.
    for (dynamic_chunks.items) |slab| std.heap.c_allocator.free(slab);
    dynamic_chunks.clearAndFree(std.heap.c_allocator);
    dynamic_entries.clearAndFree(std.heap.c_allocator);
    chunk_used = 0;
}

/// djb2 — mirrors qstr.c:64-76 exactly. Result is masked to BYTES_IN_HASH
/// (16) bits and never zero (zero == "hash not computed").
pub export fn qstr_compute_hash(data: [*]const byte, len: usize) usize {
    var hash: usize = 5381;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        hash = ((hash << 5) +% hash) ^ data[i]; // hash*33 ^ byte
    }
    hash &= 0xffff;
    if (hash == 0) hash = 1;
    return hash;
}

/// Look up an interned string; return MP_QSTRnull (0) if absent. Matches
/// the C semantics: empty input maps to MP_QSTR_ (id 1).
pub export fn qstr_find_strn(str: [*]const u8, str_len: usize) qstr {
    if (str_len == 0) return 1; // MP_QSTR_

    const want_hash: u16 = @intCast(qstr_compute_hash(str, str_len) & 0xffff);
    if (str_len > 255) return 0; // can't possibly match (we cap at u8)
    const want_len: u8 = @intCast(str_len);

    // Search dynamic pool first (newer wins on collisions).
    var di: usize = dynamic_entries.items.len;
    while (di > 0) {
        di -= 1;
        const e = dynamic_entries.items[di];
        if (e.hash == want_hash and e.len == want_len) {
            if (std.mem.eql(u8, e.str[0..want_len], str[0..str_len])) {
                return N_TOTAL + di;
            }
        }
    }

    // Search const pool by linear scan (statics + mains). The mains pool is
    // sorted in C — we could bsearch it once profiling demands; for the
    // smoke test the linear scan is fine.
    var i: usize = 0;
    while (i < N_TOTAL) : (i += 1) {
        if (StaticHashes[i] == want_hash and StaticLengths[i] == want_len) {
            if (std.mem.eql(u8, StaticStrings[i][0..want_len], str[0..str_len])) {
                return i;
            }
        }
    }
    return 0; // MP_QSTRnull
}

pub export fn qstr_from_strn(str: [*]const u8, len: usize) qstr {
    const found = qstr_find_strn(str, len);
    if (found != 0) return found;
    if (len >= 256) @panic("qstr_from_strn: name too long (> 255 bytes)");

    // Intern: copy into chunk storage, NUL-terminate, append entry.
    const n_bytes = len + 1;
    const dst = dynAlloc(n_bytes);
    @memcpy(dst[0..len], str[0..len]);
    dst[len] = 0;

    const hash: u16 = @intCast(qstr_compute_hash(str, len) & 0xffff);
    dynamic_entries.append(std.heap.c_allocator, .{
        .str = dst,
        .hash = hash,
        .len = @intCast(len),
    }) catch @panic("qstr_from_strn: entry list OOM");

    return N_TOTAL + dynamic_entries.items.len - 1;
}

pub export fn qstr_from_str(str: [*:0]const u8) qstr {
    const len = std.mem.len(str);
    return qstr_from_strn(str, len);
}

pub export fn qstr_str(q: qstr) [*:0]const u8 {
    if (q < N_TOTAL) return StaticStrings[q].ptr;
    const idx = q - N_TOTAL;
    if (idx >= dynamic_entries.items.len) @panic("qstr_str: out-of-range qstr");
    const e = dynamic_entries.items[idx];
    return @ptrCast(e.str);
}

/// Total qstr count (static + main + dynamic). Mirrors vendor's
/// QSTR_TOTAL() macro for callers (e.g. builtin_dir) that walk all qstrs.
pub export fn npy_qstr_total() usize {
    return N_TOTAL + dynamic_entries.items.len;
}

pub export fn qstr_len(q: qstr) usize {
    if (q < N_TOTAL) return StaticLengths[q];
    const idx = q - N_TOTAL;
    if (idx >= dynamic_entries.items.len) @panic("qstr_len: out-of-range qstr");
    return dynamic_entries.items[idx].len;
}

pub export fn qstr_hash(q: qstr) usize {
    if (q < N_TOTAL) return StaticHashes[q];
    const idx = q - N_TOTAL;
    if (idx >= dynamic_entries.items.len) @panic("qstr_hash: out-of-range qstr");
    return dynamic_entries.items[idx].hash;
}

pub export fn qstr_data(q: qstr, len_out: *usize) [*]const byte {
    if (q < N_TOTAL) {
        len_out.* = StaticLengths[q];
        return StaticStrings[q].ptr;
    }
    const idx = q - N_TOTAL;
    if (idx >= dynamic_entries.items.len) @panic("qstr_data: out-of-range qstr");
    const e = dynamic_entries.items[idx];
    len_out.* = e.len;
    return e.str;
}

// ---- npy_* shim wrappers (were memory/qstr_shim.c et al) ------------------
//
// Pure pass-throughs into the qstr_* C ABI above. They exist because the
// strangler's `src/**/*_api.h` headers reach into qstr via these names from
// already-ported Zig modules (compile.zig, mpprint.zig, map.zig). Same
// signatures as the existing extern decls in those modules.

// Re-added after compile_shim.c carveout (it doesn't actually provide these).

// (qstr_total override removed; shim handles) — vendor reads
// MP_STATE_VM(last_pool) which we don't populate; just return our total.
const qstr_dynamic = struct {
    extern var dynamic_entries: anyopaque;
};
// Total = N_TOTAL (static + main pools) + however many dynamic entries
// we've allocated. For builtin_dir/help which enumerate qstrs, returning
// just N_TOTAL is correct enough — the dynamic ones are runtime-only and
// not present in the static dump.
