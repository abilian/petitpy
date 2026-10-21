#!/usr/bin/env python3
# nanopython — C4 grammar-table generator.
#
# Reads vendor/micropython_embed/py/grammar.h and emits
# src/compiler/grammar_data.zig — the rule_act / rule_arg_combined /
# rule_arg_offset tables plus the bit-mask constants and named rule-id
# constants used by src/compiler/parser.zig.
#
# This is the pure-Zig replacement for src/frontend/parse_shim.c's
# macro-generated tables. Byte-identity against the shim is the
# acceptance gate (see src/compiler/grammar_data_test.zig).
#
# Re-run by hand or `make gen-grammar`. The generated file carries a
# SHA-256 fingerprint of grammar.h at the top so silent drift trips the
# build.
#
# Config: hard-coded to the "nano" preset (port/mpconfigport.h with
# NANOPYTHON_CONFIG_FULL unset). Any change to the gating flags below
# must be matched in the parser-driving config.

from __future__ import annotations

import hashlib
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
GRAMMAR_H = ROOT / "vendor" / "micropython_embed" / "py" / "grammar.h"
OUT_ZIG = ROOT / "src" / "compiler" / "grammar_data.zig"

# Nano config (ROM_LEVEL_MINIMUM with the opt-ins from port/mpconfigport.h).
# Keep in sync with the parser's compile-time view of grammar.h.
CONFIG = {
    "MICROPY_PY_ASYNC_AWAIT": 1,
    "MICROPY_PY_ASSIGN_EXPR": 1,
    "MICROPY_PY_BUILTINS_SLICE": 1,
    "MICROPY_PY_BUILTINS_SET": 1,
}

# Token-kind names → TokenKind ordinal (must match
# src/compiler/lexer.zig:TokenKind exactly — checked at parser build
# time via @intFromEnum).
TOKEN_KIND: dict[str, int] = {
    "END": 0,
    "INVALID": 1,
    "DEDENT_MISMATCH": 2,
    "LONELY_STRING_OPEN": 3,
    "MALFORMED_FSTRING": 4,
    "NEWLINE": 5,
    "INDENT": 6,
    "DEDENT": 7,
    "NAME": 8,
    "INTEGER": 9,
    "FLOAT_OR_IMAG": 10,
    "STRING": 11,
    "BYTES": 12,
    "ELLIPSIS": 13,
    "KW_FALSE": 14,
    "KW_NONE": 15,
    "KW_TRUE": 16,
    "KW___DEBUG__": 17,
    "KW_AND": 18,
    "KW_AS": 19,
    "KW_ASSERT": 20,
    "KW_ASYNC": 21,
    "KW_AWAIT": 22,
    "KW_BREAK": 23,
    "KW_CLASS": 24,
    "KW_CONTINUE": 25,
    "KW_DEF": 26,
    "KW_DEL": 27,
    "KW_ELIF": 28,
    "KW_ELSE": 29,
    "KW_EXCEPT": 30,
    "KW_FINALLY": 31,
    "KW_FOR": 32,
    "KW_FROM": 33,
    "KW_GLOBAL": 34,
    "KW_IF": 35,
    "KW_IMPORT": 36,
    "KW_IN": 37,
    "KW_IS": 38,
    "KW_LAMBDA": 39,
    "KW_NONLOCAL": 40,
    "KW_NOT": 41,
    "KW_OR": 42,
    "KW_PASS": 43,
    "KW_RAISE": 44,
    "KW_RETURN": 45,
    "KW_TRY": 46,
    "KW_WHILE": 47,
    "KW_WITH": 48,
    "KW_YIELD": 49,
    "OP_ASSIGN": 50,
    "OP_TILDE": 51,
    "OP_LESS": 52,
    "OP_MORE": 53,
    "OP_DBL_EQUAL": 54,
    "OP_LESS_EQUAL": 55,
    "OP_MORE_EQUAL": 56,
    "OP_NOT_EQUAL": 57,
    "OP_PIPE": 58,
    "OP_CARET": 59,
    "OP_AMPERSAND": 60,
    "OP_DBL_LESS": 61,
    "OP_DBL_MORE": 62,
    "OP_PLUS": 63,
    "OP_MINUS": 64,
    "OP_STAR": 65,
    "OP_AT": 66,
    "OP_DBL_SLASH": 67,
    "OP_SLASH": 68,
    "OP_PERCENT": 69,
    "OP_DBL_STAR": 70,
    "DEL_PIPE_EQUAL": 71,
    "DEL_CARET_EQUAL": 72,
    "DEL_AMPERSAND_EQUAL": 73,
    "DEL_DBL_LESS_EQUAL": 74,
    "DEL_DBL_MORE_EQUAL": 75,
    "DEL_PLUS_EQUAL": 76,
    "DEL_MINUS_EQUAL": 77,
    "DEL_STAR_EQUAL": 78,
    "DEL_AT_EQUAL": 79,
    "DEL_DBL_SLASH_EQUAL": 80,
    "DEL_SLASH_EQUAL": 81,
    "DEL_PERCENT_EQUAL": 82,
    "DEL_DBL_STAR_EQUAL": 83,
    "DEL_PAREN_OPEN": 84,
    "DEL_PAREN_CLOSE": 85,
    "DEL_BRACKET_OPEN": 86,
    "DEL_BRACKET_CLOSE": 87,
    "DEL_BRACE_OPEN": 88,
    "DEL_BRACE_CLOSE": 89,
    "DEL_COMMA": 90,
    "DEL_COLON": 91,
    "DEL_PERIOD": 92,
    "DEL_SEMICOLON": 93,
    "DEL_EQUAL": 94,
    "DEL_MINUS_MORE": 95,
}

# rule_act bit masks (lifted from py/parse.c).
RULE_ACT_ARG_MASK = 0x0F
RULE_ACT_KIND_MASK = 0x30
RULE_ACT_ALLOW_IDENT = 0x40
RULE_ACT_ADD_BLANK = 0x80
RULE_ACT_OR = 0x10
RULE_ACT_AND = 0x20
RULE_ACT_LIST = 0x30

# rule_arg bit masks.
RULE_ARG_KIND_MASK = 0xF000
RULE_ARG_ARG_MASK = 0x0FFF
RULE_ARG_TOK = 0x1000
RULE_ARG_RULE = 0x2000
RULE_ARG_OPT_RULE = 0x3000


# ── grammar.h preprocessor (simple #if / #else / #endif on CONFIG) ────────


def filter_config(text: str) -> str:
    out: list[str] = []
    # stack of (currently_active, has_matched). A simple #if FLAG / #else
    # / #endif suffices — grammar.h doesn't nest config gates.
    stack: list[bool] = [True]
    for line in text.splitlines():
        m_if = re.match(r"\s*#if\s+(\w+)\s*$", line)
        m_else = re.match(r"\s*#else\s*$", line)
        m_endif = re.match(r"\s*#endif\s*$", line)
        if m_if:
            flag = m_if.group(1)
            if flag not in CONFIG:
                raise SystemExit(
                    f"gen_grammar: unknown #if flag {flag!r} in grammar.h "
                    f"— add it to CONFIG (current line: {line!r})"
                )
            stack.append(stack[-1] and CONFIG[flag] == 1)
        elif m_else:
            # Flip current branch (only meaningful when parent is active).
            parent = all(stack[:-1])
            stack[-1] = parent and not stack[-1]
        elif m_endif:
            stack.pop()
        elif all(stack):
            out.append(line)
    if len(stack) != 1:
        raise SystemExit("gen_grammar: unbalanced #if/#endif in grammar.h")
    return "\n".join(out)


# ── DEF_RULE / DEF_RULE_NC parser ─────────────────────────────────────────

DEF_RULE_RE = re.compile(
    r"^DEF_RULE(?P<nc>_NC)?\(\s*(?P<name>\w+)\s*,\s*(?P<rest>.*?)\)\s*$"
)


def split_args(s: str) -> list[str]:
    """Split a top-level comma-separated arg list, respecting parens."""
    parts: list[str] = []
    depth = 0
    cur = ""
    for ch in s:
        if ch == "(":
            depth += 1
            cur += ch
        elif ch == ")":
            depth -= 1
            cur += ch
        elif ch == "," and depth == 0:
            parts.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        parts.append(cur.strip())
    return parts


def parse_rules(
    text: str,
) -> tuple[list[tuple[str, str, list[str]]], list[tuple[str, str, list[str]]]]:
    """Returns (with_comp, nc) — each element is (name, kind_expr, args)."""
    with_comp: list[tuple[str, str, list[str]]] = []
    nc: list[tuple[str, str, list[str]]] = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line.startswith("DEF_RULE"):
            continue
        # Reassemble: rules are always single-line in grammar.h.
        m = DEF_RULE_RE.match(line)
        if not m:
            raise SystemExit(f"gen_grammar: bad rule line: {raw!r}")
        name = m.group("name")
        rest = m.group("rest")
        parts = split_args(rest)
        if m.group("nc"):
            # DEF_RULE_NC(name, kind, args...)
            kind = parts[0]
            args = parts[1:]
            nc.append((name, kind, args))
        else:
            # DEF_RULE(name, c(...), kind, args...) — drop c(...).
            kind = parts[1]
            args = parts[2:]
            with_comp.append((name, kind, args))
    return with_comp, nc


# ── kind / arg decoders ───────────────────────────────────────────────────


def decode_kind(expr: str) -> int:
    """Decode a kind macro call into the u8 rule_act byte (sans flags)."""
    expr = expr.strip()
    # one_or_more / list / list_with_end are bare identifiers.
    if expr == "one_or_more":
        return RULE_ACT_LIST | 2
    if expr == "list":
        return RULE_ACT_LIST | 1
    if expr == "list_with_end":
        return RULE_ACT_LIST | 3
    m = re.match(r"(or|and|and_ident|and_blank)\(\s*(\d+)\s*\)$", expr)
    if not m:
        raise SystemExit(f"gen_grammar: bad kind expr {expr!r}")
    op = m.group(1)
    n = int(m.group(2))
    if n & ~RULE_ACT_ARG_MASK:
        raise SystemExit(f"gen_grammar: arg count {n} overflows 4 bits")
    if op == "or":
        return RULE_ACT_OR | n
    if op == "and":
        return RULE_ACT_AND | n
    if op == "and_ident":
        return RULE_ACT_AND | n | RULE_ACT_ALLOW_IDENT
    if op == "and_blank":
        return RULE_ACT_AND | n | RULE_ACT_ADD_BLANK
    raise SystemExit(f"gen_grammar: unreachable kind {op!r}")


def decode_arg(expr: str, rule_ids: dict[str, int]) -> int:
    """Decode a tok(T) / rule(R) / opt_rule(R) into the u16 arg word."""
    m = re.match(r"(tok|rule|opt_rule)\(\s*(\w+)\s*\)$", expr.strip())
    if not m:
        raise SystemExit(f"gen_grammar: bad arg expr {expr!r}")
    kind, name = m.group(1), m.group(2)
    if kind == "tok":
        if name not in TOKEN_KIND:
            raise SystemExit(f"gen_grammar: unknown token {name!r} in arg {expr!r}")
        return RULE_ARG_TOK | TOKEN_KIND[name]
    if name not in rule_ids:
        raise SystemExit(f"gen_grammar: unknown rule {name!r} in arg {expr!r}")
    rid = rule_ids[name]
    if rid & ~RULE_ARG_ARG_MASK:
        raise SystemExit(f"gen_grammar: rule id {rid} overflows 12 bits")
    return (RULE_ARG_RULE if kind == "rule" else RULE_ARG_OPT_RULE) | rid


# ── main generator ───────────────────────────────────────────────────────


def main() -> int:
    grammar_src = GRAMMAR_H.read_text()
    sha = hashlib.sha256(grammar_src.encode()).hexdigest()
    active = filter_config(grammar_src)
    with_comp, nc = parse_rules(active)

    # Enum ordering (must match parse_shim.c exactly): with_comp in
    # source order, then RULE_const_object, then nc in source order.
    rule_ids: dict[str, int] = {}
    ordered: list[tuple[str, str, list[str]]] = []
    for i, (name, kind, args) in enumerate(with_comp):
        rule_ids[name] = i
        ordered.append((name, kind, args))
    const_object_id = len(with_comp)
    # Note: RULE_const_object has no kind/args; sentinel slot.
    ordered.append(("const_object", "", []))
    for j, (name, kind, args) in enumerate(nc):
        rid = const_object_id + 1 + j
        rule_ids[name] = rid
        ordered.append((name, kind, args))

    total = len(ordered)

    # rule_act_table: kind byte per rule (0 for RULE_const_object).
    rule_act: list[int] = []
    for name, kind, args in ordered:
        if name == "const_object":
            rule_act.append(0)
        else:
            rule_act.append(decode_kind(kind))

    # rule_arg_combined_table: concatenated arg words, in enum order
    # (with_comp first, RULE_const_object contributes 0, then nc).
    # rule_arg_offset_table: byte-offset (low 8 bits) of each rule's args.
    rule_arg: list[int] = []
    rule_arg_off: list[int] = []
    first_above_255: int | None = None
    for name, kind, args in ordered:
        off = len(rule_arg)
        if name == "const_object":
            # parse_shim.c emits a plain 0 for the offset slot; no arg
            # data is appended.
            rule_arg_off.append(0)
            continue
        if off >= 0x100 and first_above_255 is None:
            first_above_255 = rule_ids[name]
        rule_arg_off.append(off & 0xFF)
        for a in args:
            rule_arg.append(decode_arg(a, rule_ids))

    if first_above_255 is None:
        # Sentinel: every rule fits in 8 bits — use total as a never-hit
        # threshold (matches parse_shim.c's "0;" trailing terminator).
        first_above_255 = 0

    # ── required rule-id constants (sanity check; emit-all loop below
    # exports every rule id) ──
    required = [
        "const_object",
        "atom_paren",
        "testlist_comp",
        "testlist_comp_3b",
        "testlist_comp_3c",
        "comp_for",
        "expr_stmt",
        "pass_stmt",
        "single_input",
        "eval_input",
        "file_input",
    ]
    for n in required:
        if n != "const_object" and n not in rule_ids:
            raise SystemExit(
                f"gen_grammar: required rule {n!r} not present in active config"
            )

    # ── emit grammar_data.zig ─────────────────────────────────────────────
    buf: list[str] = []
    w = buf.append
    w("// AUTO-GENERATED by tools/gen_grammar.py — DO NOT EDIT.")
    w("//")
    w("// Source: vendor/micropython_embed/py/grammar.h")
    w(f"// SHA-256: {sha}")
    w("// Config:")
    for k in sorted(CONFIG):
        w(f"//   {k} = {CONFIG[k]}")
    w("//")
    w("// To regenerate after a vendor refresh:  make gen-grammar")
    w("")
    w('const std = @import("std");')
    w("")
    w(f"pub const NUM_RULES: usize = {total};")
    w(f"pub const FIRST_RULE_WITH_OFFSET_ABOVE_255: u8 = {first_above_255};")
    w("")
    w("// rule_act bit masks (lifted from py/parse.c).")
    w(f"pub const RULE_ACT_ARG_MASK: u8 = 0x{RULE_ACT_ARG_MASK:02x};")
    w(f"pub const RULE_ACT_KIND_MASK: u8 = 0x{RULE_ACT_KIND_MASK:02x};")
    w(f"pub const RULE_ACT_ALLOW_IDENT: u8 = 0x{RULE_ACT_ALLOW_IDENT:02x};")
    w(f"pub const RULE_ACT_ADD_BLANK: u8 = 0x{RULE_ACT_ADD_BLANK:02x};")
    w(f"pub const RULE_ACT_OR: u8 = 0x{RULE_ACT_OR:02x};")
    w(f"pub const RULE_ACT_AND: u8 = 0x{RULE_ACT_AND:02x};")
    w(f"pub const RULE_ACT_LIST: u8 = 0x{RULE_ACT_LIST:02x};")
    w("")
    w("// rule_arg bit masks.")
    w(f"pub const RULE_ARG_KIND_MASK: u16 = 0x{RULE_ARG_KIND_MASK:04x};")
    w(f"pub const RULE_ARG_ARG_MASK: u16 = 0x{RULE_ARG_ARG_MASK:04x};")
    w(f"pub const RULE_ARG_TOK: u16 = 0x{RULE_ARG_TOK:04x};")
    w(f"pub const RULE_ARG_RULE: u16 = 0x{RULE_ARG_RULE:04x};")
    w(f"pub const RULE_ARG_OPT_RULE: u16 = 0x{RULE_ARG_OPT_RULE:04x};")
    w("")
    w("// Rule-id constants — one per active grammar rule, plus const_object.")
    w("// Both the parser and the C7 compiler dispatch table @field-reflect")
    w("// over these names.")
    w(f"pub const RULE_const_object: u8 = {const_object_id};")
    for n, rid in sorted(rule_ids.items(), key=lambda kv: kv[1]):
        w(f"pub const RULE_{n}: u8 = {rid};")
    w("")
    w("// ── rule_act_table ──────────────────────────────────────────────")
    w("pub const rule_act_table = [_]u8{")
    for i, v in enumerate(rule_act):
        name = ordered[i][0]
        w(f"    0x{v:02x}, // [{i}] RULE_{name}")
    w("};")
    w("")
    w("// ── rule_arg_combined_table ─────────────────────────────────────")
    w("pub const rule_arg_combined_table = [_]u16{")
    # Add inline comments at the start of each rule's arg slice.
    rule_starts: dict[int, str] = {}
    cursor = 0
    for name, kind, args in ordered:
        if name == "const_object":
            continue
        rule_starts[cursor] = name
        cursor += len(args)
    for i, v in enumerate(rule_arg):
        comment = ""
        if i in rule_starts:
            comment = f"  // RULE_{rule_starts[i]}"
        w(f"    0x{v:04x},{comment}")
    w("};")
    w("")
    w("// ── rule_arg_offset_table ───────────────────────────────────────")
    w("// Low 8 bits of each rule's offset into rule_arg_combined_table.")
    w(
        "// The 9th bit is set by getRuleArg() when id >= FIRST_RULE_WITH_OFFSET_ABOVE_255."
    )
    w("pub const rule_arg_offset_table = [_]u8{")
    for i, v in enumerate(rule_arg_off):
        name = ordered[i][0]
        w(f"    0x{v:02x}, // [{i}] RULE_{name}")
    w("};")
    w("")
    w("// ── accessors (mirror py/parse.c npy_rule_act / get_rule_arg) ───")
    w("pub inline fn ruleAct(id: u8) u8 {")
    w("    return rule_act_table[id];")
    w("}")
    w("")
    w("pub inline fn getRuleArg(id: u8) [*]const u16 {")
    w("    var off: usize = rule_arg_offset_table[id];")
    w("    if (id >= FIRST_RULE_WITH_OFFSET_ABOVE_255) off |= 0x100;")
    w("    return @ptrCast(&rule_arg_combined_table[off]);")
    w("}")
    w("")
    w("// Sanity at comptime: rule_act_table / rule_arg_offset_table sizes match.")
    w("comptime {")
    w(
        '    if (rule_act_table.len != NUM_RULES) @compileError("rule_act_table size drift");'
    )
    w(
        '    if (rule_arg_offset_table.len != NUM_RULES) @compileError("rule_arg_offset_table size drift");'
    )
    w("}")
    w("")

    OUT_ZIG.write_text("\n".join(buf))
    print(
        f"gen_grammar: wrote {OUT_ZIG.relative_to(ROOT)} "
        f"({total} rules, {len(rule_arg)} arg words, "
        f"FIRST_RULE_WITH_OFFSET_ABOVE_255={first_above_255})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
