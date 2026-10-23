#!/usr/bin/env python3
"""petitpy progress meter.

Reports what fraction of the frozen corpus the candidate interpreter runs
*byte-identically to the MicroPython oracle*. This is the single number that
tracks the strangler migration from 0% (nothing built) to 100% (pure-Zig
interpreter behaviourally indistinguishable from MicroPython).

It deliberately reuses `corpus.run_cmd`, so the candidate's output is captured
and framed exactly the way the goldens were frozen — otherwise the comparison
would be meaningless.

Usage:
  python3 tools/progress.py <command...>

`<command...>` is how to invoke the candidate interpreter. The test script path
replaces a literal `{script}` token if present, else it is appended:

  python3 tools/progress.py ./zig-out/bin/petitpy
  python3 tools/progress.py wasmtime zig-out/bin/petitpy.wasm --
  python3 tools/progress.py node tools/run.mjs {script}

Options:
  --json        Machine-readable result (for CI / a progress badge).
  --show N      Also list the first N failing tests (default 0).
  --config X    Which corpus to compare against: nano (default) or full.
  --strict      Exit 1 unless every test passes (the nano gate: 541/541 is an
                invariant, so any failure is a regression).

If the candidate is not built / not found yet, progress is reported as 0.0%
(exit 0) so this works as a dashboard from day one.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import corpus


def _bar(frac: float, width: int = 40) -> str:
    filled = round(frac * width)
    return "[" + "#" * filled + "-" * (width - filled) + "]"


def measure(argv: list[str]) -> dict:
    goldens = sorted(corpus.CORPUS.glob("*.out"))
    total = len(goldens)
    passed: list[str] = []
    failed: list[str] = []
    for g in goldens:
        script = corpus.TESTS / f"{g.stem}.py"
        got = corpus.run_cmd(argv, script)
        (passed if got == g.read_bytes() else failed).append(g.stem)
    return {
        "command": argv,
        "total": total,
        "passed": len(passed),
        "failed": len(failed),
        "percent": (100.0 * len(passed) / total) if total else 0.0,
        "failing": sorted(failed),
    }


def main(args: list[str]) -> int:
    as_json = False
    strict = False
    show = 0
    config = "full"  # ADR 012 Phase 4b — full is the default profile
    cmd: list[str] = []
    it = iter(args)
    for a in it:
        if a == "--json":
            as_json = True
        elif a == "--strict":
            strict = True
        elif a == "--show":
            show = int(next(it))
        elif a == "--config":
            config = next(it)
        else:
            cmd.append(a)

    if not cmd:
        print(__doc__)
        return 2

    corpus.set_config(config)
    goldens_present = any(corpus.CORPUS.glob("*.out"))
    if not goldens_present:
        print("no goldens; run `python3 tools/corpus.py gen` first", file=sys.stderr)
        return 1

    r = measure(cmd)

    if as_json:
        r_out = {k: v for k, v in r.items() if k != "failing"}
        r_out["failing"] = r["failing"][:show] if show else []
        print(json.dumps(r_out))
        return 0

    pct = r["percent"]
    print(f"petitpy progress: {pct:5.1f}%  {_bar(pct / 100.0)}")
    print(
        f"  passing {r['passed']}/{r['total']} corpus tests "
        f"(byte-identical to the frozen reference)"
    )
    print(f"  command: {' '.join(r['command'])}")
    if pct == 0.0:
        print(
            "  note: 0% — candidate not built yet, or no test matches the "
            "oracle. Expected before Phase 1 completes."
        )
    if show and r["failing"]:
        print(f"\n  first {min(show, len(r['failing']))} failing:")
        for name in r["failing"][:show]:
            print(f"    FAIL {name}")
    if strict and r["failing"]:
        print(f"\n  FAIL (--strict): {', '.join(r['failing'])}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
