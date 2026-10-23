"""Compile with pyfront, run on petitpy-vm, compare against CPython.

This is the only test that can say the compiler is *right* rather than merely
producing a loadable file: the bytecode is checked by what it computes.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

from pyfront import Unsupported, compile_source
from tests.programs import CLOSURES, PROGRAMS, UNSUPPORTED

ROOT = Path(__file__).resolve().parents[5]
VM = ROOT / "zig-out" / "bin" / "petitpy-vm"


@pytest.mark.skipif(not VM.exists(), reason="petitpy-vm not built")
@pytest.mark.parametrize("name", sorted(PROGRAMS))
def test_matches_cpython(name: str, tmp_path: Path) -> None:
    source = PROGRAMS[name]
    mpy = tmp_path / f"{name}.mpy"
    mpy.write_bytes(compile_source(source))

    got = subprocess.run(
        [str(VM), str(mpy)], capture_output=True, timeout=30, check=False
    )
    want = subprocess.run(
        [sys.executable, "-c", source], capture_output=True, timeout=30, check=False
    )

    assert got.returncode == 0, f"VM failed: {got.stderr.decode()}"
    assert got.stdout == want.stdout, (
        f"\n  pyfront: {got.stdout!r}\n  cpython: {want.stdout!r}"
    )


@pytest.mark.parametrize("name", sorted(UNSUPPORTED))
def test_unsupported_refuses_by_name(name: str) -> None:
    """An unhandled construct must raise, never emit wrong bytecode."""
    with pytest.raises(Unsupported):
        compile_source(UNSUPPORTED[name])


@pytest.mark.skipif(not VM.exists(), reason="petitpy-vm not built")
@pytest.mark.parametrize("name", sorted(CLOSURES))
def test_closures_match_cpython(name: str, tmp_path: Path) -> None:
    source = CLOSURES[name]
    mpy = tmp_path / f"{name}.mpy"
    mpy.write_bytes(compile_source(source))
    got = subprocess.run(
        [str(VM), str(mpy)], capture_output=True, timeout=30, check=False
    )
    want = subprocess.run(
        [sys.executable, "-c", source], capture_output=True, timeout=30, check=False
    )
    assert got.returncode == 0, f"VM failed: {got.stderr.decode()}"
    assert got.stdout == want.stdout, (
        f"\n  pyfront: {got.stdout!r}\n  cpython: {want.stdout!r}"
    )
