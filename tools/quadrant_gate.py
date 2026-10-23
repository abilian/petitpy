#!/usr/bin/env python3
"""quadrant_gate.py — strict gate for the split (compiler/VM) configuration.

petitpy splits at the bytecode boundary, and the payoff is this: in one
combined binary a compiler bug and a VM bug can compensate for each other invisibly. Splitting gives four quadrants,
and a divergence localises to one of them.

|                     | our VM              | vendor VM                    |
| our bytecode        | Q1 - this gate      | Q2 - tools/compile-exec-test |
| vendor bytecode     | Q3 - this gate      | Q4 - upstream's baseline     |

Q1 exercises `zigpy-compile` -> `petitpy-vm`. Q3 runs vendor `mpy-cross`
bytecode through our VM, which is the only check that validates the VM against
a front-end we did not write.

Metric is observable output
(stdout + stderr + exit status) against the same frozen goldens `make check`
uses, NOT .mpy byte-identity - two .mpy files can encode one program
differently and execute identically.

Strict bidirectional, like full_gate.py: an unlisted failure fails the build,
and a listed test that now passes fails it too.

The known-fails lists are baselined against `-Dconfig=full -Dfrozen-tiny=true`.
Three tests move between that and a plain `-Dconfig=full` build, so invoke this
through `make check-split`, which builds the right one first, rather than
running it against whatever happens to be in zig-out.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CORPUS = ROOT / "corpus" / "full" / "basics"
TESTS = ROOT / "corpus" / "basics"
VM = ROOT / "zig-out" / "bin" / "petitpy-vm"
ZIGPY = ROOT / "zig-out" / "bin" / "zigpy-compile"
MPY_CROSS = ROOT / "vendor" / "micropython" / "mpy-cross" / "build" / "mpy-cross"

QUADRANTS = {
    "q1": (ZIGPY, ROOT / "corpus" / "split-known-fails.txt", "our bytecode + our VM"),
    "q3": (MPY_CROSS, ROOT / "corpus" / "vendor-mpy-known-fails.txt", "vendor bytecode + our VM"),
}
TIMEOUT = 10


def load_known(path: Path) -> set[str]:
    if not path.exists():
        return set()
    out = set()
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            out.add(line.split("\t")[0].strip())
    return out


def run_quadrant(compiler: Path, tmp: Path) -> tuple[set[str], int]:
    fails: set[str] = set()
    total = 0
    for golden in sorted(CORPUS.glob("*.out")):
        name = golden.stem
        src = TESTS / f"{name}.py"
        if not src.exists():
            continue
        total += 1
        mpy = tmp / f"{name}.mpy"
        c = subprocess.run(
            [str(compiler), "-o", str(mpy), str(src)], capture_output=True, check=False
        )
        if c.returncode != 0 or not mpy.exists():
            fails.add(name)
            continue
        try:
            p = subprocess.run(
                [str(VM), str(mpy)], capture_output=True, timeout=TIMEOUT, check=False
            )
            got = p.stdout + p.stderr + f"\n[exit {p.returncode}]\n".encode()
        except subprocess.TimeoutExpired:
            fails.add(name)
            continue
        if got != golden.read_bytes():
            fails.add(name)
    return fails, total


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument(
        "--quadrant", choices=[*QUADRANTS, "all"], default="all",
        help="which quadrant to gate (default: all)",
    )
    args = ap.parse_args(argv)

    if not VM.exists():
        print(f"error: {VM.relative_to(ROOT)} not built — run `make check-split`", file=sys.stderr)
        return 2

    rc = 0
    wanted = list(QUADRANTS) if args.quadrant == "all" else [args.quadrant]
    for q in wanted:
        compiler, known_path, label = QUADRANTS[q]
        if not compiler.exists():
            print(f"{q.upper()} ({label}): SKIP — {compiler.relative_to(ROOT)} not built", file=sys.stderr)
            if compiler is MPY_CROSS:
                print("     build it with: make -C vendor/micropython/mpy-cross", file=sys.stderr)
            rc = max(rc, 2)
            continue
        with tempfile.TemporaryDirectory() as td:
            fails, total = run_quadrant(compiler, Path(td))
        known = load_known(known_path)
        new = sorted(fails - known)
        fixed = sorted(known - fails)
        passing = total - len(fails)
        print(f"{q.upper()} ({label}): {passing}/{total} passing, {len(fails)} known-fails")
        if new:
            print(f"  REGRESSION — {len(new)} failure(s) not in {known_path.name}:")
            for n in new:
                print(f"    {n}")
            rc = 1
        if fixed:
            print(f"  NOW PASSING — {len(fixed)} test(s) still listed in {known_path.name}:")
            for n in fixed:
                print(f"    {n}")
            print("  Remove them from the list in the same commit that fixed them.")
            rc = 1
        if not new and not fixed:
            print("  GREEN (matches known-fails baseline exactly)")
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
