#!/usr/bin/env python3
"""timing — cold-load wasm timing harness (ADR 010 §D2).

Measures wall-clock from spawning wasmtime on the wasmtime-compatible
wasm artifact to process exit on a tiny program (one print). This
captures parse + instantiate + first-execute, which is the metric
ADR-001 cared about ("page loads in <1 s") and which was previously
unmeasured.

Times zig-out/bin/nanopython.wasm rather than web/nanopython.wasm:
the latter declares `env::js_create_callback` (browser-only) and won't
load under wasmtime. The two binaries differ only in the JS-bridge
imports, so wasmtime timings track shipping-artifact startup faithfully.

Usage:
    python3 tools/timing.py [--wasm PATH] [--runs N] [--warmups N] [--json]

Default: 1 warmup + 5 runs, prints "<median_ms>".
--json prints the full sample distribution for debugging.

The number is comparable across commits, NOT across machines — wasmtime
startup is a function of the host kernel's page-cache state, mmap cost,
and CPU. Treat values as deltas-from-baseline, not absolutes.
"""

from __future__ import annotations

import argparse
import json
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WASM_WASMTIME = ROOT / "zig-out" / "bin" / "nanopython.wasm"


def time_once(wasm: Path, script: Path) -> float | None:
    """One wasmtime invocation. Returns seconds, or None on failure."""
    try:
        t0 = time.perf_counter()
        r = subprocess.run(
            ["wasmtime", f"--dir={script.parent}", str(wasm), str(script.name)],
            cwd=script.parent,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        t1 = time.perf_counter()
        if r.returncode != 0:
            return None
        return t1 - t0
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None


def measure(wasm: Path, warmups: int, runs: int) -> dict:
    """Returns {"median_ms", "samples_ms", "n_ok"} or {"error"}."""
    if not wasm.exists():
        return {"error": f"missing wasm: {wasm}"}
    with tempfile.TemporaryDirectory() as td:
        script = Path(td) / "ok.py"
        script.write_text('print("ok")\n')
        # Warmup failure is fatal: it means the wasm can't even start
        # under wasmtime (missing import, bad path, etc.) and no run
        # would succeed. Per-run failures get filtered silently — a
        # transient host hiccup during one of N runs shouldn't invalidate
        # the median if the others completed.
        for _ in range(warmups):
            if time_once(wasm, script) is None:
                return {"error": "warmup failed"}
        samples = []
        for _ in range(runs):
            t = time_once(wasm, script)
            if t is not None:
                samples.append(t)
    if not samples:
        return {"error": "all runs failed"}
    return {
        "median_ms": round(statistics.median(samples) * 1000, 2),
        "samples_ms": [round(s * 1000, 2) for s in samples],
        "n_ok": len(samples),
    }


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument(
        "--wasm",
        type=Path,
        default=WASM_WASMTIME,
        help=f"wasm artifact to time (default: {WASM_WASMTIME.relative_to(ROOT)})",
    )
    ap.add_argument("--warmups", type=int, default=1)
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument(
        "--json",
        action="store_true",
        help="emit full distribution as JSON instead of median",
    )
    args = ap.parse_args()

    result = measure(args.wasm, args.warmups, args.runs)
    if "error" in result:
        print(f"error: {result['error']}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(result))
    else:
        print(result["median_ms"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
