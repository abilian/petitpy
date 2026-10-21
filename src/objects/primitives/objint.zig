//! nanopython — full Zig port of py/objint.c (drops objint_shim).
//!
//! Nano config: LONGINT_IMPL=NONE, FLOAT=1, COMPLEX=0, OBJ_REPR=A.
//! Under LONGINT_NONE every "int" is a tagged small-int (no heap
//! mp_obj_int_t), so the bignum ctors all raise OverflowError. The
//! formatted-print branch that delegates to mp_obj_int_formatted_impl
//! is full-only (vendor objint_mpz.c).
//!
//! Live raises (8, all PyError-bridged):
//!   make_new TypeError / new_int_from_str_len OverflowError /
//!   new_int_from_ll / _ull / _uint / new_int small-int overflow /
//!   int_to_bytes ValueError(NULL on neg len) / OverflowError(buffer too small)

const std = @import("std");
const mp = @cImport({
    @cInclude("py/runtime.h");
    @cInclude("py/qstr.h");
});
const mirrors = @import("../../mp_mirrors.zig");
const types = @import("../../mp_type_roms.zig");
const pyerr = @import("../../pyerr.zig");
const PyError = pyerr.PyError;
const build_options = @import("build_options");

const Obj = mirrors.Obj;
const Qstr = usize;

// MP_SMALL_INT_MAX under REPR_A: 63 bits on 64-bit hosts, 31 bits on
// 32-bit hosts (wasm32). MP_SMALL_INT_POSITIVE_MASK = MAX value as usize.
const MP_SMALL_INT_BITS: comptime_int = if (@bitSizeOf(usize) >= 64) 63 else 31;
const MP_SMALL_INT_MAX: isize = (@as(isize, 1) << (MP_SMALL_INT_BITS - 1)) - 1;
const MP_SMALL_INT_POSITIVE_MASK: usize = @as(usize, @bitCast(MP_SMALL_INT_MAX));
// Sign bit of usize — 0x8000000000000000 on 64-bit, 0x80000000 on 32-bit.
const USIZE_SIGN_BIT: usize = @as(usize, 1) << (@bitSizeOf(usize) - 1);

// MP_SMALL_INT_FITS(n) — equivalent to "fits in MP_SMALL_INT_BITS signed bits".
inline fn smallIntFits(n: isize) bool {
    const u: usize = @bitCast(n);
    return ((u ^ (u << 1)) & USIZE_SIGN_BIT) == 0;
}

inline fn objIsSmallInt(o: Obj) bool {
    return (o & 1) != 0;
}

// mp_obj_is_str_or_bytes: qstr OR exact-type-str OR exact-type-bytes.
inline fn objIsStrOrBytes(o: Obj) bool {
    return (o & 7) == 2 or mirrors.isExactType(o, &mp_type_str) or mirrors.isExactType(o, &mp_type_bytes);
}

const MpBufferInfo = extern struct {
    buf: ?*anyopaque,
    len: usize,
    typecode: c_int,
};

// vstr_t layout (32 bytes): { size_t alloc; size_t len; char *buf; bool fixed_buf }.
const VstrT = extern struct {
    alloc: usize,
    len: usize,
    buf: [*c]u8,
    fixed_buf: bool,
};

extern const mp_type_type: anyopaque;
extern const mp_type_dict: anyopaque;
extern const mp_type_str: anyopaque;
extern const mp_type_bytes: anyopaque;
extern const mp_type_tuple: anyopaque;
extern const mp_type_list: anyopaque;
extern const mp_type_fun_builtin_var: anyopaque;
extern const mp_type_classmethod: anyopaque;
extern const mp_type_TypeError: anyopaque;
extern const mp_type_ValueError: anyopaque;
extern const mp_type_OverflowError: anyopaque;

extern fn mp_unary_op(op: c_int, arg: Obj) callconv(.c) Obj;
extern fn mp_binary_op(op: c_int, lhs: Obj, rhs: Obj) callconv(.c) Obj;
extern fn mp_parse_num_integer(str_: [*c]const u8, len: usize, base: c_int, lex: ?*anyopaque) callconv(.c) Obj;
extern fn mp_binary_set_int(val_sz: usize, big_endian: bool, dest: [*c]u8, val: usize) callconv(.c) void;
extern fn mp_obj_get_type_str(o: Obj) callconv(.c) [*:0]const u8;
extern fn mp_obj_get_int(arg: Obj) callconv(.c) isize;
extern fn mp_arg_check_num_sig(n_args: usize, n_kw: usize, sig: u32) callconv(.c) void;
extern fn mp_obj_str_get_data(self_in: Obj, len: *usize) callconv(.c) [*c]const u8;
extern fn mp_get_buffer(o: Obj, info: *MpBufferInfo, flags: c_uint) callconv(.c) bool;
extern fn mp_obj_new_exception_msg(t: *const anyopaque, msg: [*:0]const u8) callconv(.c) Obj;
extern fn mp_obj_new_exception_msg_varg(t: *const anyopaque, fmt: [*:0]const u8, ...) callconv(.c) Obj;
extern fn mp_obj_new_exception(t: *const anyopaque) callconv(.c) Obj;
extern fn mp_print_str(print: ?*const anyopaque, s: [*:0]const u8) callconv(.c) c_int;
extern fn mp_obj_new_int_from_uint(value: usize) callconv(.c) Obj;
extern fn mp_obj_new_bytes_from_vstr(vstr: *VstrT) callconv(.c) Obj;
extern fn vstr_init_len(vstr: *VstrT, len: usize) callconv(.c) void;
extern fn m_malloc(num_bytes: usize) callconv(.c) ?*anyopaque;
extern fn m_free(ptr: ?*anyopaque) callconv(.c) void;

// Under full + MPZ vendor provides these; under nano they're dead.
extern fn mp_obj_int_formatted_impl(
    buf_inout: *[*c]u8, buf_size_inout: *usize, fmt_size_out: *usize,
    self_in: Obj, base: c_int, prefix: [*c]const u8, base_char: u8, comma: u8,
) callconv(.c) [*c]u8;
extern fn mp_obj_int_from_bytes_impl(big_endian: bool, len: usize, buf: [*c]const u8) callconv(.c) Obj;
extern fn mp_obj_int_to_bytes_impl(self_in: Obj, big_endian: bool, len: usize, buf: [*c]u8) callconv(.c) bool;

// FLOAT=1 vendor exports (mp_obj_is_float, _get, _new_int_from_float).
// mp_obj_is_float is a macro: mp_obj_is_type(o, &mp_type_float).
extern const mp_type_float: anyopaque;
extern fn mp_obj_float_get(o: Obj) callconv(.c) f64;
inline fn objIsFloat(o: Obj) bool {
    return mirrors.isExactType(o, &mp_type_float);
}

// log2-floor table for digit-count bound.
const log_base2_floor = [_]u8{
    0, 1, 1, 2, 2, 2, 2, 3,
    3, 3, 3, 3, 3, 3, 3, 4,
};

// ── raise helpers ───────────────────────────────────────────────────
fn raiseTypeErrorIntConv(arg: Obj) PyError!void {
    _ = arg; // ERROR_REPORTING<=TERSE under nano → terse message
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_TypeError, "can't convert to int");
    return error.PyRaise;
}
fn raiseLongUnsupported() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_OverflowError, "long int not supported in this build");
    return error.PyRaise;
}
fn raiseSmallIntOverflow() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_OverflowError, "small int overflow");
    return error.PyRaise;
}
fn raiseValueErrorNull() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception(&mp_type_ValueError);
    return error.PyRaise;
}
fn raiseBufferTooSmall() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_OverflowError, "buffer too small");
    return error.PyRaise;
}

// ── make_new: int(x) / int(s, base) ────────────────────────────────
fn mpObjIntMakeNewImpl(_: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const Obj) PyError!Obj {
    // MP_OBJ_FUN_MAKE_SIG(0, 2, false) = (0<<17)|(2<<1) = 4
    mp_arg_check_num_sig(n_args, n_kw, 4);
    switch (n_args) {
        0 => return mirrors.newSmallInt(0),
        1 => {
            const o = mp_unary_op(mp.MP_UNARY_OP_INT_MAYBE, args[0]);
            if (pyerr.pending_exc != 0) return error.PyRaise;
            if (o != mirrors.OBJ_NULL) return o;
            var bufinfo = MpBufferInfo{ .buf = null, .len = 0, .typecode = 0 };
            if (mp_get_buffer(args[0], &bufinfo, 1)) { // MP_BUFFER_READ
                return mp_parse_num_integer(@ptrCast(bufinfo.buf), bufinfo.len, 10, null);
            }
            if (objIsFloat(args[0])) {
                const r = mp_obj_new_int_from_float(mp_obj_float_get(args[0]));
                if (pyerr.pending_exc != 0) return error.PyRaise;
                return r;
            }
            try raiseTypeErrorIntConv(args[0]);
            unreachable;
        },
        else => {
            var slen: usize = undefined;
            const s = mp_obj_str_get_data(args[0], &slen);
            return mp_parse_num_integer(s, slen, @intCast(mp_obj_get_int(args[1])), null);
        },
    }
}
export fn mp_obj_int_make_new(type_in: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, mpObjIntMakeNewImpl(type_in, n_args, n_kw, args));
}

// ── unary_op / binary_op (LONGINT_NONE: degenerate) ─────────────────
fn _nano_mp_obj_int_unary_op(_: c_int, _: Obj) callconv(.c) Obj {
    return mirrors.OBJ_NULL;
}
fn _nano_mp_obj_int_binary_op(op: c_int, lhs_in: Obj, rhs_in: Obj) callconv(.c) Obj {
    return mp_obj_int_binary_op_extra_cases(op, lhs_in, rhs_in);
}

fn mp_obj_int_binary_op_extra_cases(op: c_int, lhs_in: Obj, rhs_in: Obj) callconv(.c) Obj {
    if (rhs_in == mirrors.OBJ_FALSE) {
        return mp_binary_op(op, lhs_in, mirrors.newSmallInt(0));
    } else if (rhs_in == mirrors.OBJ_TRUE) {
        return mp_binary_op(op, lhs_in, mirrors.newSmallInt(1));
    } else if (op == mp.MP_BINARY_OP_MULTIPLY) {
        if (objIsStrOrBytes(rhs_in) or
            mirrors.isExactType(rhs_in, &mp_type_tuple) or
            mirrors.isExactType(rhs_in, &mp_type_list))
        {
            return mp_binary_op(op, rhs_in, lhs_in);
        }
    }
    return mirrors.OBJ_NULL;
}

// ── LONGINT_NONE big-int ctors ──────────────────────────────────────
fn rawRaiseLongUnsupp() PyError!Obj {
    try raiseLongUnsupported();
    unreachable;
}
fn _nano_mp_obj_new_int_from_str_len(_: *[*c]const u8, _: usize, _: bool, _: c_uint) callconv(.c) Obj {
    return pyerr.bridge(Obj, rawRaiseLongUnsupp());
}

fn rawRaiseSmallIntOv() PyError!Obj {
    try raiseSmallIntOverflow();
    unreachable;
}
fn _nano_mp_obj_new_int_from_ll(_: c_longlong) callconv(.c) Obj {
    return pyerr.bridge(Obj, rawRaiseSmallIntOv());
}
fn _nano_mp_obj_new_int_from_ull(_: c_ulonglong) callconv(.c) Obj {
    return pyerr.bridge(Obj, rawRaiseSmallIntOv());
}

fn newIntFromUintImpl(value: usize) PyError!Obj {
    if ((value & ~MP_SMALL_INT_POSITIVE_MASK) == 0) {
        return mirrors.newSmallInt(@bitCast(value));
    }
    try raiseSmallIntOverflow();
    unreachable;
}
fn _nano_mp_obj_new_int_from_uint(value: usize) callconv(.c) Obj {
    return pyerr.bridge(Obj, newIntFromUintImpl(value));
}

fn newIntImpl(value: isize) PyError!Obj {
    if (smallIntFits(value)) return mirrors.newSmallInt(value);
    try raiseSmallIntOverflow();
    unreachable;
}
fn _nano_mp_obj_new_int(value: isize) callconv(.c) Obj {
    return pyerr.bridge(Obj, newIntImpl(value));
}

fn _nano_mp_obj_int_get_truncated(self_in: Obj) callconv(.c) isize {
    return mirrors.smallIntValue(self_in);
}
fn _nano_mp_obj_int_get_checked(self_in: Obj) callconv(.c) isize {
    return mirrors.smallIntValue(self_in);
}
fn _nano_mp_obj_int_sign(self_in: Obj) callconv(.c) c_int {
    const val = mp_obj_get_int(self_in);
    if (val < 0) return -1;
    if (val > 0) return 1;
    return 0;
}

// ── format_size / formatted ────────────────────────────────────────
fn mp_int_format_size(num_bits: usize, base: c_int, prefix: [*c]const u8, comma: u8) callconv(.c) usize {
    std.debug.assert(2 <= base and base <= 16);
    const num_digits = num_bits / log_base2_floor[@as(usize, @intCast(base - 1))] + 1;
    const num_commas: usize = if (comma != 0)
        (if (base == 10) num_digits / 3 else num_digits / 4)
    else
        0;
    const prefix_len: usize = if (prefix != null) std.mem.span(@as([*:0]const u8, @ptrCast(prefix))).len else 0;
    return num_digits + num_commas + prefix_len + 2;
}

fn mp_obj_int_formatted(buf_inout: *[*c]u8, buf_size_inout: *usize, fmt_size_out: *usize, self_in: Obj, base: c_int, prefix: [*c]const u8, base_char: u8, comma: u8) callconv(.c) [*c]u8 {
    if (build_options.is_full and !objIsSmallInt(self_in)) {
        return mp_obj_int_formatted_impl(buf_inout, buf_size_inout, fmt_size_out, self_in, base, prefix, base_char, comma);
    }
    var num: isize = mirrors.smallIntValue(self_in);

    var sign: u8 = 0;
    if (num < 0) {
        const u: usize = @bitCast(num);
        num = @bitCast(0 -% u);
        sign = '-';
    }

    const n_comma: usize = if (base == 10) 3 else 4;
    const needed_size = mp_int_format_size(@sizeOf(isize) * 8, base, prefix, comma);
    if (needed_size > buf_size_inout.*) {
        buf_inout.* = @ptrCast(@alignCast(m_malloc(needed_size).?));
        buf_size_inout.* = needed_size;
    }
    const str: [*c]u8 = buf_inout.*;
    var b: [*c]u8 = str + needed_size;
    b -= 1;
    b[0] = 0;
    var last_comma: [*c]u8 = b;

    var unum: usize = @bitCast(num);

    if (unum == 0) {
        b -= 1;
        b[0] = '0';
    } else {
        while (true) {
            const c_val: u32 = @intCast(unum % @as(usize, @intCast(base)));
            unum = unum / @as(usize, @intCast(base));
            const ch: u8 = if (c_val >= 10) @intCast(c_val + base_char - 10) else @intCast(c_val + '0');
            b -= 1;
            b[0] = ch;
            if (comma != 0 and unum != 0 and @intFromPtr(b) > @intFromPtr(str) and (@intFromPtr(last_comma) - @intFromPtr(b)) == n_comma) {
                b -= 1;
                b[0] = comma;
                last_comma = b;
            }
            if (!(@intFromPtr(b) > @intFromPtr(str) and unum != 0)) break;
        }
    }
    if (prefix != null) {
        const prefix_len = std.mem.span(@as([*:0]const u8, @ptrCast(prefix))).len;
        const p_start = b - prefix_len;
        if (@intFromPtr(p_start) > @intFromPtr(str)) {
            b = p_start;
            var src = prefix;
            var dst = p_start;
            while (src[0] != 0) {
                dst[0] = src[0];
                dst += 1;
                src += 1;
            }
        }
    }
    if (sign != 0 and @intFromPtr(b) > @intFromPtr(str)) {
        b -= 1;
        b[0] = sign;
    }
    fmt_size_out.* = (@intFromPtr(buf_inout.*) + needed_size) - @intFromPtr(b) - 1;
    return b;
}

fn mp_obj_int_print(print: ?*const anyopaque, self_in: Obj, _: c_int) callconv(.c) void {
    var stack_buf: [@sizeOf(isize) * 4]u8 = undefined;
    var buf: [*c]u8 = &stack_buf;
    var buf_size: usize = stack_buf.len;
    var fmt_size: usize = undefined;
    const str = mp_obj_int_formatted(&buf, &buf_size, &fmt_size, self_in, 10, null, 0, 0);
    _ = mp_print_str(print, @ptrCast(str));
    if (buf != @as([*c]u8, &stack_buf)) {
        m_free(buf);
    }
}

// ── int.from_bytes(class, buf[, byteorder]) ─────────────────────────
export fn npy_iv_method_from_bytes(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    var bufinfo = MpBufferInfo{ .buf = null, .len = 0, .typecode = 0 };
    _ = mp_get_buffer(args[1], &bufinfo, 1 | 4); // READ | RAISE_IF_UNSUPPORTED
    const qstr_little = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_little));
    var buf: [*c]const u8 = @ptrCast(bufinfo.buf);
    const blen = bufinfo.len;
    var delta: isize = 1;
    const big_endian = n_args < 3 or args[2] != qstr_little;
    if (!big_endian) {
        buf += blen - 1;
        delta = -1;
    }
    var value: usize = 0;
    var len = blen;
    while (len != 0) : (len -= 1) {
        if (build_options.is_full and value > (@as(usize, @bitCast(MP_SMALL_INT_MAX)) >> 8)) {
            return mp_obj_int_from_bytes_impl(big_endian, blen, @ptrCast(bufinfo.buf));
        }
        value = (value << 8) | buf[0];
        buf = if (delta > 0) buf + 1 else buf - 1;
    }
    return mp_obj_new_int_from_uint(value);
}

// ── int.to_bytes(self, length[, byteorder]) ─────────────────────────
fn intToBytesImpl(n_args: usize, args: [*c]const Obj) PyError!Obj {
    const dlen_signed: isize = if (n_args < 2) 1 else mp_obj_get_int(args[1]);
    if (dlen_signed < 0) {
        try raiseValueErrorNull();
        unreachable;
    }
    const dlen: usize = @intCast(dlen_signed);
    const qstr_little = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_little));
    const big_endian = n_args < 3 or args[2] != qstr_little;

    var vstr: VstrT = undefined;
    vstr_init_len(&vstr, dlen);
    const data = vstr.buf;

    var overflow = false;
    if (build_options.is_full and !objIsSmallInt(args[0])) {
        overflow = !mp_obj_int_to_bytes_impl(args[0], big_endian, dlen, data);
    } else {
        const val: isize = mirrors.smallIntValue(args[0]);
        var slen: isize = 0;
        if (val > 0) {
            const bits = @sizeOf(isize) * 8;
            slen = @divTrunc(@as(isize, @intCast(bits)) - @as(isize, @intCast(@clz(@as(usize, @bitCast(val))))) + 7, 8);
        } else if (val < -1) {
            const bits = @sizeOf(isize) * 8;
            slen = @divTrunc(@as(isize, @intCast(bits)) - @as(isize, @intCast(@clz(~@as(usize, @bitCast(val))))) + 8, 8);
        } else {
            slen = -val;
        }
        if (slen <= dlen_signed) {
            @memset(data[0..dlen], if (val < 0) @as(u8, 0xFF) else @as(u8, 0x00));
            const offset: usize = if (big_endian) dlen - @as(usize, @intCast(slen)) else 0;
            mp_binary_set_int(@intCast(slen), big_endian, data + offset, @bitCast(val));
        } else {
            overflow = true;
        }
    }

    if (overflow) {
        try raiseBufferTooSmall();
        unreachable;
    }
    return mp_obj_new_bytes_from_vstr(&vstr);
}
export fn npy_iv_method_to_bytes(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, intToBytesImpl(n_args, args));
}

// ── mp_obj_new_int_from_float ───────────────────────────────────────
fn mp_obj_new_int_from_float(val: f64) callconv(.c) Obj {
    if (std.math.isNan(val)) {
        pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_ValueError, "can't convert NaN to int");
        return 0;
    }
    if (std.math.isInf(val)) {
        pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_OverflowError, "can't convert inf to int");
        return 0;
    }
    const i: isize = @intFromFloat(val);
    return mirrors.newSmallInt(i);
}

// ── ROM: methods + locals_dict + mp_type_int ────────────────────────
pub export const int_from_bytes_fun_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(2, 4, false),
    .fun = @ptrCast(&npy_iv_method_from_bytes),
};
pub export const int_from_bytes_obj: mirrors.MpObjStaticClassMethod = .{
    .base = .{ .type = &mp_type_classmethod },
    .fun = @ptrCast(&int_from_bytes_fun_obj),
};
pub export const int_to_bytes_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(1, 4, false),
    .fun = @ptrCast(&npy_iv_method_to_bytes),
};

const RomEntry = extern struct {
    key: Obj,
    value: *const anyopaque,
};
const int_locals_dict_table = [_]RomEntry{
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_from_bytes)), .value = &int_from_bytes_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_to_bytes)), .value = &int_to_bytes_obj },
};
pub export const int_locals_dict: mirrors.MpObjDict = .{
    .base = .{ .type = &mp_type_dict },
    .map = .{
        .bits = .{ .all_keys_are_qstrs = 1, .is_fixed = 1, .is_ordered = 1, .used = int_locals_dict_table.len },
        .alloc = int_locals_dict_table.len,
        .table = @ptrCast(@constCast(&int_locals_dict_table)),
    },
};

// mp_type_int: slot order — make_new=1, print=2, unary_op=3, binary_op=4, locals_dict=5
// Nano-only export: under full, vendor py/objint.c provides mp_type_int
// (different in-memory layout — vendor's macro packs slots tightly).
const _nano_mp_type_int: types.MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = 0x0000,
        .name = mp.MP_QSTR_int,
        .slot_index_make_new = 1,
        .slot_index_print = 2,
        .slot_index_call = 0,
        .slot_index_unary_op = 3,
        .slot_index_binary_op = 4,
        .slot_index_attr = 0,
        .slot_index_subscr = 0,
        .slot_index_iter = 0,
        .slot_index_buffer = 0,
        .slot_index_protocol = 0,
        .slot_index_parent = 0,
        .slot_index_locals_dict = 5,
    },
    .slots = if (build_options.is_full) .{
        // Full: vendor objint_mpz.c provides unary_op + binary_op.
        @ptrCast(&mp_obj_int_make_new),
        @ptrCast(&mp_obj_int_print),
        @ptrCast(&mp_obj_int_unary_op),
        @ptrCast(&mp_obj_int_binary_op),
        @ptrCast(&int_locals_dict),
        null, null, null, null, null, null,
    } else .{
        // Nano: our stubs from _nano_X (exported below).
        @ptrCast(&mp_obj_int_make_new),
        @ptrCast(&mp_obj_int_print),
        @ptrCast(&_nano_mp_obj_int_unary_op),
        @ptrCast(&_nano_mp_obj_int_binary_op),
        @ptrCast(&int_locals_dict),
        null, null, null, null, null, null,
    },
};

// Vendor objint_mpz.c declares these under full (LONGINT_MPZ).
extern fn mp_obj_int_unary_op(op: c_int, o_in: Obj) callconv(.c) Obj;
extern fn mp_obj_int_binary_op(op: c_int, lhs: Obj, rhs: Obj) callconv(.c) Obj;

comptime {
    _ = &mp_obj_int_make_new;
    _ = &npy_iv_method_from_bytes;
    _ = &npy_iv_method_to_bytes;
    if (!build_options.is_full) {
        _ = &int_locals_dict;
    }
    // Print/format/float-conversion + the mp_type_int singleton itself:
    // vendor objint_longlong.c (added via build.zig carveout for
    // !is_full and !longint_none) provides mp_type_int. Vendor objint.c
    // (also in that carveout) provides mp_obj_int_print, _formatted,
    // _format_size, mp_obj_new_int_from_float, etc. Skip the Zig
    // exports under LONGLONG so vendor wins; keep them under NONE
    // where vendor's objint.c is strangled.
    if (build_options.longint_none) {
        _ = &_nano_mp_type_int;
        _ = &mp_int_format_size;
        _ = &mp_obj_int_formatted;
        _ = &mp_obj_int_print;
        _ = &mp_obj_new_int_from_float;
        @export(&_nano_mp_type_int, .{ .name = "mp_type_int" });
        @export(&mp_int_format_size, .{ .name = "mp_int_format_size" });
        @export(&mp_obj_int_formatted, .{ .name = "mp_obj_int_formatted" });
        @export(&mp_obj_int_print, .{ .name = "mp_obj_int_print" });
        @export(&mp_obj_new_int_from_float, .{ .name = "mp_obj_new_int_from_float" });
    }
    // The int ctors + numeric op overrides are stub-only under
    // LONGINT_NONE. Under LONGLONG (wasm32-nano) vendor py/objint_longlong.c
    // provides the real bodies that handle heap mp_obj_int_t — those
    // must take precedence (its symbols win because our Zig exports
    // are skipped here). Under MPZ (full) vendor py/objint_mpz.c
    // does the same.
    //
    // `mp_obj_int_binary_op_extra_cases` IS provided by objint_longlong.c
    // (and objint_mpz.c) — skip the Zig stub when those arms are live.
    if (build_options.longint_none) {
        _ = &mp_obj_int_binary_op_extra_cases;
        @export(&mp_obj_int_binary_op_extra_cases, .{ .name = "mp_obj_int_binary_op_extra_cases" });
        @export(&_nano_mp_obj_int_unary_op, .{ .name = "mp_obj_int_unary_op" });
        @export(&_nano_mp_obj_int_binary_op, .{ .name = "mp_obj_int_binary_op" });
        @export(&_nano_mp_obj_new_int_from_str_len, .{ .name = "mp_obj_new_int_from_str_len" });
        @export(&_nano_mp_obj_new_int_from_ll, .{ .name = "mp_obj_new_int_from_ll" });
        @export(&_nano_mp_obj_new_int_from_ull, .{ .name = "mp_obj_new_int_from_ull" });
        @export(&_nano_mp_obj_new_int_from_uint, .{ .name = "mp_obj_new_int_from_uint" });
        @export(&_nano_mp_obj_new_int, .{ .name = "mp_obj_new_int" });
        @export(&_nano_mp_obj_int_get_truncated, .{ .name = "mp_obj_int_get_truncated" });
        @export(&_nano_mp_obj_int_get_checked, .{ .name = "mp_obj_int_get_checked" });
        @export(&_nano_mp_obj_int_sign, .{ .name = "mp_obj_int_sign" });
    }
}
