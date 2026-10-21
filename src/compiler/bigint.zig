//! Arbitrary-precision integer support for the compiler track.
//!
//! Thin layer over std.math.big.int.Managed. Two responsibilities:
//!
//!   * `parseLiteral` — accept the raw text from an integer literal
//!     (with optional `0x`/`0o`/`0b` prefix, internal `_` separators,
//!     and an optional leading `-` for fold-injected negatives) and
//!     return an owned Managed value.
//!
//!   * `toDecimalString` — emit the canonical signed-decimal text
//!     representation. Matches mpy-cross's `mp_obj_print_helper`
//!     (PRINT_REPR) output: no leading zeros, leading `-` for
//!     negatives, "0" for zero.
//!
//! Used by compile.zig's `compileConstObject` to normalize an
//! int_big payload before it lands in the .mpy constant table.
//! Vendor mpy-cross always stores int_big as decimal text (see
//! py/persistentcode.c, parsenum.c base=10); passing the original
//! source text (hex / octal / binary) through unchanged produces a
//! byte-mismatch on every non-decimal literal that overflows the
//! 30-bit SMALL_INT gate.
//!
//! No fold logic here — that's a separate layer in parser.zig.

const std = @import("std");

pub const Managed = std.math.big.int.Managed;
pub const ParseError = error{
    InvalidCharacter,
    InvalidBase,
    OutOfMemory,
};

/// Parse an integer literal into a freshly-allocated Managed.
///
/// Accepts:
///   * optional leading `-` (single sign; `+` is rejected — neither
///     vendor mp_parse_num_integer nor our lexer produces a `+`
///     prefix on integer literals)
///   * optional `0x`/`0X`, `0o`/`0O`, `0b`/`0B` base prefix
///   * internal `_` separators (silently skipped — Python 3.6+ PEP-515)
///   * decimal default
///
/// Caller owns the returned Managed and must call `.deinit()`.
pub fn parseLiteral(allocator: std.mem.Allocator, src: []const u8) ParseError!Managed {
    var s = src;
    var negative = false;
    if (s.len > 0 and s[0] == '-') {
        negative = true;
        s = s[1..];
    }
    var base: u8 = 10;
    if (s.len >= 2 and s[0] == '0') {
        switch (s[1]) {
            'x', 'X' => {
                base = 16;
                s = s[2..];
            },
            'o', 'O' => {
                base = 8;
                s = s[2..];
            },
            'b', 'B' => {
                base = 2;
                s = s[2..];
            },
            else => {},
        }
    }
    if (s.len == 0) return error.InvalidCharacter;

    var m = try Managed.init(allocator);
    errdefer m.deinit();
    // Managed.setString skips underscores and handles a leading '-',
    // but we've already stripped the sign so pass the unsigned tail.
    m.setString(base, s) catch |e| switch (e) {
        error.InvalidCharacter => return error.InvalidCharacter,
        error.InvalidBase => return error.InvalidBase,
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (negative) m.negate();
    return m;
}

/// Canonical signed-decimal text representation. Matches the bytes
/// mpy-cross writes for an int_big object: no leading zeros, leading
/// `-` for negatives, "0" for zero, no thousands separators, no
/// trailing newline. Caller owns the returned slice.
pub fn toDecimalString(allocator: std.mem.Allocator, m: Managed) std.mem.Allocator.Error![]u8 {
    // Managed.toString returns `error{InvalidBase} || Allocator.Error`.
    // base=10 is a constant so InvalidBase is unreachable; narrow the
    // error set so callers only have to handle OOM.
    return m.toString(allocator, 10, .lower) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidBase => unreachable,
    };
}

/// Convenience: parse + normalize in one shot. Returns canonical
/// decimal text. Caller owns the result slice.
pub fn normalizeToDecimal(allocator: std.mem.Allocator, src: []const u8) ParseError![]u8 {
    var m = try parseLiteral(allocator, src);
    defer m.deinit();
    return toDecimalString(allocator, m) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
}

/// Supported binary operators for parse-time constant folding.
/// Mirrors vendor `binary_op_maybe` (parse.c). Parser dispatches via
/// token / rule_kind, then names the op for this layer — bigint stays
/// agnostic about source-level syntax.
pub const BinOp = enum {
    add, // +
    sub, // -
    mul, // *
    floordiv, // //   Python floor: divFloor (q, r) → q
    mod, //       %   Python mod (euclidean for floor) → r from divFloor
    shl, //       <<
    shr, //       >>
    bor, //       |
    bxor, //      ^
    band, //      &
    pow, //       **  (non-negative integer exponent only — neg returns float)
};

pub const UnOp = enum {
    pos, // +x (identity)
    neg, // -x
    invert, // ~x  ≡  -(x + 1)
};

/// Cap on shift count to avoid runaway memory at compile time.
/// Anything above ~64K-bit shifts is unrealistic for a literal const
/// expression and likely a runtime-overflow test best left to the VM.
/// Vendor mp_obj_int_binary_op has no such cap but it's running in a
/// long-lived runtime; we're in the compiler's parse phase.
const MAX_SHIFT_BITS: usize = 1 << 16;

/// Cap on `**` exponent. Vendor has no cap but we're at compile time
/// — `2 ** 1000000` would allocate megabytes of decimal text for a
/// value the VM may never reach. 4096 lets every realistic source
/// literal fold and rejects pathological cases.
const MAX_POW_EXPONENT: i64 = 4096;

/// Apply a binary op on big-int operand texts and return canonical
/// decimal text, or null when the op is unsupported / pre-conditions
/// fail (div-by-zero, negative or oversized shift). Caller owns the
/// returned slice.
pub fn foldBinary(
    allocator: std.mem.Allocator,
    op: BinOp,
    a_text: []const u8,
    b_text: []const u8,
) ParseError!?[]u8 {
    var a = try parseLiteral(allocator, a_text);
    defer a.deinit();
    var b = try parseLiteral(allocator, b_text);
    defer b.deinit();

    var r = try Managed.init(allocator);
    defer r.deinit();

    switch (op) {
        .add => r.add(&a, &b) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
        },
        .sub => r.sub(&a, &b) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
        },
        .mul => r.mul(&a, &b) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
        },
        .floordiv, .mod => {
            if (b.eqlZero()) return null;
            var q = try Managed.init(allocator);
            defer q.deinit();
            var rem = try Managed.init(allocator);
            defer rem.deinit();
            q.divFloor(&rem, &a, &b) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
            };
            const pick = if (op == .floordiv) q else rem;
            const dec = try toDecimalString(allocator, pick);
            return dec;
        },
        .shl, .shr => {
            const shift_i = b.toInt(i64) catch return null;
            if (shift_i < 0) return null;
            const shift: usize = @intCast(shift_i);
            if (op == .shl) {
                if (shift > MAX_SHIFT_BITS) return null;
                r.shiftLeft(&a, shift) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                };
            } else {
                r.shiftRight(&a, shift) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                };
            }
        },
        .bor, .bxor, .band => {
            // Zig 0.16 std.math.big.int.Managed bitOr/bitAnd/bitXor have
            // a correctness bug for mixed-sign large-magnitude inputs:
            // e.g. (-A) | B where A ≫ B and A spans multiple 64-bit
            // limbs produces a wildly wrong magnitude (verified against
            // CPython). Small cases (-5|3, -10|4, etc.) compute
            // correctly. Rather than reimplement signed bitwise ops on
            // limbs, skip the fold when any operand is negative — the
            // VM's mpz path handles it correctly via two's-complement
            // semantics at runtime. This costs us a few bytes of fold
            // optimisation but preserves execution equivalence, which is
            // the actual gate.
            if (!a.isPositive() or !b.isPositive()) return null;
            switch (op) {
                .bor => r.bitOr(&a, &b) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                },
                .bxor => r.bitXor(&a, &b) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                },
                .band => r.bitAnd(&a, &b) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                },
                else => unreachable,
            }
        },
        .pow => {
            // Vendor (parse.c:766 → mp_binary_op → mp_obj_int_pow):
            // integer ** non-negative integer. Negative exponent
            // returns a float in Python, which we never fold — bail.
            const exp_i = b.toInt(i64) catch return null;
            if (exp_i < 0) return null;
            if (exp_i > MAX_POW_EXPONENT) return null;
            r.pow(&a, @intCast(exp_i)) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
            };
        },
    }
    const dec = try toDecimalString(allocator, r);
    return dec;
}

/// Apply a unary op on a big-int operand text. Caller owns the
/// returned slice.
pub fn foldUnary(
    allocator: std.mem.Allocator,
    op: UnOp,
    a_text: []const u8,
) ParseError!?[]u8 {
    var a = try parseLiteral(allocator, a_text);
    defer a.deinit();
    switch (op) {
        .pos => {},
        .neg => a.negate(),
        .invert => {
            // ~x == -(x + 1)
            a.addScalar(&a, @as(i32, 1)) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
            };
            a.negate();
        },
    }
    const dec = try toDecimalString(allocator, a);
    return dec;
}

/// If a Managed value fits the SMALL_INT window used by the parser
/// for inline integer leaves, return that value; else null. Used
/// after a successful bigint fold to choose between pnNewSmallInt
/// and makeNodeConstObject(.integer) — the same shape rule vendor's
/// `make_node_const_object_optimised` enforces.
///
/// SMALL_INT range matches MP_SMALL_INT_BITS=63 for MICROPY_OBJ_REPR_A
/// on a 64-bit host (the configured nano + full build).
pub fn tryToSmallInt(m: Managed) ?isize {
    const SMALL_INT_MAX: isize = (1 << 62) - 1;
    const SMALL_INT_MIN: isize = -(1 << 62);
    const v = m.toInt(i64) catch return null;
    const iv: isize = @intCast(v);
    if (iv < SMALL_INT_MIN or iv > SMALL_INT_MAX) return null;
    return iv;
}

/// Parse + classify in one call. Either the value fits SMALL_INT (no
/// allocation needed for `.small`) or it's a true big-int and the
/// canonical decimal text is returned (caller owns).
pub const FoldResult = union(enum) {
    small: isize,
    big_decimal: []u8,
};

pub fn classifyText(allocator: std.mem.Allocator, src: []const u8) ParseError!FoldResult {
    var m = try parseLiteral(allocator, src);
    defer m.deinit();
    if (tryToSmallInt(m)) |v| return .{ .small = v };
    const dec = try toDecimalString(allocator, m);
    return .{ .big_decimal = dec };
}

// ─── tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "parseLiteral decimal" {
    var m = try parseLiteral(testing.allocator, "12345");
    defer m.deinit();
    const s = try toDecimalString(testing.allocator, m);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("12345", s);
}

test "parseLiteral negative decimal" {
    var m = try parseLiteral(testing.allocator, "-1");
    defer m.deinit();
    const s = try toDecimalString(testing.allocator, m);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("-1", s);
}

test "parseLiteral zero" {
    var m = try parseLiteral(testing.allocator, "0");
    defer m.deinit();
    const s = try toDecimalString(testing.allocator, m);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("0", s);
}

test "parseLiteral hex lower" {
    var m = try parseLiteral(testing.allocator, "0xff");
    defer m.deinit();
    const s = try toDecimalString(testing.allocator, m);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("255", s);
}

test "parseLiteral hex upper-prefix" {
    var m = try parseLiteral(testing.allocator, "0XdeadBEEF");
    defer m.deinit();
    const s = try toDecimalString(testing.allocator, m);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("3735928559", s);
}

test "parseLiteral octal" {
    var m = try parseLiteral(testing.allocator, "0o17");
    defer m.deinit();
    const s = try toDecimalString(testing.allocator, m);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("15", s);
}

test "parseLiteral binary" {
    var m = try parseLiteral(testing.allocator, "0b1010");
    defer m.deinit();
    const s = try toDecimalString(testing.allocator, m);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("10", s);
}

test "parseLiteral underscores" {
    var m = try parseLiteral(testing.allocator, "1_000_000");
    defer m.deinit();
    const s = try toDecimalString(testing.allocator, m);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("1000000", s);
}

test "parseLiteral hex with underscores" {
    var m = try parseLiteral(testing.allocator, "0xff_ff");
    defer m.deinit();
    const s = try toDecimalString(testing.allocator, m);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("65535", s);
}

test "parseLiteral 2**64-1 (hex)" {
    var m = try parseLiteral(testing.allocator, "0xffffffffffffffff");
    defer m.deinit();
    const s = try toDecimalString(testing.allocator, m);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("18446744073709551615", s);
}

test "parseLiteral 2**128-1 (hex, beyond i64)" {
    var m = try parseLiteral(testing.allocator, "0xffffffffffffffffffffffffffffffff");
    defer m.deinit();
    const s = try toDecimalString(testing.allocator, m);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("340282366920938463463374607431768211455", s);
}

test "parseLiteral -(2**63) (signed, hex)" {
    var m = try parseLiteral(testing.allocator, "-0x8000000000000000");
    defer m.deinit();
    const s = try toDecimalString(testing.allocator, m);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("-9223372036854775808", s);
}

test "normalizeToDecimal — hex shorthand" {
    const s = try normalizeToDecimal(testing.allocator, "0x100");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("256", s);
}

test "normalizeToDecimal — already decimal is idempotent" {
    const s = try normalizeToDecimal(testing.allocator, "1000000000000000000000");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("1000000000000000000000", s);
}

test "isize parity sweep — same as std.fmt for values in range" {
    // Any value we hand to bigint after passing isize parse should
    // produce the same decimal text as std.fmt.allocPrint("{d}", ...).
    // This is what guarantees switching the encoding for hex / oct
    // / bin literals in compileConstObject doesn't perturb decimal
    // literals that already pass.
    const values = [_]i64{
        0, 1, -1,
        100, -100, 1073741823, // SMALL_INT_MAX
        -1073741824, // SMALL_INT_MIN
        2147483647, -2147483648, 9223372036854775807, // i64 max
        -9223372036854775807 - 1, // i64 min (avoid the -i64 literal overflow trap)
    };
    for (values) |v| {
        const fmt_s = try std.fmt.allocPrint(testing.allocator, "{d}", .{v});
        defer testing.allocator.free(fmt_s);
        var m = try parseLiteral(testing.allocator, fmt_s);
        defer m.deinit();
        const big_s = try toDecimalString(testing.allocator, m);
        defer testing.allocator.free(big_s);
        try testing.expectEqualStrings(fmt_s, big_s);
    }
}

test "parseLiteral rejects invalid base char" {
    try testing.expectError(error.InvalidCharacter, parseLiteral(testing.allocator, "0xgg"));
}

test "parseLiteral rejects empty after prefix" {
    try testing.expectError(error.InvalidCharacter, parseLiteral(testing.allocator, "0x"));
}

// ─── fold tests ────────────────────────────────────────────────────

test "foldBinary add" {
    const s = (try foldBinary(testing.allocator, .add, "0x8000000000000000", "0x8000000000000000")).?;
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("18446744073709551616", s);
}

test "foldBinary sub yielding zero" {
    const s = (try foldBinary(testing.allocator, .sub, "0xffffffffffffffff", "0xffffffffffffffff")).?;
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("0", s);
}

test "foldBinary mul beyond i64" {
    // (1 << 40) * (1 << 40) = 1 << 80
    const s = (try foldBinary(testing.allocator, .mul, "1099511627776", "1099511627776")).?;
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("1208925819614629174706176", s);
}

test "foldBinary floordiv python semantics" {
    // -7 // 3 == -3 (floor toward -inf, not -2 from C-style trunc)
    const s = (try foldBinary(testing.allocator, .floordiv, "-7", "3")).?;
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("-3", s);
}

test "foldBinary mod euclidean" {
    // -7 % 3 == 2 (positive, matches divFloor remainder)
    const s = (try foldBinary(testing.allocator, .mod, "-7", "3")).?;
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("2", s);
}

test "foldBinary floordiv-by-zero returns null" {
    const r = try foldBinary(testing.allocator, .floordiv, "5", "0");
    try testing.expect(r == null);
}

test "foldBinary shl" {
    // 1 << 65
    const s = (try foldBinary(testing.allocator, .shl, "1", "65")).?;
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("36893488147419103232", s);
}

test "foldBinary shr" {
    // (1 << 65) >> 1 = 1 << 64
    const s = (try foldBinary(testing.allocator, .shr, "36893488147419103232", "1")).?;
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("18446744073709551616", s);
}

test "foldBinary shl rejects negative shift" {
    const r = try foldBinary(testing.allocator, .shl, "1", "-1");
    try testing.expect(r == null);
}

test "foldBinary shl rejects oversize shift" {
    const r = try foldBinary(testing.allocator, .shl, "1", "1000000");
    try testing.expect(r == null);
}

test "foldBinary bitwise on big-ints" {
    const s = (try foldBinary(testing.allocator, .band, "0xffffffffffffffff", "0xff")).?;
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("255", s);
}

test "foldUnary negate" {
    const s = (try foldUnary(testing.allocator, .neg, "0x8000000000000000")).?;
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("-9223372036854775808", s);
}

test "foldUnary invert positive" {
    // ~0x3fffffff == -0x40000000 == -1073741824
    const s = (try foldUnary(testing.allocator, .invert, "0x3fffffff")).?;
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("-1073741824", s);
}

test "foldUnary invert negative" {
    // ~(-5) == 4
    const s = (try foldUnary(testing.allocator, .invert, "-5")).?;
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("4", s);
}

test "tryToSmallInt fits" {
    var m = try parseLiteral(testing.allocator, "1073741823"); // SMALL_INT_MAX
    defer m.deinit();
    try testing.expectEqual(@as(?isize, 1073741823), tryToSmallInt(m));
}

test "tryToSmallInt overflow above" {
    // SMALL_INT_MAX + 1 = 2^62 = 4611686018427387904
    var m = try parseLiteral(testing.allocator, "4611686018427387904");
    defer m.deinit();
    try testing.expect(tryToSmallInt(m) == null);
}

test "tryToSmallInt overflow below" {
    // SMALL_INT_MIN - 1 = -(2^62) - 1 = -4611686018427387905
    var m = try parseLiteral(testing.allocator, "-4611686018427387905");
    defer m.deinit();
    try testing.expect(tryToSmallInt(m) == null);
}

test "classifyText routes correctly" {
    const r_small = try classifyText(testing.allocator, "0");
    try testing.expectEqual(FoldResult{ .small = 0 }, r_small);
    const r_big = try classifyText(testing.allocator, "0xffffffffffffffff");
    defer if (r_big == .big_decimal) testing.allocator.free(r_big.big_decimal);
    try testing.expectEqualStrings("18446744073709551615", r_big.big_decimal);
}
