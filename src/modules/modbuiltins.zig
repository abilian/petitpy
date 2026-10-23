//! petitpy — Zig partial port of py/modbuiltins.c.
//!
//! Ports the simple raise-path builtin wrappers — 1-line
//! delegations to mp_unary_op / mp_binary_op / mp_obj_str_format. Each
//! eliminates a C frame from raise paths so at B2 PyError can propagate
//! purely through Zig `try` chains.
//!
//! Cluster A (this seam): abs, bin, divmod, hash, hex, oct. 6 fns.
//!
//! Under nano MICROPY_PY_BUILTINS_STR_OP_MODULO=1 → hex/oct use the
//! binary_op MODULO format path (not str.format).

const std = @import("std");
const build_options = @import("build_options");

const mirrors = @import("../mp_mirrors.zig");
const argcheck = @import("../runtime/argcheck.zig");
/// MicroPython enum/flag constants via direct @cImport.
const mp = @cImport({
    @cInclude("py/obj.h");
    @cInclude("py/runtime.h");
});

const Obj = mirrors.Obj;
const state = @import("../runtime/mpstate.zig");

// ── Vendor extern helpers (used to live as npy_modb_* shim fns) ──────

extern fn mp_obj_str_get_data(o: Obj, len_out: *usize) callconv(.c) [*]const u8;
extern fn mp_obj_str_get_qstr(o: Obj) callconv(.c) usize;
extern fn mp_obj_new_exception_msg(exc_type: *const anyopaque, msg: [*:0]const u8) callconv(.c) Obj;
extern fn mp_obj_exception_make_new(exc_type: *const anyopaque, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj;
extern fn mp_obj_new_bound_meth(meth: Obj, self: Obj) callconv(.c) Obj;
extern fn mp_obj_new_tuple(n: usize, items: [*c]const Obj) callconv(.c) Obj;
extern fn mp_obj_list_append(list: Obj, v: Obj) callconv(.c) Obj;
extern fn mp_obj_get_type(o: Obj) callconv(.c) *const anyopaque;
extern fn mp_globals_get() callconv(.c) ?*anyopaque;
extern fn mp_locals_get() callconv(.c) ?*anyopaque;
extern fn mp_locals_set(d: ?*anyopaque) callconv(.c) void;
extern fn qstr_from_strn(s: [*]const u8, n: usize) callconv(.c) usize;
extern const mp_plat_print: anyopaque;
extern const mp_sys_stdout_print: anyopaque;
extern fn mp_print_str(printer: *const anyopaque, s: [*:0]const u8) callconv(.c) c_int;
extern fn mp_print_strn(printer: *const anyopaque, s: [*]const u8, len: usize, flags: c_uint, fill: u8, width: c_int) callconv(.c) c_int;
extern fn mp_obj_print_helper(printer: *const anyopaque, o: Obj, kind: c_int) callconv(.c) void;
extern fn vstr_init_print(v: *anyopaque, sz: usize, print: *anyopaque) callconv(.c) void;
extern fn mp_map_lookup(map: *anyopaque, key: Obj, mode: c_int) callconv(.c) ?*anyopaque;

// vstr_t + mp_print_t buffers for repr_via_vstr. vstr_t is 32B; the
// mp_print_t we hand to vstr_init_print is 16B.
const PrintT = extern struct {
    data: ?*anyopaque,
    print_strn: *const anyopaque,
};

inline fn pythonPrinter() *const anyopaque {
    return if (comptime build_options.is_full) &mp_sys_stdout_print else &mp_plat_print;
}

// MP_QSTR_ marks the first generated qstr id (vendor's "0 + 1" convention).
extern fn npy_qstr_total() callconv(.c) usize;

extern fn mp_unary_op(op: c_int, arg: Obj) callconv(.c) Obj;
extern fn mp_binary_op(op: c_int, lhs: Obj, rhs: Obj) callconv(.c) Obj;
extern fn mp_obj_str_format(n_args: usize, args: [*c]const Obj, kwargs: ?*anyopaque) callconv(.c) Obj;

export fn mp_builtin_abs(o_in: Obj) callconv(.c) Obj {
    return mp_unary_op(mp.MP_UNARY_OP_ABS, o_in);
}

export fn mp_builtin_hash(o_in: Obj) callconv(.c) Obj {
    return mp_unary_op(mp.MP_UNARY_OP_HASH, o_in);
}

export fn mp_builtin_divmod(o1_in: Obj, o2_in: Obj) callconv(.c) Obj {
    return mp_binary_op(mp.MP_BINARY_OP_DIVMOD, o1_in, o2_in);
}

export fn mp_builtin_bin(o_in: Obj) callconv(.c) Obj {
    // MP_QSTR__brace_open__colon__hash_b_brace_close_ = "{:#b}" (in qstrtable).
    var args: [2]Obj = .{ mirrors.objFromQstr(@as(usize, mp.MP_QSTR__brace_open__colon__hash_b_brace_close_)), o_in };
    return mp_obj_str_format(args.len, &args, null);
}

// format(value, format_spec=''): "{:<spec>}".format(value), as bin() does
// with "{:#b}". CPython calls type(value).__format__; str.format covers the
// built-in types the same way.
export fn mp_builtin_format(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    const open = mp_obj_new_str_via_qstr("{:", 2);
    const spec = if (n_args > 1) mp_binary_op(mp.MP_BINARY_OP_ADD, open, args[1]) else open;
    if (pyerr.pending_exc != 0) return 0;
    var fmt_args: [2]Obj = .{ mp_binary_op(mp.MP_BINARY_OP_ADD, spec, mp_obj_new_str_via_qstr("}", 1)), args[0] };
    return mp_obj_str_format(fmt_args.len, &fmt_args, null);
}

export fn mp_builtin_hex(o_in: Obj) callconv(.c) Obj {
    // hex/oct format qstrs aren't generated → intern at runtime.
    var args: [2]Obj = .{ mirrors.objFromQstr(@as(usize, qstr_from_strn("{:#x}", 5))), o_in };
    return mp_obj_str_format(args.len, &args, null);
}

export fn mp_builtin_oct(o_in: Obj) callconv(.c) Obj {
    var args: [2]Obj = .{ mirrors.objFromQstr(@as(usize, qstr_from_strn("{:#o}", 5))), o_in };
    return mp_obj_str_format(args.len, &args, null);
}

// ── W6 #4 cluster B: callable / chr / ord / pow / globals / locals ──
//
// 6 more small builtins. 3 explicit raises (chr range, ord len, pow 3-arg).
// Under nano UNICODE=0, POW3=0 — branch simplifications applied.

const pyerr = @import("../pyerr.zig");
const PyError = pyerr.PyError;

extern fn mp_obj_get_int(arg: Obj) callconv(.c) isize;
extern fn mp_obj_get_float(arg: Obj) callconv(.c) f64;
extern fn mp_obj_new_float(val: f64) callconv(.c) Obj;
extern fn mp_obj_new_int_from_float(val: f64) callconv(.c) Obj;
extern fn nearbyint(val: f64) callconv(.c) f64;
extern fn mp_obj_new_str_via_qstr(data: [*]const u8, len: usize) callconv(.c) Obj;
// Cleanup pass: retire pure pass-through npy_modb_* wrappers.
extern fn mp_obj_is_callable(o: Obj) callconv(.c) bool;
extern fn mp_obj_new_int(v: isize) callconv(.c) Obj;
extern fn mp_obj_new_dict(n: usize) callconv(.c) Obj;
extern fn mp_obj_new_list(n: usize, items: [*c]const Obj) callconv(.c) Obj;

fn raiseChrRange() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_ValueError, "chr() arg not in range(0x110000)");
    return error.PyRaise;
}
fn raiseOrdExpectsChar() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_TypeError, "ord expects a character");
    return error.PyRaise;
}
// raisePow3NotSupp retired — pow(b, e, m) is now implemented in
// Zig via mp_binary_op (square-and-multiply).

export fn mp_builtin_callable(o_in: Obj) callconv(.c) Obj {
    return if (mp_obj_is_callable(o_in)) mirrors.OBJ_TRUE else mirrors.OBJ_FALSE;
}

fn chrImpl(o_in: Obj) PyError!Obj {
    // CPython + MP's UNICODE-enabled chr(): full code-point range up
    // to U+10FFFF, returned as a UTF-8-encoded string. MICROPY_PY_
    // BUILTINS_STR_UNICODE=1 in mpconfigport.h, so this matches our
    // config; the previous 0-255 cap was the non-UNICODE branch.
    const ord_val = mp_obj_get_int(o_in);
    if (ord_val < 0 or ord_val >= 0x110000) {
        try raiseChrRange();
        unreachable;
    }
    var buf: [4]u8 = undefined;
    const c: u32 = @intCast(ord_val);
    var len: usize = undefined;
    if (c < 0x80) {
        buf[0] = @intCast(c);
        len = 1;
    } else if (c < 0x800) {
        buf[0] = @intCast(0xC0 | (c >> 6));
        buf[1] = @intCast(0x80 | (c & 0x3F));
        len = 2;
    } else if (c < 0x10000) {
        buf[0] = @intCast(0xE0 | (c >> 12));
        buf[1] = @intCast(0x80 | ((c >> 6) & 0x3F));
        buf[2] = @intCast(0x80 | (c & 0x3F));
        len = 3;
    } else {
        buf[0] = @intCast(0xF0 | (c >> 18));
        buf[1] = @intCast(0x80 | ((c >> 12) & 0x3F));
        buf[2] = @intCast(0x80 | ((c >> 6) & 0x3F));
        buf[3] = @intCast(0x80 | (c & 0x3F));
        len = 4;
    }
    return mp_obj_new_str_via_qstr(&buf, len);
}

export fn mp_builtin_chr(o_in: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, chrImpl(o_in));
}

fn ordImpl(o_in: Obj) PyError!Obj {
    var len: usize = undefined;
    const data = mp_obj_str_get_data(o_in, &len);
    // Under full + MICROPY_PY_BUILTINS_STR_UNICODE: str (not bytes) is
    // UTF-8 encoded, so a 1-char str may span multiple bytes. Compute
    // utf8_charlen and use utf8_get_char to get the codepoint. Vendor
    // modbuiltins.c:340-355.
    // vendor mp_obj_is_str: a qstr, or an object of exact type str.
    if (build_options.str_unicode and (mirrors.isQstr(o_in) or mirrors.isExactType(o_in, &mp_type_str))) {
        len = utf8_charlen(data, len);
        if (len == 1) {
            return mirrors.newSmallInt(@as(intptr_t_zig, @intCast(utf8_get_char(data))));
        }
    } else if (len == 1) {
        return mirrors.newSmallInt(@as(intptr_t_zig, @intCast(data[0])));
    }
    try raiseOrdExpectsChar();
    unreachable;
}

extern fn utf8_charlen(s: [*]const u8, len: usize) callconv(.c) usize;
extern fn utf8_get_char(s: [*]const u8) callconv(.c) u32;

const intptr_t_zig = isize;

export fn mp_builtin_ord(o_in: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, ordImpl(o_in));
}

extern fn mp_obj_int_pow3(base: Obj, exponent: Obj, modulus: Obj) callconv(.c) Obj;

fn powImpl(n_args: usize, args: [*c]const Obj) PyError!Obj {
    if (n_args == 2) {
        return mp_binary_op(mp.MP_BINARY_OP_POWER, args[0], args[1]);
    }
    if (comptime build_options.is_full) {
        // POW3=1 + LONGINT_MPZ: use vendor mpz modular exponentiation.
        // Vendor modbuiltins.c:376. Wrapped through the NLR trampoline
        // per ADR 013 so vendor MPZ raises (divide-by-zero, type-check)
        // unwind to a try/except rather than exit(1)ing.
        const nlr_trampoline = @import("../runtime/nlr_trampoline.zig");
        const r = nlr_trampoline.callPow3(&mp_obj_int_pow3, args[0], args[1], args[2]);
        if (pyerr.pending_exc != 0) return error.PyRaise;
        return r;
    }
    // Nano: implement modular exponentiation in Zig via mp_binary_op.
    // Operates on whatever int representation the runtime currently uses
    // (smallint everywhere; heap mp_obj_int_t under LONGLONG on wasm32).
    // Algorithm: square-and-multiply. CPython requires exp >= 0 for the
    // 3-arg int form (a negative exp would need modular inverse).
    const base_in = args[0];
    const exp_in = args[1];
    const mod_in = args[2];
    const zero = mirrors.newSmallInt(0);
    const one = mirrors.newSmallInt(1);
    if (mp_obj_is_true(mp_binary_op(mp.MP_BINARY_OP_EQUAL, mod_in, zero))) {
        pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_ValueError, "pow() 3rd arg cannot be 0");
        return error.PyRaise;
    }
    if (mp_obj_is_true(mp_binary_op(mp.MP_BINARY_OP_LESS, exp_in, zero))) {
        pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_ValueError, "pow() with negative exp + modulus not supported");
        return error.PyRaise;
    }
    var result = one;
    var base = mp_binary_op(mp.MP_BINARY_OP_MODULO, base_in, mod_in);
    var exp = exp_in;
    while (mp_obj_is_true(mp_binary_op(mp.MP_BINARY_OP_MORE, exp, zero))) {
        if (mp_obj_is_true(mp_binary_op(mp.MP_BINARY_OP_AND, exp, one))) {
            result = mp_binary_op(mp.MP_BINARY_OP_MODULO, mp_binary_op(mp.MP_BINARY_OP_MULTIPLY, result, base), mod_in);
        }
        exp = mp_binary_op(mp.MP_BINARY_OP_RSHIFT, exp, one);
        base = mp_binary_op(mp.MP_BINARY_OP_MODULO, mp_binary_op(mp.MP_BINARY_OP_MULTIPLY, base, base), mod_in);
    }
    return result;
}

export fn mp_builtin_pow(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, powImpl(n_args, args));
}

export fn mp_builtin_globals() callconv(.c) Obj {
    return @intFromPtr(mp_globals_get());
}

export fn mp_builtin_locals() callconv(.c) Obj {
    return @intFromPtr(mp_locals_get());
}

// ── W6 #4 cluster C: iter / next / all / any / repr / __repl_print__ ──
//
// 6 more builtins. 1 raise (next StopIteration). Under nano NEXT2=0
// (simpler 1-arg next form), CAN_OVERRIDE_BUILTINS=0 (the `_` setting in
// __repl_print__ is dead).

extern fn mp_getiter(o: Obj, iter_buf: ?*anyopaque) callconv(.c) Obj;
extern fn mp_iternext(iter: Obj) callconv(.c) Obj;
extern fn mp_iternext_allow_raise(iter: Obj) callconv(.c) Obj;
extern fn mp_obj_is_true(o: Obj) callconv(.c) bool;

fn raiseStopIter() PyError!void {
    // Mirrors mp_raise_StopIteration: if MP_STATE_THREAD(stop_iteration_arg)
    // is NULL, construct StopIteration() (0 args); else StopIteration(arg).
    const arg: Obj = state.threadState().stop_iteration_arg;
    if (arg == mirrors.OBJ_NULL) {
        pyerr.pending_exc = mp_obj_new_exception(&mp_type_StopIteration);
    } else {
        pyerr.pending_exc = mp_obj_exception_make_new(&mp_type_StopIteration, 1, 0, @ptrCast(&arg));
    }
    return error.PyRaise;
}

export fn mp_builtin_iter(o_in: Obj) callconv(.c) Obj {
    return mp_getiter(o_in, null);
}

fn nextImpl(o: Obj) PyError!Obj {
    const ret = mp_iternext_allow_raise(o);
    // B2 polled-sentinel: distinguish raise (pending_exc set) from
    // STOP_ITERATION sentinel return.
    if (pyerr.pending_exc != 0) return error.PyRaise;
    if (ret == mirrors.OBJ_STOP_ITERATION) {
        try raiseStopIter();
        unreachable;
    }
    return ret;
}

// NEXT2 form: next(it) or next(it, default).
fn next2Impl(n_args: usize, args: [*c]const Obj) PyError!Obj {
    if (n_args == 1) return nextImpl(args[0]);
    const ret = mp_iternext(args[0]);
    if (pyerr.pending_exc != 0) return error.PyRaise;
    return if (ret == mirrors.OBJ_STOP_ITERATION) args[1] else ret;
}

export fn mp_builtin_next(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, next2Impl(n_args, args));
}

const ITER_BUF_SIZE: usize = @sizeOf(mirrors.MpObjIterBuf);

export fn mp_builtin_all(o_in: Obj) callconv(.c) Obj {
    var iter_buf: [64]u8 align(16) = undefined;
    std.debug.assert(ITER_BUF_SIZE <= iter_buf.len);
    const iterable = mp_getiter(o_in, &iter_buf);
    while (true) {
        const item = mp_iternext(iterable);
        if (item == mirrors.OBJ_STOP_ITERATION) break;
        if (!mp_obj_is_true(item)) return mirrors.OBJ_FALSE;
    }
    return mirrors.OBJ_TRUE;
}

export fn mp_builtin_any(o_in: Obj) callconv(.c) Obj {
    var iter_buf: [64]u8 align(16) = undefined;
    std.debug.assert(ITER_BUF_SIZE <= iter_buf.len);
    const iterable = mp_getiter(o_in, &iter_buf);
    while (true) {
        const item = mp_iternext(iterable);
        if (item == mirrors.OBJ_STOP_ITERATION) break;
        if (mp_obj_is_true(item)) return mirrors.OBJ_TRUE;
    }
    return mirrors.OBJ_FALSE;
}

export fn mp_builtin_repr(o_in: Obj) callconv(.c) Obj {
    // vstr_init_print + print_helper(REPR) + new_str_from_vstr chain.
    var vstr_buf: VstrBytes align(8) = undefined;
    var print: PrintT = undefined;
    vstr_init_print(@ptrCast(&vstr_buf), 16, @ptrCast(&print));
    mp_obj_print_helper(@ptrCast(&print), o_in, mp.PRINT_REPR);
    return mp_obj_new_str_from_vstr(@ptrCast(&vstr_buf));
}

export fn mp_builtin___repl_print__(o: Obj) callconv(.c) Obj {
    if (o != mirrors.OBJ_NONE) {
        const printer = pythonPrinter();
        mp_obj_print_helper(printer, o, mp.PRINT_REPR);
        _ = mp_print_str(printer, "\n");
    }
    return mirrors.OBJ_NONE;
}

// ── W6 #4 cluster D: getattr / setattr / hasattr (delattr DEAD nano) ──
//
// All 3 fns can raise via mp_load_method / mp_store_attr / mp_obj_str_get_qstr
// (bridge longjmps under B1, propagate via Zig frame harmlessly).
//
// mp_load_attr_default is the C static helper inlined into Zig as
// loadAttrDefault. It dispatches to mp_load_method (raising) when defval
// is NULL, or mp_load_method_protected (silent) when defval is provided.

// C qstr is size_t (qstr.h:60); usize matches that on every target.
const Qstr = usize;
extern fn mp_load_method(base: Obj, attr: Qstr, dest: [*c]Obj) callconv(.c) void;
extern fn mp_load_method_maybe(base: Obj, attr: Qstr, dest: *[2]Obj) callconv(.c) void;
extern fn mp_load_method_protected(obj: Obj, attr: Qstr, dest: [*c]Obj, catch_all_exc: bool) callconv(.c) void;
extern fn mp_store_attr(base: Obj, attr: Qstr, value: Obj) callconv(.c) void;

fn loadAttrDefault(base: Obj, attr: Qstr, defval: Obj) Obj {
    var dest: [2]Obj = .{ 0, 0 }; // MP_OBJ_NULL = 0
    if (defval == 0) {
        mp_load_method(base, attr, &dest);
    } else {
        mp_load_method_protected(base, attr, &dest, false);
    }
    if (dest[0] == 0) {
        return defval;
    } else if (dest[1] == 0) {
        return dest[0]; // plain attribute (not a method)
    } else {
        return mp_obj_new_bound_meth(dest[0], dest[1]);
    }
}

export fn mp_builtin_getattr(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    const defval: Obj = if (n_args > 2) args[2] else 0;
    const attr: Qstr = @intCast(mp_obj_str_get_qstr(args[1]));
    return loadAttrDefault(args[0], attr, defval);
}

export fn mp_builtin_setattr(base: Obj, attr: Obj, value: Obj) callconv(.c) Obj {
    const attr_q: Qstr = @intCast(mp_obj_str_get_qstr(attr));
    if (pyerr.pending_exc != 0) return 0; // B2: bad attr type
    mp_store_attr(base, attr_q, value);
    return mirrors.OBJ_NONE;
}

export fn mp_builtin_hasattr(object_in: Obj, attr_in: Obj) callconv(.c) Obj {
    const attr: Qstr = @intCast(mp_obj_str_get_qstr(attr_in));
    if (pyerr.pending_exc != 0) return 0; // B2: bad attr type
    var dest: [2]Obj = .{ 0, 0 };
    mp_load_method_protected(object_in, attr, &dest, false);
    return mirrors.newBool(dest[0] != 0);
}

// ── W6 #4 cluster E: sum / sorted (min/max DEAD nano) ──
//
// min/max are entirely dead under MICROPY_PY_BUILTINS_MIN_MAX=0 — not
// ported. Live live in this cluster: sum + sorted.

extern fn mp_obj_list_make_new(type_in: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj;
extern fn mp_obj_list_sort(n_args: usize, pos_args: [*c]const Obj, kw_args: ?*anyopaque) callconv(.c) Obj;

fn raiseSortedKwarg() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_TypeError, "must use keyword argument for key function");
    return error.PyRaise;
}

export fn mp_builtin_sum(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    var value: Obj = if (n_args == 1) mirrors.newSmallInt(0) else args[1];
    var iter_buf: [64]u8 align(16) = undefined;
    std.debug.assert(ITER_BUF_SIZE <= iter_buf.len);
    const iterable = mp_getiter(args[0], &iter_buf);
    while (true) {
        const item = mp_iternext(iterable);
        if (item == mirrors.OBJ_STOP_ITERATION) break;
        value = mp_binary_op(mp.MP_BINARY_OP_ADD, value, item);
    }
    return value;
}

fn sortedImpl(n_args: usize, args: [*c]const Obj, kwargs: ?*anyopaque) PyError!Obj {
    if (n_args > 1) {
        try raiseSortedKwarg();
        unreachable;
    }
    var self_arr: [1]Obj = .{mp_obj_list_make_new(&mp_type_list, 1, 0, args)};
    _ = mp_obj_list_sort(1, &self_arr, kwargs);
    return self_arr[0];
}

export fn mp_builtin_sorted(n_args: usize, args: [*c]const Obj, kwargs: ?*anyopaque) callconv(.c) Obj {
    return pyerr.bridge(Obj, sortedImpl(n_args, args, kwargs));
}

// ── W6 #4 cluster F (partial): round + build_class ──
//
// Under nano: ROUND_INT=0, FLOAT=0 → round simplifies dramatically (1
// raise for int+ndigits, fall-through is just mp_obj_new_int).
//
// build_class is the metaclass-construction entry called from class
// statement bytecode. Calls mp_call_function_0 + mp_call_function_n_kw
// (both Zig). Raises only transitively.

extern fn mp_call_function_0(fun: Obj) callconv(.c) Obj;
extern fn mp_call_function_n_kw(fun: Obj, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj;

fn raiseRoundIntNotSupp() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception(&mp_type_NotImplementedError);
    return error.PyRaise;
}

// mp_obj_is_int is a macro in vendor: small_int OR exact-type-int.
inline fn objIsInt(o: Obj) bool {
    return mirrors.isSmallInt(o) or mirrors.isExactType(o, &mp_type_int);
}

fn roundImpl(n_args_in: usize, args: [*c]const Obj) PyError!Obj {
    // `round(x, None)` is `round(x)` in CPython; MicroPython rejects it.
    const n_args = if (build_options.is_full and n_args_in == 2 and args[1] == mirrors.OBJ_NONE) 1 else n_args_in;
    const o_in = args[0];
    if (objIsInt(o_in)) {
        if (n_args <= 1) return o_in;
        if (comptime build_options.is_full) {
            // ROUND_INT=1: round-half-to-even algorithm via int binops.
            // Mirrors upstream py/modbuiltins.c::mp_builtin_round.
            const num_dig = mp_obj_get_int(args[1]);
            if (num_dig >= 0) return o_in;
            const ten = mirrors.newSmallInt(10);
            const neg_d = mirrors.newSmallInt(@as(isize, @intCast(-num_dig)));
            const two = mirrors.newSmallInt(2);
            const mult = mp_binary_op(mp.MP_BINARY_OP_POWER, ten, neg_d);
            const half_mult = mp_binary_op(mp.MP_BINARY_OP_FLOOR_DIVIDE, mult, two);
            const modulo = mp_binary_op(mp.MP_BINARY_OP_MODULO, o_in, mult);
            const rounded = mp_binary_op(mp.MP_BINARY_OP_SUBTRACT, o_in, modulo);
            if (mp_obj_is_true(mp_binary_op(mp.MP_BINARY_OP_MORE, half_mult, modulo))) {
                return rounded;
            } else if (mp_obj_is_true(mp_binary_op(mp.MP_BINARY_OP_MORE, modulo, half_mult))) {
                return mp_binary_op(mp.MP_BINARY_OP_ADD, rounded, mult);
            } else {
                // tie → round to even
                const floor = mp_binary_op(mp.MP_BINARY_OP_FLOOR_DIVIDE, o_in, mult);
                const one = mirrors.newSmallInt(1);
                if (mp_obj_is_true(mp_binary_op(mp.MP_BINARY_OP_AND, floor, one))) {
                    return mp_binary_op(mp.MP_BINARY_OP_ADD, rounded, mult);
                }
                return rounded;
            }
        }
        try raiseRoundIntNotSupp();
        unreachable;
    }
    // Float path. Vendor py/objfloat.c is now in the float-arm carveout,
    // so mp_obj_get_float + mp_obj_new_float / mp_obj_new_int_from_float
    // are live. Matches CPython behavior: round(x) returns int,
    // round(x, n) returns float with n decimal places.
    const val = mp_obj_get_float(o_in);
    if (n_args > 1) {
        const num_dig = mp_obj_get_int(args[1]);
        const m = std.math.pow(f64, 10.0, @as(f64, @floatFromInt(num_dig)));
        const rounded = nearbyint(val * m) / m;
        return mp_obj_new_float(rounded);
    }
    return mp_obj_new_int_from_float(nearbyint(val));
}

export fn mp_builtin_round(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, roundImpl(n_args, args));
}

export fn mp_builtin___build_class__(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    std.debug.assert(2 <= n_args);

    // Set the new class's __locals__ object.
    const old_locals = mp_locals_get();
    const class_locals = mp_obj_new_dict(0);
    mp_locals_set(mirrors.objToPtr(class_locals));

    // Run the class body.
    const cell = mp_call_function_0(args[0]);

    // Restore the old __locals__ before exception-propagation. Vendor uses
    // NLR for this; we polled pyerr.pending_exc instead. Without the check,
    // a raise from the class body (e.g. setattr on a non-instance) returns
    // cell=0 from pyerr.bridge, which is NOT OBJ_NONE, so the cellSet below
    // would panic on fromObj(0).
    mp_locals_set(old_locals);
    if (pyerr.pending_exc != 0) return 0;

    // Resolve the metaclass.
    const meta: Obj = if (n_args == 2)
        @intFromPtr(&mp_type_type)
    else
        @intFromPtr(mp_obj_get_type(args[2]));

    // Build the meta-call args: (name, tuple(bases), locals).
    var meta_args: [3]Obj = .{
        args[1],
        mp_obj_new_tuple(n_args - 2, args + 2),
        class_locals,
    };
    const new_class = mp_call_function_n_kw(meta, 3, 0, &meta_args);
    if (pyerr.pending_exc != 0) return 0;

    if (cell != mirrors.OBJ_NONE) {
        mirrors.MpObjCell.cellSet(cell, new_class);
    }
    if (build_options.is_full) initSubclass(new_class, args[2..n_args]);
    return new_class;
}

// __qstr_shadow_begin__
// MP_QSTR___init_subclass__
// __qstr_shadow_end__

/// PEP 487: the first base with an `__init_subclass__` is called with the
/// new class, as a class method. MicroPython does not call it.
fn initSubclass(new_class: Obj, bases: []const Obj) void {
    for (bases) |base| {
        var dest: [2]Obj = .{ mirrors.OBJ_NULL, mirrors.OBJ_NULL };
        mp_load_method_maybe(base, mq.MP_QSTR___init_subclass__, &dest);
        if (dest[0] == mirrors.OBJ_NULL) continue;
        // A plain function or a classmethod bound to the base: either
        // way, the new class is `cls`.
        _ = mp_call_function_1(dest[0], new_class);
        return;
    }
}

// ── W6 #4 cluster F (continued): mp_builtin_dir ──
//
// 0 args  → list of names in local namespace (walk locals dict's map)
// 1 arg   → list of names from probing all qstrs via mp_load_method_protected
// Under nano ALL_SPECIAL_METHODS=0 → no __dir__ slot dispatch.
//
// dict map access uses the mp_mirrors.MpMap packed-struct mirror directly
// (post-port of map_shim.c → map.zig — npy_mapz_* accessors retired).
// The mp_map_slot_is_filled macro becomes: key != MP_OBJ_NULL && key != SENTINEL.

export fn mp_builtin_dir(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    const dir_list = mp_obj_new_list(0, null);
    if (n_args == 0) {
        // Walk locals dict's map.
        const dict_ptr = mp_locals_get();
        const dict: *mirrors.MpObjDict = @ptrCast(@alignCast(dict_ptr));
        const map = &dict.map;
        var i: usize = 0;
        while (i < map.alloc) : (i += 1) {
            if (map.slotFilled(i)) {
                _ = mp_obj_list_append(dir_list, map.keyAt(i));
            }
        }
    } else {
        // Probe all qstrs.
        const nqstr = npy_qstr_total();
        // MP_QSTR_ has id 1 (the empty qstr); start at the next one.
        var i: usize = @as(usize, mp.MP_QSTR_) + 1;
        while (i < nqstr) : (i += 1) {
            var dest: [2]Obj = .{ 0, 0 };
            mp_load_method_protected(args[0], @intCast(i), &dest, false);
            if (dest[0] != 0) {
                // Under full (MICROPY_PY_ALL_SPECIAL_METHODS=1), if the
                // probe finds a bound __dir__ method (dest[1] != NULL),
                // delegate to it and return its result instead of the
                // full attribute list. Mirrors vendor modbuiltins.c:179.
                if (comptime build_options.is_full) {
                    if (i == @as(usize, mp.MP_QSTR___dir__) and dest[1] != 0) {
                        return mp_call_method_n_kw(0, 0, &dest);
                    }
                }
                _ = mp_obj_list_append(dir_list, mirrors.objFromQstr(@as(usize, i)));
            }
        }
    }
    return dir_list;
}

extern fn mp_call_method_n_kw(n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj;

// ── W6 #4 cluster F (continued): mp_builtin_print ──
//
// Print n_args positional values, comma-separated by `sep` (kw, default
// " "), terminated by `end` (kw, default "\n"). Under nano IO=0,
// STDFILES=0 → no `file=` kwarg, output goes to mp_plat_print.
//
// The kw-arg parse table has rom_obj defaults that are config-sensitive;
// kept C-side via npy_modb_print_parse_args.

// MP_ARG_KW_ONLY | MP_ARG_OBJ = 0x203. ROM-obj defaults are config-sensitive.
const print_allowed_args_nano = [_]mirrors.MpArg{
    .{ .qst = mp.MP_QSTR_sep, .flags = 0x203, .defval = .{ .u_rom_obj = mirrors.objFromQstr(@as(usize, mp.MP_QSTR__space_)) } },
    .{ .qst = mp.MP_QSTR_end, .flags = 0x203, .defval = .{ .u_rom_obj = mirrors.objFromQstr(@as(usize, mp.MP_QSTR__0x0a_)) } },
};

extern const mp_sys_stdout_obj: anyopaque;

extern fn mp_get_stream_raise(stream: Obj, flags: c_int) callconv(.c) ?*const anyopaque;
extern fn mp_stream_write_adaptor(stream: ?*anyopaque, buf: [*]const u8, len: usize) callconv(.c) void;

export fn mp_builtin_print(n_args: usize, pos_args: [*c]const Obj, kw_args: ?*anyopaque) callconv(.c) Obj {
    var sep: Obj = 0;
    var end: Obj = 0;
    var file: Obj = 0;
    var flush = false;

    if (comptime build_options.is_full) {
        // Full has file= kwarg. Default = &mp_sys_stdout_obj.
        const print_allowed_args_full = [_]mirrors.MpArg{
            .{ .qst = mp.MP_QSTR_sep, .flags = 0x203, .defval = .{ .u_rom_obj = mirrors.objFromQstr(@as(usize, mp.MP_QSTR__space_)) } },
            .{ .qst = mp.MP_QSTR_end, .flags = 0x203, .defval = .{ .u_rom_obj = mirrors.objFromQstr(@as(usize, mp.MP_QSTR__0x0a_)) } },
            .{ .qst = mp.MP_QSTR_file, .flags = 0x203, .defval = .{ .u_rom_obj = @intFromPtr(&mp_sys_stdout_obj) } },
            .{ .qst = mp.MP_QSTR_flush, .flags = 0x201, .defval = .{ .u_bool = false } }, // MP_ARG_KW_ONLY | MP_ARG_BOOL
        };
        var parsed: [4]mirrors.MpArgVal = undefined;
        mp_arg_parse_all(0, null, kw_args, print_allowed_args_full.len, &print_allowed_args_full, &parsed);
        if (pyerr.pending_exc != 0) return mirrors.OBJ_NULL;
        sep = parsed[0].u_obj;
        end = parsed[1].u_obj;
        file = parsed[2].u_obj;
        flush = parsed[3].u_bool;
    } else {
        var parsed: [2]mirrors.MpArgVal = undefined;
        mp_arg_parse_all(0, null, kw_args, print_allowed_args_nano.len, &print_allowed_args_nano, &parsed);
        if (pyerr.pending_exc != 0) return mirrors.OBJ_NULL;
        sep = parsed[0].u_obj;
        end = parsed[1].u_obj;
    }

    var sep_len: usize = undefined;
    const sep_data = mp_obj_str_get_data(sep, &sep_len);
    var end_len: usize = undefined;
    const end_data = mp_obj_str_get_data(end, &end_len);

    // Under full, route through file= if user-provided (or default
    // sys.stdout). Under nano, file is 0 and we use mp_plat_print directly.
    if (build_options.is_full and file != 0) {
        var i: usize = 0;
        while (i < n_args) : (i += 1) {
            if (i > 0) {
                _ = mp_get_stream_raise(file, 2); // MP_STREAM_OP_WRITE
                mp_stream_write_adaptor(mirrors.objToPtr(file), sep_data, sep_len);
            }
            // Adapter printer writing to file via stream protocol.
            _ = mp_get_stream_raise(file, 2);
            var print: PrintT = .{
                .data = mirrors.objToPtr(file),
                .print_strn = @ptrCast(&mp_stream_write_adaptor),
            };
            mp_obj_print_helper(@ptrCast(&print), pos_args[i], mp.PRINT_STR);
        }
        _ = mp_get_stream_raise(file, 2);
        mp_stream_write_adaptor(mirrors.objToPtr(file), end_data, end_len);
        if (flush) {
            var dest: [2]Obj = undefined;
            mp_load_method(file, mp.MP_QSTR_flush, &dest);
            if (pyerr.pending_exc != 0) return mirrors.OBJ_NULL;
            _ = mp_call_method_n_kw(0, 0, &dest);
        }
    } else {
        const printer = pythonPrinter();
        var i: usize = 0;
        while (i < n_args) : (i += 1) {
            if (i > 0) _ = mp_print_strn(printer, sep_data, sep_len, 0, 0, 0);
            mp_obj_print_helper(printer, pos_args[i], mp.PRINT_STR);
        }
        _ = mp_print_strn(printer, end_data, end_len, 0, 0, 0);
    }
    return mirrors.OBJ_NONE;
}

extern fn mp_arg_parse_all(n_pos: usize, pos: [*c]const Obj, kws: ?*anyopaque, n_allowed: usize, allowed: ?*const anyopaque, out_vals: ?*anyopaque) callconv(.c) void;

// ── TRUE-ZIG-PORT (post-restructure): min / max ──────────────────────
//
// Body lifted from npy_modbuiltins_shim.c::_nano_builtin_min_max. The
// algorithm: scan an iterable (1-arg form) or argv (multi-arg form),
// tracking the current best by applying the comparison op to the key
// (item itself or key_fn(item)). Empty iterable → either `default=`
// kwarg or ValueError.

extern fn mp_call_function_1(fn_obj: Obj, arg: Obj) callconv(.c) Obj;

fn raiseMinMaxEmpty() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_ValueError, "arg is an empty sequence");
    return error.PyRaise;
}

const MP_MAP_LOOKUP: c_int = 0;

fn unpackMinMaxKwargs(kw: ?*anyopaque, key_fn_out: *Obj, default_out: *Obj) void {
    if (kw == null) {
        key_fn_out.* = 0;
        default_out.* = 0;
        return;
    }
    const e_key = mp_map_lookup(@ptrCast(kw.?), mirrors.objFromQstr(@as(usize, mp.MP_QSTR_key)), MP_MAP_LOOKUP);
    key_fn_out.* = if (e_key) |p| @as(*mirrors.MpMap.Elem, @ptrCast(@alignCast(p))).value else 0;
    const e_def = mp_map_lookup(@ptrCast(kw.?), mirrors.objFromQstr(@as(usize, mp.MP_QSTR_default)), MP_MAP_LOOKUP);
    default_out.* = if (e_def) |p| @as(*mirrors.MpMap.Elem, @ptrCast(@alignCast(p))).value else 0;
}

fn minMaxImpl(n_args: usize, args: [*c]const Obj, kwargs: ?*anyopaque, op: c_int) PyError!Obj {
    var key_fn: Obj = 0;
    var default_val: Obj = 0;
    unpackMinMaxKwargs(kwargs, &key_fn, &default_val);

    var best_key: Obj = 0;
    var best_obj: Obj = 0;

    if (n_args == 1) {
        var iter_buf: [64]u8 align(16) = undefined;
        std.debug.assert(ITER_BUF_SIZE <= iter_buf.len);
        const iterable = mp_getiter(args[0], &iter_buf);
        while (true) {
            const item = mp_iternext(iterable);
            if (item == mirrors.OBJ_STOP_ITERATION) break;
            const key = if (key_fn == 0) item else mp_call_function_1(key_fn, item);
            if (best_obj == 0 or mp_binary_op(op, key, best_key) == mirrors.OBJ_TRUE) {
                best_key = key;
                best_obj = item;
            }
        }
        if (best_obj == 0) {
            if (default_val != 0) return default_val;
            try raiseMinMaxEmpty();
            unreachable;
        }
        return best_obj;
    }

    var i: usize = 0;
    while (i < n_args) : (i += 1) {
        const key = if (key_fn == 0) args[i] else mp_call_function_1(key_fn, args[i]);
        if (best_obj == 0 or mp_binary_op(op, key, best_key) == mirrors.OBJ_TRUE) {
            best_key = key;
            best_obj = args[i];
        }
    }
    return best_obj;
}

export fn mp_builtin_max(n_args: usize, args: [*c]const Obj, kwargs: ?*anyopaque) callconv(.c) Obj {
    return pyerr.bridge(Obj, minMaxImpl(n_args, args, kwargs, mp.MP_BINARY_OP_MORE));
}

export fn mp_builtin_min(n_args: usize, args: [*c]const Obj, kwargs: ?*anyopaque) callconv(.c) Obj {
    return pyerr.bridge(Obj, minMaxImpl(n_args, args, kwargs, mp.MP_BINARY_OP_LESS));
}

// ── mp_builtin_input (under MICROPY_PY_BUILTINS_INPUT) ────────────────
//
// Reads a line from stdin via `readline`. CTRL-C → KeyboardInterrupt;
// EOF on empty line → EOFError. Both go through the polled-sentinel
// pyerr.pending_exc path.

const CHAR_CTRL_C: c_int = 0x03;
const CHAR_CTRL_D: c_int = 0x04;

// vstr_t is 32 bytes on macOS aarch64 (mirrors raise.zig's VstrBytes).
const VstrBytes = [32]u8;

extern fn readline(line: *anyopaque, prompt: [*:0]const u8) callconv(.c) c_int;
extern fn vstr_init(v: *anyopaque, sz: usize) callconv(.c) void;
extern fn mp_obj_new_str_from_vstr(v: *anyopaque) callconv(.c) Obj;
inline fn vstrLen(v: *const anyopaque) usize {
    // vstr_t layout: alloc (8) + len (8) + buf (8) + bool.
    const p: [*]const usize = @ptrCast(@alignCast(v));
    return p[1];
}
extern fn mp_obj_print(o: Obj, kind: c_int) callconv(.c) void;
extern fn mp_obj_new_exception(t: *const anyopaque) callconv(.c) Obj;

extern const mp_type_KeyboardInterrupt: anyopaque;
extern const mp_type_EOFError: anyopaque;

fn inputImpl(n_args: usize, args: [*c]const Obj) Obj {
    if (n_args == 1) {
        mp_obj_print(args[0], mp.PRINT_STR);
    }
    var vstr_buf: VstrBytes align(8) = undefined;
    const vstr_ptr: *anyopaque = @ptrCast(&vstr_buf);
    vstr_init(vstr_ptr, 16);
    const ret = readline(vstr_ptr, "");
    if (ret == CHAR_CTRL_C) {
        pyerr.pending_exc = mp_obj_new_exception(&mp_type_KeyboardInterrupt);
        return mirrors.OBJ_NULL;
    }
    if (vstrLen(vstr_ptr) == 0 and ret == CHAR_CTRL_D) {
        pyerr.pending_exc = mp_obj_new_exception(&mp_type_EOFError);
        return mirrors.OBJ_NULL;
    }
    return mp_obj_new_str_from_vstr(vstr_ptr);
}

export fn mp_builtin_input(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return inputImpl(n_args, args);
}

// ── mp_builtin_delattr (under MICROPY_CPYTHON_COMPAT) ─────────────────
// delattr(o, name) is just setattr(o, name, MP_OBJ_NULL).

export fn mp_builtin_delattr(base: Obj, attr: Obj) callconv(.c) Obj {
    return mp_builtin_setattr(base, attr, mirrors.OBJ_NULL);
}

// ── Const fun-object definitions (replace MP_DEFINE_CONST_FUN_OBJ_*) ──
//
// MP_DEFINE_CONST_FUN_OBJ_VAR (no _BETWEEN) ⇒ sig (min, MP_OBJ_FUN_ARGS_MAX, false).

extern const mp_type_fun_builtin_0: anyopaque;
extern const mp_type_fun_builtin_1: anyopaque;
extern const mp_type_fun_builtin_2: anyopaque;
extern const mp_type_fun_builtin_3: anyopaque;
extern const mp_type_fun_builtin_var: anyopaque;

const FUN_ARGS_MAX: u32 = 0xffff;

fn varFun(min: u32, max: u32, fp: *const anyopaque) mirrors.MpObjFunBuiltinVar {
    return .{ .base = .{ .type = &mp_type_fun_builtin_var }, .sig = mirrors.makeFunSig(min, max, false), .fun = fp };
}

fn kwFun(min: u32, fp: *const anyopaque) mirrors.MpObjFunBuiltinVar {
    return .{ .base = .{ .type = &mp_type_fun_builtin_var }, .sig = mirrors.makeFunSig(min, FUN_ARGS_MAX, true), .fun = fp };
}

extern fn mp_obj_id(o: Obj) callconv(.c) Obj;
extern fn mp_obj_len(o: Obj) callconv(.c) Obj;

pub export const mp_builtin___build_class___obj: mirrors.MpObjFunBuiltinVar = varFun(2, FUN_ARGS_MAX, @ptrCast(&mp_builtin___build_class__));
pub export const mp_builtin_abs_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&mp_builtin_abs) };
pub export const mp_builtin_all_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&mp_builtin_all) };
pub export const mp_builtin_any_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&mp_builtin_any) };
pub export const mp_builtin_bin_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&mp_builtin_bin) };
pub export const mp_builtin_callable_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&mp_builtin_callable) };
pub export const mp_builtin_chr_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&mp_builtin_chr) };
pub export const mp_builtin_dir_obj: mirrors.MpObjFunBuiltinVar = varFun(0, 1, @ptrCast(&mp_builtin_dir));
pub export const mp_builtin_format_obj: mirrors.MpObjFunBuiltinVar = varFun(1, 2, @ptrCast(&mp_builtin_format));
pub export const mp_builtin_divmod_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_2 }, .fun = @ptrCast(&mp_builtin_divmod) };
pub export const mp_builtin_hash_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&mp_builtin_hash) };
pub export const mp_builtin_hex_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&mp_builtin_hex) };
pub export const mp_builtin_getattr_obj: mirrors.MpObjFunBuiltinVar = varFun(2, 3, @ptrCast(&mp_builtin_getattr));
pub export const mp_builtin_setattr_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_3 }, .fun = @ptrCast(&mp_builtin_setattr) };
pub export const mp_builtin_hasattr_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_2 }, .fun = @ptrCast(&mp_builtin_hasattr) };
pub export const mp_builtin_globals_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_0 }, .fun = @ptrCast(&mp_builtin_globals) };
pub export const mp_builtin_locals_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_0 }, .fun = @ptrCast(&mp_builtin_locals) };
pub export const mp_builtin_iter_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&mp_builtin_iter) };
pub export const mp_builtin_next_obj: mirrors.MpObjFunBuiltinVar = varFun(1, 2, @ptrCast(&mp_builtin_next));
pub export const mp_builtin_oct_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&mp_builtin_oct) };
pub export const mp_builtin_ord_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&mp_builtin_ord) };
pub export const mp_builtin_pow_obj = argcheck.kwVar(2, &.{ 0, 0, mq.MP_QSTR_mod }, .{ mirrors.OBJ_NULL, mirrors.OBJ_NULL, mirrors.OBJ_NONE }, &mp_builtin_pow);
pub export const mp_builtin_print_obj: mirrors.MpObjFunBuiltinVar = kwFun(0, @ptrCast(&mp_builtin_print));
pub export const mp_builtin___repl_print___obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&mp_builtin___repl_print__) };
pub export const mp_builtin_repr_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&mp_builtin_repr) };
// __qstr_shadow_begin__
// MP_QSTR_ndigits
// MP_QSTR_mod
// __qstr_shadow_end__
pub export const mp_builtin_round_obj = argcheck.kwVar(1, &.{ 0, mq.MP_QSTR_ndigits }, .{ mirrors.OBJ_NULL, mirrors.OBJ_NONE }, &mp_builtin_round);
pub export const mp_builtin_sum_obj = argcheck.kwVar(1, &.{ 0, mq.MP_QSTR_start }, .{ mirrors.OBJ_NULL, mirrors.newSmallInt(0) }, &mp_builtin_sum);
pub export const mp_builtin_sorted_obj: mirrors.MpObjFunBuiltinVar = kwFun(1, @ptrCast(&mp_builtin_sorted));
pub export const mp_builtin_min_obj: mirrors.MpObjFunBuiltinVar = kwFun(1, @ptrCast(&mp_builtin_min));
pub export const mp_builtin_max_obj: mirrors.MpObjFunBuiltinVar = kwFun(1, @ptrCast(&mp_builtin_max));
pub export const mp_builtin_id_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&mp_obj_id) };
pub export const mp_builtin_len_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&mp_obj_len) };
pub export const mp_builtin_input_obj: mirrors.MpObjFunBuiltinVar = varFun(0, 1, @ptrCast(&mp_builtin_input));
pub export const mp_builtin_delattr_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_2 }, .fun = @ptrCast(&mp_builtin_delattr) };

// ── mp_module_builtins_globals table ──────────────────────────────────
//
// Mirrors py/modbuiltins.c::mp_module_builtins_globals_table — every
// nano-active entry becomes a RomEntry. Config-gated entries are
// included/excluded via `build_options.is_full` at comptime (full enables:
// COMPLEX, EVAL_EXEC, EXECFILE→OFF, COMPILE, IO, NOTIMPLEMENTED, ASYNC_AWAIT,
// STR_UNICODE, ROUND_INT/POW3 (no extra entries), HELP existed already).
//
// Per port/mpconfigport.h nano-arm:
//   ON: BYTEARRAY, ENUMERATE, FILTER, FLOAT, SET, FROZENSET, INPUT,
//       PROPERTY, REVERSED, SLICE, MEMORYVIEW, HELP, CPYTHON_COMPAT,
//       MIN_MAX.
//   OFF: COMPLEX, EVAL_EXEC, EXECFILE, COMPILE, IO, NOTIMPLEMENTED,
//        ASYNC_AWAIT, STR_UNICODE, EMIT_NATIVE.

extern const mp_type_module: anyopaque;
extern const mp_type_dict: anyopaque;

// Built-in type singletons.
extern const mp_type_bool: anyopaque;
extern const mp_type_bytes: anyopaque;
extern const mp_type_bytearray: anyopaque;
extern const mp_type_complex: anyopaque;
extern const mp_type_dict_obj: anyopaque; // unused — dict is mp_type_dict
extern const mp_type_enumerate: anyopaque;
extern const mp_type_filter: anyopaque;
extern const mp_type_float: anyopaque;
extern const mp_type_frozenset: anyopaque;
extern const mp_type_int: anyopaque;
extern const mp_type_list: anyopaque;
extern const mp_type_map: anyopaque;
extern const mp_type_memoryview: anyopaque;
extern const mp_type_object: anyopaque;
extern const mp_type_property: anyopaque;
extern const mp_type_range: anyopaque;
extern const mp_type_reversed: anyopaque;
extern const mp_type_set: anyopaque;
extern const mp_type_slice: anyopaque;
extern const mp_type_str: anyopaque;
extern const mp_type_super: anyopaque;
extern const mp_type_tuple: anyopaque;
extern const mp_type_type: anyopaque;
extern const mp_type_zip: anyopaque;
extern const mp_type_classmethod: anyopaque;
extern const mp_type_staticmethod: anyopaque;

// Built-in singleton objects.
extern const mp_const_ellipsis_obj: anyopaque;
extern const mp_const_notimplemented_obj: anyopaque;

// External fun-obj symbols (still defined by vendor or other modules).
extern const mp_builtin___import___obj: anyopaque;
extern const mp_builtin_compile_obj: anyopaque;
extern const mp_builtin_eval_obj: anyopaque;
extern const mp_builtin_exec_obj: anyopaque;
extern const mp_builtin_help_obj: anyopaque;
extern const mp_builtin_isinstance_obj: anyopaque;
extern const mp_builtin_issubclass_obj: anyopaque;
extern const mp_builtin_open_obj: anyopaque;

// Built-in exception types.
extern const mp_type_BaseException: anyopaque;
extern const mp_type_ArithmeticError: anyopaque;
extern const mp_type_AssertionError: anyopaque;
extern const mp_type_AttributeError: anyopaque;
extern const mp_type_Exception: anyopaque;
extern const mp_type_GeneratorExit: anyopaque;
extern const mp_type_ImportError: anyopaque;
extern const mp_type_ModuleNotFoundError: anyopaque;
extern const mp_type_IndentationError: anyopaque;
extern const mp_type_IndexError: anyopaque;
extern const mp_type_KeyError: anyopaque;
extern const mp_type_LookupError: anyopaque;
extern const mp_type_MemoryError: anyopaque;
extern const mp_type_NameError: anyopaque;
extern const mp_type_NotImplementedError: anyopaque;
extern const mp_type_OSError: anyopaque;
extern const mp_type_OverflowError: anyopaque;
extern const mp_type_RuntimeError: anyopaque;
extern const mp_type_StopAsyncIteration: anyopaque;
extern const mp_type_StopIteration: anyopaque;
extern const mp_type_SyntaxError: anyopaque;
extern const mp_type_SystemExit: anyopaque;
extern const mp_type_TypeError: anyopaque;
extern const mp_type_UnicodeError: anyopaque;
extern const mp_type_ValueError: anyopaque;
extern const mp_type_ZeroDivisionError: anyopaque;

const QstrId = usize;
const mq = @cImport({
    @cInclude("py/qstr.h");
});

const RomEntry = extern struct {
    key: Obj,
    value: *const anyopaque,
};

fn re(qid: QstrId, val: *const anyopaque) RomEntry {
    return .{ .key = mirrors.objFromQstr(qid), .value = val };
}
fn req(qid: QstrId, vqid: QstrId) RomEntry {
    return .{ .key = mirrors.objFromQstr(qid), .value = @ptrFromInt(mirrors.objFromQstr(vqid)) };
}

const mp_module_builtins_globals_table = blk: {
    var entries: [200]RomEntry = undefined;
    var n: usize = 0;

    entries[n] = req(mq.MP_QSTR___name__, mq.MP_QSTR_builtins);
    n += 1;
    entries[n] = re(mq.MP_QSTR___build_class__, &mp_builtin___build_class___obj);
    n += 1;
    entries[n] = re(mq.MP_QSTR___import__, &mp_builtin___import___obj);
    n += 1;
    entries[n] = re(mq.MP_QSTR___repl_print__, &mp_builtin___repl_print___obj);
    n += 1;

    // built-in types
    entries[n] = re(mq.MP_QSTR_bool, &mp_type_bool);
    n += 1;
    entries[n] = re(mq.MP_QSTR_bytes, &mp_type_bytes);
    n += 1;
    entries[n] = re(mq.MP_QSTR_bytearray, &mp_type_bytearray);
    n += 1; // BYTEARRAY=1
    if (build_options.is_full) {
        entries[n] = re(mq.MP_QSTR_complex, &mp_type_complex);
        n += 1;
    }
    entries[n] = re(mq.MP_QSTR_dict, &mp_type_dict);
    n += 1;
    entries[n] = re(mq.MP_QSTR_enumerate, &mp_type_enumerate);
    n += 1; // ENUMERATE=1
    entries[n] = re(mq.MP_QSTR_filter, &mp_type_filter);
    n += 1; // FILTER=1
    entries[n] = re(mq.MP_QSTR_float, &mp_type_float);
    n += 1; // FLOAT=1
    entries[n] = re(mq.MP_QSTR_frozenset, &mp_type_frozenset);
    n += 1; // SET&FROZENSET=1
    entries[n] = re(mq.MP_QSTR_int, &mp_type_int);
    n += 1;
    entries[n] = re(mq.MP_QSTR_list, &mp_type_list);
    n += 1;
    entries[n] = re(mq.MP_QSTR_map, &mp_type_map);
    n += 1;
    entries[n] = re(mq.MP_QSTR_memoryview, &mp_type_memoryview);
    n += 1; // MEMORYVIEW=1
    entries[n] = re(mq.MP_QSTR_object, &mp_type_object);
    n += 1;
    entries[n] = re(mq.MP_QSTR_property, &mp_type_property);
    n += 1; // PROPERTY=1
    entries[n] = re(mq.MP_QSTR_range, &mp_type_range);
    n += 1;
    entries[n] = re(mq.MP_QSTR_reversed, &mp_type_reversed);
    n += 1; // REVERSED=1
    entries[n] = re(mq.MP_QSTR_set, &mp_type_set);
    n += 1; // SET=1
    entries[n] = re(mq.MP_QSTR_slice, &mp_type_slice);
    n += 1; // SLICE=1
    entries[n] = re(mq.MP_QSTR_str, &mp_type_str);
    n += 1;
    entries[n] = re(mq.MP_QSTR_super, &mp_type_super);
    n += 1;
    entries[n] = re(mq.MP_QSTR_tuple, &mp_type_tuple);
    n += 1;
    entries[n] = re(mq.MP_QSTR_type, &mp_type_type);
    n += 1;
    entries[n] = re(mq.MP_QSTR_zip, &mp_type_zip);
    n += 1;

    entries[n] = re(mq.MP_QSTR_classmethod, &mp_type_classmethod);
    n += 1;
    entries[n] = re(mq.MP_QSTR_staticmethod, &mp_type_staticmethod);
    n += 1;

    // built-in objects
    entries[n] = re(mq.MP_QSTR_Ellipsis, &mp_const_ellipsis_obj);
    n += 1;
    entries[n] = re(mq.MP_QSTR_NotImplemented, &mp_const_notimplemented_obj);
    n += 1;

    // built-in user functions
    entries[n] = re(mq.MP_QSTR_abs, &mp_builtin_abs_obj);
    n += 1;
    entries[n] = re(mq.MP_QSTR_all, &mp_builtin_all_obj);
    n += 1;
    entries[n] = re(mq.MP_QSTR_any, &mp_builtin_any_obj);
    n += 1;
    entries[n] = re(mq.MP_QSTR_bin, &mp_builtin_bin_obj);
    n += 1;
    entries[n] = re(mq.MP_QSTR_callable, &mp_builtin_callable_obj);
    n += 1;
    if (build_options.is_full) {
        entries[n] = re(mq.MP_QSTR_compile, &mp_builtin_compile_obj);
        n += 1;
    }
    entries[n] = re(mq.MP_QSTR_chr, &mp_builtin_chr_obj);
    n += 1;
    // CPYTHON_COMPAT=1 → delattr present in both nano+full
    entries[n] = re(mq.MP_QSTR_delattr, &mp_builtin_delattr_obj);
    n += 1;
    entries[n] = re(mq.MP_QSTR_dir, &mp_builtin_dir_obj);
    n += 1;
    entries[n] = re(mq.MP_QSTR_divmod, &mp_builtin_divmod_obj);
    n += 1;
    // EVAL_EXEC defaults to MICROPY_ENABLE_COMPILER (=1) in both nano + full.
    entries[n] = re(mq.MP_QSTR_eval, &mp_builtin_eval_obj);
    n += 1;
    entries[n] = re(mq.MP_QSTR_exec, &mp_builtin_exec_obj);
    n += 1;
    entries[n] = re(mq.MP_QSTR_format, &mp_builtin_format_obj);
    n += 1;
    entries[n] = re(mq.MP_QSTR_getattr, &mp_builtin_getattr_obj);
    n += 1;
    entries[n] = re(mq.MP_QSTR_setattr, &mp_builtin_setattr_obj);
    n += 1;
    entries[n] = re(mq.MP_QSTR_globals, &mp_builtin_globals_obj);
    n += 1;
    entries[n] = re(mq.MP_QSTR_hasattr, &mp_builtin_hasattr_obj);
    n += 1;
    entries[n] = re(mq.MP_QSTR_hash, &mp_builtin_hash_obj);
    n += 1;
    // help() needs vendor py/builtinhelp.c which only ships under full
    // (build.zig:453). Under nano the link symbol is a zero-init stub
    // in vendor_stubs.zig — calling it crashes (null type pointer).
    // Don't expose the name: the canonical "feature not present" Python
    // pattern is the SKIP-on-NameError idiom (see tests/basics/builtin_help.py).
    // Aligns with ADR 009 Lane D (size first) — wasm doesn't need help().
    if (build_options.is_full) {
        entries[n] = re(mq.MP_QSTR_help, &mp_builtin_help_obj);
        n += 1;
    }
    entries[n] = re(mq.MP_QSTR_hex, &mp_builtin_hex_obj);
    n += 1;
    entries[n] = re(mq.MP_QSTR_id, &mp_builtin_id_obj);
    n += 1;
    entries[n] = re(mq.MP_QSTR_input, &mp_builtin_input_obj);
    n += 1; // INPUT=1
    entries[n] = re(mq.MP_QSTR_isinstance, &mp_builtin_isinstance_obj);
    n += 1;
    entries[n] = re(mq.MP_QSTR_issubclass, &mp_builtin_issubclass_obj);
    n += 1;
    entries[n] = re(mq.MP_QSTR_iter, &mp_builtin_iter_obj);
    n += 1;
    entries[n] = re(mq.MP_QSTR_len, &mp_builtin_len_obj);
    n += 1;
    entries[n] = re(mq.MP_QSTR_locals, &mp_builtin_locals_obj);
    n += 1;
    entries[n] = re(mq.MP_QSTR_max, &mp_builtin_max_obj);
    n += 1; // MIN_MAX=1
    entries[n] = re(mq.MP_QSTR_min, &mp_builtin_min_obj);
    n += 1;
    entries[n] = re(mq.MP_QSTR_next, &mp_builtin_next_obj);
    n += 1;
    entries[n] = re(mq.MP_QSTR_oct, &mp_builtin_oct_obj);
    n += 1;
    if (build_options.is_full) {
        entries[n] = re(mq.MP_QSTR_open, &mp_builtin_open_obj);
        n += 1;
    }
    entries[n] = re(mq.MP_QSTR_ord, &mp_builtin_ord_obj);
    n += 1;
    entries[n] = re(mq.MP_QSTR_pow, &mp_builtin_pow_obj);
    n += 1;
    entries[n] = re(mq.MP_QSTR_print, &mp_builtin_print_obj);
    n += 1;
    entries[n] = re(mq.MP_QSTR_repr, &mp_builtin_repr_obj);
    n += 1;
    entries[n] = re(mq.MP_QSTR_round, &mp_builtin_round_obj);
    n += 1;
    entries[n] = re(mq.MP_QSTR_sorted, &mp_builtin_sorted_obj);
    n += 1;
    entries[n] = re(mq.MP_QSTR_sum, &mp_builtin_sum_obj);
    n += 1;

    // built-in exceptions
    entries[n] = re(mq.MP_QSTR_BaseException, &mp_type_BaseException);
    n += 1;
    entries[n] = re(mq.MP_QSTR_ArithmeticError, &mp_type_ArithmeticError);
    n += 1;
    entries[n] = re(mq.MP_QSTR_AssertionError, &mp_type_AssertionError);
    n += 1;
    entries[n] = re(mq.MP_QSTR_AttributeError, &mp_type_AttributeError);
    n += 1;
    entries[n] = re(mq.MP_QSTR_EOFError, &mp_type_EOFError);
    n += 1;
    entries[n] = re(mq.MP_QSTR_Exception, &mp_type_Exception);
    n += 1;
    entries[n] = re(mq.MP_QSTR_GeneratorExit, &mp_type_GeneratorExit);
    n += 1;
    entries[n] = re(mq.MP_QSTR_ImportError, &mp_type_ImportError);
    n += 1;
    if (build_options.is_full) {
        entries[n] = re(mq.MP_QSTR_ModuleNotFoundError, &mp_type_ModuleNotFoundError);
        n += 1;
    }
    entries[n] = re(mq.MP_QSTR_IndentationError, &mp_type_IndentationError);
    n += 1;
    entries[n] = re(mq.MP_QSTR_IndexError, &mp_type_IndexError);
    n += 1;
    entries[n] = re(mq.MP_QSTR_KeyboardInterrupt, &mp_type_KeyboardInterrupt);
    n += 1;
    entries[n] = re(mq.MP_QSTR_KeyError, &mp_type_KeyError);
    n += 1;
    entries[n] = re(mq.MP_QSTR_LookupError, &mp_type_LookupError);
    n += 1;
    entries[n] = re(mq.MP_QSTR_MemoryError, &mp_type_MemoryError);
    n += 1;
    entries[n] = re(mq.MP_QSTR_NameError, &mp_type_NameError);
    n += 1;
    entries[n] = re(mq.MP_QSTR_NotImplementedError, &mp_type_NotImplementedError);
    n += 1;
    entries[n] = re(mq.MP_QSTR_OSError, &mp_type_OSError);
    n += 1;
    entries[n] = re(mq.MP_QSTR_OverflowError, &mp_type_OverflowError);
    n += 1;
    entries[n] = re(mq.MP_QSTR_RuntimeError, &mp_type_RuntimeError);
    n += 1;
    // StopAsyncIteration is exposed whenever MICROPY_PY_ASYNC_AWAIT is on.
    // The flag is set under both nano (A1, port/mpconfigport.h) and full.
    if (@hasDecl(mp, "MICROPY_PY_ASYNC_AWAIT") and mp.MICROPY_PY_ASYNC_AWAIT != 0) {
        entries[n] = re(mq.MP_QSTR_StopAsyncIteration, &mp_type_StopAsyncIteration);
        n += 1;
    }
    entries[n] = re(mq.MP_QSTR_StopIteration, &mp_type_StopIteration);
    n += 1;
    entries[n] = re(mq.MP_QSTR_SyntaxError, &mp_type_SyntaxError);
    n += 1;
    entries[n] = re(mq.MP_QSTR_SystemExit, &mp_type_SystemExit);
    n += 1;
    entries[n] = re(mq.MP_QSTR_TypeError, &mp_type_TypeError);
    n += 1;
    if (build_options.is_full) {
        entries[n] = re(mq.MP_QSTR_UnicodeError, &mp_type_UnicodeError);
        n += 1;
    }
    entries[n] = re(mq.MP_QSTR_ValueError, &mp_type_ValueError);
    n += 1;
    entries[n] = re(mq.MP_QSTR_ZeroDivisionError, &mp_type_ZeroDivisionError);
    n += 1;

    var final: [n]RomEntry = undefined;
    for (0..n) |i| final[i] = entries[i];
    break :blk final;
};

pub export const mp_module_builtins_globals: mirrors.MpObjDict = .{
    .base = .{ .type = &mp_type_dict },
    .map = .{
        .bits = .{
            .all_keys_are_qstrs = 1,
            .is_fixed = 1,
            .is_ordered = 1,
            .used = mp_module_builtins_globals_table.len,
        },
        .alloc = mp_module_builtins_globals_table.len,
        .table = @ptrCast(@constCast(&mp_module_builtins_globals_table)),
    },
};

pub export const mp_module_builtins: mirrors.MpObjModule = .{
    .base = .{ .type = &mp_type_module },
    .globals = @ptrCast(@constCast(&mp_module_builtins_globals)),
};

comptime {
    _ = &mp_builtin_abs;
    _ = &mp_builtin_hash;
    _ = &mp_builtin_divmod;
    _ = &mp_builtin_bin;
    _ = &mp_builtin_hex;
    _ = &mp_builtin_oct;
    _ = &mp_builtin_callable;
    _ = &mp_builtin_chr;
    _ = &mp_builtin_ord;
    _ = &mp_builtin_pow;
    _ = &mp_builtin_globals;
    _ = &mp_builtin_locals;
    _ = &mp_builtin_iter;
    _ = &mp_builtin_next;
    _ = &mp_builtin_all;
    _ = &mp_builtin_any;
    _ = &mp_builtin_repr;
    _ = &mp_builtin___repl_print__;
    _ = &mp_builtin_getattr;
    _ = &mp_builtin_setattr;
    _ = &mp_builtin_hasattr;
    _ = &mp_builtin_sum;
    _ = &mp_builtin_sorted;
    _ = &mp_builtin_round;
    _ = &mp_builtin___build_class__;
    _ = &mp_builtin_dir;
    _ = &mp_builtin_print;
    _ = &mp_builtin_min;
    _ = &mp_builtin_max;
    _ = &mp_builtin_input;
    _ = &mp_builtin_delattr;
    _ = &mp_module_builtins;
    _ = &mp_module_builtins_globals;
}
