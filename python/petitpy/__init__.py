"""petitpy — a small Python runtime (native + wasm32-wasi).

This importable package is the PyPI wrapper. The runtime is a native
binary the wheel installs as the `petitpy` and `ppy` scripts, with its
stdlib at `share/petitpy/lib` in the environment's data directory, where
the binary finds it. `python -m petitpy` and `find_bin()` reach it from
Python.
"""
from __future__ import annotations

import os
import sysconfig
from pathlib import Path


def find_bin() -> Path:
    """Return the path to the installed petitpy binary."""
    exe = "petitpy.exe" if os.name == "nt" else "petitpy"
    return Path(sysconfig.get_path("scripts")) / exe


def find_lib() -> Path:
    """Return the path to the installed on-disk stdlib directory."""
    return Path(sysconfig.get_path("data")) / "share" / "petitpy" / "lib"


__all__ = ["find_bin", "find_lib"]
