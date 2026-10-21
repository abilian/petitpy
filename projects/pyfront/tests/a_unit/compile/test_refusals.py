"""Every refusal the README promises, checked.

pyfront compiles a subset, and its whole safety argument is that it says so:
an unsupported construct is an `Unsupported` naming itself, never bytecode
that runs and computes the wrong answer. That makes each refusal a contract,
and the raise lines were among the least-covered in the package.

A refusal that silently stops refusing is the dangerous direction. It does not
fail loudly — it starts emitting something.
"""

from __future__ import annotations

import pytest

from pyfront import Unsupported, compile_source

REFUSALS = [
    # (construct, source, fragment of the message)
    ("async def", "async def f():\n    pass\n", "AsyncFunctionDef"),
    ("await", "async def f():\n    await g()\n", "Async"),
    ("zero-arg super()", "class C:\n    def m(self):\n        super()\n", "super"),
    ("starred target", "a, *b = [1, 2, 3]\n", "starred target"),
    ("del of a list target", "del [a, b]\n", "del of"),
    ("keyword-only params", "def f(*, a):\n    return a\n", "keyword-only"),
    ("positional-only params", "def f(a, /):\n    return a\n", "keyword-only"),
    ("rich lambda signature", "f = lambda *a: a\n", "lambda signature"),
    ("class decorator", "@d\nclass C:\n    pass\n", "class decorator"),
    ("metaclass=", "class C(metaclass=M):\n    pass\n", "keyword argument"),
    ("multi-for genexp", "g = (x for a in b for x in a)\n", "more than one"),
    ("** in a dict display", "d = {**a}\n", "unpacking"),
    ("multi-item with", "with a as x, b as y:\n    pass\n", "more than one item"),
    (
        "non-final bare except",
        "try:\n    pass\nexcept:\n    pass\nexcept E:\n    pass\n",
        "bare except",
    ),
    ("f-string conversion", 'x = f"{a!r}"\n', "conversion"),
    ("nested format spec", 'x = f"{a:{w}}"\n', "nested expression"),
    (
        "two stars",
        "match m:\n    case [*a, 1, *b]:\n        pass\n",
        "more than one star",
    ),
    (
        "** in a mapping pattern",
        'match m:\n    case {"k": v, **rest}:\n        pass\n',
        "capture in a mapping",
    ),
    (
        "positional class sub-pattern",
        "match m:\n    case P(1):\n        pass\n",
        "positional sub-pattern",
    ),
]


@pytest.mark.parametrize(
    ("source", "fragment"),
    [(src, frag) for _, src, frag in REFUSALS],
    ids=[name for name, _, _ in REFUSALS],
)
def test_refused_by_name(source: str, fragment: str) -> None:
    with pytest.raises(Unsupported, match=fragment):
        compile_source(source, "<test>")


def test_the_supported_neighbour_of_each_refusal_still_compiles() -> None:
    """Guards the tests above from passing for the wrong reason: a compiler
    that refused everything would make every one of them green."""
    for source in (
        "def f(a, b=1, *args, **kw):\n    return a\n",
        "class C(B):\n    def m(self):\n        return super(C, self).m()\n",
        "a, b = 1, 2\n",
        "del a\n",
        "g = (x for x in y)\n",
        "d = {'a': 1}\n",
        "with a as x:\n    pass\n",
        "try:\n    pass\nexcept E:\n    pass\nexcept:\n    pass\n",
        'x = f"{a:>10}"\n',
        "match m:\n    case [a, b]:\n        pass\n",
        "match m:\n    case [a, *rest]:\n        pass\n",
        'match m:\n    case {"k": v}:\n        pass\n',
        "match m:\n    case {}:\n        pass\n",
        "match m:\n    case P(x=1):\n        pass\n",
    ):
        assert compile_source(source, "<test>")
