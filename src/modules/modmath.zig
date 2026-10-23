//! petitpy — Zig port of py/modmath.c (the `math` builtin module).
//!
//! Nano config: MICROPY_PY_BUILTINS_FLOAT=1, MICROPY_PY_MATH=1,
//! MICROPY_PY_MATH_CONSTANTS=1. FACTORIAL/ISCLOSE/SPECIAL_FUNCTIONS/
//! GAMMA/ATAN2_FIX_INFNAN/POW_FIX_NAN/COPYSIGN_FIX_NAN/FMOD_FIX_INFNAN/
//! MODF_FIX_NEGZERO are all OFF under nano, so the live surface is the
//! standard libm wrappers plus the 5 float constants.
//!
//! Float constants (mp_const_float_{pi,e,tau,inf,nan}_obj) live here as
//! properly initialized `MpObjFloat` structs (the old zero-init stubs in
//! vendor_stubs.zig were tombstones; this file replaces them).
//!
//! The MP_REGISTER_MODULE marker stays in src/modules/modmath.c (a 4-line
//! tombstone) — makemoduledefs.py scans only .c sources.

const std = @import("std");
const mp = @cImport({
    @cInclude("py/qstr.h");
    @cInclude("py/runtime0.h");
});
const mirrors = @import("../mp_mirrors.zig");
const pyerr = @import("../pyerr.zig");

const Obj = mirrors.Obj;
const Qstr = usize;

extern const mp_type_module: anyopaque;
extern const mp_type_dict: anyopaque;
extern const mp_type_float: anyopaque;
extern const mp_type_fun_builtin_1: anyopaque;
extern const mp_type_fun_builtin_2: anyopaque;
extern const mp_type_fun_builtin_var: anyopaque;
extern const mp_type_ValueError: anyopaque;
extern const mp_type_ZeroDivisionError: anyopaque;

extern fn mp_obj_get_float(o: Obj) callconv(.c) f64;
extern fn mp_obj_get_int(o: Obj) callconv(.c) isize;
extern fn mp_obj_new_float(v: f64) callconv(.c) Obj;
extern fn mp_obj_new_int_from_float(v: f64) callconv(.c) Obj;
extern fn mp_obj_new_tuple(n: usize, items: [*c]const Obj) callconv(.c) Obj;
extern fn mp_obj_new_exception_msg(t: *const anyopaque, msg: [*:0]const u8) callconv(.c) Obj;

// PyError-pending raise (B1.5 polled convention). Sets pending_exc and
// returns OBJ_NULL so the VM unwinds.
fn raiseDomainError() Obj {
    pyerr.pending_exc = mp_obj_new_exception_msg(
        &mp_type_ValueError,
        "math domain error",
    );
    return mirrors.OBJ_NULL;
}
fn raiseDivByZero() Obj {
    pyerr.pending_exc = mp_obj_new_exception_msg(
        &mp_type_ZeroDivisionError,
        "divide by zero",
    );
    return mirrors.OBJ_NULL;
}

const MpObjFloat = mirrors.MpObjFloat;

// Float constants: vendor py/objfloat.c provides the real ROM objects
// now that it's in the float-arm carveout (build.zig). Reference them
// as extern — our previous local @export'd copies conflicted.
extern const mp_const_float_pi_obj: MpObjFloat;
extern const mp_const_float_e_obj: MpObjFloat;
extern const mp_const_float_tau_obj: MpObjFloat;
extern const mp_const_float_inf_obj: MpObjFloat;
extern const mp_const_float_nan_obj: MpObjFloat;

// ── Generic helpers ──────────────────────────────────────────────────
//
// vendor modmath.c:44-61 — domain error if result is nan/inf but the
// input wasn't. Lifts the libm wrapper into the same predicate shape.

inline fn generic1(x_obj: Obj, comptime f: fn (f64) f64) Obj {
    const x = mp_obj_get_float(x_obj);
    const ans = f(x);
    if ((std.math.isNan(ans) and !std.math.isNan(x)) or
        (std.math.isInf(ans) and !std.math.isInf(x)))
    {
        return raiseDomainError();
    }
    return mp_obj_new_float(ans);
}

inline fn generic2(x_obj: Obj, y_obj: Obj, comptime f: fn (f64, f64) f64) Obj {
    const x = mp_obj_get_float(x_obj);
    const y = mp_obj_get_float(y_obj);
    const ans = f(x, y);
    if ((std.math.isNan(ans) and !std.math.isNan(x) and !std.math.isNan(y)) or
        (std.math.isInf(ans) and !std.math.isInf(x) and !std.math.isInf(y)))
    {
        return raiseDomainError();
    }
    return mp_obj_new_float(ans);
}

// libm extern fns — Zig's std.math.sin/cos etc. wrap libm too, but the
// vendor C calls libm directly, so we do the same for byte-identical
// edge-case behaviour.
extern fn sin(x: f64) callconv(.c) f64;
extern fn cos(x: f64) callconv(.c) f64;
extern fn tan(x: f64) callconv(.c) f64;
extern fn asin(x: f64) callconv(.c) f64;
extern fn acos(x: f64) callconv(.c) f64;
extern fn atan(x: f64) callconv(.c) f64;
extern fn atan2(y: f64, x: f64) callconv(.c) f64;
extern fn exp(x: f64) callconv(.c) f64;
extern fn log(x: f64) callconv(.c) f64;
extern fn sqrt(x: f64) callconv(.c) f64;
extern fn pow(x: f64, y: f64) callconv(.c) f64;
extern fn hypot(x: f64, y: f64) callconv(.c) f64;

// __qstr_shadow_begin__
// MP_QSTR_hypot
// MP_QSTR_gcd
// __qstr_shadow_end__
extern fn fabs(x: f64) callconv(.c) f64;
extern fn copysign(x: f64, y: f64) callconv(.c) f64;
extern fn fmod(x: f64, y: f64) callconv(.c) f64;
extern fn ceil(x: f64) callconv(.c) f64;
extern fn floor(x: f64) callconv(.c) f64;
extern fn trunc(x: f64) callconv(.c) f64;
extern fn ldexp(x: f64, exp_arg: c_int) callconv(.c) f64;
extern fn frexp(x: f64, exp_out: *c_int) callconv(.c) f64;
extern fn modf(x: f64, int_part_out: *f64) callconv(.c) f64;

// Wrapper trampolines (libm symbols' calling convention is `.c`, but
// `generic1/2`'s comptime fn ptr expects Zig calling convention).
fn libm_sin(x: f64) f64 {
    return sin(x);
}
fn libm_cos(x: f64) f64 {
    return cos(x);
}
fn libm_tan(x: f64) f64 {
    return tan(x);
}
fn libm_asin(x: f64) f64 {
    return asin(x);
}
fn libm_acos(x: f64) f64 {
    return acos(x);
}
fn libm_atan(x: f64) f64 {
    return atan(x);
}
fn libm_atan2(y: f64, x: f64) f64 {
    return atan2(y, x);
}
fn libm_hypot(x: f64, y: f64) f64 {
    return hypot(x, y);
}
fn libm_exp(x: f64) f64 {
    return exp(x);
}
fn libm_log(x: f64) f64 {
    return log(x);
}
fn libm_sqrt(x: f64) f64 {
    return sqrt(x);
}
fn libm_pow(x: f64, y: f64) f64 {
    return pow(x, y);
}
fn libm_fabs(x: f64) f64 {
    return fabs(x);
}
fn libm_copysign(x: f64, y: f64) f64 {
    return copysign(x, y);
}
fn libm_fmod(x: f64, y: f64) f64 {
    return fmod(x, y);
}
// log2 implemented via natural log * (1/ln 2) (vendor #if MP_NEED_LOG2;
// macOS/Linux libc both have log2 but we mirror vendor's portable form).
fn libm_log2(x: f64) f64 {
    return log(x) * 1.442695040888963407354163704;
}
// log10 = log * (1/ln 10).
fn libm_log10(x: f64) f64 {
    return log(x) * 0.4342944819032518276511289189;
}

// ── Function bodies + fun-obj exports ────────────────────────────────

fn py_math_sin(x: Obj) callconv(.c) Obj {
    return generic1(x, libm_sin);
}
fn py_math_cos(x: Obj) callconv(.c) Obj {
    return generic1(x, libm_cos);
}
fn py_math_tan(x: Obj) callconv(.c) Obj {
    return generic1(x, libm_tan);
}
fn py_math_asin(x: Obj) callconv(.c) Obj {
    return generic1(x, libm_asin);
}
fn py_math_acos(x: Obj) callconv(.c) Obj {
    return generic1(x, libm_acos);
}
fn py_math_atan(x: Obj) callconv(.c) Obj {
    return generic1(x, libm_atan);
}
fn py_math_atan2(y: Obj, x: Obj) callconv(.c) Obj {
    return generic2(y, x, libm_atan2);
}
fn py_math_hypot(x: Obj, y: Obj) callconv(.c) Obj {
    return generic2(x, y, libm_hypot);
}
fn py_math_exp(x: Obj) callconv(.c) Obj {
    return generic1(x, libm_exp);
}
fn py_math_log2(x: Obj) callconv(.c) Obj {
    return generic1(x, libm_log2);
}
fn py_math_log10(x: Obj) callconv(.c) Obj {
    return generic1(x, libm_log10);
}
fn py_math_sqrt(x: Obj) callconv(.c) Obj {
    return generic1(x, libm_sqrt);
}
fn py_math_pow(x: Obj, y: Obj) callconv(.c) Obj {
    return generic2(x, y, libm_pow);
}
fn py_math_fabs(x: Obj) callconv(.c) Obj {
    return generic1(x, libm_fabs);
}
fn py_math_copysign(x: Obj, y: Obj) callconv(.c) Obj {
    return generic2(x, y, libm_copysign);
}
fn py_math_fmod(x: Obj, y: Obj) callconv(.c) Obj {
    return generic2(x, y, libm_fmod);
}

// ceil/floor/trunc: result is an int (vendor MATH_FUN_1_TO_INT).
fn py_math_ceil(x: Obj) callconv(.c) Obj {
    return mp_obj_new_int_from_float(ceil(mp_obj_get_float(x)));
}
fn py_math_floor(x: Obj) callconv(.c) Obj {
    return mp_obj_new_int_from_float(floor(mp_obj_get_float(x)));
}
fn py_math_trunc(x: Obj) callconv(.c) Obj {
    return mp_obj_new_int_from_float(trunc(mp_obj_get_float(x)));
}

// isnan/isinf/isfinite: result is bool (vendor MATH_FUN_1_TO_BOOL).
fn py_math_isnan(x: Obj) callconv(.c) Obj {
    return mirrors.newBool(std.math.isNan(mp_obj_get_float(x)));
}
fn py_math_isinf(x: Obj) callconv(.c) Obj {
    return mirrors.newBool(std.math.isInf(mp_obj_get_float(x)));
}
fn py_math_isfinite(x: Obj) callconv(.c) Obj {
    return mirrors.newBool(std.math.isFinite(mp_obj_get_float(x)));
}

// ldexp(x, exp): vendor MATH_FUN_2_FLT_INT — float, int → float.
fn py_math_ldexp(x_obj: Obj, exp_obj: Obj) callconv(.c) Obj {
    const x = mp_obj_get_float(x_obj);
    const e: c_int = @intCast(mp_obj_get_int(exp_obj));
    return mp_obj_new_float(ldexp(x, e));
}

// log(x[, base]) — 1 or 2 args (vendor MP_DEFINE_CONST_FUN_OBJ_VAR_BETWEEN 1,2).
fn py_math_log(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    const x = mp_obj_get_float(args[0]);
    if (x <= 0.0) return raiseDomainError();
    const l = log(x);
    if (n_args == 1) return mp_obj_new_float(l);
    const base = mp_obj_get_float(args[1]);
    if (base <= 0.0) return raiseDomainError();
    if (base == 1.0) return raiseDivByZero();
    return mp_obj_new_float(l / log(base));
}

// frexp(x): returns (significand, exponent) tuple.
fn py_math_frexp(x_obj: Obj) callconv(.c) Obj {
    var int_exp: c_int = 0;
    const sig = frexp(mp_obj_get_float(x_obj), &int_exp);
    var items: [2]Obj = .{
        mp_obj_new_float(sig),
        mirrors.newSmallInt(@as(isize, @intCast(int_exp))),
    };
    return mp_obj_new_tuple(2, &items);
}

// modf(x): returns (fractional, integral) tuple.
fn py_math_modf(x_obj: Obj) callconv(.c) Obj {
    var int_part: f64 = 0.0;
    const frac = modf(mp_obj_get_float(x_obj), &int_part);
    var items: [2]Obj = .{
        mp_obj_new_float(frac),
        mp_obj_new_float(int_part),
    };
    return mp_obj_new_tuple(2, &items);
}

// radians(x) = x * (pi/180); degrees(x) = x * (180/pi).
fn py_math_radians(x_obj: Obj) callconv(.c) Obj {
    return mp_obj_new_float(mp_obj_get_float(x_obj) * (std.math.pi / 180.0));
}
fn py_math_degrees(x_obj: Obj) callconv(.c) Obj {
    return mp_obj_new_float(mp_obj_get_float(x_obj) * (180.0 / std.math.pi));
}

// ── Function-object data exports ─────────────────────────────────────

pub export const mp_math_sqrt_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_math_sqrt) };
pub export const mp_math_pow_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_2 }, .fun = @ptrCast(&py_math_pow) };
pub export const mp_math_exp_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_math_exp) };
pub export const mp_math_log_obj: mirrors.MpObjFunBuiltinVar = .{ .base = .{ .type = &mp_type_fun_builtin_var }, .sig = mirrors.makeFunSig(1, 2, false), .fun = @ptrCast(&py_math_log) };
pub export const mp_math_log2_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_math_log2) };
pub export const mp_math_log10_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_math_log10) };
pub export const mp_math_cos_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_math_cos) };
pub export const mp_math_sin_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_math_sin) };
pub export const mp_math_tan_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_math_tan) };
pub export const mp_math_acos_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_math_acos) };
pub export const mp_math_asin_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_math_asin) };
pub export const mp_math_atan_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_math_atan) };
pub export const mp_math_atan2_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_2 }, .fun = @ptrCast(&py_math_atan2) };
pub export const mp_math_hypot_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_2 }, .fun = @ptrCast(&py_math_hypot) };
pub export const mp_math_ceil_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_math_ceil) };
pub export const mp_math_copysign_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_2 }, .fun = @ptrCast(&py_math_copysign) };
pub export const mp_math_fabs_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_math_fabs) };
pub export const mp_math_floor_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_math_floor) };
pub export const mp_math_fmod_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_2 }, .fun = @ptrCast(&py_math_fmod) };
pub export const mp_math_frexp_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_math_frexp) };
pub export const mp_math_ldexp_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_2 }, .fun = @ptrCast(&py_math_ldexp) };
pub export const mp_math_modf_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_math_modf) };
pub export const mp_math_isfinite_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_math_isfinite) };
pub export const mp_math_isinf_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_math_isinf) };
pub export const mp_math_isnan_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_math_isnan) };
pub export const mp_math_trunc_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_math_trunc) };
pub export const mp_math_radians_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_math_radians) };
// math.gcd(*integers), CPython 3.9+: Euclid over int objects, so big
// ints work on full. gcd() is 0 and the result is never negative.
extern const mp_type_int: anyopaque;
extern const mp_type_bool: anyopaque;
extern const mp_type_TypeError: anyopaque;
extern fn mp_obj_get_type(o: Obj) callconv(.c) *const anyopaque;
extern fn mp_binary_op(op: c_int, lhs: Obj, rhs: Obj) callconv(.c) Obj;
extern fn mp_unary_op(op: c_int, arg: Obj) callconv(.c) Obj;
extern fn mp_obj_is_true(o: Obj) callconv(.c) bool;

fn py_math_gcd(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    var a: Obj = mirrors.newSmallInt(0);
    for (args[0..n_args]) |x| {
        const t = mp_obj_get_type(x);
        if (!mirrors.isSmallInt(x) and t != @as(*const anyopaque, &mp_type_int) and t != @as(*const anyopaque, &mp_type_bool)) {
            pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_TypeError, "gcd() requires integers");
            return mirrors.OBJ_NULL;
        }
        var b = mp_unary_op(mp.MP_UNARY_OP_ABS, x);
        if (pyerr.pending_exc != 0) return mirrors.OBJ_NULL;
        while (mp_obj_is_true(b)) {
            const r = mp_binary_op(mp.MP_BINARY_OP_MODULO, a, b);
            if (pyerr.pending_exc != 0) return mirrors.OBJ_NULL;
            a = b;
            b = r;
        }
    }
    return a;
}
pub export const mp_math_gcd_obj: mirrors.MpObjFunBuiltinVar = .{ .base = .{ .type = &mp_type_fun_builtin_var }, .sig = mirrors.makeFunSig(0, 0xffff, false), .fun = @ptrCast(&py_math_gcd) }; // 0xffff: MP_OBJ_FUN_ARGS_MAX
pub export const mp_math_degrees_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_math_degrees) };

// ── Module globals dict ──────────────────────────────────────────────

const RomEntry = extern struct {
    key: Obj,
    value: *const anyopaque,
};

const mp_module_math_globals_table = [_]RomEntry{
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR___name__)), .value = @ptrFromInt(mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_math))) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_e)), .value = &mp_const_float_e_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_pi)), .value = &mp_const_float_pi_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_tau)), .value = &mp_const_float_tau_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_inf)), .value = &mp_const_float_inf_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_nan)), .value = &mp_const_float_nan_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_sqrt)), .value = &mp_math_sqrt_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_pow)), .value = &mp_math_pow_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_exp)), .value = &mp_math_exp_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_log)), .value = &mp_math_log_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_log2)), .value = &mp_math_log2_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_log10)), .value = &mp_math_log10_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_cos)), .value = &mp_math_cos_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_sin)), .value = &mp_math_sin_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_tan)), .value = &mp_math_tan_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_acos)), .value = &mp_math_acos_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_asin)), .value = &mp_math_asin_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_atan)), .value = &mp_math_atan_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_atan2)), .value = &mp_math_atan2_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_ceil)), .value = &mp_math_ceil_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_hypot)), .value = &mp_math_hypot_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_copysign)), .value = &mp_math_copysign_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_fabs)), .value = &mp_math_fabs_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_floor)), .value = &mp_math_floor_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_fmod)), .value = &mp_math_fmod_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_frexp)), .value = &mp_math_frexp_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_ldexp)), .value = &mp_math_ldexp_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_modf)), .value = &mp_math_modf_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_isfinite)), .value = &mp_math_isfinite_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_isinf)), .value = &mp_math_isinf_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_isnan)), .value = &mp_math_isnan_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_trunc)), .value = &mp_math_trunc_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_radians)), .value = &mp_math_radians_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_degrees)), .value = &mp_math_degrees_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_gcd)), .value = &mp_math_gcd_obj },
};

pub export const mp_module_math_globals: mirrors.MpObjDict = .{
    .base = .{ .type = &mp_type_dict },
    .map = .{
        .bits = .{
            .all_keys_are_qstrs = 1,
            .is_fixed = 1,
            .is_ordered = 1,
            .used = mp_module_math_globals_table.len,
        },
        .alloc = mp_module_math_globals_table.len,
        .table = @ptrCast(@constCast(&mp_module_math_globals_table)),
    },
};

pub export const mp_module_math: mirrors.MpObjModule = .{
    .base = .{ .type = &mp_type_module },
    .globals = @ptrCast(@constCast(&mp_module_math_globals)),
};

comptime {
    _ = &mp_module_math;
    _ = &mp_module_math_globals;
    _ = &mp_const_float_pi_obj;
    _ = &mp_const_float_e_obj;
    _ = &mp_const_float_tau_obj;
    _ = &mp_const_float_inf_obj;
    _ = &mp_const_float_nan_obj;
}
