#!/usr/bin/env python3
"""nanopython benchmark runner — wall-clock comparison vs MicroPython + CPython.

Simple by design (ADR-004 D4 first pass): no SQLite, no YAML, no pyperf —
just the runner the maintainer asked for. Discovers benchmarks/programs/*.py,
runs each on each available interpreter (warmup K, timed N), and emits a
markdown report to docs/benchmarks.md.

Usage:
    python3 benchmarks/runner.py          # full report
    python3 benchmarks/runner.py --quick  # K=1 N=2 (smoke run)
"""

from __future__ import annotations

import argparse
import math
import os
import platform
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PROGRAMS_DIR = REPO_ROOT / "benchmarks" / "programs"
REPORT_PATH = REPO_ROOT / "docs" / "benchmarks.md"


def _find_binary(*relative_paths: str) -> Path | None:
    """Search REPO_ROOT then ancestors for any of the relative paths.
    Worktrees may not contain sandbox/ or zig-out/; ancestor lookup lets the
    runner work from the main repo's built binaries when invoked from one."""
    candidates: list[Path] = []
    bases = [REPO_ROOT, *REPO_ROOT.parents]
    for base in bases:
        for rel in relative_paths:
            candidates.append(base / rel)
    for p in candidates:
        if p.exists():
            return p
    return None


# Interpreter wiring. Path is resolved at runtime; missing ones are skipped
# (the report notes which were unavailable).
NANO_BIN = _find_binary("zig-out/bin/nanopython")
MPY_BIN = _find_binary("sandbox/micropython/ports/unix/build-standard/micropython")

# Order matters: leftmost column in the report is the headline interpreter.
INTERPRETERS = [
    ("nanopython", str(NANO_BIN) if NANO_BIN else ""),
    ("MicroPython", str(MPY_BIN) if MPY_BIN else ""),
    ("CPython", sys.executable),
]


def run_once(binary: str, script: Path) -> tuple[float, str]:
    """Run script with binary, returning (wall-clock seconds, stdout)."""
    t0 = time.perf_counter()
    proc = subprocess.run(
        [binary, str(script)],
        capture_output=True,
        text=True,
        timeout=120,
    )
    elapsed = time.perf_counter() - t0
    if proc.returncode != 0:
        raise RuntimeError(
            f"{binary} {script.name} exited {proc.returncode}\n"
            f"stderr: {proc.stderr[:500]}"
        )
    return elapsed, proc.stdout.strip()


def time_benchmark(binary: str, script: Path, warmups: int, runs: int):
    """Returns (min_seconds, median_seconds, output)."""
    output = None
    for _ in range(warmups):
        _, output = run_once(binary, script)
    samples = []
    for _ in range(runs):
        t, out = run_once(binary, script)
        samples.append(t)
        if output is None:
            output = out
    return min(samples), statistics.median(samples), output


def geomean(values: list[float]) -> float:
    if not values:
        return float("nan")
    log_sum = sum(math.log(v) for v in values if v > 0)
    return math.exp(log_sum / len(values))


def interpreter_version(name: str, binary: str) -> str:
    if not binary or not os.path.exists(binary):
        return "missing"
    try:
        if name == "CPython":
            out = subprocess.run(
                [binary, "--version"], capture_output=True, text=True, timeout=5
            ).stdout.strip()
            return out or "unknown"
        if name == "nanopython":
            out = subprocess.run(
                [binary, "--version"], capture_output=True, text=True, timeout=5
            ).stdout.strip()
            return out or "unknown"
        if name == "MicroPython":
            # MicroPython supports --version on the unix port (line 1 = name+version).
            out = subprocess.run(
                [binary, "--version"], capture_output=True, text=True, timeout=5,
            ).stdout.strip().splitlines()
            return out[0] if out else "unknown"
    except Exception as e:
        return f"unknown ({e})"
    return "unknown"


def binary_size(binary: str) -> str:
    if not binary or not os.path.exists(binary):
        return "n/a"
    size = os.path.getsize(binary)
    if size >= 1 << 20:
        return f"{size / (1 << 20):.2f} MB"
    return f"{size / 1024:.0f} KB"


def git_sha() -> str:
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            capture_output=True, text=True, cwd=REPO_ROOT, timeout=5,
        )
        return out.stdout.strip() or "unknown"
    except Exception:
        return "unknown"


def render_report(results, available, warmups, runs):
    """results: dict[bench_name][interpreter_name] = (min, median, output)
    available: list[(name, binary)] of interpreters that ran.
    """
    names = [n for n, _ in available]
    lines = []
    lines.append("# nanopython benchmarks")
    lines.append("")
    lines.append(f"- Date: {time.strftime('%Y-%m-%d %H:%M:%S %Z')}")
    lines.append(f"- Platform: {platform.system()} {platform.machine()} ({platform.platform()})")
    lines.append(f"- Commit: `{git_sha()}`")
    lines.append(f"- Methodology: K={warmups} warmup, N={runs} timed iterations per (interpreter, benchmark). Reported value is the median wall-clock; minimum shown in tooltip-style parens.")
    lines.append("")
    lines.append("## Interpreters")
    lines.append("")
    lines.append("| Name | Binary | Size | Version |")
    lines.append("|---|---|---|---|")
    for name, binary in available:
        size = binary_size(binary) if binary else "n/a"
        ver = interpreter_version(name, binary)
        if not binary:
            path_disp = "n/a"
        elif name == "CPython":
            # System python — display the basename only.
            path_disp = Path(binary).name
        else:
            # Relative-to-repo when inside the tree; basename otherwise.
            try:
                path_disp = str(Path(binary).resolve().relative_to(REPO_ROOT.resolve().parent))
            except ValueError:
                path_disp = Path(binary).name
        lines.append(f"| {name} | `{path_disp}` | {size} | {ver} |")
    lines.append("")
    lines.append("nanopython is built with `make build-release` (`-Doptimize=ReleaseFast -Dconfig=nano`). MicroPython is the upstream `unix-standard` build. CPython is the system `python3`.")
    lines.append("")

    # Build the comparison table dynamically based on `names`.
    lines.append("## Results")
    lines.append("")
    headers = ["benchmark"] + [f"{n} median (s)" for n in names]
    # Ratios are only meaningful when nanopython is present alongside another.
    has_nano = "nanopython" in names
    if has_nano and "MicroPython" in names:
        headers.append("nano / MicroPython")
    if has_nano and "CPython" in names:
        headers.append("nano / CPython")
    headers.append("output match")
    lines.append("| " + " | ".join(headers) + " |")
    lines.append("|" + "|".join(["---"] * len(headers)) + "|")

    # For geomean.
    nano_over_mpy: list[float] = []
    nano_over_cpy: list[float] = []

    for bench in sorted(results):
        row = [bench]
        per_interp = results[bench]
        outputs = {n: per_interp[n][2] for n in names if n in per_interp}
        for n in names:
            if n in per_interp:
                lo, med, _ = per_interp[n]
                row.append(f"{med:.3f} (min {lo:.3f})")
            else:
                row.append("—")
        nano_med = per_interp.get("nanopython", (None, None, None))[1]
        mpy_med = per_interp.get("MicroPython", (None, None, None))[1]
        cpy_med = per_interp.get("CPython", (None, None, None))[1]
        if has_nano and "MicroPython" in names:
            if nano_med and mpy_med:
                r = nano_med / mpy_med
                nano_over_mpy.append(r)
                row.append(f"{r:.2f}×")
            else:
                row.append("—")
        if has_nano and "CPython" in names:
            if nano_med and cpy_med:
                r = nano_med / cpy_med
                nano_over_cpy.append(r)
                row.append(f"{r:.2f}×")
            else:
                row.append("—")
        # Output equivalence.
        out_set = set(outputs.values())
        row.append("yes" if len(out_set) == 1 else "**NO**")
        lines.append("| " + " | ".join(row) + " |")

    # Geomean row.
    geo_row = ["**geomean**"] + ["—"] * len(names)
    if has_nano and "MicroPython" in names:
        geo_row.append(f"**{geomean(nano_over_mpy):.2f}×**")
    if has_nano and "CPython" in names:
        geo_row.append(f"**{geomean(nano_over_cpy):.2f}×**")
    geo_row.append("—")
    lines.append("| " + " | ".join(geo_row) + " |")
    lines.append("")

    lines.append("Ratio reading: `nano / X` means nanopython's median divided by X's median. A value of `1.50×` means nanopython took 1.5× as long as X (i.e. X is faster). Lower is better for nanopython.")
    lines.append("")
    lines.append("## Output equivalence")
    lines.append("")
    mismatches = [
        b for b in results
        if len({results[b][n][2] for n in names if n in results[b]}) > 1
    ]
    if not mismatches:
        lines.append("All benchmarks produce byte-identical stdout across all available interpreters.")
    else:
        lines.append("**Mismatches detected** — investigate before trusting timings:")
        for b in mismatches:
            lines.append(f"- `{b}`:")
            for n in names:
                if n in results[b]:
                    lines.append(f"  - {n}: `{results[b][n][2]}`")
    lines.append("")
    lines.append("## Reproduce")
    lines.append("")
    lines.append("```sh")
    lines.append("# 1. Build a ReleaseFast nanopython (Debug is artificially slow).")
    lines.append("make build-release")
    lines.append("")
    lines.append("# 2. (Optional) Build MicroPython unix-standard if absent.")
    lines.append("(cd sandbox/micropython/ports/unix && make submodules && make)")
    lines.append("")
    lines.append("# 3. Run the suite.")
    lines.append("python3 benchmarks/runner.py")
    lines.append("```")
    lines.append("")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true", help="K=1 N=2 smoke run")
    ap.add_argument("--warmup", type=int, default=2)
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--output", type=Path, default=REPORT_PATH)
    args = ap.parse_args()
    if args.quick:
        args.warmup = 1
        args.runs = 2

    programs = sorted(PROGRAMS_DIR.glob("*.py"))
    if not programs:
        print(f"No benchmarks found under {PROGRAMS_DIR}", file=sys.stderr)
        return 1

    available = []
    for name, binary in INTERPRETERS:
        if binary and (os.path.exists(binary) or shutil.which(binary)):
            available.append((name, binary))
        else:
            print(f"  [skip] {name}: binary not found at {binary}", file=sys.stderr)
    if not available:
        print("No interpreters available — aborting.", file=sys.stderr)
        return 1

    results: dict[str, dict[str, tuple[float, float, str]]] = {}
    for script in programs:
        bench = script.stem
        print(f"== {bench}")
        results[bench] = {}
        for name, binary in available:
            print(f"   {name:12s}", end="", flush=True)
            try:
                lo, med, out = time_benchmark(binary, script, args.warmup, args.runs)
                print(f"  min={lo:.3f}s  median={med:.3f}s")
                results[bench][name] = (lo, med, out)
            except Exception as e:
                print(f"  FAILED: {e}")

    report = render_report(results, available, args.warmup, args.runs)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(report)
    print(f"\nReport written to {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
