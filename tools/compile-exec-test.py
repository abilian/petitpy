#!/usr/bin/env python3
"""compile-exec-test — the actual success criterion for the compiler track.

For each Python test in corpus/basics/:
  1. Compile to .mpy via our zigpy-compile (the Zig-based frontend).
  2. Execute the .mpy through the upstream unix MicroPython binary
     (the SAME C VM that was used to freeze corpus/full/basics/*.out).
  3. Diff captured stdout+stderr+exit-status against the frozen .out.

Pass means: programs compiled by the Zig-based front-end and run through
the C VM produce the same observable output as programs compiled by the
C-based front-end and run through the same C VM. This is the actual goal
(the "Our bytecode + Vendor VM" quadrant of the compiler x VM matrix).
The byte-identity `.mpy` proxy that `compile-test` measures is a tighter pre-flight diagnostic only.

Usage:
  python3 tools/compile-exec-test.py [--verbose] [--limit N]
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ZIGPY = ROOT / "zig-out" / "bin" / "zigpy-compile"
ORACLE = (
    ROOT
    / "vendor"
    / "micropython"
    / "ports"
    / "unix"
    / "build-standard"
    / "micropython"
)
TESTS = ROOT / "corpus" / "basics"
CORPUS = ROOT / "corpus" / "full" / "basics"
EXCLUDED = ROOT / "corpus" / "full" / "EXCLUDED.txt"
TIMEOUT = 30


def fmt_out(stdout: bytes, stderr: bytes, returncode: int) -> bytes:
    """Match corpus.py's frozen-output convention."""
    return stdout + stderr + f"\n[exit {returncode}]\n".encode()


def read_excluded() -> set[str]:
    if not EXCLUDED.exists():
        return set()
    return {
        ln.strip()
        for ln in EXCLUDED.read_text().splitlines()
        if ln.strip() and not ln.startswith("#")
    }


def run_one(py: Path, workdir: Path) -> tuple[str, bytes | None, bytes | None]:
    """Compile + execute one .py. Returns (status, expected, got).

    status ∈ {"PASS", "FAIL", "COMPILE_FAIL", "RUNNER_ERROR", "TIMEOUT"}.
    """
    name = py.stem
    golden_path = CORPUS / f"{name}.out"
    if not golden_path.exists():
        return ("NO_GOLDEN", None, None)

    mpy_path = workdir / f"{name}.mpy"
    # Compile via zigpy-compile.
    try:
        proc = subprocess.run(
            [str(ZIGPY), "-o", str(mpy_path), str(py)],
            capture_output=True,
            timeout=TIMEOUT,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return ("TIMEOUT", None, None)
    except (FileNotFoundError, PermissionError) as e:
        return ("RUNNER_ERROR", None, f"zigpy-compile launch failed: {e}".encode())
    if proc.returncode != 0:
        return ("COMPILE_FAIL", None, proc.stdout + proc.stderr)

    # Execute via `-m <module>` so the .mpy loads with __name__ ==
    # "__main__" — same as the .out files were generated under (oracle
    # was run as `micropython script.py` which also sets __main__).
    # `__import__` would set __name__ to the module name and __file__
    # to the .mpy path; tests that key off either (e.g. builtin_help
    # printing __module__, sys_path checking __file__.endswith) would
    # diverge under that path. The unix port doesn't accept a .mpy
    # filename argv directly (tries to parse as Python source).
    try:
        env = dict(os.environ)
        env["MICROPYPATH"] = str(workdir)
        run = subprocess.run(
            [str(ORACLE), "-m", name],
            capture_output=True,
            timeout=TIMEOUT,
            cwd=str(workdir),
            env=env,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return ("TIMEOUT", None, None)

    got = fmt_out(run.stdout, run.stderr, run.returncode)
    expected = golden_path.read_bytes()
    return ("PASS" if got == expected else "FAIL", expected, got)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--verbose", "-v", action="store_true")
    ap.add_argument("--limit", type=int, default=0, help="max tests to run")
    ap.add_argument(
        "--show-diff",
        action="store_true",
        help="for each FAIL, print first 8 lines of unified diff",
    )
    args = ap.parse_args()

    if not ZIGPY.exists():
        print(f"zigpy-compile not built: {ZIGPY}", file=sys.stderr)
        print("Run: zig build", file=sys.stderr)
        return 2
    if not ORACLE.exists():
        print(f"upstream micropython not built: {ORACLE}", file=sys.stderr)
        return 2
    if not CORPUS.exists():
        print(f"frozen corpus not found: {CORPUS}", file=sys.stderr)
        return 2

    excluded = read_excluded()
    scripts = sorted(TESTS.glob("*.py"))
    if args.limit:
        scripts = scripts[: args.limit]

    counts = {
        "PASS": 0,
        "FAIL": 0,
        "COMPILE_FAIL": 0,
        "TIMEOUT": 0,
        "RUNNER_ERROR": 0,
        "NO_GOLDEN": 0,
        "EXCLUDED": 0,
        "NANO_OOS": 0,
    }
    fails: list[tuple[str, str, bytes | None, bytes | None]] = []

    def is_async_test(py: Path) -> bool:
        # Nano config has MICROPY_PY_ASYNC_AWAIT=0; the lexer doesn't
        # recognise async/await keywords. Tests dedicated to those
        # features (file name starts with "async_") are out of nano
        # scope by design, not compiler bugs. Tests that *mention*
        # async/await elsewhere (e.g. syntaxerror.py feeding `await 1`
        # to a SyntaxError check) DO compile in nano — keep them in.
        return py.name.startswith("async_")

    with tempfile.TemporaryDirectory(prefix="cetest_") as tmp:
        workdir = Path(tmp)
        for py in scripts:
            name = py.stem
            if name in excluded:
                counts["EXCLUDED"] += 1
                continue
            if is_async_test(py):
                counts["NANO_OOS"] += 1
                continue
            status, expected, got = run_one(py, workdir)
            counts[status] = counts.get(status, 0) + 1
            if status not in ("PASS", "EXCLUDED", "NO_GOLDEN"):
                fails.append((status, name, expected, got))
            if args.verbose:
                print(f"  {status:14} {name}")

    total = (
        sum(counts.values())
        - counts["NO_GOLDEN"]
        - counts["EXCLUDED"]
        - counts["NANO_OOS"]
    )
    print(
        f"compile-exec-test: {counts['PASS']}/{total} pass, "
        f"{counts['FAIL']} fail, {counts['COMPILE_FAIL']} compile-fail, "
        f"{counts['TIMEOUT']} timeout, {counts['RUNNER_ERROR']} runner-err"
    )
    print(
        f"  (skipped: {counts['NO_GOLDEN']} no-golden, "
        f"{counts['EXCLUDED']} excluded, {counts['NANO_OOS']} async/nano-OOS)"
    )

    if fails and args.show_diff:
        print()
        for status, name, expected, got in fails[:25]:
            print(f"=== {status} {name} ===")
            if expected and got:
                import difflib

                diff = list(
                    difflib.unified_diff(
                        expected.decode(errors="replace").splitlines(keepends=True),
                        got.decode(errors="replace").splitlines(keepends=True),
                        fromfile="expected",
                        tofile="got",
                        n=2,
                    )
                )
                for line in diff[:12]:
                    print(line.rstrip("\n"))
            else:
                if got:
                    print(got.decode(errors="replace"))
        if len(fails) > 25:
            print(f"  ... and {len(fails) - 25} more")

    return 0 if counts["FAIL"] == 0 and counts["COMPILE_FAIL"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
