// Compiler-track lexer — pure Zig Python tokeniser.
//
// Replaces src/frontend/lexer.zig for the C→Zig compiler track. Key
// divergences from the legacy frontend lexer:
//
//   1. No @cImport. The `mp_token_kind_t` enum is mirrored locally as
//      `TokenKind` with the exact same ordinal layout (one variant per
//      vendor MP_TOKEN_* tag). A comptime fingerprint check (NUMBER_OF)
//      catches accidental drift if the vendor enum grows.
//   2. All C-runtime couplings removed: vstr -> std.ArrayList(u8),
//      m_malloc/m_realloc -> std.mem.Allocator, unichar_is* -> inline
//      ASCII predicates, mp_reader_t -> pure-Zig `Reader` struct with
//      function-pointer hooks, npy_optimise_value() -> `debug_mode` field
//      set by the caller at construction time.
//   3. No C-ABI exports. Public API is pure-Zig: `lexerNewFromStr`,
//      `lexerNew`, `lexerToNext`, `lexerFree`.
//   4. No qstr interning inside the lexer. The lexer is a pure tokeniser
//      and accumulates raw NAME/STRING/BYTES bytes into Lexer.vstr; the
//      parser (C4, future) calls qstr_from_strn() on consumption. The
//      ONE qstr touch-point is Lexer.source_name (set by caller at
//      construction time), and even that is just a u16 field — qstr.zig
//      is imported only for the type alias.
//   5. No PyError dependency. The runtime error machinery is replaced
//      with a local `StringParseError` set.
//
// Algorithm is a verbatim port of vendor py/lexer.c, preserving the
// 3-char lookahead state machine, CRLF normalisation, tab expansion,
// indent-stack push/pop, and the encoded operator/delimiter scanner.
//
// FSTRINGS are enabled (port/mpconfigport.h: MICROPY_PY_FSTRINGS=1) so
// the f-string args-buffer apparatus is included. ASYNC_AWAIT is now
// enabled under both nano and full (port/mpconfigport.h:
// MICROPY_PY_ASYNC_AWAIT=1) — KW_ASYNC and KW_AWAIT are unconditional
// slots between KW_ASSERT and KW_BREAK. STR_UNICODE remains config-driven.
//
// Invariant the compiler-track lexer must hold: token streams must be
// byte-identical to vendor `py/lexer.c` across the corpus, validated by
// the differential test harness (token_dump.c + lexer_test.zig).

const std = @import("std");
const build_options = @import("build_options");
const qstr_mod = @import("qstr.zig");

// ASYNC_AWAIT keywords are now wired in at the parse level (A1):
// KW_ASYNC and KW_AWAIT sit between KW_ASSERT and KW_BREAK with
// everything downstream shifted +2. NUMBER_OF: 94 → 96. The keyword
// table and the comptime fingerprint are aligned accordingly. Validation
// (where await may appear) and compile/VM dispatch land in A2/A3/A4.

// STR_UNICODE selects how string-literal escapes are emitted (see vendor
// MICROPY_PY_BUILTINS_STR_UNICODE in py/mpconfig.h, py/lexer.c:495-509).
//   true  → `str` is a Unicode code-point sequence; escapes are encoded
//           as UTF-8 (CPython-compatible default; "\xff" → 2 bytes c3 bf
//           representing U+00FF).
//   false → `str` is a byte sequence; "\xff" → 1 byte ff.
// Independent of full/nano: configure via build.zig `-Dstr-unicode=…`.
const STR_UNICODE = build_options.str_unicode;

// ── Public types ──────────────────────────────────────────────────────────

/// MicroPython token kind. Variant ordinals match vendor mp_token_kind_t
/// for the nano + FSTRINGS + ASYNC_AWAIT config. If the vendor enum
/// is regenerated the comptime fingerprint check at the bottom of this
/// section will fail with a clear message.
pub const TokenKind = enum(u8) {
    END = 0,
    INVALID = 1,
    DEDENT_MISMATCH = 2,
    LONELY_STRING_OPEN = 3,
    MALFORMED_FSTRING = 4,
    NEWLINE = 5,
    INDENT = 6,
    DEDENT = 7,
    NAME = 8,
    INTEGER = 9,
    FLOAT_OR_IMAG = 10,
    STRING = 11,
    BYTES = 12,
    ELLIPSIS = 13,
    KW_FALSE = 14,
    KW_NONE = 15,
    KW_TRUE = 16,
    KW___DEBUG__ = 17,
    KW_AND = 18,
    KW_AS = 19,
    KW_ASSERT = 20,
    KW_ASYNC = 21,
    KW_AWAIT = 22,
    KW_BREAK = 23,
    KW_CLASS = 24,
    KW_CONTINUE = 25,
    KW_DEF = 26,
    KW_DEL = 27,
    KW_ELIF = 28,
    KW_ELSE = 29,
    KW_EXCEPT = 30,
    KW_FINALLY = 31,
    KW_FOR = 32,
    KW_FROM = 33,
    KW_GLOBAL = 34,
    KW_IF = 35,
    KW_IMPORT = 36,
    KW_IN = 37,
    KW_IS = 38,
    KW_LAMBDA = 39,
    KW_NONLOCAL = 40,
    KW_NOT = 41,
    KW_OR = 42,
    KW_PASS = 43,
    KW_RAISE = 44,
    KW_RETURN = 45,
    KW_TRY = 46,
    KW_WHILE = 47,
    KW_WITH = 48,
    KW_YIELD = 49,
    OP_ASSIGN = 50,
    OP_TILDE = 51,
    OP_LESS = 52,
    OP_MORE = 53,
    OP_DBL_EQUAL = 54,
    OP_LESS_EQUAL = 55,
    OP_MORE_EQUAL = 56,
    OP_NOT_EQUAL = 57,
    OP_PIPE = 58,
    OP_CARET = 59,
    OP_AMPERSAND = 60,
    OP_DBL_LESS = 61,
    OP_DBL_MORE = 62,
    OP_PLUS = 63,
    OP_MINUS = 64,
    OP_STAR = 65,
    OP_AT = 66,
    OP_DBL_SLASH = 67,
    OP_SLASH = 68,
    OP_PERCENT = 69,
    OP_DBL_STAR = 70,
    DEL_PIPE_EQUAL = 71,
    DEL_CARET_EQUAL = 72,
    DEL_AMPERSAND_EQUAL = 73,
    DEL_DBL_LESS_EQUAL = 74,
    DEL_DBL_MORE_EQUAL = 75,
    DEL_PLUS_EQUAL = 76,
    DEL_MINUS_EQUAL = 77,
    DEL_STAR_EQUAL = 78,
    DEL_AT_EQUAL = 79,
    DEL_DBL_SLASH_EQUAL = 80,
    DEL_SLASH_EQUAL = 81,
    DEL_PERCENT_EQUAL = 82,
    DEL_DBL_STAR_EQUAL = 83,
    DEL_PAREN_OPEN = 84,
    DEL_PAREN_CLOSE = 85,
    DEL_BRACKET_OPEN = 86,
    DEL_BRACKET_CLOSE = 87,
    DEL_BRACE_OPEN = 88,
    DEL_BRACE_CLOSE = 89,
    DEL_COMMA = 90,
    DEL_COLON = 91,
    DEL_PERIOD = 92,
    DEL_SEMICOLON = 93,
    DEL_EQUAL = 94,
    DEL_MINUS_MORE = 95,
    NUMBER_OF = 96,
};

comptime {
    // Sanity: keep the variant count fingerprinted. A vendor enum drift
    // adding/removing keywords would change this.
    if (@intFromEnum(TokenKind.NUMBER_OF) != 96) {
        @compileError("TokenKind ordinal layout drift — re-pin against vendor py/lexer.h");
    }
}

/// Vendor's `unichar` (uint32_t). EOF is the all-ones sentinel —
/// matches `(unichar)(mp_uint_t)-1` in vendor C.
pub const unichar = u32;
pub const EOF: unichar = ~@as(unichar, 0);

const TAB_SIZE: usize = 8;
const ALLOC_INDENT_INIT: usize = 10;
const ALLOC_INDENT_INC: usize = 8;

// ── Reader abstraction ────────────────────────────────────────────────────
//
// Replaces vendor's mp_reader_t. The lexer doesn't care WHERE bytes come
// from — a slice, a file, an embedded blob — only how to pull the next
// byte. Two function pointers plus an opaque context: readByteFn returns
// null on EOF, closeFn frees any underlying resource (called by
// lexerFree).
//
// The slice reader (most common case in tests) is provided as a
// convenience factory.

pub const Reader = struct {
    ctx: *anyopaque,
    readByteFn: *const fn (ctx: *anyopaque) ?u8,
    closeFn: *const fn (ctx: *anyopaque) void,

    pub inline fn readByte(self: Reader) ?u8 {
        return self.readByteFn(self.ctx);
    }

    pub inline fn close(self: Reader) void {
        self.closeFn(self.ctx);
    }

    /// Slice-backed reader. The returned Reader holds a pointer to
    /// `state`, which the caller must keep alive for the lexer's
    /// lifetime (lexerNewFromStr handles this by allocating the state
    /// on the same heap as the Lexer struct).
    pub fn fromSlice(state: *SliceState, buf: []const u8) Reader {
        state.* = .{ .buf = buf, .pos = 0 };
        return .{
            .ctx = @ptrCast(state),
            .readByteFn = sliceReadByte,
            .closeFn = sliceClose,
        };
    }
};

pub const SliceState = struct {
    buf: []const u8,
    pos: usize,
};

fn sliceReadByte(ctx: *anyopaque) ?u8 {
    const s: *SliceState = @ptrCast(@alignCast(ctx));
    if (s.pos >= s.buf.len) return null;
    const b = s.buf[s.pos];
    s.pos += 1;
    return b;
}

fn sliceClose(ctx: *anyopaque) void {
    _ = ctx;
}

// ── String-literal error set ──────────────────────────────────────────────
//
// Local replacement for the runtime PyError chain. The parser (caller)
// translates these into its own diagnostic surface — the lexer itself
// has no view of the diagnostic format.

pub const StringParseError = error{
    UnicodeNameEscape, // \N{NAME} escape (not supported in nano)
    OutOfMemory,
};

// ── Lexer struct ──────────────────────────────────────────────────────────

pub const Lexer = struct {
    allocator: std.mem.Allocator,
    source_name: qstr_mod.qstr,
    reader: Reader,
    /// Slice-state slab used when Reader is a fromSlice() reader. Lives
    /// alongside the Lexer struct so lexerFree can drop it in one shot.
    /// null when the caller passed a custom Reader.
    slice_state: ?*SliceState,

    chr0: unichar,
    chr1: unichar,
    chr2: unichar,
    // FSTRINGS: saved input queue, restored when fstring args buffer
    // drains. Mirrors vendor lex->chr*_saved fields.
    chr0_saved: unichar,
    chr1_saved: unichar,
    chr2_saved: unichar,

    line: usize,
    column: usize,

    emit_dent: isize,
    nested_bracket_level: i32,

    alloc_indent_level: usize,
    num_indent_level: usize,
    indent_level: []u16,

    tok_line: usize,
    tok_column: usize,
    tok_kind: TokenKind,
    vstr: std.ArrayList(u8),

    // FSTRINGS: extracted .format(args...) buffer + read cursor.
    fstring_args: std.ArrayList(u8),
    fstring_args_idx: usize,

    // Soft-keyword lookahead. Empty for every input that never triggers
    // peekLineEndsWithColon, which is all of them but `match`/`case`.
    // See the SOFT KEYWORDS section below.
    peek_toks: std.ArrayList(SavedTok),
    peek_vstr: std.ArrayList(u8),
    peek_idx: usize,

    debug_mode: bool,
};

/// One buffered token: everything lexerToNext() publishes to the parser.
/// vstr bytes live in Lexer.peek_vstr at [off..off+len].
const SavedTok = struct {
    kind: TokenKind,
    line: usize,
    column: usize,
    vstr_off: usize,
    vstr_len: usize,
};

// ── Character predicates (inline ASCII; replace unichar_*) ────────────────

inline fn CUR(l: *Lexer) unichar {
    return l.chr0;
}

inline fn isEnd(l: *Lexer) bool {
    return l.chr0 == EOF;
}

inline fn isPhysicalNewline(l: *Lexer) bool {
    return l.chr0 == '\n';
}

inline fn isChar(l: *Lexer, ch: u8) bool {
    return l.chr0 == ch;
}

inline fn isCharOr(l: *Lexer, c1: u8, c2: u8) bool {
    return l.chr0 == c1 or l.chr0 == c2;
}

inline fn isCharOr3(l: *Lexer, c1: u8, c2: u8, c3: u8) bool {
    return l.chr0 == c1 or l.chr0 == c2 or l.chr0 == c3;
}

inline fn isCharOr4(l: *Lexer, c1: u8, c2: u8, c3: u8, c4: u8) bool {
    return l.chr0 == c1 or l.chr0 == c2 or l.chr0 == c3 or l.chr0 == c4;
}

inline fn isCharFollowing(l: *Lexer, ch: u8) bool {
    return l.chr1 == ch;
}

inline fn isCharFollowingOr(l: *Lexer, c1: u8, c2: u8) bool {
    return l.chr1 == c1 or l.chr1 == c2;
}

inline fn isCharFollowingFollowingOr(l: *Lexer, c1: u8, c2: u8) bool {
    return l.chr2 == c1 or l.chr2 == c2;
}

inline fn isCharAnd(l: *Lexer, c1: u8, c2: u8) bool {
    return l.chr0 == c1 and l.chr1 == c2;
}

// ASCII-only predicates — vendor's unichar_is* are likewise ASCII-only
// (see vendor/micropython_embed/py/unicode.c:118 comment).
inline fn isSpace(ch: unichar) bool {
    return ch < 128 and (ch == ' ' or (ch >= 9 and ch <= 13));
}

inline fn isAlpha(ch: unichar) bool {
    return ch < 128 and ((ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z'));
}

inline fn isDigit(ch: unichar) bool {
    return ch >= '0' and ch <= '9';
}

inline fn isXdigit(ch: unichar) bool {
    return isDigit(ch) or
        (ch >= 'A' and ch <= 'F') or
        (ch >= 'a' and ch <= 'f');
}

inline fn xdigitValue(ch: unichar) unichar {
    var n: unichar = ch - '0';
    if (n > 9) {
        n &= ~@as(unichar, 'a' - 'A');
        n -= ('A' - ('9' + 1));
    }
    return n;
}

inline fn isWhitespace(l: *Lexer) bool {
    return isSpace(l.chr0);
}

inline fn isLetter(l: *Lexer) bool {
    return isAlpha(l.chr0);
}

inline fn isDigitP(l: *Lexer) bool {
    return isDigit(l.chr0);
}

inline fn isFollowingDigit(l: *Lexer) bool {
    return isDigit(l.chr1);
}

inline fn isFollowingBaseChar(l: *Lexer) bool {
    const c = l.chr1 | 0x20;
    return c == 'b' or c == 'o' or c == 'x';
}

inline fn isFollowingOdigit(l: *Lexer) bool {
    return l.chr1 >= '0' and l.chr1 <= '7';
}

inline fn isHeadOfIdentifier(l: *Lexer) bool {
    return isLetter(l) or l.chr0 == '_' or l.chr0 >= 0x80;
}

inline fn isTailOfIdentifier(l: *Lexer) bool {
    return isHeadOfIdentifier(l) or isDigitP(l);
}

inline fn isStringOrBytes(l: *Lexer) bool {
    // FSTRINGS: include 'f' and 'rf'/'fr' prefixes.
    return isCharOr(l, '\'', '\"') or
        (isCharOr4(l, 'r', 'u', 'b', 'f') and isCharFollowingOr(l, '\'', '\"')) or
        ((isCharAnd(l, 'r', 'b') or isCharAnd(l, 'b', 'r') or
            isCharAnd(l, 'r', 'f') or isCharAnd(l, 'f', 'r')) and
            isCharFollowingFollowingOr(l, '\'', '\"'));
}

// ── next_char + indent stack ──────────────────────────────────────────────

fn nextChar(l: *Lexer) void {
    // C uses size_t wraparound: column starts at (size_t)-2 and the
    // three priming nextChar() calls wrap it up to 1. Mirror with %-ops.
    if (l.chr0 == '\n') {
        l.line += 1;
        l.column = 1;
    } else if (l.chr0 == '\t') {
        l.column = (((l.column -% 1 +% TAB_SIZE) / TAB_SIZE) * TAB_SIZE) +% 1;
    } else {
        l.column +%= 1;
    }

    l.chr0 = l.chr1;
    l.chr1 = l.chr2;

    // FSTRINGS: when injecting fstring args, read from the args buffer
    // instead of the source reader; on exhaustion, restore the saved
    // input queue.
    if (l.fstring_args_idx != 0) {
        if (l.fstring_args_idx < l.fstring_args.items.len) {
            l.chr2 = l.fstring_args.items[l.fstring_args_idx];
            l.fstring_args_idx += 1;
        } else {
            l.chr2 = 0;
        }
        if (l.chr0 == 0) {
            // consumed all fstring data, restore saved input queue
            l.chr0 = l.chr0_saved;
            l.chr1 = l.chr1_saved;
            l.chr2 = l.chr2_saved;
            l.fstring_args.clearRetainingCapacity();
            l.fstring_args_idx = 0;
        }
    } else {
        l.chr2 = if (l.reader.readByte()) |b| @intCast(b) else EOF;
    }

    if (l.chr1 == '\r') {
        l.chr1 = '\n';
        if (l.chr2 == '\n') {
            l.chr2 = if (l.reader.readByte()) |b| @intCast(b) else EOF;
        }
    }

    if (l.chr2 == EOF and l.chr1 != EOF and l.chr1 != '\n') {
        l.chr2 = '\n';
    }
}

fn indentPush(l: *Lexer, indent: usize) std.mem.Allocator.Error!void {
    if (l.num_indent_level >= l.alloc_indent_level) {
        const new_alloc = l.alloc_indent_level + ALLOC_INDENT_INC;
        const grown = try l.allocator.realloc(l.indent_level, new_alloc);
        l.indent_level = grown;
        l.alloc_indent_level = new_alloc;
    }
    l.indent_level[l.num_indent_level] = @intCast(indent);
    l.num_indent_level += 1;
}

inline fn indentTop(l: *Lexer) usize {
    return l.indent_level[l.num_indent_level - 1];
}

inline fn indentPop(l: *Lexer) void {
    l.num_indent_level -= 1;
}

// ── Operator/delimiter encoding tables (verbatim port) ────────────────────

const tok_enc =
    "()[]{},;~" ++
    ":e=" ++
    "<e=c<e=" ++
    ">e=c>e=" ++
    "*e=c*e=" ++
    "+e=" ++
    "-e=e>" ++
    "&e=" ++
    "|e=" ++
    "/e=c/e=" ++
    "%e=" ++
    "^e=" ++
    "@e=" ++
    "=e=" ++
    "!.";

const tok_enc_kind = [_]TokenKind{
    .DEL_PAREN_OPEN,     .DEL_PAREN_CLOSE,
    .DEL_BRACKET_OPEN,   .DEL_BRACKET_CLOSE,
    .DEL_BRACE_OPEN,     .DEL_BRACE_CLOSE,
    .DEL_COMMA,          .DEL_SEMICOLON,
    .OP_TILDE,           .DEL_COLON,
    .OP_ASSIGN,          .OP_LESS,
    .OP_LESS_EQUAL,      .OP_DBL_LESS,
    .DEL_DBL_LESS_EQUAL, .OP_MORE,
    .OP_MORE_EQUAL,      .OP_DBL_MORE,
    .DEL_DBL_MORE_EQUAL, .OP_STAR,
    .DEL_STAR_EQUAL,     .OP_DBL_STAR,
    .DEL_DBL_STAR_EQUAL, .OP_PLUS,
    .DEL_PLUS_EQUAL,     .OP_MINUS,
    .DEL_MINUS_EQUAL,    .DEL_MINUS_MORE,
    .OP_AMPERSAND,       .DEL_AMPERSAND_EQUAL,
    .OP_PIPE,            .DEL_PIPE_EQUAL,
    .OP_SLASH,           .DEL_SLASH_EQUAL,
    .OP_DBL_SLASH,       .DEL_DBL_SLASH_EQUAL,
    .OP_PERCENT,         .DEL_PERCENT_EQUAL,
    .OP_CARET,           .DEL_CARET_EQUAL,
    .OP_AT,              .DEL_AT_EQUAL,
    .DEL_EQUAL,          .OP_DBL_EQUAL,
};

// ── Keyword table ─────────────────────────────────────────────────────────
//
// Same order as the enum from KW_FALSE; sorted by C strcmp. ASYNC_AWAIT
// is on (port/mpconfigport.h: MICROPY_PY_ASYNC_AWAIT=1) so "async" and
// "await" are unconditional entries between "assert" and "break".

const tok_kw = [_][:0]const u8{
    "False", "None",   "True",   "__debug__", "and",      "as",       "assert",
    "async", "await",  "break",  "class",     "continue", "def",      "del",
    "elif",  "else",   "except", "finally",   "for",      "from",     "global",
    "if",    "import", "in",     "is",        "lambda",   "nonlocal", "not",
    "or",    "pass",   "raise",  "return",    "try",      "while",    "with",
    "yield",
};

/// C strcmp semantics on NUL-terminated bytes vs. a NUL-terminated
/// Zig string. Returns negative / 0 / positive in the C tradition.
fn strcmp(a: [*]const u8, b: [*:0]const u8) i32 {
    var i: usize = 0;
    while (true) : (i += 1) {
        const ca = a[i];
        const cb = b[i];
        if (ca != cb) {
            return @as(i32, ca) - @as(i32, cb);
        }
        if (ca == 0) return 0;
    }
}

// ── get_hex helper ────────────────────────────────────────────────────────

fn getHex(l: *Lexer, num_digits_in: usize, result: *unichar) bool {
    var num: unichar = 0;
    var num_digits = num_digits_in;
    while (num_digits != 0) {
        num_digits -= 1;
        nextChar(l);
        const ch = CUR(l);
        if (!isXdigit(ch)) {
            return false;
        }
        num = (num << 4) + xdigitValue(ch);
    }
    result.* = num;
    return true;
}

// ── String/bytes literal parsing ──────────────────────────────────────────

fn parseStringLiteralInner(l: *Lexer, is_raw: bool, is_fstring: bool) StringParseError!void {
    var quote_char: u8 = '\'';
    if (isChar(l, '\"')) {
        quote_char = '\"';
    }
    nextChar(l);

    var num_quotes: usize = undefined;
    if (isCharAnd(l, quote_char, quote_char)) {
        nextChar(l);
        nextChar(l);
        num_quotes = 3;
    } else {
        num_quotes = 1;
    }

    // FSTRINGS: prep the .format(... ) buffer if this is an f-string.
    if (is_fstring) {
        // Empty fstring_args means a fresh f-string; otherwise an adjacent
        // concatenated f-string just keeps appending to the args buffer.
        if (l.fstring_args.items.len == 0) {
            try l.fstring_args.appendSlice(l.allocator, ".format(");
        }
    }

    var n_closing: usize = 0;
    while (!isEnd(l) and (num_quotes > 1 or !isChar(l, '\n')) and n_closing < num_quotes) {
        if (isChar(l, quote_char)) {
            n_closing += 1;
            try l.vstr.append(l.allocator, @intCast(CUR(l) & 0xff));
        } else {
            n_closing = 0;

            // FSTRINGS: handle {...} placeholders.
            while (is_fstring and isChar(l, '{')) {
                nextChar(l);
                if (isChar(l, '{')) {
                    // {{ → literal { (passes through to str.format).
                    try l.vstr.append(l.allocator, '{');
                    nextChar(l);
                } else {
                    // wrap each arg in (): f"{a,b}, {c}" → "{}".format((a,b),(c),)
                    try l.fstring_args.append(l.allocator, '(');
                    const start_i = l.fstring_args.items.len;
                    var nested: u32 = 0;
                    // Extract until top-level ':' or '}' or '!r/!s' conversion.
                    while (!isEnd(l) and (nested != 0 or
                        !(isCharOr(l, ':', '}') or
                            (isChar(l, '!') and isCharFollowingOr(l, 'r', 's') and
                                isCharFollowingFollowingOr(l, ':', '}')))))
                    {
                        const ch: u8 = @intCast(CUR(l) & 0xff);
                        if (ch == '[' or ch == '{') {
                            nested +%= 1;
                        } else if (ch == ']' or ch == '}') {
                            nested -%= 1;
                        }
                        try l.fstring_args.append(l.allocator, ch);
                        nextChar(l);
                    }
                    // f'{a=}' — inject "a=" before the '{' (in the literal),
                    // and strip the trailing '=' from the arg.
                    if (l.fstring_args.items.len > start_i and
                        l.fstring_args.items[l.fstring_args.items.len - 1] == '=')
                    {
                        const head = l.fstring_args.items[start_i..l.fstring_args.items.len];
                        try l.vstr.appendSlice(l.allocator, head);
                        l.fstring_args.items.len -= 1;
                    }
                    try l.fstring_args.append(l.allocator, ')');
                    try l.fstring_args.append(l.allocator, ',');
                }
                try l.vstr.append(l.allocator, '{');
            }

            if (isChar(l, '\\')) {
                nextChar(l);
                var ch = CUR(l);
                if (is_raw) {
                    try l.vstr.append(l.allocator, '\\');
                } else {
                    switch (ch) {
                        '\n' => ch = EOF,
                        '\\', '\'', '\"' => {},
                        'a' => ch = 0x07,
                        'b' => ch = 0x08,
                        't' => ch = 0x09,
                        'n' => ch = 0x0a,
                        'v' => ch = 0x0b,
                        'f' => ch = 0x0c,
                        'r' => ch = 0x0d,
                        'u', 'U', 'x' => {
                            if ((ch == 'u' or ch == 'U') and l.tok_kind == .BYTES) {
                                // b'ሴ' == b'\\u1234'
                                try l.vstr.append(l.allocator, '\\');
                            } else {
                                var num: unichar = 0;
                                const ndig: usize = if (ch == 'x') 2 else if (ch == 'u') 4 else 8;
                                if (!getHex(l, ndig, &num)) {
                                    l.tok_kind = .INVALID;
                                }
                                ch = num;
                            }
                        },
                        'N' => return error.UnicodeNameEscape,
                        else => {
                            if (ch >= '0' and ch <= '7') {
                                var digits: i32 = 3;
                                var num: unichar = ch - '0';
                                while (true) {
                                    if (!isFollowingOdigit(l)) break;
                                    digits -= 1;
                                    if (digits == 0) break;
                                    nextChar(l);
                                    num = num * 8 + (CUR(l) - '0');
                                }
                                ch = num;
                            } else {
                                try l.vstr.append(l.allocator, '\\');
                            }
                        },
                    }
                }
                // Shared with the raw branch: the char after '\' is still
                // emitted (raw keeps the '\' too). Matches lexer.c structure.
                if (ch != EOF) {
                    if (STR_UNICODE) {
                        // STR_UNICODE: str keeps codepoint (utf-8 encode);
                        // bytes keeps raw byte. Vendor lexer.c:496-509.
                        if (ch < 0x110000 and l.tok_kind == .STRING) {
                            try appendUnichar(l, ch);
                        } else if (ch < 0x100 and l.tok_kind == .BYTES) {
                            try l.vstr.append(l.allocator, @intCast(ch));
                        } else {
                            l.tok_kind = .INVALID;
                        }
                    } else if (ch < 0x100) {
                        try l.vstr.append(l.allocator, @intCast(ch));
                    } else {
                        l.tok_kind = .INVALID;
                    }
                }
            } else {
                try l.vstr.append(l.allocator, @intCast(CUR(l) & 0xff));
            }
        }
        nextChar(l);
    }

    if (n_closing < num_quotes) {
        l.tok_kind = .LONELY_STRING_OPEN;
    }

    // vstr_cut_tail_bytes equivalent — drop the closing quote chars
    // we accumulated while scanning for the terminator.
    if (l.vstr.items.len >= n_closing) {
        l.vstr.items.len -= n_closing;
    } else {
        l.vstr.items.len = 0;
    }
}

/// Encode `ch` as UTF-8 into the vstr. Matches vstr_add_char semantics
/// (which calls utf8_get_char_len + utf8_get_char_encode).
fn appendUnichar(l: *Lexer, ch: unichar) std.mem.Allocator.Error!void {
    if (ch < 0x80) {
        try l.vstr.append(l.allocator, @intCast(ch));
    } else if (ch < 0x800) {
        try l.vstr.appendSlice(l.allocator, &.{
            @intCast(0xC0 | (ch >> 6)),
            @intCast(0x80 | (ch & 0x3F)),
        });
    } else if (ch < 0x10000) {
        try l.vstr.appendSlice(l.allocator, &.{
            @intCast(0xE0 | (ch >> 12)),
            @intCast(0x80 | ((ch >> 6) & 0x3F)),
            @intCast(0x80 | (ch & 0x3F)),
        });
    } else {
        try l.vstr.appendSlice(l.allocator, &.{
            @intCast(0xF0 | (ch >> 18)),
            @intCast(0x80 | ((ch >> 12) & 0x3F)),
            @intCast(0x80 | ((ch >> 6) & 0x3F)),
            @intCast(0x80 | (ch & 0x3F)),
        });
    }
}

// ── skip_whitespace ───────────────────────────────────────────────────────

fn skipWhitespace(l: *Lexer, stop_at_newline: bool) bool {
    while (!isEnd(l)) {
        if (isPhysicalNewline(l)) {
            if (stop_at_newline and l.nested_bracket_level == 0) {
                return true;
            }
            nextChar(l);
        } else if (isWhitespace(l)) {
            nextChar(l);
        } else if (isChar(l, '#')) {
            nextChar(l);
            while (!isEnd(l) and !isPhysicalNewline(l)) {
                nextChar(l);
            }
        } else if (isCharAnd(l, '\\', '\n')) {
            nextChar(l);
            nextChar(l);
        } else {
            break;
        }
    }
    return false;
}

// ── Main state machine ───────────────────────────────────────────────────

/// Advance the lexer one token. The new token is exposed via the
/// `tok_kind`, `tok_line`, `tok_column`, `vstr` fields on Lexer.
// ── SOFT KEYWORDS ─────────────────────────────────────────────────────────
//
// `match` and `case` are soft keywords: valid identifiers everywhere,
// statement introducers only in one position. They are deliberately NOT
// in tok_kw and get no TokenKind of their own — the lexer emits NAME for
// them exactly as vendor py/lexer.c does, so the token stream stays
// byte-identical for every input and TokenKind.NUMBER_OF stays pinned at
// 96 (see the comptime fingerprint above).
//
// Disambiguation is the parser's job, but it needs more than the one
// token of lookahead the parser has: `match (x):` is a match statement
// and `match(x)` is a call, and only the trailing ':' separates them.
// Reader is a byte-at-a-time interface with no seek, so the scan-ahead
// happens at the token level — peekLineEndsWithColon() buffers a logical
// line and rewinds, and lexerToNext() replays the buffer before it
// resumes scanning.

inline fn peekDrainIfDone(l: *Lexer) void {
    if (l.peek_idx == l.peek_toks.items.len) {
        l.peek_toks.clearRetainingCapacity();
        l.peek_vstr.clearRetainingCapacity();
        l.peek_idx = 0;
    }
}

/// Append the token the lexer is currently sitting on to the buffer.
fn peekAppendCurrent(l: *Lexer) StringParseError!void {
    const off = l.peek_vstr.items.len;
    try l.peek_vstr.appendSlice(l.allocator, l.vstr.items);
    try l.peek_toks.append(l.allocator, .{
        .kind = l.tok_kind,
        .line = l.tok_line,
        .column = l.tok_column,
        .vstr_off = off,
        .vstr_len = l.vstr.items.len,
    });
}

/// Publish a buffered token as the current one.
fn peekRestore(l: *Lexer, t: SavedTok) StringParseError!void {
    l.tok_kind = t.kind;
    l.tok_line = t.line;
    l.tok_column = t.column;
    l.vstr.clearRetainingCapacity();
    try l.vstr.appendSlice(l.allocator, l.peek_vstr.items[t.vstr_off..][0..t.vstr_len]);
}

/// Scan to the end of the current logical line without consuming it, and
/// report whether the last token before the terminator was ':'.
///
/// The caller's stream position is unchanged: every token scanned is
/// buffered and replayed by lexerToNext(), starting with the one the
/// caller was sitting on.
///
/// NEWLINE is only emitted at nested_bracket_level == 0 (skipWhitespace),
/// so bracket depth needs no tracking here — a bracketed line arrives as
/// one logical line for free.
pub fn peekLineEndsWithColon(l: *Lexer) StringParseError!bool {
    std.debug.assert(l.peek_toks.items.len == 0);

    try peekAppendCurrent(l);
    var prev = l.tok_kind;
    while (l.tok_kind != .NEWLINE and l.tok_kind != .END) {
        prev = l.tok_kind;
        try lexerScanNext(l);
        try peekAppendCurrent(l);
    }

    try peekRestore(l, l.peek_toks.items[0]);
    l.peek_idx = 1;
    peekDrainIfDone(l);
    return prev == .DEL_COLON;
}

/// Advance to the next token. Serves the soft-keyword lookahead buffer
/// first when one is live; otherwise scans real input.
pub fn lexerToNext(l: *Lexer) StringParseError!void {
    if (l.peek_idx < l.peek_toks.items.len) {
        const t = l.peek_toks.items[l.peek_idx];
        l.peek_idx += 1;
        try peekRestore(l, t);
        peekDrainIfDone(l);
        return;
    }
    try lexerScanNext(l);
}

fn lexerScanNext(l: *Lexer) StringParseError!void {
    l.vstr.clearRetainingCapacity();

    const had_physical_newline = skipWhitespace(l, true);

    l.tok_line = l.line;
    l.tok_column = l.column;

    if (l.emit_dent < 0) {
        l.tok_kind = .DEDENT;
        l.emit_dent += 1;
    } else if (l.emit_dent > 0) {
        l.tok_kind = .INDENT;
        l.emit_dent -= 1;
    } else if (had_physical_newline) {
        _ = skipWhitespace(l, false);

        l.tok_kind = .NEWLINE;

        const num_spaces = l.column - 1;
        if (num_spaces == indentTop(l)) {
            // same level
        } else if (num_spaces > indentTop(l)) {
            try indentPush(l, num_spaces);
            l.emit_dent += 1;
        } else {
            while (num_spaces < indentTop(l)) {
                indentPop(l);
                l.emit_dent -= 1;
            }
            if (num_spaces != indentTop(l)) {
                l.tok_kind = .DEDENT_MISMATCH;
            }
        }
    } else if (isEnd(l)) {
        l.tok_kind = .END;
    } else if (isStringOrBytes(l)) {
        l.tok_kind = .END;

        while (true) {
            var is_raw = false;
            var is_fstring = false;
            var kind: TokenKind = .STRING;
            var n_char: i32 = 0;
            if (isChar(l, 'u')) {
                n_char = 1;
            } else if (isChar(l, 'b')) {
                kind = .BYTES;
                n_char = 1;
                if (isCharFollowing(l, 'r')) {
                    is_raw = true;
                    n_char = 2;
                }
            } else if (isChar(l, 'r')) {
                is_raw = true;
                n_char = 1;
                if (isCharFollowing(l, 'b')) {
                    kind = .BYTES;
                    n_char = 2;
                } else if (isCharFollowing(l, 'f')) {
                    is_fstring = true;
                    n_char = 2;
                }
            } else if (isChar(l, 'f')) {
                is_fstring = true;
                n_char = 1;
                if (isCharFollowing(l, 'r')) {
                    is_raw = true;
                    n_char = 2;
                }
            }

            if (l.tok_kind == .END) {
                l.tok_kind = kind;
            } else if (l.tok_kind != kind) {
                break;
            }

            if (n_char != 0) {
                nextChar(l);
                if (n_char == 2) {
                    nextChar(l);
                }
            }

            try parseStringLiteralInner(l, is_raw, is_fstring);

            _ = skipWhitespace(l, true);

            if (!isStringOrBytes(l)) break;
        }

        // FSTRINGS: at end-of-fstring token, switch input source to the
        // .format(args...) buffer we've been building.
        if (l.fstring_args.items.len != 0 and l.fstring_args_idx == 0) {
            try l.fstring_args.append(l.allocator, ')');
            l.chr0_saved = l.chr0;
            l.chr1_saved = l.chr1;
            l.chr2_saved = l.chr2;
            l.chr0 = l.fstring_args.items[0];
            l.chr1 = if (l.fstring_args.items.len > 1) l.fstring_args.items[1] else 0;
            l.chr2 = if (l.fstring_args.items.len > 2) l.fstring_args.items[2] else 0;
            l.fstring_args_idx = 3;
        }
    } else if (isHeadOfIdentifier(l)) {
        l.tok_kind = .NAME;

        try l.vstr.append(l.allocator, @intCast(CUR(l) & 0xff));
        nextChar(l);

        while (!isEnd(l) and isTailOfIdentifier(l)) {
            try l.vstr.append(l.allocator, @intCast(CUR(l) & 0xff));
            nextChar(l);
        }

        // strcmp on a NUL-terminated copy. Vendor uses
        // vstr_null_terminated_str which guarantees one byte past len
        // is 0. We use a stack buffer for small identifiers, fall back
        // to allocating one byte of headroom when oversized.
        try l.vstr.append(l.allocator, 0);
        const s_ptr: [*]const u8 = l.vstr.items.ptr;
        // pop the NUL — it must not be visible to downstream consumers
        // of vstr (which read items.len bytes).
        defer l.vstr.items.len -= 1;

        var i: usize = 0;
        while (i < tok_kw.len) : (i += 1) {
            const cmp = strcmp(s_ptr, tok_kw[i].ptr);
            if (cmp == 0) {
                l.tok_kind = @enumFromInt(@intFromEnum(TokenKind.KW_FALSE) + @as(u8, @intCast(i)));
                if (l.tok_kind == .KW___DEBUG__) {
                    l.tok_kind = if (l.debug_mode) .KW_TRUE else .KW_FALSE;
                }
                break;
            } else if (cmp < 0) {
                break;
            }
        }
    } else if (isDigitP(l) or (isChar(l, '.') and isFollowingDigit(l))) {
        var forced_integer = false;
        if (isChar(l, '.')) {
            l.tok_kind = .FLOAT_OR_IMAG;
        } else {
            l.tok_kind = .INTEGER;
            if (isChar(l, '0') and isFollowingBaseChar(l)) {
                forced_integer = true;
            }
        }

        try l.vstr.append(l.allocator, @intCast(CUR(l) & 0xff));
        nextChar(l);

        while (!isEnd(l)) {
            if (!forced_integer and isCharOr(l, 'e', 'E')) {
                l.tok_kind = .FLOAT_OR_IMAG;
                try l.vstr.append(l.allocator, 'e');
                nextChar(l);
                if (isChar(l, '+') or isChar(l, '-')) {
                    try l.vstr.append(l.allocator, @intCast(CUR(l) & 0xff));
                    nextChar(l);
                }
            } else if (isLetter(l) or isDigitP(l) or isChar(l, '.')) {
                if (isCharOr3(l, '.', 'j', 'J')) {
                    l.tok_kind = .FLOAT_OR_IMAG;
                }
                try l.vstr.append(l.allocator, @intCast(CUR(l) & 0xff));
                nextChar(l);
            } else if (isChar(l, '_')) {
                nextChar(l);
            } else {
                break;
            }
        }
    } else {
        // Encoded delimiter / operator scan.
        var ti: usize = 0; // index into tok_enc
        var tok_enc_index: usize = 0;
        while (tok_enc[ti] != 0 and !isChar(l, tok_enc[ti])) : (ti += 1) {
            if (tok_enc[ti] == 'e' or tok_enc[ti] == 'c') {
                ti += 1;
            }
            tok_enc_index += 1;
        }

        nextChar(l);

        if (tok_enc[ti] == 0) {
            l.tok_kind = .INVALID;
        } else if (tok_enc[ti] == '!') {
            if (isChar(l, '=')) {
                nextChar(l);
                l.tok_kind = .OP_NOT_EQUAL;
            } else {
                l.tok_kind = .INVALID;
            }
        } else if (tok_enc[ti] == '.') {
            if (isCharAnd(l, '.', '.')) {
                nextChar(l);
                nextChar(l);
                l.tok_kind = .ELLIPSIS;
            } else {
                l.tok_kind = .DEL_PERIOD;
            }
        } else {
            ti += 1;
            var t_index = tok_enc_index;
            while (tok_enc[ti] == 'c' or tok_enc[ti] == 'e') {
                t_index += 1;
                if (isChar(l, tok_enc[ti + 1])) {
                    nextChar(l);
                    tok_enc_index = t_index;
                    if (tok_enc[ti] == 'e') {
                        break;
                    }
                } else if (tok_enc[ti] == 'c') {
                    break;
                }
                ti += 2;
            }

            l.tok_kind = tok_enc_kind[tok_enc_index];

            if (l.tok_kind == .DEL_PAREN_OPEN or
                l.tok_kind == .DEL_BRACKET_OPEN or
                l.tok_kind == .DEL_BRACE_OPEN)
            {
                l.nested_bracket_level += 1;
            } else if (l.tok_kind == .DEL_PAREN_CLOSE or
                l.tok_kind == .DEL_BRACKET_CLOSE or
                l.tok_kind == .DEL_BRACE_CLOSE)
            {
                l.nested_bracket_level -= 1;
            }
        }
    }
}

// ── Constructors / destructor ─────────────────────────────────────────────

/// Allocate and prime a new Lexer reading from `reader`. The caller
/// owns `reader`'s context lifetime UNLESS the Reader was constructed
/// via Reader.fromSlice() AND the caller used lexerNewFromStr (in which
/// case lexerFree drops the slice state too).
///
/// `source_name` is a pre-interned qstr id naming the source. The lexer
/// never dereferences it — it's just carried through for the parser.
///
/// `debug_mode` is true under the unoptimised (default) Python settings
/// and turns `__debug__` into a KW_TRUE literal. Set to false to emit
/// KW_FALSE (i.e. behave as if -O was passed).
pub fn lexerNew(
    allocator: std.mem.Allocator,
    source_name: qstr_mod.qstr,
    reader: Reader,
    debug_mode: bool,
) StringParseError!*Lexer {
    return lexerNewInternal(allocator, source_name, reader, null, debug_mode);
}

/// Convenience: construct a Lexer reading from an in-memory byte slice.
/// The slice must outlive the Lexer. lexerFree drops the embedded
/// SliceState along with the Lexer struct.
pub fn lexerNewFromStr(
    allocator: std.mem.Allocator,
    source_name: qstr_mod.qstr,
    src: []const u8,
    debug_mode: bool,
) StringParseError!*Lexer {
    const state = try allocator.create(SliceState);
    errdefer allocator.destroy(state);
    const reader = Reader.fromSlice(state, src);
    return lexerNewInternal(allocator, source_name, reader, state, debug_mode);
}

fn lexerNewInternal(
    allocator: std.mem.Allocator,
    source_name: qstr_mod.qstr,
    reader: Reader,
    slice_state: ?*SliceState,
    debug_mode: bool,
) StringParseError!*Lexer {
    const l = try allocator.create(Lexer);
    errdefer allocator.destroy(l);

    const indent = try allocator.alloc(u16, ALLOC_INDENT_INIT);
    errdefer allocator.free(indent);

    l.* = .{
        .allocator = allocator,
        .source_name = source_name,
        .reader = reader,
        .slice_state = slice_state,
        .chr0 = 0,
        .chr1 = 0,
        .chr2 = 0,
        .chr0_saved = 0,
        .chr1_saved = 0,
        .chr2_saved = 0,
        .line = 1,
        .column = @as(usize, 0) -% 2, // priming wrap — see nextChar header
        .emit_dent = 0,
        .nested_bracket_level = 0,
        .alloc_indent_level = ALLOC_INDENT_INIT,
        .num_indent_level = 1,
        .indent_level = indent,
        .tok_line = 0,
        .tok_column = 0,
        .tok_kind = .END,
        .vstr = std.ArrayList(u8).empty,
        .fstring_args = std.ArrayList(u8).empty,
        .fstring_args_idx = 0,
        .peek_toks = std.ArrayList(SavedTok).empty,
        .peek_vstr = std.ArrayList(u8).empty,
        .peek_idx = 0,
        .debug_mode = debug_mode,
    };
    l.indent_level[0] = 0;

    // Prime the 3-char lookahead and zero out the vstr.
    nextChar(l);
    nextChar(l);
    nextChar(l);

    try lexerToNext(l);

    // Vendor lexer.c: any token that doesn't start in column 1 (and
    // isn't a NEWLINE) becomes an implicit INDENT at the file head.
    if (l.tok_column != 1 and l.tok_kind != .NEWLINE) {
        l.tok_kind = .INDENT;
    }

    return l;
}

/// Free everything owned by the Lexer: indent stack, vstr/fstring_args
/// backing storage, the slice state if any, and the Lexer struct
/// itself. Calls reader.close() before tearing down the struct.
///
/// Accepts a nullable pointer for ergonomic match with the vendor C
/// API; null is a no-op.
pub fn lexerFree(maybe_l: ?*Lexer) void {
    const l = maybe_l orelse return;
    l.reader.close();
    l.vstr.deinit(l.allocator);
    l.fstring_args.deinit(l.allocator);
    l.peek_toks.deinit(l.allocator);
    l.peek_vstr.deinit(l.allocator);
    l.allocator.free(l.indent_level);
    if (l.slice_state) |s| l.allocator.destroy(s);
    l.allocator.destroy(l);
}

// ── Smoke tests ───────────────────────────────────────────────────────────
//
// These exercise the public API end-to-end with std.testing.allocator
// for leak detection. The heavy validation (552/552 byte-identical
// streams against vendor) lives in lexer_test.zig.

const testing = std.testing;

test "smoke: empty input yields NEWLINE then END" {
    const lex = try lexerNewFromStr(testing.allocator, 0, "", true);
    defer lexerFree(lex);
    try testing.expectEqual(TokenKind.NEWLINE, lex.tok_kind);
    try lexerToNext(lex);
    try testing.expectEqual(TokenKind.END, lex.tok_kind);
}

test "smoke: pass tokenises to KW_PASS + NEWLINE + END" {
    const lex = try lexerNewFromStr(testing.allocator, 0, "pass\n", true);
    defer lexerFree(lex);
    try testing.expectEqual(TokenKind.KW_PASS, lex.tok_kind);
    try lexerToNext(lex);
    try testing.expectEqual(TokenKind.NEWLINE, lex.tok_kind);
    try lexerToNext(lex);
    try testing.expectEqual(TokenKind.END, lex.tok_kind);
}

test "smoke: identifier accumulates into vstr" {
    const lex = try lexerNewFromStr(testing.allocator, 0, "hello\n", true);
    defer lexerFree(lex);
    try testing.expectEqual(TokenKind.NAME, lex.tok_kind);
    try testing.expectEqualSlices(u8, "hello", lex.vstr.items);
}

test "smoke: integer literal" {
    const lex = try lexerNewFromStr(testing.allocator, 0, "42\n", true);
    defer lexerFree(lex);
    try testing.expectEqual(TokenKind.INTEGER, lex.tok_kind);
    try testing.expectEqualSlices(u8, "42", lex.vstr.items);
}

test "smoke: simple string literal" {
    const lex = try lexerNewFromStr(testing.allocator, 0, "'abc'\n", true);
    defer lexerFree(lex);
    try testing.expectEqual(TokenKind.STRING, lex.tok_kind);
    try testing.expectEqualSlices(u8, "abc", lex.vstr.items);
}

test "smoke: indent / dedent" {
    const src = "def f():\n    return 1\n";
    const lex = try lexerNewFromStr(testing.allocator, 0, src, true);
    defer lexerFree(lex);
    // def f():
    try testing.expectEqual(TokenKind.KW_DEF, lex.tok_kind);
    try lexerToNext(lex);
    try testing.expectEqual(TokenKind.NAME, lex.tok_kind);
    try lexerToNext(lex);
    try testing.expectEqual(TokenKind.DEL_PAREN_OPEN, lex.tok_kind);
    try lexerToNext(lex);
    try testing.expectEqual(TokenKind.DEL_PAREN_CLOSE, lex.tok_kind);
    try lexerToNext(lex);
    try testing.expectEqual(TokenKind.DEL_COLON, lex.tok_kind);
    try lexerToNext(lex);
    try testing.expectEqual(TokenKind.NEWLINE, lex.tok_kind);
    try lexerToNext(lex);
    try testing.expectEqual(TokenKind.INDENT, lex.tok_kind);
    try lexerToNext(lex);
    try testing.expectEqual(TokenKind.KW_RETURN, lex.tok_kind);
    try lexerToNext(lex);
    try testing.expectEqual(TokenKind.INTEGER, lex.tok_kind);
    try lexerToNext(lex);
    try testing.expectEqual(TokenKind.NEWLINE, lex.tok_kind);
    try lexerToNext(lex);
    try testing.expectEqual(TokenKind.DEDENT, lex.tok_kind);
    try lexerToNext(lex);
    try testing.expectEqual(TokenKind.END, lex.tok_kind);
}

test "smoke: __debug__ flips on debug_mode" {
    {
        const lex = try lexerNewFromStr(testing.allocator, 0, "__debug__\n", true);
        defer lexerFree(lex);
        try testing.expectEqual(TokenKind.KW_TRUE, lex.tok_kind);
    }
    {
        const lex = try lexerNewFromStr(testing.allocator, 0, "__debug__\n", false);
        defer lexerFree(lex);
        try testing.expectEqual(TokenKind.KW_FALSE, lex.tok_kind);
    }
}

test "smoke: hex escape in string literal" {
    const lex = try lexerNewFromStr(testing.allocator, 0, "'\\x41'\n", true);
    defer lexerFree(lex);
    try testing.expectEqual(TokenKind.STRING, lex.tok_kind);
    try testing.expectEqualSlices(u8, "A", lex.vstr.items);
}

test "smoke: nested brackets suppress newline" {
    const src = "(1,\n 2)\n";
    const lex = try lexerNewFromStr(testing.allocator, 0, src, true);
    defer lexerFree(lex);
    // No NEWLINE between '1,' and '2' because nested_bracket_level > 0.
    try testing.expectEqual(TokenKind.DEL_PAREN_OPEN, lex.tok_kind);
    try lexerToNext(lex);
    try testing.expectEqual(TokenKind.INTEGER, lex.tok_kind);
    try lexerToNext(lex);
    try testing.expectEqual(TokenKind.DEL_COMMA, lex.tok_kind);
    try lexerToNext(lex);
    try testing.expectEqual(TokenKind.INTEGER, lex.tok_kind);
    try lexerToNext(lex);
    try testing.expectEqual(TokenKind.DEL_PAREN_CLOSE, lex.tok_kind);
}

// ── Soft-keyword lookahead ────────────────────────────────────────────────

/// Dump a whole token stream as "KIND:vstr\n" lines. Used to prove a
/// peeked run replays to exactly the stream an unpeeked one produces.
fn dumpStream(alloc: std.mem.Allocator, src: []const u8, peek_at: ?[]const u8) ![]u8 {
    const lex = try lexerNewFromStr(alloc, 0, src, true);
    defer lexerFree(lex);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    while (lex.tok_kind != .END) {
        if (peek_at) |name| {
            if (lex.tok_kind == .NAME and std.mem.eql(u8, lex.vstr.items, name)) {
                _ = try peekLineEndsWithColon(lex);
            }
        }
        try out.appendSlice(alloc, @tagName(lex.tok_kind));
        try out.append(alloc, ':');
        try out.appendSlice(alloc, lex.vstr.items);
        try out.append(alloc, '\n');
        try lexerToNext(lex);
    }
    return out.toOwnedSlice(alloc);
}

test "soft keywords: peeking a line replays it byte-identically" {
    const cases = [_][]const u8{
        "match x:\n    case 1:\n        pass\n",
        // The ambiguity the peek exists to resolve: same prefix, and a
        // bracketed subject so NEWLINE suppression is in play too.
        "match (x):\n    case (1):\n        pass\n",
        "match(x)\n",
        // f-strings rewrite the input queue mid-line; scanning past one
        // and replaying must not desync that state machine.
        "match f'{a}{b!r:>{w}}':\n    case 1:\n        pass\n",
        // Unbalanced bracket: no NEWLINE until EOF, so the peek buffers
        // the rest of the file. A syntax error downstream either way.
        "match (x:\n    pass\n",
        // `match` and `case` as ordinary identifiers must be untouched.
        "match = 1\ncase = 2\nprint(match + case)\n",
    };
    for (cases) |src| {
        const plain = try dumpStream(testing.allocator, src, null);
        defer testing.allocator.free(plain);
        for ([_][]const u8{ "match", "case" }) |kw| {
            const peeked = try dumpStream(testing.allocator, src, kw);
            defer testing.allocator.free(peeked);
            try testing.expectEqualStrings(plain, peeked);
        }
    }
}

test "soft keywords: the colon verdict separates statement from call" {
    const cases = [_]struct { src: []const u8, want: bool }{
        .{ .src = "match x:\n    pass\n", .want = true },
        .{ .src = "match (x):\n    pass\n", .want = true },
        .{ .src = "match [a, b]:\n    pass\n", .want = true },
        // A dict subject: braces carry colons, but only the last token
        // before NEWLINE decides.
        .{ .src = "match {1: 2}:\n    pass\n", .want = true },
        .{ .src = "match {1: 2}\n", .want = false },
        .{ .src = "match(x)\n", .want = false },
        .{ .src = "match = 1\n", .want = false },
        .{ .src = "match.group(0)\n", .want = false },
        // Bracketed line continuation: one logical line, verdict is the
        // colon after the close paren.
        .{ .src = "match (\n    x\n):\n    pass\n", .want = true },
        // An annotation ends in a name, not a colon.
        .{ .src = "match: int = 1\n", .want = false },
    };
    for (cases) |c| {
        const lex = try lexerNewFromStr(testing.allocator, 0, c.src, true);
        defer lexerFree(lex);
        try testing.expectEqual(c.want, try peekLineEndsWithColon(lex));
        // The peek left the stream where it found it.
        try testing.expectEqual(TokenKind.NAME, lex.tok_kind);
        try testing.expectEqualStrings("match", lex.vstr.items);
    }
}
