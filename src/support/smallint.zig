//! nanopython — Zig port of py/smallint.c (Step 4: the object-model
//! strangle, the FIRST unit — see notes/10-objectmodel-strangle.md).
//!
//! Two pure `mp_int_t` arithmetic functions: no mp_obj, no nlr, no
//! MicroPython headers → the simplest possible strangle: NO shim, NO
//! @cImport, plain `export fn`. This is the proof that Step 4 is
//! ordinary mechanical strangling with the keystone's novelty spent.
//!
//! `mp_int_t` = 8-byte signed (nano MICROPY_OBJ_REPR_A → intptr_t),
//! verified by _Static_assert under the nano config = Zig `isize`.
//! `nm -gU` of the C object: exactly `mp_small_int_modulo` /
//! `mp_small_int_floor_divide` (no MICROPY_WRAP_).
//!
//! Faithful to C under `-fno-sanitize=undefined` (lesson #6): C's
//! signed `+`/unary-`-` rely on 2's-complement wrap → `+%`/`-%`;
//! C `%` = `@rem` (truncated remainder); C `/` = `@divTrunc`
//! (toward zero). Callers (objint/runtime) guarantee divisor != 0
//! and promote to bigint before the INT_MIN/-1 pathology, exactly
//! as the C original relies on.

const Int = isize; // mp_int_t (intptr_t, 8-byte signed; nano REPR_A)

pub export fn mp_small_int_modulo(dividend_in: Int, divisor: Int) Int {
    // Python specs require that mod has same sign as second operand
    var dividend = @rem(dividend_in, divisor); // C: dividend %= divisor
    if ((dividend < 0 and divisor > 0) or (dividend > 0 and divisor < 0)) {
        dividend +%= divisor;
    }
    return dividend;
}

pub export fn mp_small_int_floor_divide(num_in: Int, denom: Int) Int {
    var num = num_in;
    if (num >= 0) {
        if (denom < 0) {
            num +%= (0 -% denom) -% 1; // C: num += -denom - 1
        }
    } else {
        if (denom >= 0) {
            num +%= (0 -% denom) +% 1; // C: num += -denom + 1
        }
    }
    return @divTrunc(num, denom); // C: num / denom (trunc toward zero)
}

comptime {
    // Force full body+ABI analysis (the `_ = &fn;` rule; `_ = fn;`
    // is a fake green). `export` already links them; this guards the
    // unwired-validation build too.
    _ = &mp_small_int_modulo;
    _ = &mp_small_int_floor_divide;
}
