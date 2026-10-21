"""Every corpus program, compiled and checked without a VM.

The e2e differential suite is the only thing that can say the bytecode is
*right*. But most of what it exercises does not need a subprocess to be worth
checking: that each construct's emit path runs at all, and that the container
it produces decodes exactly, are cheap questions with precise answers.

Splitting it that way is what moves half of `compile`'s statements out of the
expensive tier. A failure here names the construct and the malformation; the
same failure at the e2e tier is a VM that prints the wrong thing.
"""

from __future__ import annotations

import pytest

from pyfront import compile_source
from tests.mpy_reader import MalformedError, parse
from tests.programs import CLOSURES, PROGRAMS

CORPUS = {**PROGRAMS, **CLOSURES}


@pytest.mark.parametrize("name", sorted(CORPUS))
def test_compiles_to_a_container_that_decodes_exactly(name: str) -> None:
    """Walking the blob and landing on the final byte catches a truncated
    payload, a mis-encoded var-int, or a missing NUL terminator."""
    qstrs, _objs, n_codes = parse(compile_source(CORPUS[name], name))
    assert "<module>" in qstrs
    assert n_codes >= 1


@pytest.mark.parametrize("name", sorted(CORPUS))
def test_compilation_is_deterministic(name: str) -> None:
    """Set iteration or unstable interning would show up as a compiler that
    emits different bytes for the same source — a miserable thing to debug
    from a differential failure."""
    source = CORPUS[name]
    assert compile_source(source, name) == compile_source(source, name)


def test_every_name_the_program_uses_reaches_the_qstr_table() -> None:
    """A name missing from the table is a load that resolves to the wrong
    slot, which is a wrong answer rather than a crash."""
    qstrs, _objs, _n = parse(
        compile_source("def outer(alpha):\n    return alpha.beta\n", "t")
    )
    assert {"outer", "alpha", "beta"} <= set(qstrs)


# ── the reader is a test fixture, so it needs its own floor ───────────────
#
# Every assertion above is only as good as `parse` being strict. A reader
# that accepted anything would make the whole file pass vacuously.


def test_reader_rejects_a_truncated_blob() -> None:
    blob = compile_source("print(1)\n", "t")
    with pytest.raises(MalformedError):
        parse(blob[:-3])


def test_reader_rejects_trailing_bytes() -> None:
    blob = compile_source("print(1)\n", "t")
    with pytest.raises(MalformedError, match="trailing"):
        parse(blob + b"\x00")


def test_reader_rejects_a_stripped_nul_terminator() -> None:
    """The exact shape of the bug this whole apparatus is aimed at."""
    blob = compile_source('x = "ab"\n', "t")
    assert b"ab\x00" in blob
    with pytest.raises(MalformedError):
        parse(blob.replace(b"ab\x00", b"ab", 1))


def test_reader_rejects_a_bad_header() -> None:
    with pytest.raises(MalformedError, match="header"):
        parse(b"XX\x00\x3f")
