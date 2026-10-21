//! nanopython — Zig port of py/unicode.c. Binary-verified LIVE
//! (unichar_isalpha/tolower used by lexer.c[Zig] + objstr.c). MICROPY_PY_BUILTINS_STR_UNICODE=0
//! (probed) ⇒ the utf8_* fns are #if-dead; nano exports exactly the
//! 11 ASCII unichar_* below. No nlr / no obj / no headers → shimless
//! `export fn` (the smallint recipe).
//!
//! `unichar` = 4-byte (verified) = u32; `bool` = C _Bool; `mp_uint_t`
//! = usize. The file-local `attr[128]` table is rebuilt here from the
//! SAME FL_*/AT_* symbolic source as the C array literal (not
//! hand-computed bytes — faithful by construction, no transcription
//! risk). Faithful (lesson #6): C `&&` short-circuits the table
//! index (guarded by `c < 128`); signed/`mp_uint_t` arithmetic in
//! xdigit_value via `-%`/`&~` exactly as C under -fno-sanitize.

const Uc = u32; // unichar
const UInt = usize; // mp_uint_t

// attribute flags (verbatim from py/unicode.c)
const FL_PRINT: u8 = 0x01;
const FL_SPACE: u8 = 0x02;
const FL_DIGIT: u8 = 0x04;
const FL_ALPHA: u8 = 0x08;
const FL_UPPER: u8 = 0x10;
const FL_LOWER: u8 = 0x20;
const FL_XDIGIT: u8 = 0x40;

const AT_PR: u8 = FL_PRINT;
const AT_SP: u8 = FL_SPACE | FL_PRINT;
const AT_DI: u8 = FL_DIGIT | FL_PRINT | FL_XDIGIT;
const AT_AL: u8 = FL_ALPHA | FL_PRINT; // (unused in the table, kept for parity)
const AT_UP: u8 = FL_UPPER | FL_ALPHA | FL_PRINT;
const AT_LO: u8 = FL_LOWER | FL_ALPHA | FL_PRINT;
const AT_UX: u8 = FL_UPPER | FL_ALPHA | FL_PRINT | FL_XDIGIT;
const AT_LX: u8 = FL_LOWER | FL_ALPHA | FL_PRINT | FL_XDIGIT;

// table of attributes for ascii characters — identical literal to C
const attr = [128]u8{
    0,     0,     0,     0,     0,     0,     0,     0,
    0,     AT_SP, AT_SP, AT_SP, AT_SP, AT_SP, 0,     0,
    0,     0,     0,     0,     0,     0,     0,     0,
    0,     0,     0,     0,     0,     0,     0,     0,
    AT_SP, AT_PR, AT_PR, AT_PR, AT_PR, AT_PR, AT_PR, AT_PR,
    AT_PR, AT_PR, AT_PR, AT_PR, AT_PR, AT_PR, AT_PR, AT_PR,
    AT_DI, AT_DI, AT_DI, AT_DI, AT_DI, AT_DI, AT_DI, AT_DI,
    AT_DI, AT_DI, AT_PR, AT_PR, AT_PR, AT_PR, AT_PR, AT_PR,
    AT_PR, AT_UX, AT_UX, AT_UX, AT_UX, AT_UX, AT_UX, AT_UP,
    AT_UP, AT_UP, AT_UP, AT_UP, AT_UP, AT_UP, AT_UP, AT_UP,
    AT_UP, AT_UP, AT_UP, AT_UP, AT_UP, AT_UP, AT_UP, AT_UP,
    AT_UP, AT_UP, AT_UP, AT_PR, AT_PR, AT_PR, AT_PR, AT_PR,
    AT_PR, AT_LX, AT_LX, AT_LX, AT_LX, AT_LX, AT_LX, AT_LO,
    AT_LO, AT_LO, AT_LO, AT_LO, AT_LO, AT_LO, AT_LO, AT_LO,
    AT_LO, AT_LO, AT_LO, AT_LO, AT_LO, AT_LO, AT_LO, AT_LO,
    AT_LO, AT_LO, AT_LO, AT_PR, AT_PR, AT_PR, AT_PR, 0,
};

inline fn at(c: Uc) u8 {
    return attr[@as(usize, c)]; // only reached when c < 128 (C && guard)
}

pub export fn unichar_isspace(c: Uc) bool {
    return c < 128 and (at(c) & FL_SPACE) != 0;
}
pub export fn unichar_isalpha(c: Uc) bool {
    return c < 128 and (at(c) & FL_ALPHA) != 0;
}
pub export fn unichar_isdigit(c: Uc) bool {
    return c < 128 and (at(c) & FL_DIGIT) != 0;
}
pub export fn unichar_isxdigit(c: Uc) bool {
    return c < 128 and (at(c) & FL_XDIGIT) != 0;
}
pub export fn unichar_isident(c: Uc) bool {
    return c < 128 and ((at(c) & (FL_ALPHA | FL_DIGIT)) != 0 or c == '_');
}
pub export fn unichar_isalnum(c: Uc) bool {
    return c < 128 and ((at(c) & (FL_ALPHA | FL_DIGIT)) != 0);
}
pub export fn unichar_isupper(c: Uc) bool {
    return c < 128 and (at(c) & FL_UPPER) != 0;
}
pub export fn unichar_islower(c: Uc) bool {
    return c < 128 and (at(c) & FL_LOWER) != 0;
}
pub export fn unichar_tolower(c: Uc) Uc {
    if (unichar_isupper(c)) return c +% 0x20;
    return c;
}
pub export fn unichar_toupper(c: Uc) Uc {
    if (unichar_islower(c)) return c -% 0x20;
    return c;
}
pub export fn unichar_xdigit_value(c: Uc) UInt {
    // c is assumed to be a hex digit
    var n: UInt = @as(UInt, c) -% '0';
    if (n > 9) {
        n &= ~@as(UInt, 'a' - 'A'); // ~0x20
        n -%= ('A' - ('9' + 1)); // 7
    }
    return n;
}

// MICROPY_PY_BUILTINS_STR_UNICODE — vendor unicode.c lines 72-114. Only
// referenced under full; under nano these are dead-code (no caller).
// Defined unconditionally in Zig so they're always link-available; the
// gate is purely in the C-side callers.
inline fn isCont(c: u8) bool { return (c & 0xC0) == 0x80; }
inline fn isNonAscii(c: u8) bool { return (c & 0x80) != 0; }

pub export fn utf8_get_char(s_in: [*]const u8) Uc {
    var s = s_in;
    var ord: Uc = s[0]; s += 1;
    if (!isNonAscii(@truncate(ord))) return ord;
    ord &= 0x7F;
    var mask: Uc = 0x40;
    while ((ord & mask) != 0) : (mask >>= 1) {
        ord &= ~mask;
    }
    while (isCont(s[0])) {
        ord = (ord << 6) | (s[0] & 0x3F);
        s += 1;
    }
    return ord;
}

pub export fn utf8_next_char(s_in: [*]const u8) [*]const u8 {
    var s = s_in + 1;
    while (isCont(s[0])) : (s += 1) {}
    return s;
}

pub export fn utf8_charlen(str_in: [*]const u8, len: usize) usize {
    var s = str_in;
    const top = str_in + len;
    var charlen: usize = 0;
    while (@intFromPtr(s) < @intFromPtr(top)) : (s += 1) {
        if (!isCont(s[0])) charlen += 1;
    }
    return charlen;
}

pub export fn utf8_ptr_to_index(s: [*]const u8, ptr_in: [*]const u8) usize {
    var ptr = ptr_in;
    var i: usize = 0;
    while (@intFromPtr(ptr) > @intFromPtr(s)) {
        ptr -= 1;
        if (!isCont(ptr[0])) i += 1;
    }
    return i;
}

comptime {
    _ = &unichar_isspace;
    _ = &unichar_isalpha;
    _ = &unichar_isdigit;
    _ = &unichar_isxdigit;
    _ = &unichar_isident;
    _ = &unichar_isalnum;
    _ = &unichar_isupper;
    _ = &unichar_islower;
    _ = &unichar_tolower;
    _ = &unichar_toupper;
    _ = &unichar_xdigit_value;
    _ = &utf8_get_char;
    _ = &utf8_next_char;
    _ = &utf8_charlen;
    _ = &utf8_ptr_to_index;
}
