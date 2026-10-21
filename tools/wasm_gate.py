#!/usr/bin/env python3
"""wasm_gate.py — strict regression gate for the WASM corpus.

Per CLAUDE.md, the byte-exact corpus is the project's load-bearing
correctness gate. The native target reports 100% pass; the WASM target
does not (yet). To prevent quality drift, this script:

  - Runs the corpus through the WASM binary via tools/run_wasm.sh.
  - Subtracts the skip-on-wasm32 list (tests whose goldens depend on
    64-bit smallint width; not runnable on wasm32 by construction).
  - Compares the remaining failures against corpus/wasm-known-fails.txt.
  - EXITS NON-ZERO on:
      (a) a test fails that is NOT in known-fails AND not skipped (regression),
      (b) a test in known-fails now passes (golden is stale — remove from
          the list before landing),
      (c) a test in skip-on-wasm32 now passes (skip is stale — same).

The discipline mirrors the byte-exact oracle, applied to the WASM
target: we freeze a regression-detector snapshot
and never let the list grow. Closing items requires fixing the test
AND removing it from the known-fails list in the same commit.

Skipped tests are NEITHER passes nor failures — they don't count toward
the denominator on wasm32. The gate displays passed / failed / skipped.

Usage:
    make wasm-check
    python3 tools/wasm_gate.py
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
KNOWN_FAILS = ROOT / "corpus" / "wasm-known-fails.txt"
SKIP_LIST = ROOT / "corpus" / "skip-on-wasm32.txt"
WASM_BIN = ROOT / "zig-out" / "bin" / "nanopython.wasm"
RUN_WASM = ROOT / "tools" / "run_wasm.sh"


def load_list(path: Path, required: bool = True) -> set[str]:
    if not path.exists():
        if required:
            print(f"error: {path.relative_to(ROOT)} not found", file=sys.stderr)
            sys.exit(2)
        return set()
    return {
        line.strip()
        for line in path.read_text().splitlines()
        if line.strip() and not line.startswith("#")
    }


def current_failures() -> tuple[set[str], int]:
    """Run the corpus and return (failures, total). Reuses progress.py."""
    if not WASM_BIN.exists():
        print(
            f"error: {WASM_BIN.relative_to(ROOT)} not built — run `make wasm-small` first",
            file=sys.stderr,
        )
        sys.exit(2)
    if not RUN_WASM.exists():
        print(f"error: {RUN_WASM.relative_to(ROOT)} missing", file=sys.stderr)
        sys.exit(2)

    progress = ROOT / "tools" / "progress.py"
    r = subprocess.run(
        # ADR 012 Phase 4b: progress.py now defaults to --config full;
        # the wasm arm is pinned to nano (per Makefile Phase 4a pins),
        # so we must explicitly select the nano corpus here.
        [
            "python3",
            str(progress),
            "--config",
            "nano",
            str(RUN_WASM),
            str(WASM_BIN),
            "--show",
            "1000",
        ],
        capture_output=True,
        text=True,
        timeout=600,
        check=False,
    )
    out = r.stdout + r.stderr
    fails: set[str] = set()
    total = 0
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("FAIL "):
            fails.add(s.split(None, 1)[1])
        if "passing" in s and "corpus tests" in s:
            try:
                total = int(s.split("/")[1].split()[0])
            except (IndexError, ValueError):
                pass
    return fails, total


def main(argv: list[str]) -> int:
    argparse.ArgumentParser(description=__doc__).parse_args(argv)

    known = load_list(KNOWN_FAILS, required=True)
    skipped = load_list(SKIP_LIST, required=False)
    overlap = known & skipped
    if overlap:
        print(
            f"error: {len(overlap)} test(s) appear in BOTH known-fails and skip lists "
            f"— pick one:",
            file=sys.stderr,
        )
        for t in sorted(overlap):
            print(f"  - {t}", file=sys.stderr)
        return 2

    all_failures, total = current_failures()

    # Raw is the honest top-line: tests that pass divided by tests that
    # exist. Skip-listed tests are documented but still count as failures
    # against the raw denominator — the runtime did not pass them.
    raw_passing = total - len(all_failures)
    raw_pct = raw_passing * 100 / total if total else 0

    # In-scope subtracts skipped tests from BOTH numerator and denominator.
    # Useful for triaging: of the tests the runtime is expected to handle,
    # how many work. Always reported alongside the raw number — never alone.
    in_scope_failures = all_failures - skipped
    in_scope_total = total - len(skipped)
    in_scope_passing = in_scope_total - len(in_scope_failures)
    in_scope_pct = in_scope_passing * 100 / in_scope_total if in_scope_total else 0

    print(f"WASM corpus: {raw_passing}/{total} = {raw_pct:.1f}% raw passing")
    print(
        f"             ({in_scope_passing}/{in_scope_total} = {in_scope_pct:.1f}% in-scope; "
        f"{len(skipped)} tests skip-listed as not runnable on wasm32)"
    )
    print(f"  Known-fails baseline: {len(known)}")
    print(
        f"  Actual fails:         {len(in_scope_failures)} in-scope, {len(all_failures)} total"
    )
    print(f"  Skipped (wasm32):     {len(skipped)}")

    regressions = in_scope_failures - known
    unexpected_passes = known - in_scope_failures
    stale_skips = skipped - all_failures

    if not regressions and not unexpected_passes and not stale_skips:
        print("\nWASM gate: GREEN (matches known-fails baseline + skip list exactly)")
        return 0

    print()
    if regressions:
        print(
            f"REGRESSION — {len(regressions)} test(s) fail but are NOT in the "
            f"known-fails list:"
        )
        for t in sorted(regressions):
            print(f"  + FAIL  {t}")
        print()
        print("  Fix the regression (or add the test to corpus/wasm-known-fails.txt")
        print("  in the same commit, but only if the failure is intentional).")

    if unexpected_passes:
        print(
            f"GOLDEN OUT OF DATE — {len(unexpected_passes)} test(s) now pass that "
            f"are still in known-fails:"
        )
        for t in sorted(unexpected_passes):
            print(f"  - PASS  {t}")
        print()
        print("  Remove these from corpus/wasm-known-fails.txt before landing.")
        print("  Updating the known-fails list IS the way the WASM pass-rate climbs.")

    if stale_skips:
        print(
            f"SKIP LIST STALE — {len(stale_skips)} test(s) on the skip list now pass "
            f"(skip is no longer needed):"
        )
        for t in sorted(stale_skips):
            print(f"  - PASS  {t}")
        print()
        print("  Remove these from corpus/skip-on-wasm32.txt before landing.")
        print("  A skipped test that passes is invisible quality — the skip list")
        print("  must reflect tests that genuinely cannot pass on wasm32.")

    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
