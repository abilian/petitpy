"""The dispatch table, measured against Python's grammar by astero.

`Compiler` dispatches on node class name. Without a check, a production nobody
thought about is indistinguishable from one deliberately left out, and Python
grows productions between releases. astero's `Coverage` splits the difference
three ways: handled, excused with a stated reason, and missing. `absent` and
`redundant` then catch excuses that have gone stale, which makes the list
bidirectional in the same way the repo's known-fails files are.
"""

from __future__ import annotations

from astero.coverage import Coverage
from astero.python.lang import PY

from pyfront.compile import Compiler

#: Productions pyfront does not compile, grouped by why. Every name here is a
#: decision; anything not here and not handled fails the test.
OUT_OF_SCOPE = {
    "needs a runtime feature pyfront does not emit yet": frozenset({
        "AsyncFor",
        "TryStar",
        "AsyncWith",
        "Await",
        "AsyncFunctionDef",
        "Starred",
        "TypeAlias",
    }),
    "structural: carried by the productions that contain them": frozenset({
        "arguments",
        "arg",
        "keyword",
        "alias",
        "withitem",
        "comprehension",
        "excepthandler",
        "ExceptHandler",
        "match_case",
        "TypeVar",
        "ParamSpec",
        "TypeVarTuple",
        "Interactive",
        "Expression",
        "FunctionType",
        "Load",
        "Store",
        "Del",
    }),
    "operator tokens: read off the node, never dispatched to": frozenset({
        "Add",
        "Sub",
        "Mult",
        "MatMult",
        "Div",
        "Mod",
        "Pow",
        "LShift",
        "RShift",
        "BitOr",
        "BitXor",
        "BitAnd",
        "FloorDiv",
        "Invert",
        "Not",
        "UAdd",
        "USub",
        "And",
        "Or",
        "Eq",
        "NotEq",
        "Lt",
        "LtE",
        "Gt",
        "GtE",
        "Is",
        "IsNot",
        "In",
        "NotIn",
    }),
    "abstract bases in the grammar, never instantiated": frozenset({
        "AST",
        "mod",
        "stmt",
        "expr",
        "expr_context",
        "boolop",
        "operator",
        "unaryop",
        "cmpop",
        "pattern",
        "type_ignore",
        "type_param",
    }),
    "handled by Compiler.compile directly, not through dispatch": frozenset({
        "Module",
    }),
    "3.14 t-strings; the runtime has no template type": frozenset({
        "TemplateStr",
        "Interpolation",
    }),
    "type-comment machinery, absent from the runtime": frozenset({
        "TypeIgnore",
    }),
    "match sub-patterns: desugared by _pattern_test, not dispatched": frozenset({
        "MatchValue",
        "MatchSingleton",
        "MatchSequence",
        "MatchMapping",
        "MatchClass",
        "MatchStar",
        "MatchAs",
        "MatchOr",
    }),
}


def handled() -> frozenset[str]:
    """Production names Compiler has a `_Name` method for."""
    return frozenset(
        n[1:]
        for n in dir(Compiler)
        if n.startswith("_") and not n.startswith("__") and n[1:2].isupper()
    )


def coverage() -> Coverage:
    return Coverage(
        handled=handled(),
        expected=frozenset(PY.productions),
        accounted=OUT_OF_SCOPE,
    )


def test_no_production_is_unaccounted_for() -> None:
    missing = coverage().missing
    assert not missing, (
        "productions neither handled nor listed in OUT_OF_SCOPE:\n  "
        + "\n  ".join(sorted(missing))
        + "\n\nAdd a `_Name` method, or list it with the reason it is out of scope."
    )


def test_no_excuse_is_stale() -> None:
    cov = coverage()
    assert not cov.redundant, (
        "listed as out of scope but handled after all: "
        + ", ".join(sorted(cov.redundant))
    )
