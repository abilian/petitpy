#!/usr/bin/env python3
"""full_gate.py — strict regression gate for the full-corpus arm.

Per ADR 012 the full arm becomes the default profile over time; per ADR
013 / Phase 3.5 the headline is now 536/552 (97.1%). This gate freezes
that progress: any regression fails CI, any unexpected pass requires
removing the test from corpus/full-known-fails.txt in the same commit.

Mirrors tools/wasm_gate.py's discipline exactly — bidirectional check
(no new fails outside the list, no stale entries that now pass). The
list only ever shrinks.

Usage:
    make check-full
    python3 tools/full_gate.py
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
KNOWN_FAILS = ROOT / "corpus" / "full-known-fails.txt"
CORPUS = ROOT / "corpus" / "full" / "basics"
TESTS = ROOT / "sandbox" / "micropython" / "tests" / "basics"
BIN = ROOT / "zig-out" / "bin" / "nanopython"


def load_list(path: Path) -> set[str]:
    if not path.exists():
        print(f"error: {path.relative_to(ROOT)} not found", file=sys.stderr)
        sys.exit(2)
    return {
        line.strip()
        for line in path.read_text().splitlines()
        if line.strip() and not line.startswith("#")
    }


def current_failures() -> tuple[set[str], int]:
    """Run every golden's test through the binary; return (failures, total)."""
    if not BIN.exists():
        print(
            f"error: {BIN.relative_to(ROOT)} not built — run `make build CONFIG=full` first",
            file=sys.stderr,
        )
        sys.exit(2)
    fails: set[str] = set()
    total = 0
    for g in sorted(CORPUS.glob("*.out")):
        name = g.stem
        script = TESTS / f"{name}.py"
        total += 1
        try:
            p = subprocess.run(
                [str(BIN), str(script)], capture_output=True, timeout=10, check=False
            )
            got = p.stdout + p.stderr + f"\n[exit {p.returncode}]\n".encode()
        except subprocess.TimeoutExpired:
            fails.add(name)
            continue
        if got != g.read_bytes():
            fails.add(name)
    return fails, total


def main(argv: list[str]) -> int:
    argparse.ArgumentParser(description=__doc__).parse_args(argv)

    known = load_list(KNOWN_FAILS)
    actual, total = current_failures()
    passing = total - len(actual)
    pct = passing * 100 / total if total else 0

    print(f"Full corpus: {passing}/{total} = {pct:.1f}% passing")
    print(f"  Known-fails baseline: {len(known)}")
    print(f"  Actual fails:         {len(actual)}")

    regressions = actual - known
    unexpected_passes = known - actual

    if not regressions and not unexpected_passes:
        print("\nFull gate: GREEN (matches known-fails baseline exactly)")
        return 0

    print()
    if regressions:
        print(
            f"REGRESSION — {len(regressions)} test(s) fail but are NOT in the known-fails list:"
        )
        for t in sorted(regressions):
            print(f"  + FAIL  {t}")
        print()
        print("  Fix the regression (or add the test to corpus/full-known-fails.txt")
        print("  in the same commit, with an ADR-tracked rationale).")

    if unexpected_passes:
        print(
            f"GOLDEN OUT OF DATE — {len(unexpected_passes)} test(s) now pass that are still in known-fails:"
        )
        for t in sorted(unexpected_passes):
            print(f"  - PASS  {t}")
        print()
        print("  Remove these from corpus/full-known-fails.txt before landing.")
        print("  Updating the known-fails list IS how the full pass-rate climbs.")

    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
