#!/usr/bin/env python3
# nanopython — grammar overlays.
#
# Adds two syntax features MicroPython's grammar doesn't ship:
#
#   1. PEP 448 `{**d}` dict-unpack — extends dictorsetmaker_item via a
#      new OR wrapper (dictorsetmaker_entry) so `{**d}` parses; the
#      wrapper is NC so existing compile.zig checks for
#      RULE_dictorsetmaker_item stay valid. Emit at
#      compile.zig::compileDictorsetmakerDblStar.
#
#   2. PEP 570 positional-only `/` marker — adds typedargslist_slash /
#      varargslist_slash rules matching a lone `/` token in the param
#      list. MicroPython doesn't distinguish positional-only anyway,
#      so both compile-side walkers just skip the node. Unblocks e.g.
#      `def f(self, x, /, y): ...`.

import sys
import pathlib

# ── 1. dict-unpack ────────────────────────────────────────────────────────

DICT_OLD = """DEF_RULE_NC(dictorsetmaker, and_ident(2), rule(dictorsetmaker_item), opt_rule(dictorsetmaker_tail))
#if MICROPY_PY_BUILTINS_SET
DEF_RULE(dictorsetmaker_item, c(dictorsetmaker_item), and_ident(2), rule(test), opt_rule(generic_colon_test))
#else
DEF_RULE(dictorsetmaker_item, c(dictorsetmaker_item), and(3), rule(test), tok(DEL_COLON), rule(test))
#endif
DEF_RULE_NC(dictorsetmaker_tail, or(2), rule(comp_for), rule(dictorsetmaker_list))
DEF_RULE_NC(dictorsetmaker_list, and(2), tok(DEL_COMMA), opt_rule(dictorsetmaker_list2))
DEF_RULE_NC(dictorsetmaker_list2, list_with_end, rule(dictorsetmaker_item), tok(DEL_COMMA))"""

DICT_NEW = """DEF_RULE_NC(dictorsetmaker, and_ident(2), rule(dictorsetmaker_entry), opt_rule(dictorsetmaker_tail))
DEF_RULE_NC(dictorsetmaker_entry, or(2), rule(dictorsetmaker_dbl_star), rule(dictorsetmaker_item))
DEF_RULE(dictorsetmaker_dbl_star, c(dictorsetmaker_dbl_star), and(2), tok(OP_DBL_STAR), rule(test))
#if MICROPY_PY_BUILTINS_SET
DEF_RULE(dictorsetmaker_item, c(dictorsetmaker_item), and_ident(2), rule(test), opt_rule(generic_colon_test))
#else
DEF_RULE(dictorsetmaker_item, c(dictorsetmaker_item), and(3), rule(test), tok(DEL_COLON), rule(test))
#endif
DEF_RULE_NC(dictorsetmaker_tail, or(2), rule(comp_for), rule(dictorsetmaker_list))
DEF_RULE_NC(dictorsetmaker_list, and(2), tok(DEL_COMMA), opt_rule(dictorsetmaker_list2))
DEF_RULE_NC(dictorsetmaker_list2, list_with_end, rule(dictorsetmaker_entry), tok(DEL_COMMA))"""

# ── 2. positional-only `/` marker ─────────────────────────────────────────

SLASH_OLD = """DEF_RULE_NC(typedargslist_item, or(3), rule(typedargslist_name), rule(typedargslist_star), rule(typedargslist_dbl_star))
DEF_RULE_NC(typedargslist_name, and_ident(3), tok(NAME), opt_rule(generic_colon_test), opt_rule(generic_equal_test))
DEF_RULE_NC(typedargslist_star, and(2), tok(OP_STAR), opt_rule(tfpdef))
DEF_RULE_NC(typedargslist_dbl_star, and(3), tok(OP_DBL_STAR), tok(NAME), opt_rule(generic_colon_test))"""

SLASH_NEW = """DEF_RULE_NC(typedargslist_item, or(4), rule(typedargslist_name), rule(typedargslist_star), rule(typedargslist_dbl_star), rule(typedargslist_slash))
DEF_RULE_NC(typedargslist_name, and_ident(3), tok(NAME), opt_rule(generic_colon_test), opt_rule(generic_equal_test))
DEF_RULE_NC(typedargslist_star, and(2), tok(OP_STAR), opt_rule(tfpdef))
DEF_RULE_NC(typedargslist_dbl_star, and(3), tok(OP_DBL_STAR), tok(NAME), opt_rule(generic_colon_test))
DEF_RULE_NC(typedargslist_slash, and(1), tok(OP_SLASH))"""

VARARGS_OLD = """DEF_RULE_NC(varargslist_item, or(3), rule(varargslist_name), rule(varargslist_star), rule(varargslist_dbl_star))
DEF_RULE_NC(varargslist_name, and_ident(2), tok(NAME), opt_rule(generic_equal_test))
DEF_RULE_NC(varargslist_star, and(2), tok(OP_STAR), opt_rule(vfpdef))
DEF_RULE_NC(varargslist_dbl_star, and(2), tok(OP_DBL_STAR), tok(NAME))"""

VARARGS_NEW = """DEF_RULE_NC(varargslist_item, or(4), rule(varargslist_name), rule(varargslist_star), rule(varargslist_dbl_star), rule(varargslist_slash))
DEF_RULE_NC(varargslist_name, and_ident(2), tok(NAME), opt_rule(generic_equal_test))
DEF_RULE_NC(varargslist_star, and(2), tok(OP_STAR), opt_rule(vfpdef))
DEF_RULE_NC(varargslist_dbl_star, and(2), tok(OP_DBL_STAR), tok(NAME))
DEF_RULE_NC(varargslist_slash, and(1), tok(OP_SLASH))"""


WITH_OLD = """DEF_RULE(with_stmt, c(with_stmt), and(4), tok(KW_WITH), rule(with_stmt_list), tok(DEL_COLON), rule(suite))
DEF_RULE_NC(with_stmt_list, list, rule(with_item), tok(DEL_COMMA))"""

WITH_NEW = """DEF_RULE(with_stmt, c(with_stmt), and(4), tok(KW_WITH), rule(with_body), tok(DEL_COLON), rule(suite))
DEF_RULE_NC(with_body, or(2), rule(with_body_paren), rule(with_stmt_list))
DEF_RULE_NC(with_body_paren, and(3), tok(DEL_PAREN_OPEN), rule(with_paren_list), tok(DEL_PAREN_CLOSE))
DEF_RULE_NC(with_paren_list, list_with_end, rule(with_item), tok(DEL_COMMA))
DEF_RULE_NC(with_stmt_list, list, rule(with_item), tok(DEL_COMMA))"""


PATCHES = [
    ("dict-unpack (PEP 448)", DICT_OLD, DICT_NEW, "dictorsetmaker_entry"),
    ("typedargslist / (PEP 570)", SLASH_OLD, SLASH_NEW, "typedargslist_slash"),
    ("varargslist / (PEP 570)", VARARGS_OLD, VARARGS_NEW, "varargslist_slash"),
    ("parenthesized with (PEP 617)", WITH_OLD, WITH_NEW, "with_body_paren"),
]


def main() -> int:
    target = pathlib.Path(sys.argv[1])
    text = target.read_text()
    for label, old, new, marker in PATCHES:
        if marker in text:
            print(f"patch_grammar: {label} — already patched", file=sys.stderr)
            continue
        if old not in text:
            print(f"patch_grammar: {label} — expected block not found",
                  file=sys.stderr)
            return 1
        text = text.replace(old, new)
        print(f"patch_grammar: {label} — applied", file=sys.stderr)
    target.write_text(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
