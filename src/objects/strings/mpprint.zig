//! nanopython — full Zig port of py/mpprint.c.
//! mp_print_str / mp_print_strn (the pad/fill/group state machine),
//! mp_print_int (uint→string base conversion), mp_print_mp_int
//! (objint-coupled), mp_print_float (FLOAT=1 in both nano and full),
//! mp_printf / mp_vprintf (variadic), and the platform/stderr
//! constants mp_plat_print / mp_stderr_print.
//!
//! Faithful (lesson #6): the pad_common table + offset slices are
//! reproduced byte-identically; size_t/int mixed arithmetic mirrors
//! C (small format widths — isize math, no wrap in practice);
//! SUPPORT_INT_BASE_PREFIX=0 (dead, omitted). mp_print_int's
//! `x = -x` on mp_uint_t is wrapping negate (`0 -% x`).

const std = @import("std");
const mp = @cImport({
    @cInclude("py/mpprint.h");
});

// mp_vprintf / mp_printf are in src/objects/strings/va_ops.c — see
// that file for why the va_list-touching code can't stay in Zig on
// aarch64-Linux under the LLVM backend.

const Print = ?*const anyopaque; // const mp_print_t *

// mp_print_t layout (mpprint.h): { void *data; mp_print_strn_t print_strn; }
const PrintStrnFn = *const fn (?*anyopaque, [*c]const u8, usize) callconv(.c) void;
const PrintT = extern struct {
    data: ?*anyopaque,
    print_strn: PrintStrnFn,
};

// Vendor symbols used below.
extern fn mp_hal_stdout_tx_strn_cooked(str: [*c]const u8, len: usize) callconv(.c) void;
extern fn qstr_data(q: usize, len_out: *usize) callconv(.c) [*c]const u8;
extern fn m_free(ptr: ?*anyopaque) callconv(.c) void;
extern fn mp_format_float(f: f64, buf: [*c]u8, buf_size: usize, fmt: u8, prec: c_int, sign: u8) callconv(.c) c_int;

// pad_spaces[16] and pad_common[23] — byte-identical to mpprint.c
const pad_spaces = [_]u8{' '} ** 16;
const pad_common = [23]u8{
    '0', '0', '0', '0', '0', '0', '0', '0', '0', '0', '0', '0',
    '0', '0', '0', '0', '_', '0', '0', '0', ',', '0', '0',
};
// pad_zeroes = common+0 (16); _underscore = common+12 (5);
// _comma = common+17 (4)
const pad_zeroes_size: usize = 16;
const pad_zeroes_underscore_off: usize = 12;
const pad_zeroes_underscore_size: usize = 5;
const pad_zeroes_comma_off: usize = 17;
const pad_zeroes_comma_size: usize = 4;

// Inline the former npy_pr_emit helper: call the print_strn function pointer.
inline fn emit(print: Print, p: [*c]const u8, n: usize) void {
    const pt: *const PrintT = @ptrCast(@alignCast(print));
    pt.print_strn(pt.data, p, n);
}

// mp_vprintf 'l'/'ll' format support — comptime-folded sizeof comparisons.
// MP_INT_MAX corresponds to @sizeOf(isize); mp_uint_t = usize on this build.
const support_l_format: bool = @sizeOf(c_long) > @sizeOf(c_int) and @sizeOf(c_long) == @sizeOf(isize);
const support_ll_format: bool = @sizeOf(isize) > @sizeOf(c_long);
const long_is_uint_t: bool = @sizeOf(c_long) == @sizeOf(usize);
const int_is_uint_t: bool = @sizeOf(c_int) == @sizeOf(usize);

export fn mp_print_str(print: Print, str: [*c]const u8) c_int {
    const len = std.mem.span(@as([*:0]const u8, @ptrCast(str))).len;
    if (len != 0) emit(print, str, len);
    return @intCast(len);
}

export fn mp_print_strn(print: Print, str: [*c]const u8, len: usize, flags: c_uint, fill: u8, width_in: c_int) c_int {
    var left_pad: isize = 0;
    var right_pad: isize = 0;
    var pad: isize = @as(isize, width_in) - @as(isize, @bitCast(len));
    var width: isize = width_in;
    var pad_size: isize = undefined;
    var total: isize = 0;
    var pad_base: [*]const u8 = undefined;
    var pad_off: usize = 0;
    const grouping: u8 = @truncate(flags >> @intCast(mp.PF_FLAG_SEP_POS));

    if (fill == 0 or fill == ' ') {
        pad_base = &pad_spaces;
        pad_size = pad_spaces.len;
    } else if (fill == '0' and grouping == 0) {
        pad_base = &pad_common;
        pad_size = @intCast(pad_zeroes_size);
    } else if (fill == '0') {
        if (grouping == '_') {
            pad_base = pad_common[pad_zeroes_underscore_off..].ptr;
            pad_size = @intCast(pad_zeroes_underscore_size);
        } else {
            pad_base = pad_common[pad_zeroes_comma_off..].ptr;
            pad_size = @intCast(pad_zeroes_comma_size);
        }
        if (@rem(width, pad_size) == 0) {
            pad += 1;
            width += 1;
        }
        pad_off = @intCast(pad_size - 1 - @rem(width, pad_size));
    } else {
        // single non-standard fill char, 1 at a time
        pad_base = @ptrCast(&fill);
        pad_size = 1;
    }

    if ((flags & @as(c_uint, @intCast(mp.PF_FLAG_CENTER_ADJUST))) != 0) {
        left_pad = @divTrunc(pad, 2);
        right_pad = pad - left_pad;
    } else if ((flags & @as(c_uint, @intCast(mp.PF_FLAG_LEFT_ADJUST))) != 0) {
        right_pad = pad;
    } else {
        left_pad = pad;
    }

    if (left_pad > 0) {
        total += left_pad;
        while (left_pad > 0) {
            var p = left_pad;
            if (p > pad_size) p = pad_size;
            emit(print, pad_base + pad_off, @intCast(p));
            left_pad -= p;
        }
    }
    if (len != 0) {
        emit(print, str, len);
        total += @as(isize, @bitCast(len));
    }
    if (right_pad > 0) {
        total += right_pad;
        while (right_pad > 0) {
            var p = right_pad;
            if (p > pad_size) p = pad_size;
            emit(print, pad_base + pad_off, @intCast(p));
            right_pad -= p;
        }
    }
    return @intCast(total);
}

const INT_BUF_SIZE: usize = @sizeOf(isize) * 4;

export fn mp_print_int(print: Print, x_in: usize, sgn: c_int, base: c_int, base_char: c_int, flags: c_uint, fill: u8, width_in: c_int) c_int {
    var x = x_in;
    var width = width_in;
    var sign: u8 = 0;
    if (sgn != 0) {
        if (@as(isize, @bitCast(x)) < 0) {
            sign = '-';
            x = 0 -% x; // wrapping negate (mp_uint_t)
        } else if ((flags & @as(c_uint, @intCast(F(mp.PF_FLAG_SHOW_SIGN)))) != 0) {
            sign = '+';
        } else if ((flags & @as(c_uint, @intCast(F(mp.PF_FLAG_SPACE_SIGN)))) != 0) {
            sign = ' ';
        }
    }

    var buf: [INT_BUF_SIZE]u8 = undefined;
    var b: usize = INT_BUF_SIZE; // index of one-past current digit (fill downward)
    const ubase: usize = @intCast(base);
    if (x == 0) {
        b -= 1;
        buf[b] = '0';
    } else {
        while (true) {
            var ch: usize = x % ubase;
            x /= ubase;
            if (ch >= 10) {
                ch += @as(usize, @intCast(base_char)) - 10;
            } else {
                ch += '0';
            }
            b -= 1;
            buf[b] = @truncate(ch);
            if (!(b > 0 and x != 0)) break;
        }
    }

    var len: c_int = 0;
    // SUPPORT_INT_BASE_PREFIX=0 → prefix branches omitted (dead)
    if ((flags & @as(c_uint, @intCast(F(mp.PF_FLAG_PAD_AFTER_SIGN)))) != 0) {
        if (sign != 0) {
            len += mp_print_strn(print, @ptrCast(&sign), 1, flags, fill, 1);
            width -= 1;
        }
    } else {
        if (sign != 0 and b > 0) {
            b -= 1;
            buf[b] = sign;
        }
    }
    len += mp_print_strn(print, buf[b..].ptr, INT_BUF_SIZE - b, flags, fill, width);
    return len;
}

// Post-B2 port: mp_print_mp_int (the int-format beast, ~130 LOC C → Zig).
//
// Faithful to the C body: stack-local [4*sizeof(mp_int_t)]u8 buffer for
// mp_obj_int_formatted, optional heap fallback (handled inside int_formatted),
// PAD_AFTER_SIGN sign-split, prec→zero-padded prec_width logic, then
// dispatch through mp_print_strn for the final framing.

const Obj = usize; // mp_obj_t under REPR_A (uintptr-shaped)
extern fn mp_obj_int_formatted(buf_inout: *[*c]u8, buf_size_inout: *usize, fmt_size_out: *usize, self_in: Obj, base: c_int, prefix: [*c]const u8, base_char: u8, comma: u8) callconv(.c) [*c]u8;
extern fn mp_obj_int_sign(self_in: Obj) callconv(.c) c_int;
extern fn mp_obj_get_int(arg: Obj) callconv(.c) isize;
extern const mp_type_int: anyopaque;

// mp_obj_is_int (obj.h macro): small-int tag OR base.type == &mp_type_int.
// REPR_A: small-int has low bit set; obj-base lookup needs the obj-tag check.
inline fn objIsInt(o: Obj) bool {
    if ((o & 1) != 0) return true; // small int
    if (o == 0 or (o & 3) != 0) return false; // not a heap obj
    const base: *const struct { type: *const anyopaque } = @ptrFromInt(o);
    return base.type == &mp_type_int;
}

// MP_OBJ_NEW_SMALL_INT under REPR_A: (v << 1) | 1.
inline fn smallInt(v: isize) Obj {
    return @bitCast((v << 1) | 1);
}

// Convenience: hoist c_int flag constants to c_uint for bitwise ops.
inline fn F(flag: c_int) c_uint {
    return @intCast(flag);
}

export fn mp_print_mp_int(print: Print, x_in: Obj, base: c_uint, base_char_in: c_int, flags_in: c_uint, fill_in: u8, width_in: c_int, prec_in: c_int) c_int {
    std.debug.assert(base == 2 or base == 8 or base == 10 or base == 16);

    var x = x_in;
    var flags = flags_in;
    var fill = fill_in;
    var width = width_in;
    var prec = prec_in;
    const base_char: u8 = @intCast(base_char_in);

    if (!objIsInt(x)) {
        x = smallInt(mp_obj_get_int(x));
    }

    if ((flags & (F(mp.PF_FLAG_LEFT_ADJUST) | F(mp.PF_FLAG_CENTER_ADJUST))) == 0 and fill == '0') {
        if (prec > width) width = prec;
        prec = 0;
    }

    var prefix_buf: [4]u8 = .{ 0, 0, 0, 0 };
    var prefix_w: usize = 0;

    if (mp_obj_int_sign(x) >= 0) {
        if ((flags & F(mp.PF_FLAG_SHOW_SIGN)) != 0) {
            prefix_buf[prefix_w] = '+';
            prefix_w += 1;
        } else if ((flags & F(mp.PF_FLAG_SPACE_SIGN)) != 0) {
            prefix_buf[prefix_w] = ' ';
            prefix_w += 1;
        }
    }

    if ((flags & F(mp.PF_FLAG_SHOW_PREFIX)) != 0) {
        if (base == 2) {
            prefix_buf[prefix_w] = '0';
            prefix_w += 1;
            prefix_buf[prefix_w] = base_char + 'b' - 'a';
            prefix_w += 1;
        } else if (base == 8) {
            prefix_buf[prefix_w] = '0';
            prefix_w += 1;
            if ((flags & F(mp.PF_FLAG_SHOW_OCTAL_LETTER)) != 0) {
                prefix_buf[prefix_w] = base_char + 'o' - 'a';
                prefix_w += 1;
            }
        } else if (base == 16) {
            prefix_buf[prefix_w] = '0';
            prefix_w += 1;
            prefix_buf[prefix_w] = base_char + 'x' - 'a';
            prefix_w += 1;
        }
    }
    prefix_buf[prefix_w] = 0; // C-string terminator
    const prefix_len: c_int = @intCast(prefix_w);

    const comma: u8 = @intCast((flags >> @intCast(mp.PF_FLAG_SEP_POS)) & 0xff);

    // Stack buffer (mp_obj_int_formatted falls back to heap if too small).
    var stack_buf: [@sizeOf(isize) * 4]u8 = undefined;
    var buf: [*c]u8 = &stack_buf;
    var buf_size: usize = stack_buf.len;
    var fmt_size: usize = 0;
    var str: [*c]u8 = undefined;

    if (prec > 1) flags |= F(mp.PF_FLAG_PAD_AFTER_SIGN);
    var sign: u8 = 0;
    if ((flags & F(mp.PF_FLAG_PAD_AFTER_SIGN)) != 0) {
        str = mp_obj_int_formatted(&buf, &buf_size, &fmt_size, x, @intCast(base), null, base_char, comma);
        if (str[0] == '-') {
            sign = '-';
            str += 1;
            fmt_size -= 1;
        }
    } else {
        str = mp_obj_int_formatted(&buf, &buf_size, &fmt_size, x, @intCast(base), &prefix_buf[0], base_char, comma);
    }

    var spaces_before: c_int = 0;
    var spaces_after: c_int = 0;

    if (prec > 1) {
        var prec_width: c_int = @intCast(fmt_size);
        if (prec_width < prec) prec_width = prec;
        if ((flags & F(mp.PF_FLAG_PAD_AFTER_SIGN)) != 0) {
            if (sign != 0) prec_width += 1;
            prec_width += prefix_len;
        }
        if (prec_width < width) {
            if ((flags & F(mp.PF_FLAG_LEFT_ADJUST)) != 0) {
                spaces_after = width - prec_width;
            } else {
                spaces_before = width - prec_width;
            }
        }
        fill = '0';
        flags &= ~@as(c_uint, @intCast(mp.PF_FLAG_LEFT_ADJUST));
    }

    var len: c_int = 0;
    if (spaces_before != 0) {
        len += mp_print_strn(print, "", 0, 0, ' ', spaces_before);
    }
    if ((flags & F(mp.PF_FLAG_PAD_AFTER_SIGN)) != 0) {
        if (sign != 0) {
            len += mp_print_strn(print, @ptrCast(&sign), 1, 0, 0, 1);
            width -= 1;
        }
        if (prefix_len != 0) {
            len += mp_print_strn(print, &prefix_buf, @intCast(prefix_len), 0, 0, 1);
            width -= prefix_len;
        }
    }
    if (prec > 1) width = prec;

    len += mp_print_strn(print, str, fmt_size, flags, fill, width);

    if (spaces_after != 0) {
        len += mp_print_strn(print, "", 0, 0, ' ', spaces_after);
    }

    if (buf != @as([*c]u8, &stack_buf)) {
        // m_del(char, buf, buf_size) = m_free(buf) under nano (the
        // MICROPY_MALLOC_USES_ALLOCATED_SIZE=0 arm — buf_size discarded).
        m_free(buf);
    }
    return len;
}


// ── Platform/stderr printers ─────────────────────────────────────────
// mp_plat_print routes to the platform's stdout (mp_hal_stdout_tx_strn_cooked).
fn plat_print_strn(env: ?*anyopaque, str: [*c]const u8, len: usize) callconv(.c) void {
    _ = env;
    mp_hal_stdout_tx_strn_cooked(str, len);
}
pub export const mp_plat_print: PrintT = .{ .data = null, .print_strn = &plat_print_strn };

// mp_stderr_print routes to fd 2 (write(2, ...)); used by the full build's
// MICROPY_ERROR_PRINTER so warnings + tracebacks don't interleave with stdout.
// Faithful to vendor's unix main.c (fwrite+fflush on stderr) — the unix
// stdio is line-buffered, so the explicit fflush is needed there; with
// write(2) the system call is unbuffered so no flush is required.
const unistd = @cImport({
    @cInclude("unistd.h");
});
fn stderr_print_strn(env: ?*anyopaque, str: [*c]const u8, len: usize) callconv(.c) void {
    _ = env;
    _ = unistd.write(2, str, len);
}
pub export const mp_stderr_print: PrintT = .{ .data = null, .print_strn = &stderr_print_strn };

// repr(float): vendor's `prec` value asking for "optimal repr" (formatfloat.h).
const MP_FLOAT_REPR_PREC: c_int = 99;

// repr(float) as CPython prints it: the shortest digits that round-trip
// (std.fmt's {e} is Ryu), positional when the exponent is in [-4, 16),
// scientific otherwise. Vendor's mp_format_float approximates, and gets
// the last digit wrong (sqrt(2) ends in 952, 5e-324 prints as 1.8e-323).
// Finite values only; returns the length, NUL-terminated.
fn formatFloatRepr(f: f64, buf: []u8, sign: u8) usize {
    var tmp: [32]u8 = undefined;
    const sci = std.fmt.bufPrint(&tmp, "{e}", .{@abs(f)}) catch unreachable;
    const e_at = std.mem.indexOfScalar(u8, sci, 'e').?;
    const exp = std.fmt.parseInt(i32, sci[e_at + 1 ..], 10) catch unreachable;
    var digits: [24]u8 = undefined;
    var nd: usize = 0;
    for (sci[0..e_at]) |c| {
        if (c != '.') {
            digits[nd] = c;
            nd += 1;
        }
    }
    var n: usize = 0;
    if (std.math.signbit(f)) {
        buf[n] = '-';
        n += 1;
    } else if (sign != 0) {
        buf[n] = sign;
        n += 1;
    }
    if (exp < -4 or exp >= 16) {
        buf[n] = digits[0];
        n += 1;
        if (nd > 1) {
            buf[n] = '.';
            @memcpy(buf[n + 1 .. n + nd], digits[1..nd]);
            n += nd;
        }
        const e_sign: u8 = if (exp < 0) '-' else '+';
        n += (std.fmt.bufPrint(buf[n..], "e{c}{d:0>2}", .{ e_sign, @abs(exp) }) catch unreachable).len;
    } else if (exp < 0) {
        const zeros: usize = @intCast(-exp - 1);
        @memcpy(buf[n .. n + 2], "0.");
        @memset(buf[n + 2 .. n + 2 + zeros], '0');
        n += 2 + zeros;
        @memcpy(buf[n .. n + nd], digits[0..nd]);
        n += nd;
    } else {
        const int_len: usize = @intCast(exp + 1);
        if (nd <= int_len) {
            @memcpy(buf[n .. n + nd], digits[0..nd]);
            @memset(buf[n + nd .. n + int_len], '0');
            n += int_len;
        } else {
            @memcpy(buf[n .. n + int_len], digits[0..int_len]);
            buf[n + int_len] = '.';
            @memcpy(buf[n + int_len + 1 .. n + nd + 1], digits[int_len..nd]);
            n += nd + 1;
        }
    }
    buf[n] = 0;
    return n;
}

// ── mp_print_float ───────────────────────────────────────────────────
// Faithful port of py/mpprint.c's mp_print_float (FLOAT=1 in nano and full),
// except repr, which is shortest round-trip (formatFloatRepr).
export fn mp_print_float(print: Print, f: f64, fmt: u8, flags: c_uint, fill: u8, width: c_int, prec: c_int) c_int {
    var buf: [36]u8 = undefined;
    var sign: u8 = 0;
    var chrs: c_int = 0;
    var w = width;

    if ((flags & F(mp.PF_FLAG_SHOW_SIGN)) != 0) {
        sign = '+';
    } else if ((flags & F(mp.PF_FLAG_SPACE_SIGN)) != 0) {
        sign = ' ';
    }

    var len: c_int = if (prec == MP_FLOAT_REPR_PREC and fmt == 'g' and std.math.isFinite(f))
        @intCast(formatFloatRepr(f, buf[0 .. buf.len - 3], sign))
    else
        mp_format_float(f, &buf, buf.len - 3, fmt, prec, sign);

    // ALWAYS_DECIMAL: append ".0" if no '.', 'e', or 'n' in buffer.
    if ((flags & F(mp.PF_FLAG_ALWAYS_DECIMAL)) != 0) {
        var has_special = false;
        var i: usize = 0;
        const ulen: usize = @intCast(len);
        while (i < ulen) : (i += 1) {
            const b = buf[i];
            if (b == '.' or b == 'e' or b == 'n') {
                has_special = true;
                break;
            }
        }
        if (!has_special) {
            buf[@intCast(len)] = '.';
            len += 1;
            buf[@intCast(len)] = '0';
            len += 1;
            buf[@intCast(len)] = 0;
        }
    }

    if ((flags & F(mp.PF_FLAG_ADD_PERCENT)) != 0) {
        buf[@intCast(len)] = '%';
        len += 1;
        buf[@intCast(len)] = 0;
    }

    var s: [*c]const u8 = &buf;

    // PAD_AFTER_SIGN: if first char is space/+/- (i.e. < '0'), emit it first.
    if ((flags & F(mp.PF_FLAG_PAD_AFTER_SIGN)) != 0 and buf[0] < '0') {
        s += 1;
        chrs += mp_print_strn(print, &buf, 1, 0, 0, 1);
        w -= 1;
        len -= 1;
    }

    chrs += mp_print_strn(print, s, @intCast(len), flags, fill, w);
    return chrs;
}

comptime {
    _ = &mp_print_str;
    _ = &mp_print_strn;
    _ = &mp_print_int;
    _ = &mp_print_mp_int;
    // mp_vprintf / mp_printf live in va_ops.c — the C compile
    // guarantees their export; no comptime reference needed here.
    _ = &mp_print_float;
    _ = &mp_plat_print;
    _ = &mp_stderr_print;
}
