"""Hatchling build hook — invokes `python -m ziglang build` and puts the
resulting binary and the on-disk stdlib into the wheel.

The wheel bundles a single-pass `zig build -Dconfig=full -Doptimize=ReleaseFast`
binary (no `-Dfrozen-tiny`) as two scripts, `bin/petitpy` and its short
name `bin/ppy`, each the binary itself (a wheel cannot hold a symlink),
and the stdlib as shared data at `share/petitpy/lib/`, where the
runtime looks next to its own executable (ADR 016 §3). The modules that the
Makefile flow freezes ship as .py files there instead; skipping frozen-tiny
removes the two-pass build that would need `zigpy-compile` in the isolated
pip build env.

Cross-compile via the `NANOPYTHON_TARGET` env var (`<zig-triple>:<wheel-tag>`,
e.g. `x86_64-linux-gnu.2.17:manylinux_2_17_x86_64`).  Absent = host build.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

from hatchling.builders.hooks.plugin.interface import BuildHookInterface
from packaging import tags

# The wheel's stdlib, bundled at share/petitpy/lib/: every module under
# nanopython-lib/ (packages included).
STDLIB_DIR = "nanopython-lib"
# The JS bridge: importing it on native raises ImportError by design.
BROWSER_ONLY = {"js.py"}


def stdlib_files(root: Path) -> dict[Path, str]:
    """Source file -> path under share/petitpy/lib/."""
    lib = root / STDLIB_DIR
    return {
        src: src.relative_to(lib).as_posix()
        for src in lib.rglob("*.py")
        if "__pycache__" not in src.parts and src.name not in BROWSER_ONLY
    }


class CustomBuildHook(BuildHookInterface):
    PLUGIN_NAME = "custom"

    def initialize(self, version: str, build_data: dict[str, Any]) -> None:
        build_data["pure_python"] = False
        build_data["infer_tag"] = False

        # Cross-compile shape (used by the sourcehut release matrix; a local
        # `uv build` sets no env var and gets a native host wheel).
        target = os.environ.get("NANOPYTHON_TARGET", "")
        if target:
            zig_target, wheel_tag = target.split(":", 1)
            zig_target_arg = [f"-Dtarget={zig_target}"]
            build_data["tag"] = f"py3-none-{wheel_tag}"
        else:
            zig_target_arg = []
            build_data["tag"] = f"py3-none-{next(tags.platform_tags())}"

        root = Path(self.root)
        # The full-config build fails on the `nanopython-vm` variant binary
        # (10 unresolved float symbols, deferred).
        # The main `nanopython` binary builds cleanly; verify by checking it
        # exists after the run, mirroring the Makefile pattern of `-zig build`
        # followed by an explicit binary-presence check.
        subprocess.run(
            [
                sys.executable,
                "-m",
                "ziglang",
                "build",
                "-Dconfig=full",
                "-Doptimize=ReleaseFast",
                "-Dstrip=true",
                *zig_target_arg,
            ],
            check=False,
            cwd=root,
        )

        suffix = ".exe" if "win" in build_data["tag"] else ""
        binary = root / "zig-out" / "bin" / f"nanopython{suffix}"
        if not binary.exists():
            raise FileNotFoundError(
                f"zig build did not produce {binary}. "
                f"Check the ziglang subprocess output above for errors."
            )
        short = binary.with_name(f"ppy{suffix}")
        shutil.copy2(binary, short)

        scripts = build_data.setdefault("shared_scripts", {})
        scripts[str(binary)] = f"petitpy{suffix}"
        scripts[str(short)] = f"ppy{suffix}"

        data = build_data.setdefault("shared_data", {})
        for src, dest in stdlib_files(root).items():
            data[str(src)] = f"share/petitpy/lib/{dest}"
