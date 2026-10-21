//! NX-1 — Zig port of vendor `py/persistentcode.c` LOAD path.
//!
//! Source: `vendor/micropython_embed/py/persistentcode.c` (lines
//! 159–539). Save path, native code, RV32, ROM, and dynamic-compiler
//! arms are excluded by config (see `notes/39-nx1-port-plan.md`).
//!
//! Vendor `py/persistentcode.c` was dropped from `build.zig` at
//! step 9 of NX-1; this file now owns the canonical
//! `mp_raw_code_load` / `mp_raw_code_load_mem` symbols consumed by
//! `src/runtime/zig_compile_bridge.c`.

const std = @import("std");
const mirrors = @import("../mp_mirrors.zig");
const pyerr = @import("../pyerr.zig");
const PyError = pyerr.PyError;

const Obj = mirrors.Obj;

// ── extern surface used by load_qstr / load_obj ──────────────────────
//
// Vendor C symbols. `qstr_from_strn` is Zig-side
// (`src/runtime/qstr.zig:356`); the others are vendor C (str/bytes/int
// constructors + the heap allocator + the const-obj singletons).

extern fn qstr_from_strn(str: [*]const u8, len: usize) callconv(.c) usize;
extern fn m_malloc(num_bytes: usize) callconv(.c) ?*anyopaque;
extern fn m_free(ptr: ?*anyopaque) callconv(.c) void;
extern fn mp_obj_new_tuple(n: usize, items: [*c]const Obj) callconv(.c) Obj;
// `mp_obj_new_str_from_utf8_vstr` is a macro alias for
// `mp_obj_new_str_from_vstr` when MICROPY_PY_BUILTINS_STR_UNICODE_CHECK
// is off (see obj.h:1008). Use the underlying symbol directly.
extern fn mp_obj_new_str_from_vstr(vstr: ?*anyopaque) callconv(.c) Obj;
extern fn mp_obj_new_bytes_from_vstr(vstr: ?*anyopaque) callconv(.c) Obj;
extern fn mp_parse_num_integer(str: [*]const u8, len: usize, base: c_int, lex: ?*anyopaque) callconv(.c) Obj;
extern fn mp_parse_num_float(str: [*]const u8, len: usize, allow_imag: bool, lex: ?*anyopaque) callconv(.c) Obj;
extern fn vstr_init_len(vstr: *VstrLocal, len: usize) callconv(.c) void;
extern fn mp_reader_new_mem(reader: *mirrors.MpReader, buf: [*]const u8, len: usize, free_len: usize) callconv(.c) void;
extern fn mp_obj_new_exception_msg(t: *const anyopaque, msg: [*:0]const u8) callconv(.c) Obj;
extern const mp_type_ValueError: anyopaque;
extern const mp_const_empty_bytes_obj: anyopaque;
extern const mp_const_ellipsis_obj: anyopaque;

// NX-3 N1 raise helper (PyError convention; notes/41, /42). Sets
// pyerr.pending_exc + returns error.PyRaise — the C-ABI exports
// (mp_raw_code_load, mp_raw_code_load_mem) wrap their Impls with
// pyerr.bridge which catches and returns the zero sentinel; C callers
// poll pending_exc.
fn raiseIncompatibleMpy() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_ValueError, "incompatible .mpy file");
    return error.PyRaise;
}

// emitglue helpers (Zig-side, src/frontend/emitglue.zig).
extern fn mp_emit_glue_new_raw_code() callconv(.c) *mirrors.MpRawCode;
extern fn mp_emit_glue_assign_bytecode(
    rc: *mirrors.MpRawCode,
    code: [*]const u8,
    children: ?*?*mirrors.MpRawCode,
    scope_flags: u16,
) callconv(.c) void;

// vstr_t layout (vendor misc.h). Local mirror — kept private to
// persistentcode.zig so `load_obj` can stack-allocate one and pass to
// the vendor str/bytes constructors.
const VstrLocal = extern struct {
    alloc: usize,
    len: usize,
    buf: [*c]u8,
    fixed_buf: bool,
};

// REPR_A immediate-obj encodings (obj.h:102, MP_OBJ_NEW_IMMEDIATE_OBJ
// with val << 3 | 6). mp_const_none/false/true are macros that expand
// to these; we replicate the integer values directly to avoid a
// `@cImport` round-trip.
const MP_CONST_NONE: Obj = (0 << 3) | 6; // = 6
const MP_CONST_FALSE: Obj = (1 << 3) | 6; // = 14
const MP_CONST_TRUE: Obj = (3 << 3) | 6; // = 30

// Header byte 3 (small-int width) check in mp_raw_code_load. 64-bit
// target; matches smallint.h:69.
const MP_SMALL_INT_BITS: u8 = 63;

// ── leaf primitives (persistentcode.c:159–179) ─────────────────────

/// Vendor `read_byte` (persistentcode.c:159–161). Reads one byte from
/// the reader; `readbyte` returns `mp_uint_t` (= usize) but the caller
/// always narrows to one byte.
///
/// `pub` only for in-process Zig unit tests in `src/tests.zig`.
pub fn read_byte(reader: *mirrors.MpReader) u8 {
    const cb = reader.readbyte.?;
    const v = cb(reader.data);
    return @as(u8, @truncate(v));
}

/// Vendor `read_bytes` (persistentcode.c:163–167). Reads `len` bytes
/// from the reader into `buf`.
pub fn read_bytes(reader: *mirrors.MpReader, buf: [*]u8, len: usize) void {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        buf[i] = read_byte(reader);
    }
}

/// Vendor `read_uint` (persistentcode.c:169–179). 7-bit continuation
/// varint decoder: each byte's high bit means "more"; the low 7 bits
/// accumulate big-endian (most-significant-group first).
pub fn read_uint(reader: *mirrors.MpReader) usize {
    var unum: usize = 0;
    while (true) {
        const b = read_byte(reader);
        unum = (unum << 7) | @as(usize, b & 0x7f);
        if ((b & 0x80) == 0) break;
    }
    return unum;
}

// ── prelude decoders (bc.h:104–162) ─────────────────────────────────

/// Internal return type for `decodePreludeSize`. The C side writes
/// into two locals; we return both as a pair.
pub const PreludeSize = struct {
    n_info: usize,
    n_cell: usize,
};

/// Vendor `MP_BC_PRELUDE_SIG_DECODE_INTO` (bc.h:104–125). Advances
/// `ip.*` past the consumed bytes and returns the 6 SIG fields.
///
/// First byte:        xSSSSEAA → S(4), E(1), A(2)
/// Continuation byte: xFSSKAED → extends S, E, F, A, K, D
/// After loop: S += 1.
pub fn decodePreludeSig(ip: *[*]const u8) mirrors.MpBytecodePrelude {
    var p = ip.*;
    var z: u8 = p[0];
    p += 1;
    var S: u32 = (@as(u32, z) >> 3) & 0xf;
    var E: u32 = (@as(u32, z) >> 2) & 0x1;
    var F: u32 = 0;
    var A: u32 = @as(u32, z) & 0x3;
    var K: u32 = 0;
    var D: u32 = 0;
    // n is the continuation-byte index. u5 (the shift-width type for u32)
    // would overflow `2 * n` once n ≥ 16, panicking in safe builds and
    // wrapping in release. Keep n in u32 and cast at the shift sites; the
    // @intCast(s) into u5 surfaces malformed-prelude inputs as a panic.
    var n: u32 = 0;
    while ((z & 0x80) != 0) : (n += 1) {
        z = p[0];
        p += 1;
        const s: u5 = @intCast(n);
        const s2: u5 = @intCast(2 * n);
        S |= (@as(u32, z) & 0x30) << s2;
        E |= (@as(u32, z) & 0x02) << s;
        F |= ((@as(u32, z) & 0x40) >> 6) << s;
        A |= (@as(u32, z) & 0x4) << s;
        K |= ((@as(u32, z) & 0x08) >> 3) << s;
        D |= (@as(u32, z) & 0x1) << s;
    }
    S += 1;
    ip.* = p;
    return .{
        .n_state = S,
        .n_exc_stack = E,
        .scope_flags = F,
        .n_pos_args = A,
        .n_kwonly_args = K,
        .n_def_pos_args = D,
    };
}

/// Vendor `MP_BC_PRELUDE_SIZE_DECODE_INTO` (bc.h:148–162). Advances
/// `ip.*` and returns `(n_info, n_cell)`.
///
/// Each byte: xIIIIIIC. C accumulates 1 bit per byte; I accumulates 6
/// bits per byte. High bit = continuation.
pub fn decodePreludeSize(ip: *[*]const u8) PreludeSize {
    var p = ip.*;
    var I: usize = 0;
    var C: usize = 0;
    // n stays in u32 so `6 * n` doesn't wrap inside the shift-width type
    // (u6 caps at 63, so n ≥ 11 would silently corrupt I). Cast at the
    // shift sites so malformed input panics rather than producing garbage.
    var n: u32 = 0;
    while (true) : (n += 1) {
        const z: u8 = p[0];
        p += 1;
        const s: u6 = @intCast(n);
        const s6: u6 = @intCast(6 * n);
        C |= (@as(usize, z) & 1) << s;
        I |= ((@as(usize, z) & 0x7e) >> 1) << s6;
        if ((z & 0x80) == 0) break;
    }
    ip.* = p;
    return .{ .n_info = I, .n_cell = C };
}

// ── load_qstr (persistentcode.c:181–203) ────────────────────────────
//
// Skips MICROPY_VFS_ROM branch entirely (gate is off in both arms).
// Decodes a length-prefixed qstr from the reader; low bit of length =
// "static qstr already in the table" optimization.
fn load_qstr(reader: *mirrors.MpReader) mirrors.QstrShort {
    var len = read_uint(reader);
    if ((len & 1) != 0) {
        // Static qstr — len is actually the qstr ID shifted left by 1.
        return @intCast(len >> 1);
    }
    len >>= 1;

    // Allocate, read, intern.
    const str: [*]u8 = @ptrCast(m_malloc(len));
    read_bytes(reader, str, len);
    _ = read_byte(reader); // discard null terminator
    const q = qstr_from_strn(str, len);
    m_free(str);
    return @intCast(q);
}

// ── load_obj (persistentcode.c:223–289) ──────────────────────────────
//
// Skips MICROPY_EMIT_INLINE_ASM/ENABLE_NATIVE_CODE (no FUN_TABLE) and
// MICROPY_VFS_ROM (no memory-mapped read). Dispatches on a one-byte
// type tag; STR/BYTES/INT/FLOAT/COMPLEX/TUPLE share a length-prefixed
// data section after the tag.
fn load_obj(reader: *mirrors.MpReader) Obj {
    const obj_type = read_byte(reader);
    if (obj_type == mirrors.MP_PERSISTENT_OBJ_NONE) {
        return MP_CONST_NONE;
    } else if (obj_type == mirrors.MP_PERSISTENT_OBJ_FALSE) {
        return MP_CONST_FALSE;
    } else if (obj_type == mirrors.MP_PERSISTENT_OBJ_TRUE) {
        return MP_CONST_TRUE;
    } else if (obj_type == mirrors.MP_PERSISTENT_OBJ_ELLIPSIS) {
        return @intFromPtr(&mp_const_ellipsis_obj);
    } else {
        const len = read_uint(reader);

        // Empty-bytes shortcut.
        if (len == 0 and obj_type == mirrors.MP_PERSISTENT_OBJ_BYTES) {
            _ = read_byte(reader); // skip null terminator
            return @intFromPtr(&mp_const_empty_bytes_obj);
        } else if (obj_type == mirrors.MP_PERSISTENT_OBJ_TUPLE) {
            const tuple_obj = mp_obj_new_tuple(len, null);
            const tuple = mirrors.MpObjTuple.fromObj(tuple_obj);
            const items = tuple.itemsPtr();
            var i: usize = 0;
            while (i < len) : (i += 1) {
                items[i] = load_obj(reader);
            }
            return tuple_obj;
        }

        // Read the object's data into a local vstr (RAM only — no ROM).
        var vstr: VstrLocal = undefined;
        vstr_init_len(&vstr, len);
        read_bytes(reader, @ptrCast(vstr.buf), len);

        // Construct the typed object.
        if (obj_type == mirrors.MP_PERSISTENT_OBJ_STR or
            obj_type == mirrors.MP_PERSISTENT_OBJ_BYTES)
        {
            _ = read_byte(reader); // skip null terminator
            if (obj_type == mirrors.MP_PERSISTENT_OBJ_STR) {
                return mp_obj_new_str_from_vstr(&vstr);
            } else {
                return mp_obj_new_bytes_from_vstr(&vstr);
            }
        } else if (obj_type == mirrors.MP_PERSISTENT_OBJ_INT) {
            return mp_parse_num_integer(@ptrCast(vstr.buf), vstr.len, 10, null);
        } else {
            // FLOAT or COMPLEX. mp_parse_num_float covers both via
            // the `allow_imag` flag.
            std.debug.assert(obj_type == mirrors.MP_PERSISTENT_OBJ_FLOAT or
                obj_type == mirrors.MP_PERSISTENT_OBJ_COMPLEX);
            return mp_parse_num_float(
                @ptrCast(vstr.buf),
                vstr.len,
                obj_type == mirrors.MP_PERSISTENT_OBJ_COMPLEX,
                null,
            );
        }
    }
}

// ── load_raw_code (persistentcode.c:291-462) ─────────────────────────
//
// Recursive bytecode-tree loader. Skips MICROPY_EMIT_INLINE_ASM /
// ENABLE_NATIVE_CODE / VFS_ROM / TRACK_BSS_RODATA arms (all off in
// both nano and full). Only MP_CODE_BYTECODE is supported; any other
// kind byte raises ValueError ("incompatible .mpy file"), matching the
// vendor static-assert branch at line 299-301.
//
// The `context` arg is unused in the bytecode-only path — vendor only
// reads it for native-code arms. Keep it in the signature so that the
// recursion stays a faithful 1:1 port (a future NX-N that re-enables
// native code can pass it down without re-plumbing).
fn load_raw_code(
    reader: *mirrors.MpReader,
    context: ?*mirrors.MpModuleContext,
) PyError!*mirrors.MpRawCode {
    // Load function kind and data length.
    const kind_len = read_uint(reader);
    const kind = (kind_len & 3) + @intFromEnum(mirrors.MpRawCodeKind.MP_CODE_BYTECODE);
    const has_children = (kind_len & 4) != 0;
    const fun_data_len = kind_len >> 3;

    if (kind != @intFromEnum(mirrors.MpRawCodeKind.MP_CODE_BYTECODE)) {
        try raiseIncompatibleMpy();
    }

    // Allocate and read bytecode. (No MICROPY_VFS_ROM path: free_len > 0
    // means non-ROM in mp_reader_new_mem semantics, and we always copy.)
    // errdefer: if a recursive load_raw_code below raises, we free
    // fun_data here to avoid the leak the code review flagged.
    const fun_data: [*]u8 = @ptrCast(m_malloc(fun_data_len));
    errdefer m_free(fun_data);
    read_bytes(reader, fun_data, fun_data_len);

    // Load children if any. (No `+ (kind == NATIVE_PY)` slot — native off.)
    var children: ?[*]?*mirrors.MpRawCode = null;
    if (has_children) {
        const n_children = read_uint(reader);
        // .mpy is attacker-controlled input via the bridge; guard the
        // sizeof(ptr) * n_children multiplication against overflow before
        // handing it to m_malloc. Vendor C has the same exposure.
        const buf_bytes = std.math.mul(usize, @sizeOf(?*mirrors.MpRawCode), n_children) catch {
            try raiseIncompatibleMpy();
            unreachable;
        };
        const buf = m_malloc(buf_bytes).?;
        const arr: [*]?*mirrors.MpRawCode = @ptrCast(@alignCast(buf));
        // errdefer: free the children pointer-array buffer if any
        // recursive load_raw_code below raises (closes the leak the
        // code review flagged; notes/37).
        errdefer m_free(@as(?*anyopaque, @ptrCast(arr)));
        var i: usize = 0;
        while (i < n_children) : (i += 1) {
            arr[i] = try load_raw_code(reader, context);
        }
        children = arr;
    }

    // Create raw_code and decode prelude SIG for scope_flags. The C
    // walks the prelude bytes in-place with a discarded `ip`; we do the
    // same via a slice cursor.
    const rc = mp_emit_glue_new_raw_code();
    var ip: [*]const u8 = fun_data;
    const sig = decodePreludeSig(&ip);

    mp_emit_glue_assign_bytecode(
        rc,
        fun_data,
        @ptrCast(children),
        @intCast(sig.scope_flags),
    );

    return rc;
}

// ── mp_module_context_alloc_tables (bc.h:296-310, static inline) ────
//
// Static-inline in vendor `bc.h`, so we port it instead of declaring
// extern. Under MICROPY_EMIT_BYTECODE_USES_QSTR_TABLE=1 (true for both
// nano and full), allocates one combined block holding the qstr table
// followed by the obj table, both via vendor `m_malloc`.
fn mp_module_context_alloc_tables(
    ctx: *mirrors.MpModuleContext,
    n_qstr: usize,
    n_obj: usize,
) void {
    const usize_bytes = @sizeOf(usize);
    const qstr_bytes = n_qstr * @sizeOf(mirrors.QstrShort);
    const nq = (qstr_bytes + usize_bytes - 1) / usize_bytes;
    const total_words = nq + n_obj;
    const mem = m_malloc(total_words * usize_bytes).?;
    ctx.constants.qstr_table_or_source_file = @intFromPtr(mem);
    const words: [*]usize = @ptrCast(@alignCast(mem));
    ctx.constants.obj_table = @ptrCast(words + nq);
}

// ── mp_raw_code_load (persistentcode.c:464-533) ──────────────────────
//
// Vendor's top-level entry. The vendor NLR-jump-callback that calls
// `reader.close` on exception (lines 466-467, 532) becomes an
// `errdefer` here: any Zig-level error path (via PyError after the
// NX-3 N1 conversion — `try raiseIncompatibleMpy()` propagates an
// error.PyRaise that gets caught at the C-ABI bridge) triggers cleanup
// before the bridge returns its zero sentinel. C callers poll
// pyerr.pending_exc after the call.
//
// Header validation:
//   header[0] = 'M'
//   header[1] = MPY_VERSION (currently 6)
//   header[2] = encoded arch + sub_version; we accept only ARCH_NONE
//              (native code disabled in both arms — sub_version is
//              irrelevant if arch == NONE per vendor line 474).
//   header[3] = small-int bits; reject larger than ours.
//
fn mpRawCodeLoadImpl(
    reader: *mirrors.MpReader,
    cm: *mirrors.MpCompiledModule,
) PyError!void {
    errdefer if (reader.close) |close| close(reader.data);

    var header: [4]u8 = undefined;
    read_bytes(reader, &header, 4);
    // arch = (header[2] >> 2) & 0x2F  (MPY_FEATURE_DECODE_ARCH).
    const arch: u8 = (header[2] >> 2) & 0x2F;
    if (header[0] != 'M' or
        header[1] != mirrors.MPY_VERSION or
        arch != 0 or // MP_NATIVE_ARCH_NONE
        header[3] > MP_SMALL_INT_BITS)
    {
        try raiseIncompatibleMpy();
    }
    // Arch != NONE is unreachable here (we just gated on arch == 0),
    // so the inner `MPY_FEATURE_ARCH_TEST` arm and the
    // `MPY_FEATURE_ARCH_FLAGS_TEST` read of arch_flags are dead under
    // our config. Vendor lines 478-505 collapse to nothing.

    const n_qstr = read_uint(reader);
    const n_obj = read_uint(reader);
    mp_module_context_alloc_tables(cm.context.?, n_qstr, n_obj);

    // Load qstrs.
    const ctx = cm.context.?;
    const qstr_table: [*]mirrors.QstrShort = @ptrFromInt(ctx.constants.qstr_table_or_source_file);
    var i: usize = 0;
    while (i < n_qstr) : (i += 1) {
        qstr_table[i] = load_qstr(reader);
    }

    // Load constant objects.
    i = 0;
    while (i < n_obj) : (i += 1) {
        ctx.constants.obj_table[i] = load_obj(reader);
    }

    // Load top-level module.
    cm.rc = try load_raw_code(reader, ctx);

    // Vendor calls nlr_pop_jump_callback(true) which invokes
    // reader.close. Mirror that explicitly.
    if (reader.close) |close| close(reader.data);
}

pub export fn mp_raw_code_load(
    reader: *mirrors.MpReader,
    cm: *mirrors.MpCompiledModule,
) callconv(.c) void {
    pyerr.bridge(void, mpRawCodeLoadImpl(reader, cm));
}

// ── mp_raw_code_load_mem (persistentcode.c:535-539) ──────────────────
//
// Thin wrapper: build an in-memory reader over `buf` and dispatch.
fn mpRawCodeLoadMemImpl(
    buf: [*]const u8,
    len: usize,
    cm: *mirrors.MpCompiledModule,
) PyError!void {
    var reader: mirrors.MpReader = undefined;
    mp_reader_new_mem(&reader, buf, len, 0);
    try mpRawCodeLoadImpl(&reader, cm);
}

pub export fn mp_raw_code_load_mem(
    buf: [*]const u8,
    len: usize,
    cm: *mirrors.MpCompiledModule,
) callconv(.c) void {
    pyerr.bridge(void, mpRawCodeLoadMemImpl(buf, len, cm));
}
