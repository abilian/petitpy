"""The `pyfront` command, over its documented contract.

The README promises three outcomes: 0 compiled, 2 refused by name, anything
else a bug. That promise is load-bearing — `tools/capability_matrix.py` reads
exit 2 as "this construct is unsupported" and treats every other non-zero exit
as pyfront being broken. It got that distinction wrong once already, and read
a dead pyfront as 65 front-end gaps while the gate stayed green.

The module was at 0% coverage.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

import pytest

from pyfront.cli import main
from pyfront.emit.mpy import MPY_MAGIC, MPY_VERSION

if TYPE_CHECKING:
    from pathlib import Path


def test_compiles_to_the_named_output(tmp_path: Path) -> None:
    src = tmp_path / "hello.py"
    src.write_text("print(1 + 1)\n")
    out = tmp_path / "hello.mpy"

    assert main([str(src), "-o", str(out)]) == 0

    blob = out.read_bytes()
    assert blob[0] == MPY_MAGIC
    assert blob[1] == MPY_VERSION


def test_output_defaults_to_the_source_with_mpy(tmp_path: Path) -> None:
    src = tmp_path / "hello.py"
    src.write_text("x = 1\n")

    assert main([str(src)]) == 0
    assert (tmp_path / "hello.mpy").exists()


@pytest.mark.parametrize(
    ("source", "expected"),
    [
        ("async def f():\n    pass\n", "AsyncFunctionDef"),
        ("class C:\n    def m(self):\n        super()\n", "super"),
        ("match [1]:\n    case [*a, 1, *b]:\n        pass\n", "more than one star"),
    ],
)
def test_unsupported_construct_exits_2_and_names_itself(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    source: str,
    expected: str,
) -> None:
    src = tmp_path / "bad.py"
    src.write_text(source)

    assert main([str(src), "-o", str(tmp_path / "bad.mpy")]) == 2
    assert expected in capsys.readouterr().err


def test_syntax_error_also_exits_2(tmp_path: Path) -> None:
    """A refusal is a refusal whether pyfront or CPython's parser made it."""
    src = tmp_path / "bad.py"
    src.write_text("def (\n")

    assert main([str(src), "-o", str(tmp_path / "bad.mpy")]) == 2


def test_a_refusal_writes_no_output(tmp_path: Path) -> None:
    """A half-written .mpy would be worse than none: the matrix would run it."""
    src = tmp_path / "bad.py"
    src.write_text("async def f():\n    pass\n")
    out = tmp_path / "bad.mpy"

    assert main([str(src), "-o", str(out)]) == 2
    assert not out.exists()
