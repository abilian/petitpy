//! petitpy — Zig port of py/runtime_utils.c.
//!
//! NX-3 N4 (2026-06-05): npy_nlr_run wrap dropped — m_malloc_fail is
//! now polled (no longjmp) and no other Zig path longjmps under nano,
//! so the setjmp landing pad is dead code. Just call the function
//! directly and inspect pyerr.pending_exc.
//!
//! 2 protected callers — `mp_call_function_{1,2}_protected`: on
//! polled raise *print* the exception and return MP_OBJ_NULL (NO
//! re-raise — same shape as objgetitemiter).
//! 2 PURE fns — `mp_mul_{ll,mp_int_t}_overflow`: overflow predicates,
//! no nlr (like smallint) → shimless. `mp_call_function_{1,2}` are
//! real symbols (runtime.zig exports) → `extern fn`, no shim at all.
//!
//! Faithful: `MICROPY_USE_GCC_MUL_OVERFLOW_INTRINSIC=0` (probed) so
//! both overflow fns are compiled. `MP_INT_MAX/MIN = INTPTR_MAX/MIN`
//! (nano REPR_A, mp_int_t=isize). C integer `/` = `@divTrunc`; all
//! divisors are guarded (>0, or `x != 0 &&`). The C source NEVER
//! writes `*res` and has an empty `if (!overflow) {}` — replicated
//! exactly (`_ = res;`, no-op).

const std = @import("std");

const Obj = usize; // mp_obj_t
const LL = c_longlong; // long long
const MpInt = isize; // mp_int_t (nano REPR_A = intptr_t)

const pyerr = @import("../pyerr.zig");

extern fn mp_call_function_1(fun: Obj, arg: Obj) Obj;
extern fn mp_call_function_2(fun: Obj, arg1: Obj, arg2: Obj) Obj;
extern fn mp_obj_print_exception(print: *const anyopaque, exc: Obj) callconv(.c) void;
extern const mp_plat_print: anyopaque;

inline fn printExcAndClear() void {
    const ev = pyerr.pending_exc;
    pyerr.pending_exc = 0;
    mp_obj_print_exception(&mp_plat_print, ev);
}

export fn mp_call_function_1_protected(fun: Obj, arg: Obj) Obj {
    const ret = mp_call_function_1(fun, arg);
    if (pyerr.pending_exc != 0) {
        printExcAndClear();
        return 0;
    }
    return ret;
}

export fn mp_call_function_2_protected(fun: Obj, arg1: Obj, arg2: Obj) Obj {
    const ret = mp_call_function_2(fun, arg1, arg2);
    if (pyerr.pending_exc != 0) {
        printExcAndClear();
        return 0;
    }
    return ret;
}

export fn mp_mul_ll_overflow(x: LL, y: LL, res: [*c]LL) bool {
    const LMAX = std.math.maxInt(LL);
    const LMIN = std.math.minInt(LL);
    var overflow: bool = undefined;
    if (x > 0) { // x is positive
        if (y > 0) { // x and y are positive
            overflow = (x > @divTrunc(LMAX, y));
        } else { // x positive, y nonpositive
            overflow = (y < @divTrunc(LMIN, x));
        }
    } else { // x is nonpositive
        if (y > 0) { // x nonpositive, y positive
            overflow = (x < @divTrunc(LMIN, y));
        } else { // x and y nonpositive
            overflow = (x != 0 and y < @divTrunc(LMAX, x));
        }
    }
    if (!overflow) {
        res[0] = x *% y; // C: *res = x * y (no-overflow path → no wrap)
    }
    return overflow;
}

export fn mp_mul_mp_int_t_overflow(x: MpInt, y: MpInt, res: [*c]MpInt) bool {
    const IMAX = std.math.maxInt(MpInt); // MP_INT_MAX = INTPTR_MAX
    const IMIN = std.math.minInt(MpInt); // MP_INT_MIN = INTPTR_MIN
    if (x > 0) { // x is positive
        if (y > 0) { // x and y are positive
            if (x > @divTrunc(IMAX, y)) return true;
        } else { // x positive, y nonpositive
            if (y < @divTrunc(IMIN, x)) return true;
        }
    } else { // x is nonpositive
        if (y > 0) { // x nonpositive, y positive
            if (x < @divTrunc(IMIN, y)) return true;
        } else { // x and y nonpositive
            if (x != 0 and y < @divTrunc(IMAX, x)) return true;
        }
    }
    res[0] = x *% y; // C: *res = x * y (no-overflow path → no wrap)
    return false;
}

comptime {
    _ = &mp_call_function_1_protected;
    _ = &mp_call_function_2_protected;
    _ = &mp_mul_ll_overflow;
    _ = &mp_mul_mp_int_t_overflow;
}
