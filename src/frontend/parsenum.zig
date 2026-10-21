//! nanopython — Zig port of py/parsenum.c (Axis-B B1.5 W3; notes/11).
//!
//! Nano config (probed): MICROPY_LONGINT_IMPL=NONE,
//! MICROPY_PY_BUILTINS_FLOAT=0, MICROPY_PY_BUILTINS_COMPLEX=0,
//! MICROPY_ERROR_REPORTING<=TERSE.
//!   ⇒ mp_parse_num_integer: small-int path live (digit accumulation
//!     + per-step overflow check via mp_mul_mp_int_t_overflow +
//!     MP_SMALL_INT_FITS); overflow falls over to
//!     mp_obj_new_int_from_str_len (which under LONGINT_NONE raises
//!     OverflowError, faithful to C).
//!   ⇒ mp_parse_num_float: just the FLOAT=0 #else one-liner — always
//!     raises ValueError "decimal numbers not supported".
//!   ⇒ mp_parse_num_decimal does NOT exist as a symbol (COMPLEX=0).
//!
//! Faithful (lesson #6): the C `goto have_ret_val` from the overflow
//! re-parse is preserved by routing both paths to a common
//! convergent post-block (check parsed something / skip trailing
//! whitespace / check we reached end). The `goto value_error` paths
//! become `try raiseExc(...)` per the PyError convention. The
//! raise_exc helper (lex!=NULL converts ValueError to SyntaxError +
//! traceback) is the shim's npy_pn_convert_to_syntax_error.

const std = @import("std");
const builtin = @import("builtin");
const mirrors = @import("../mp_mirrors.zig");
const pyerr = @import("../pyerr.zig");
const PyError = pyerr.PyError;
const build_options = @import("build_options");

// Reuse already-Zig parsenumbase + unicode exports directly (their
// ABI is exposed via main.zig imports; declared extern here).
extern fn mp_parse_num_base(str: [*c]const u8, len: usize, base: [*c]c_int) usize;
extern fn unichar_isspace(ch: u32) bool;

extern fn mp_obj_new_int_from_str_len(s: *[*c]const u8, len: usize, neg: bool, base: c_uint) callconv(.c) Obj;
// Vendor objint_longlong.c provides this under LONGLONG. Under NONE the
// call is comptime-gated out (the symbol is unresolved by design).
extern fn mp_obj_new_int_from_ll(val: i64) callconv(.c) Obj;
extern fn mp_obj_exception_add_traceback(self_in: Obj, file: usize, line: usize, block: usize) callconv(.c) void;
extern const mp_type_SyntaxError: anyopaque;
extern const mp_type_OverflowError: anyopaque;

const Obj = mirrors.Obj;
const Lex = ?*anyopaque; // mp_lexer_t*

// MP_QSTRnull = 0.
const QSTR_NULL: usize = 0;

// MP_SMALL_INT_FITS — same as in objint.zig.
// Sign bit of usize: 0x8000000000000000 on 64-bit, 0x80000000 on 32-bit.
inline fn smallIntFits(n: isize) bool {
    const u: usize = @bitCast(n);
    const sign_bit: usize = @as(usize, 1) << (@bitSizeOf(usize) - 1);
    return ((u ^ (u << 1)) & sign_bit) == 0;
}

// Mutate exc.base.type → SyntaxError + add traceback from the lexer's
// source_name + tok_line. Vendor mp_lexer_t layout (see lexer.h:161):
// source_name (qstr/usize) is at offset 0; tok_line follows a known
// sequence of fields. We model the layout with an extern struct so
// @offsetOf gives a stable, config-aware (FSTRINGS=1 in nano+full)
// offset to tok_line. (Was: read via npy_pnum_lex_tok_line in
// parsenum_shim.c; that shim is now retired.)
const LexerLayout = extern struct {
    // public + private fields, in declaration order, only enough to
    // reach tok_line. See vendor/micropython_embed/py/lexer.h:161-188.
    source_name: usize, // qstr
    reader_data: ?*anyopaque,
    reader_readbyte: ?*const anyopaque,
    reader_close: ?*const anyopaque,
    chr0: u32, // unichar
    chr1: u32,
    chr2: u32,
    // FSTRINGS=1 in both nano and full configs.
    chr0_saved: u32,
    chr1_saved: u32,
    chr2_saved: u32,
    line: usize,
    column: usize,
    emit_dent: isize, // mp_int_t
    nested_bracket_level: isize,
    alloc_indent_level: usize,
    num_indent_level: usize,
    indent_level: ?*u16,
    tok_line: usize,
};

fn convertToSyntaxError(exc: Obj, lex: Lex) void {
    // exc.base.type = &mp_type_SyntaxError
    const base: *mirrors.MpObjBase = @ptrFromInt(exc);
    base.type = &mp_type_SyntaxError;
    const lex_layout: *const LexerLayout = @ptrCast(@alignCast(lex.?));
    mp_obj_exception_add_traceback(exc, lex_layout.source_name, lex_layout.tok_line, QSTR_NULL);
}

fn raiseExc(exc: Obj, lex: Lex) PyError!void {
    if (lex != null) convertToSyntaxError(exc, lex);
    pyerr.pending_exc = exc;
    return error.PyRaise;
}

extern fn mp_obj_new_exception_msg(t: *const anyopaque, msg: [*:0]const u8) callconv(.c) Obj;
extern const mp_type_ValueError: anyopaque;

inline fn badBaseExc() Obj {
    return mp_obj_new_exception_msg(&mp_type_ValueError, "int() arg 2 must be >= 2 and <= 36");
}
inline fn invalidIntExc() Obj {
    return mp_obj_new_exception_msg(&mp_type_ValueError, "invalid syntax for integer");
}
inline fn invalidNumberExc() Obj {
    return mp_obj_new_exception_msg(&mp_type_ValueError, "invalid syntax for number");
}

fn raiseBadBase() PyError!void {
    pyerr.pending_exc = badBaseExc();
    return error.PyRaise;
}

fn mpParseNumIntegerImpl(str_in: [*c]const u8, len: usize, base_in: c_int, lex: Lex) PyError!Obj {
    var str: [*c]const u8 = str_in;
    const top: [*c]const u8 = str_in + len;
    var neg: bool = false;
    var base: c_int = base_in;

    // check radix base
    if ((base != 0 and base < 2) or base > 36) {
        // Vendor calls mp_raise_ValueError directly (lex-conversion
        // intentionally skipped — this branch isn't reached from parser).
        try raiseBadBase();
    }

    // skip leading whitespace
    while (@intFromPtr(str) < @intFromPtr(top) and unichar_isspace(str[0])) : (str += 1) {}

    // parse optional sign
    if (@intFromPtr(str) < @intFromPtr(top)) {
        if (str[0] == '+') {
            str += 1;
        } else if (str[0] == '-') {
            str += 1;
            neg = true;
        }
    }

    // parse optional base prefix
    const remaining = @intFromPtr(top) - @intFromPtr(str);
    str += mp_parse_num_base(str, remaining, &base);

    // string should be an integer number. Accumulator type is
    // comptime-selected per MICROPY_LONGINT_IMPL — matches vendor
    // parsenum.c's PARSED_INT_FITS shape:
    //   - LONGLONG (wasm32-nano): u64 accumulator, cap at LLONG_MAX+1,
    //     overflow raises (no bignum to spill into).
    //   - NONE (nano native) + MPZ (full): mp_int_t accumulator (=isize
    //     on REPR_A), cap at smallint, overflow promotes via polymorphic
    //     mp_obj_new_int_from_str_len — which raises under NONE and
    //     allocates a heap mpz under MPZ.
    // Earlier the MPZ arm was wrongly routed to the LONGLONG-shaped u64
    // accumulator, which let parsed_val reach 1<<63 then panic with
    // @intCast in the post-parse branch (e.g. `x = 0x8000000000000000`).
    // ADR 012 Phase 3.5 step 3.
    const Acc = if (build_options.longint_impl == .longlong) u64 else isize;
    const ACC_MAX_POS_PLUS_ONE: u64 = if (build_options.longint_impl == .longlong) (1 << 63) else 0;

    var parsed_val: Acc = 0;
    const str_val_start: [*c]const u8 = str;
    var overflowed: bool = false;
    while (@intFromPtr(str) < @intFromPtr(top)) : (str += 1) {
        var dig: u32 = str[0];
        if (dig >= '0' and dig <= '9') {
            dig -= '0';
        } else if (dig == '_') {
            continue;
        } else {
            dig |= 0x20; // make digit lower-case
            if (dig >= 'a' and dig <= 'z') {
                dig -= 'a' - 10;
            } else {
                break; // unknown character
            }
        }
        if (dig >= @as(u32, @intCast(base))) break;

        if (comptime build_options.longint_impl != .longlong) {
            // NONE + MPZ arm: accumulate in isize; per-digit smallint fit check.
            // Overflow promotes to the polymorphic ctor — raises under NONE,
            // allocates heap mpz under MPZ.
            const mul_result = @mulWithOverflow(parsed_val, @as(isize, @intCast(base)));
            if (mul_result[1] != 0) {
                overflowed = true;
                break;
            }
            parsed_val = mul_result[0];
            parsed_val +%= @intCast(dig);
            if (!smallIntFits(parsed_val)) {
                overflowed = true;
                break;
            }
        } else {
            // LONGLONG arm: u64 accumulator capped at LLONG_MAX+1.
            const r = @mulWithOverflow(parsed_val, @as(u64, @intCast(base)));
            if (r[1] != 0) {
                overflowed = true;
                break;
            }
            const s_ = @addWithOverflow(r[0], @as(u64, dig));
            if (s_[1] != 0) {
                overflowed = true;
                break;
            }
            if (s_[0] > ACC_MAX_POS_PLUS_ONE) {
                overflowed = true;
                break;
            }
            parsed_val = s_[0];
        }
    }

    // produce ret_val from the path we took.
    var ret_val: Obj = undefined;
    if (overflowed) {
        if (comptime build_options.longint_impl != .longlong) {
            // NONE + MPZ both delegate to the vendor polymorphic str ctor.
            // Under NONE the linked stub at objint.c:334 raises
            // OverflowError("long int not supported in this build"); under
            // MPZ the linked impl (objint_mpz.c:413) allocates a heap
            // mp_obj_int_t and fills it via mpz_set_from_str. ADR 012
            // Phase 3.5 — closes the parser-side LONGLONG hardcoding that
            // broke 39 intbig tests under full.
            var s2: [*c]const u8 = str_val_start;
            const rem = @intFromPtr(top) - @intFromPtr(str_val_start);
            ret_val = mp_obj_new_int_from_str_len(&s2, rem, neg, @intCast(base));
            if (pyerr.pending_exc != 0) return error.PyRaise;
            str = s2;
        } else {
            // LONGLONG arm: parsed_val exceeded LLONG_MAX+1 and there's no
            // higher-precision backend to hand off to.
            pyerr.pending_exc = mp_obj_new_exception_msg(
                &mp_type_OverflowError,
                "result overflows long long storage");
            return error.PyRaise;
        }
    } else if (comptime build_options.longint_impl != .longlong) {
        // NONE + MPZ arm: parsed_val fits in smallint by construction
        // (overflow above bailed to the polymorphic ctor). Wrap directly.
        const v: isize = if (neg) -parsed_val else parsed_val;
        ret_val = mirrors.newSmallInt(v);
    } else {
        // LONGLONG arm: parsed_val ∈ [0, LLONG_MAX+1]. Convert to signed,
        // dispatch through vendor mp_obj_new_int_from_ll (small_int when
        // it fits, else heap mp_obj_int_t).
        const signed_val: i64 = if (neg) blk: {
            if (parsed_val == ACC_MAX_POS_PLUS_ONE) {
                break :blk std.math.minInt(i64);
            }
            break :blk -@as(i64, @intCast(parsed_val));
        } else @intCast(parsed_val);
        ret_val = mp_obj_new_int_from_ll(signed_val);
        if (pyerr.pending_exc != 0) return error.PyRaise;
    }

    // check we parsed something
    if (str == str_val_start) {
        try raiseExc(invalidIntExc(), lex);
        unreachable;
    }

    // skip trailing whitespace
    while (@intFromPtr(str) < @intFromPtr(top) and unichar_isspace(str[0])) : (str += 1) {}

    // check we reached the end of the string
    if (str != top) {
        try raiseExc(invalidIntExc(), lex);
        unreachable;
    }

    return ret_val;
}

export fn mp_parse_num_integer(str_: [*c]const u8, len: usize, base: c_int, lex: Lex) callconv(.c) Obj {
    return pyerr.bridge(Obj, mpParseNumIntegerImpl(str_, len, base, lex));
}

// ── Unified float + decimal parser ────────────────────────────────────
//
// Single Zig port replacing two C shim bodies (mp_parse_num_float_impl
// and mp_parse_num_decimal_impl). The REAL_IMAG_STATE / 'j' / two-pass
// machinery comptime-compiles out when complex_enabled=false (nano).
//
// vendor parsenum.h:42-54 has a static-inline mp_parse_num_float that
// wraps mp_parse_num_decimal when COMPLEX=1. Under full our Zig export
// of mp_parse_num_float is an unused symbol (callers see the inline);
// harmless coexistence.
//
// 2026-05-26: retired both mp_parse_num_decimal_impl (~85 LOC) and
// mp_parse_num_float_impl (~43 LOC) from parsenum_shim.c. The Phase 3
// COMPLEX-paydown discipline (lesson #31): both shim bodies were
// verbatim copies of vendor; the actual algorithm is pure logic so
// belongs Zig-side.
// (`std` and `build_options` already imported at the top of the file.)

const DECIMAL_STATE_START = 0;
const DECIMAL_STATE_HAVE_REAL = 1;
const DECIMAL_STATE_HAVE_IMAG = 2;

extern fn mp_obj_new_float(val: f64) Obj;
extern fn mp_obj_new_complex(real: f64, imag: f64) Obj;
extern fn pow(x: f64, y: f64) callconv(.c) f64;
// (`std` already imported at the top of the file.)
const INFINITY_F: f64 = std.math.inf(f64);
const NAN_F: f64 = std.math.nan(f64);

// ── FLOAT-parsing core (was parsenum_shim.c FLOAT block) ──────────────
//
// On darwin-aarch64 long double == double, so vendor's auto-selection
// (mpconfig.h:992) lands at MICROPY_FLOAT_FORMAT_IMPL_APPROX with
// mp_large_float_t = mp_float_t = f64 and mp_large_float_uint_t = u64.
// Both nano and full configs hit this path. The bitfield-manipulation
// arm is what we port; the EXACT arm only triggers when long double
// is wider than double (not our target).
//
// mp_float_union_t mirror: 64-bit little-endian double laid out as
// {frc:52, exp:11, sgn:1}. See vendor/.../py/misc.h:283-299.

const MpFloatUnionPacked = packed struct(u64) {
    frc: u52,
    exp: u11,
    sgn: u1,
};

// MANTISSA_MAX for u64 (sizeof(mp_large_float_uint_t) == 8).
const MANTISSA_MAX: u64 = 0x1999999999999998;

// MAX_EXACT_POWER_OF_5 for MICROPY_FLOAT_IMPL_DOUBLE (used only by the
// EXACT arm; we hit APPROX, so this is unused here. Kept as a comment
// for future EXACT-arm port).
// const MAX_EXACT_POWER_OF_5 = 22;

export fn mp_decimal_exp(num: f64, dec_exp_in: c_int) callconv(.c) f64 {
    if (dec_exp_in == 0 or num == 0.0) return num;
    // APPROX arm: shift the binary exponent by dec_exp, then multiply
    // by 5^dec_exp to convert from 2^dec_exp to 10^dec_exp scaling.
    var res_u: MpFloatUnionPacked = @bitCast(num);
    const new_exp: i32 = @as(i32, @intCast(res_u.exp)) + dec_exp_in;
    // Clamp/cast: in the C code this is an unchecked bitfield add. We
    // truncate to 11 bits via @truncate after wrapping cast.
    res_u.exp = @truncate(@as(u32, @bitCast(new_exp)));
    var res_f: f64 = @bitCast(res_u);
    // MAX_EXACT_POWER_OF_5 = 22 for FLOAT_IMPL_DOUBLE.
    if (dec_exp_in < 0 and dec_exp_in >= -22) {
        res_f /= pow(5.0, @as(f64, @floatFromInt(-dec_exp_in)));
    } else {
        res_f *= pow(5.0, @as(f64, @floatFromInt(dec_exp_in)));
    }
    return res_f;
}

const PARSE_DEC_IN_INTG: u32 = 0;
const PARSE_DEC_IN_FRAC: u32 = 1;
const PARSE_DEC_IN_EXP: u32 = 2;

inline fn acceptDigit(p_mantissa: u64, dig: u32, p_exp_extra: *c_int, in: u32) u64 {
    if (p_mantissa < MANTISSA_MAX) {
        if (in == PARSE_DEC_IN_FRAC) p_exp_extra.* -= 1;
        return 10 * p_mantissa + dig;
    }
    if (in == PARSE_DEC_IN_INTG) p_exp_extra.* += 1;
    return p_mantissa;
}

extern fn strtod(nptr: [*:0]const u8, endptr: ?*[*:0]u8) callconv(.c) f64;

// libc strtod, correctly rounded, on the scanned text without its `_`
// separators. Native only: the platform libc has it for free, while on
// wasm a correct parser costs 16 KB (wasi-libc's strtod) to 25 KB
// (std.fmt.parseFloat) against a 330 KB binary, so wasm keeps vendor's
// approximation, which can be an ulp off on 17-digit literals. Null when
// the text is not all number (a dangling exponent) or too long.
fn exactDecimal(text: []const u8) ?f64 {
    if (comptime builtin.target.os.tag == .wasi) return null;
    var buf: [128]u8 = undefined;
    var n: usize = 0;
    for (text) |c| {
        if (c == '_') continue;
        if (n + 1 >= buf.len) return null;
        buf[n] = c;
        n += 1;
    }
    buf[n] = 0;
    var end: [*:0]u8 = undefined;
    const v = strtod(@ptrCast(&buf), &end);
    if (@intFromPtr(end) != @intFromPtr(&buf) + n) return null;
    return v;
}

export fn mp_parse_float_internal(str_in: [*c]const u8, len: usize, res: *f64) callconv(.c) [*c]const u8 {
    var str: [*c]const u8 = str_in;
    const top: [*c]const u8 = str_in + len;
    var in: u32 = PARSE_DEC_IN_INTG;
    var exp_neg: bool = false;
    var mantissa: u64 = 0;
    var exp_val: c_int = 0;
    var exp_extra: c_int = 0;
    var trailing_zeros_intg: c_int = 0;
    var trailing_zeros_frac: c_int = 0;
    while (@intFromPtr(str) < @intFromPtr(top)) {
        var dig: u32 = str[0];
        str += 1;
        if (dig >= '0' and dig <= '9') {
            dig -= '0';
            if (in == PARSE_DEC_IN_EXP) {
                // INT_MAX/2 - 9) / 10 to avoid overflow during 10*exp_val + dig
                const INT_MAX: c_int = std.math.maxInt(c_int);
                if (exp_val < @divTrunc(@divTrunc(INT_MAX, 2) - 9, 10)) {
                    exp_val = 10 * exp_val + @as(c_int, @intCast(dig));
                }
            } else {
                if (dig == 0 or mantissa >= MANTISSA_MAX) {
                    if (in == PARSE_DEC_IN_INTG) trailing_zeros_intg += 1 else trailing_zeros_frac += 1;
                } else {
                    while (trailing_zeros_intg > 0) {
                        mantissa = acceptDigit(mantissa, 0, &exp_extra, PARSE_DEC_IN_INTG);
                        trailing_zeros_intg -= 1;
                    }
                    while (trailing_zeros_frac > 0) {
                        mantissa = acceptDigit(mantissa, 0, &exp_extra, PARSE_DEC_IN_FRAC);
                        trailing_zeros_frac -= 1;
                    }
                    mantissa = acceptDigit(mantissa, dig, &exp_extra, in);
                }
            }
        } else if (in == PARSE_DEC_IN_INTG and dig == '.') {
            in = PARSE_DEC_IN_FRAC;
        } else if (in != PARSE_DEC_IN_EXP and (dig | 0x20) == 'e') {
            in = PARSE_DEC_IN_EXP;
            if (@intFromPtr(str) < @intFromPtr(top)) {
                if (str[0] == '+') {
                    str += 1;
                } else if (str[0] == '-') {
                    str += 1;
                    exp_neg = true;
                }
            }
            if (@intFromPtr(str) == @intFromPtr(top)) return null;
        } else if (dig == '_') {
            continue;
        } else {
            str -= 1;
            break;
        }
    }
    if (exp_neg) exp_val = -exp_val;
    exp_val += exp_extra + trailing_zeros_intg;
    // The scan above decides what is a number; on native the value comes
    // from strtod, which rounds correctly, so float(repr(x)) is x.
    // mp_decimal_exp's mantissa * 10^exp is off by an ulp at times
    // ("2.2250738585072014e-308"). It stays for what strtod does not take
    // whole and vendor accepts: a dangling exponent ("1e+").
    res.* = exactDecimal(str_in[0 .. @intFromPtr(str) - @intFromPtr(str_in)]) orelse mp_decimal_exp(@floatFromInt(mantissa), exp_val);
    return str;
}

fn parseDecimalImpl(
    str_in: [*c]const u8,
    len: usize,
    allow_imag: bool,
    force_complex: bool,
    lex: Lex,
    comptime complex_enabled: bool,
) PyError!Obj {
    var str = str_in;
    const top: [*c]const u8 = str_in + len;
    var dec_val: f64 = 0;
    var dec_real: f64 = 0;
    var state: u32 = DECIMAL_STATE_START;

    parse_loop: while (true) {
        var dec_neg = false;

        while (@intFromPtr(str) < @intFromPtr(top) and unichar_isspace(str[0])) : (str += 1) {}
        if (@intFromPtr(str) < @intFromPtr(top)) {
            if (str[0] == '+') {
                str += 1;
            } else if (str[0] == '-') {
                str += 1;
                dec_neg = true;
            }
        }
        const str_val_start = str;

        // inf / infinity / nan / fall through to float-internal.
        if (@intFromPtr(str + 2) < @intFromPtr(top) and (str[0] | 0x20) == 'i' and (str[1] | 0x20) == 'n' and (str[2] | 0x20) == 'f') {
            str += 3;
            dec_val = INFINITY_F;
            if (@intFromPtr(str + 4) < @intFromPtr(top) and (str[0] | 0x20) == 'i' and (str[1] | 0x20) == 'n' and (str[2] | 0x20) == 'i' and (str[3] | 0x20) == 't' and (str[4] | 0x20) == 'y') {
                str += 5;
            }
        } else if (@intFromPtr(str + 2) < @intFromPtr(top) and (str[0] | 0x20) == 'n' and (str[1] | 0x20) == 'a' and (str[2] | 0x20) == 'n') {
            str += 3;
            dec_val = NAN_F;
        } else {
            str = mp_parse_float_internal(str, @intFromPtr(top) - @intFromPtr(str), &dec_val);
            if (str == null) {
                try raiseExc(invalidNumberExc(), lex);
                unreachable;
            }
        }

        // 'j' suffix → mark imaginary. Only meaningful when COMPLEX is on;
        // under nano (complex_enabled=false) this branch comptime-elides
        // and the allow_imag arg is ignored (matches vendor's COMPLEX=0
        // path which #if-removes the whole block).
        if (comptime complex_enabled) {
            if (allow_imag and @intFromPtr(str) < @intFromPtr(top) and (str[0] | 0x20) == 'j') {
                if (str == str_val_start) dec_val = 1; // "j" → "1j"
                str += 1;
                state |= DECIMAL_STATE_HAVE_IMAG;
            }
        }

        if (dec_neg) dec_val = -dec_val;
        if (str == str_val_start) {
            try raiseExc(invalidNumberExc(), lex);
            unreachable;
        }

        while (@intFromPtr(str) < @intFromPtr(top) and unichar_isspace(str[0])) : (str += 1) {}
        if (str != top) {
            if (comptime complex_enabled) {
                if (force_complex and state == DECIMAL_STATE_START) {
                    // "3+4j" two-pass: captured real, parse imag.
                    dec_real = dec_val;
                    dec_val = 0;
                    state |= DECIMAL_STATE_HAVE_REAL;
                    continue :parse_loop;
                }
            }
            try raiseExc(invalidNumberExc(), lex);
            unreachable;
        }
        break :parse_loop;
    }

    if (comptime complex_enabled) {
        if (state == DECIMAL_STATE_HAVE_REAL) {
            try raiseExc(invalidNumberExc(), lex); // "3+" with no imag follow-up
            unreachable;
        }
        if (state != DECIMAL_STATE_START) return mp_obj_new_complex(dec_real, dec_val);
        if (force_complex) return mp_obj_new_complex(dec_val, 0);
    }
    return mp_obj_new_float(dec_val);
}

export fn mp_parse_num_float(str_: [*c]const u8, len: usize, allow_imag: bool, lex: Lex) callconv(.c) Obj {
    // Under full, vendor's static-inline mp_parse_num_float inlines to
    // mp_parse_num_decimal at every call site — this export is unused
    // (but harmless to keep). Under nano, this IS the live entry.
    return pyerr.bridge(Obj, parseDecimalImpl(str_, len, allow_imag, false, lex, build_options.is_full));
}

const decimal_glue = if (build_options.is_full) struct {
    pub fn impl(str_in: [*c]const u8, len: usize, allow_imag: bool, force_complex: bool, lex: Lex) PyError!Obj {
        return parseDecimalImpl(str_in, len, allow_imag, force_complex, lex, true);
    }
} else struct {
    pub fn impl(str_: [*c]const u8, len: usize, allow_imag: bool, force_complex: bool, lex: Lex) PyError!Obj {
        _ = .{ str_, len, allow_imag, force_complex, lex };
        unreachable; // never called under nano (vendor's mp_parse_num_float is the real one)
    }
};

export fn mp_parse_num_decimal(str_: [*c]const u8, len: usize, allow_imag: bool, force_complex: bool, lex: Lex) callconv(.c) Obj {
    return pyerr.bridge(Obj, decimal_glue.impl(str_, len, allow_imag, force_complex, lex));
}

comptime {
    _ = &mp_parse_num_integer;
    _ = &mp_parse_num_float;
    _ = &mp_parse_num_decimal;
    _ = &mp_decimal_exp;
    _ = &mp_parse_float_internal;
}
