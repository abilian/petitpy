#!/usr/bin/env python3
"""metrics — record + report nanopython size, coverage, and perf over time.

Subcommands:
    record           Measure current state, append a row to history.
    report           Print recent rows with delta-from-previous.
    latest           Print the most recent row, human-readable.

Storage: one NDJSON file at metrics/history.ndjson. One record per line,
git-diffable, scriptable, no schema migrations.

Each record captures three categories:

    size      — wasm/native artifact bytes (the shipping artifacts; the
                native is the ReleaseFast binary, not the Debug build)
    coverage  — test pass counts: native corpus, wasm corpus, golden-programs
    perf      — benchmark geomean vs MicroPython + CPython (optional;
                runs the sandbox/p2w/programs/benchmarks/ programs)

Size + coverage are fast (~3s) and the default for `record`. Perf takes
minutes; opt in with `record --with-perf`.

Column meanings (used by `report` and `latest`):

    wasm-raw          web/nanopython.wasm — the production ship artifact
    wasm-opt          wasm post `wasm-opt -Oz`; only present after `make wasm-opt`
    native-release    zig-out/bin/nanopython after `make build-release`
                      (ReleaseFast — what a user would actually run on a host)
    corpus            corpus/nano/basics/*.out byte-exact gate, native side
                      (538/541 today; 541/541 is the strangler invariant target)
    wasm-corpus       same corpus, but run through wasmtime
                      (out of 541 raw; the wasm baseline known-fails list
                      documents 73 expected failures)
    works/            golden-programs/works/ — real Python programs that work
                      on BOTH native and wasm today (out of 823 in scope;
                      see ADR 008)

Usage:
    python3 tools/metrics.py record [--with-perf] [--quick] [--note "blah"]
    python3 tools/metrics.py report [-n 20]
    python3 tools/metrics.py latest

See ADR 005 (optimization landscape), ADR 007 (wasm fat loss), and
ADR 009 §6 (Lane D — Size, then performance) for the rationale.
"""

from __future__ import annotations

import argparse
import gzip
import json
import re
import statistics
import subprocess
import sys
import time
from datetime import UTC, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HISTORY = ROOT / "metrics" / "history.ndjson"

sys.path.insert(0, str(Path(__file__).resolve().parent))
import timing

# The "ship" artifact — what a user actually downloads. Built by `make web`
# (ReleaseSmall + frozen-tiny + wasm32-wasi).
WASM_SHIP = ROOT / "web" / "nanopython.wasm"

# Optional post-wasm-opt artifact. Produced by `make wasm-opt`. Tracked
# separately so ADR 007 P1's progress is visible row-by-row.
WASM_OPT = ROOT / "zig-out" / "bin" / "nanopython.opt.wasm"

# Native binary used for measurement. `make build-release` produces this
# as ReleaseFast — what a user would actually run. Debug-build size
# isn't a useful longitudinal metric (it doesn't ship anywhere).
NATIVE_BIN = ROOT / "zig-out" / "bin" / "nanopython"

# Frozen-tiny .mpy total — the bundled stdlib baked into the wasm.
FROZEN_DIR = ROOT / "build-frozen"

# Wasm runner + corpus gate inputs.
WASM_BIN = ROOT / "zig-out" / "bin" / "nanopython.wasm"
RUN_WASM = ROOT / "tools" / "run_wasm.sh"
WASM_KNOWN_FAILS = ROOT / "corpus" / "wasm-known-fails.txt"

# p2w benchmark programs — reused per the user's direction. Each is a
# pure-Python program runnable on any interpreter; nanopython native +
# wasm + MicroPython unix-standard + CPython all accept them.
BENCH_DIR = ROOT / "sandbox" / "p2w" / "programs" / "benchmarks"
MP_BIN = (
    ROOT
    / "vendor"
    / "micropython"
    / "ports"
    / "unix"
    / "build-standard"
    / "micropython"
)
CPYTHON = "python3"


def git_sha_short() -> str:
    r = subprocess.run(
        ["git", "rev-parse", "--short=8", "HEAD"],
        capture_output=True,
        text=True,
        cwd=ROOT,
        check=False,
    )
    return r.stdout.strip()


def git_sha_full() -> str:
    r = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        capture_output=True,
        text=True,
        cwd=ROOT,
        check=False,
    )
    return r.stdout.strip()


def measure_size_bytes(path: Path) -> int | None:
    if not path.exists():
        return None
    return path.stat().st_size


def measure_gzipped_bytes(path: Path) -> int | None:
    """Kept for historical records — useful for tracking the download
    cost over an HTTP transport even though the report doesn't show it."""
    if not path.exists():
        return None
    return len(gzip.compress(path.read_bytes(), compresslevel=9))


def measure_frozen_total_bytes() -> int | None:
    if not FROZEN_DIR.exists():
        return None
    total = 0
    for f in FROZEN_DIR.glob("*.mpy"):
        total += f.stat().st_size
    return total


def measure_native_corpus_pass() -> tuple[int | None, int | None]:
    if not NATIVE_BIN.exists():
        return None, None
    try:
        r = subprocess.run(
            [
                "python3",
                str(ROOT / "tools" / "progress.py"),
                "--config",
                "nano",
                str(NATIVE_BIN),
            ],
            capture_output=True,
            text=True,
            timeout=120,
            cwd=ROOT,
            check=False,
        )
        m = re.search(r"passing (\d+)/(\d+)", r.stdout)
        if m:
            return int(m.group(1)), int(m.group(2))
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    return None, None


def measure_wasm_corpus_pass() -> dict:
    """The wasm gate's view of the corpus. We pass progress.py the
    wasmtime wrapper so it runs each test on the wasm binary. Counts
    are raw — the known-fails list is recorded separately so trends
    in the raw count can move independently from baseline curation."""
    out: dict = {}
    if not WASM_BIN.exists() or not RUN_WASM.exists():
        return out
    try:
        r = subprocess.run(
            [
                "python3",
                str(ROOT / "tools" / "progress.py"),
                str(RUN_WASM),
                str(WASM_BIN),
            ],
            capture_output=True,
            text=True,
            timeout=300,
            cwd=ROOT,
            check=False,
        )
        m = re.search(r"passing (\d+)/(\d+)", r.stdout)
        if m:
            out["wasm_corpus_pass"] = int(m.group(1))
            out["wasm_corpus_total"] = int(m.group(2))
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    # Baseline = number of tests in wasm-known-fails.txt.
    if WASM_KNOWN_FAILS.exists():
        known = sum(
            1
            for line in WASM_KNOWN_FAILS.read_text().splitlines()
            if line.strip() and not line.strip().startswith("#")
        )
        out["wasm_known_fails_baseline"] = known
    return out


def measure_coverage() -> dict:
    cov: dict = {}
    np, nt = measure_native_corpus_pass()
    if np is not None:
        cov["corpus_native_pass"] = np
        cov["corpus_native_total"] = nt
    cov.update(measure_wasm_corpus_pass())
    gp_dir = ROOT / "golden-programs"
    if gp_dir.exists():
        for bucket in (
            "works",
            "works-native-only",
            "needs-stdlib",
            "needs-grammar",
            "needs-async",
            "needs-fs",
            "needs-mpz",
            "disagreement",
        ):
            count = (
                len(list((gp_dir / bucket).glob("*.py")))
                if (gp_dir / bucket).exists()
                else 0
            )
            cov[f"golden_{bucket.replace('-', '_')}"] = count
    return cov


# ── perf ──────────────────────────────────────────────────────────────


def time_run(argv: list[str], script: Path, timeout: float) -> float | None:
    """Single timed run. Returns wall-clock seconds, or None on failure.

    Failure detection: non-zero exit code, OR an uncaught-exception
    traceback in either stream. Belt-and-suspenders — exit code alone
    is sufficient (since the embed_exec exit-code fix landed); the
    traceback check stays as defense against any future interpreter
    or wrapper that re-introduces a print-then-exit-0 path.
    """
    try:
        t0 = time.perf_counter()
        r = subprocess.run(
            argv + [str(script)],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        t1 = time.perf_counter()
        if r.returncode != 0:
            return None
        combined = (r.stdout or "") + (r.stderr or "")
        if "Traceback (most recent call last)" in combined:
            return None
        return t1 - t0
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None


def time_benchmark(
    argv: list[str], script: Path, warmups: int, runs: int, timeout: float = 60.0
) -> float | None:
    """Warm + N timed runs; return median wall-clock seconds."""
    for _ in range(warmups):
        if time_run(argv, script, timeout) is None:
            return None
    samples = []
    for _ in range(runs):
        t = time_run(argv, script, timeout)
        if t is None:
            return None
        samples.append(t)
    if not samples:
        return None
    return statistics.median(samples)


def measure_perf(quick: bool = False) -> dict | None:
    """Run the p2w benchmark set through every available interpreter.

    Computes geomean of (nano_time / oracle_time) across all benchmarks
    that completed on both nano and the oracle. Records per-benchmark
    median times so future analysis can drill down.
    """
    if not BENCH_DIR.exists():
        return {"error": f"benchmark dir missing: {BENCH_DIR}"}
    programs = sorted(
        p
        for p in BENCH_DIR.glob("*.py")
        if not p.stem.endswith("_native") and p.stem not in {"run_benchmarks"}
    )
    if not programs:
        return {"error": "no programs found"}

    warmups, runs = (0, 1) if quick else (1, 3)
    interpreters: dict[str, list[str]] = {}
    if NATIVE_BIN.exists():
        interpreters["nano_native"] = [str(NATIVE_BIN)]
    if WASM_BIN.exists() and RUN_WASM.exists():
        interpreters["nano_wasm"] = ["bash", str(RUN_WASM), str(WASM_BIN)]
    if MP_BIN.exists():
        interpreters["micropython"] = [str(MP_BIN)]
    interpreters["cpython"] = [CPYTHON]

    per_bench: dict[str, dict[str, float | None]] = {}
    for p in programs:
        per_bench[p.stem] = {}
        for name, argv in interpreters.items():
            per_bench[p.stem][name] = time_benchmark(argv, p, warmups, runs)

    perf: dict = {"per_benchmark": per_bench, "n_programs": len(programs)}

    # Geomeans. Only include a benchmark if BOTH sides completed.
    def geomean(values: list[float]) -> float:
        log_sum = sum(__import__("math").log(v) for v in values)
        return __import__("math").exp(log_sum / len(values))

    for oracle in ("micropython", "cpython"):
        if oracle not in interpreters or "nano_native" not in interpreters:
            continue
        ratios = []
        for times in per_bench.values():
            n = times.get("nano_native")
            o = times.get(oracle)
            if n is None or o is None or o <= 0:
                continue
            ratios.append(n / o)
        if ratios:
            perf[f"geomean_native_vs_{oracle}"] = geomean(ratios)

    # Wasm-side ratios (mostly for tracking startup-time pain).
    if "nano_wasm" in interpreters and "cpython" in interpreters:
        ratios = []
        for times in per_bench.values():
            n = times.get("nano_wasm")
            o = times.get("cpython")
            if n is None or o is None or o <= 0:
                continue
            ratios.append(n / o)
        if ratios:
            perf["geomean_wasm_vs_cpython"] = geomean(ratios)

    return perf


# ── record / report / latest ──────────────────────────────────────────


def build_record(with_perf: bool, quick_perf: bool, note: str | None) -> dict:
    rec: dict = {
        "commit": git_sha_short(),
        "commit_full": git_sha_full(),
        "timestamp": datetime.now(UTC).isoformat(timespec="seconds"),
    }
    if note:
        rec["note"] = note

    rec["size"] = {
        "wasm_ship_raw": measure_size_bytes(WASM_SHIP),
        "wasm_ship_gzipped": measure_gzipped_bytes(WASM_SHIP),
        "wasm_opt_raw": measure_size_bytes(WASM_OPT),
        "native_release": measure_size_bytes(NATIVE_BIN),
        "frozen_tiny_total": measure_frozen_total_bytes(),
    }
    rec["coverage"] = measure_coverage()
    rec["timing"] = measure_cold_load()
    if with_perf:
        rec["perf"] = measure_perf(quick=quick_perf)
    return rec


def measure_cold_load() -> dict:
    """ADR 010 §D2 — cold-load wasm timing. Delegates to timing.measure
    so the harness path + rationale live in one place (tools/timing.py)."""
    return timing.measure(timing.WASM_WASMTIME, warmups=1, runs=5)


def cmd_record(args) -> int:
    rec = build_record(with_perf=args.with_perf, quick_perf=args.quick, note=args.note)
    HISTORY.parent.mkdir(parents=True, exist_ok=True)
    with HISTORY.open("a", encoding="utf-8") as f:
        f.write(json.dumps(rec, sort_keys=True) + "\n")
    print(f"recorded {rec['commit']} @ {rec['timestamp']}")
    print_human(rec, prefix="  ")
    return 0


def fmt_bytes(n: int | None) -> str:
    if n is None:
        return "n/a"
    if n < 1024:
        return f"{n}"
    if n < 1024 * 1024:
        return f"{n / 1024:.1f}K"
    return f"{n / 1024 / 1024:.1f}M"


def fmt_delta(cur: int | None, prev: int | None) -> str:
    if cur is None or prev is None:
        return ""
    d = cur - prev
    if d == 0:
        return "="
    sign = "+" if d > 0 else "-"
    return f"{sign}{fmt_bytes(abs(d))}"


def print_human(rec: dict, prefix: str = "") -> None:
    s = rec.get("size", {})
    c = rec.get("coverage", {})
    print(
        f"{prefix}wasm-raw:       {fmt_bytes(s.get('wasm_ship_raw'))}  "
        f"opt={fmt_bytes(s.get('wasm_opt_raw'))}"
    )
    print(f"{prefix}native-release: {fmt_bytes(s.get('native_release'))}")
    print(f"{prefix}frozen-tiny:    {fmt_bytes(s.get('frozen_tiny_total'))}")
    if c:
        np = c.get("corpus_native_pass")
        nt = c.get("corpus_native_total")
        if np is not None:
            print(f"{prefix}corpus native:  {np}/{nt}")
        wp = c.get("wasm_corpus_pass")
        wt = c.get("wasm_corpus_total")
        wk = c.get("wasm_known_fails_baseline")
        if wp is not None:
            tail = f" (baseline {wt - wk if wt and wk else '?'}/{wt})" if wk else ""
            print(f"{prefix}corpus wasm:    {wp}/{wt}{tail}")
        works = c.get("golden_works")
        wno = c.get("golden_works_native_only")
        if works is not None:
            print(f"{prefix}golden works:   {works}  (works-native-only: {wno})")
    t = rec.get("timing")
    if t and "error" not in t and t.get("median_ms") is not None:
        print(
            f"{prefix}cold-load wasm: {t['median_ms']:.1f} ms (median of {t.get('n_ok', '?')} runs)"
        )
    perf = rec.get("perf")
    if perf and "error" not in perf:
        if "geomean_native_vs_micropython" in perf:
            print(
                f"{prefix}native vs MP:   {perf['geomean_native_vs_micropython']:.2f}×"
            )
        if "geomean_native_vs_cpython" in perf:
            print(f"{prefix}native vs CPy:  {perf['geomean_native_vs_cpython']:.2f}×")
        if "geomean_wasm_vs_cpython" in perf:
            print(f"{prefix}wasm vs CPy:    {perf['geomean_wasm_vs_cpython']:.2f}×")


def read_history() -> list[dict]:
    if not HISTORY.exists():
        return []
    out = []
    with HISTORY.open(encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return out


def _fmt_ratio(perf: dict | None, key: str) -> str:
    if not perf or "error" in perf:
        return "—"
    v = perf.get(key)
    return f"{v:.2f}×" if v is not None else "—"


def cmd_report(args) -> int:
    hist = read_history()
    if not hist:
        print("no history yet — run `make metrics-record` first", file=sys.stderr)
        return 1
    rows = hist[-args.n :]

    # SIZE + COVERAGE table — always present.
    print(
        f"{'commit':>10}  {'when':>10}  {'wasm-raw':>9}  {'wasm-opt':>9}  "
        f"{'native':>9}  {'native-corpus':>13}  {'wasm-corpus':>11}  {'works/':>7}  "
        f"{'cold-ms':>7}"
    )
    print("-" * 105)
    prev_size = None
    for rec in rows:
        s = rec.get("size", {})
        c = rec.get("coverage", {})
        date = rec["timestamp"][:10]
        raw = s.get("wasm_ship_raw")
        opt = s.get("wasm_opt_raw")
        nat = s.get("native_release")
        np = c.get("corpus_native_pass")
        nt = c.get("corpus_native_total")
        ncorp = f"{np}/{nt}" if np is not None else ""
        wp = c.get("wasm_corpus_pass")
        wt = c.get("wasm_corpus_total")
        wcorp = f"{wp}/{wt}" if wp is not None else ""
        works = c.get("golden_works", "")
        t = rec.get("timing", {}) or {}
        cold = (
            f"{t['median_ms']:.0f}"
            if isinstance(t.get("median_ms"), (int, float))
            else ""
        )
        delta = fmt_delta(raw, prev_size)
        print(
            f"{rec['commit']:>10}  {date:>10}  "
            f"{fmt_bytes(raw):>9}  {fmt_bytes(opt):>9}  "
            f"{fmt_bytes(nat):>9}  {ncorp:>13}  {wcorp:>11}  {works:>7}  "
            f"{cold:>7}  {delta}"
        )
        prev_size = raw

    # PERF table — only shown if at least one row has perf data.
    perf_rows = [r for r in rows if r.get("perf") and "error" not in r["perf"]]
    if perf_rows:
        print()
        print(
            f"{'commit':>10}  {'when':>10}  {'nano vs MP':>10}  "
            f"{'nano vs CPy':>11}  {'wasm vs CPy':>11}  {'wasm vs nano':>12}"
        )
        print("-" * 76)
        for rec in rows:
            perf = rec.get("perf")
            mp = _fmt_ratio(perf, "geomean_native_vs_micropython")
            cp = _fmt_ratio(perf, "geomean_native_vs_cpython")
            wcp = _fmt_ratio(perf, "geomean_wasm_vs_cpython")
            # Derived: wasm vs nano (how much slower wasm is vs the native arm)
            if perf and "error" not in perf:
                wn = perf.get("geomean_wasm_vs_cpython")
                nn = perf.get("geomean_native_vs_cpython")
                wn_vs_nn = f"{wn / nn:.2f}×" if wn and nn else "—"
            else:
                wn_vs_nn = "—"
            print(
                f"{rec['commit']:>10}  {rec['timestamp'][:10]:>10}  "
                f"{mp:>10}  {cp:>11}  {wcp:>11}  {wn_vs_nn:>12}"
            )
    else:
        print()
        print("(no perf rows in history — run `make metrics-record-perf` to add one)")

    print()
    print("Column key:")
    print(
        "  wasm-raw      — web/nanopython.wasm (ReleaseSmall + frozen-tiny + wasm32-wasi)."
    )
    print(
        "  wasm-opt      — same, post `wasm-opt -Oz`. Empty until `make wasm-opt` ran."
    )
    print(
        "  native        — zig-out/bin/nanopython after `make build-release` (ReleaseFast)."
    )
    print("  native-corpus — `make check` count: byte-exact corpus, native arm.")
    print(
        "                  541 is the strangler invariant; ≤538 today = 3 pre-existing gaps."
    )
    print(
        "  wasm-corpus   — same tests, run through wasmtime. The `wasm-known-fails.txt`"
    )
    print(
        "                  baseline (73 today) is recorded separately in each row's JSON."
    )
    print(
        "  works/        — `golden-programs/works/` — real Python programs that work on"
    )
    print("                  BOTH native and wasm (823 in-scope; see ADR 008).")
    print(
        '  cold-ms       — wasmtime cold-load of `print("ok")`, median of 5 runs (ADR 010 §D2).'
    )
    print(
        "                  Comparable across commits on the same machine, NOT across hosts."
    )
    print("  Δ (right col) — change in wasm-raw vs the previous row.")
    if perf_rows:
        print("  nano vs MP    — geomean of (nano_native_time / MP_time) across")
        print(
            "                  the p2w benchmark set. Missing today: MP unix-standard"
        )
        print("                  lacks `__future__` which every p2w benchmark imports.")
        print("  nano vs CPy   — same, vs CPython 3.x.")
        print("  wasm vs CPy   — same, but using the wasm binary (via wasmtime).")
        print("  wasm vs nano  — derived: wasm-vs-CPy divided by nano-vs-CPy. The cost")
        print(
            "                  of running through wasmtime vs running native (host-side)."
        )
    return 0


def cmd_latest(args) -> int:
    hist = read_history()
    if not hist:
        print("no history yet", file=sys.stderr)
        return 1
    rec = hist[-1]
    print(f"{rec['commit']} @ {rec['timestamp']}")
    if rec.get("note"):
        print(f"  note: {rec['note']}")
    print_human(rec, prefix="  ")
    if not rec.get("perf"):
        print()
        print("  (no perf data in this row — `make metrics-record-perf` to add)")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)

    sp_rec = sub.add_parser("record", help="measure + append a history row")
    sp_rec.add_argument(
        "--with-perf",
        action="store_true",
        help="also run the p2w benchmark set through every "
        "available interpreter (minutes; default skips)",
    )
    sp_rec.add_argument(
        "--quick",
        action="store_true",
        help="single-run benchmarks instead of median-of-3",
    )
    sp_rec.add_argument(
        "--note", default=None, help="free-text annotation for this record"
    )
    sp_rec.set_defaults(func=cmd_record)

    sp_rep = sub.add_parser("report", help="print recent records as a trend table")
    sp_rep.add_argument(
        "-n", type=int, default=20, help="how many recent records to show (default 20)"
    )
    sp_rep.set_defaults(func=cmd_report)

    sp_lat = sub.add_parser("latest", help="print the most recent record")
    sp_lat.set_defaults(func=cmd_latest)

    args = p.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
