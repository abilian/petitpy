#!/usr/bin/env python3
"""Cross-platform memory-footprint benchmark for hop3-rootd under multiple
Python interpreters. Runs three workloads (cold start, full import,
dispatch loop) N times per cell, reports median peak RSS + wall time.

    Linux path uses GNU `/usr/bin/time -f "%M" -o <file>` as the
    measurement wrapper. rusage-via-wait4 (both os.fork+exec and
    posix_spawn) inherits the parent Python harness's page table
    briefly as COW and inflates ru_maxrss. A /proc/<pid>/status VmHWM
    polling loop also misses short (< 10ms) workloads' peaks by
    racing kernel page-fault accounting — verified against GNU time
    on a 5.7 MB cold-start reporting 16 KB via poll.

    macOS path uses os.wait4 rusage directly via posix_spawn; Darwin's
    ru_maxrss does not exhibit the same fork-COW inflation.

Usage:
    python3 tools/measure-hop3-footprint.py \\
        --hop3-src ~/projects/hop3/hop3/packages/hop3-rootd/src \\
        --interpreter "petitpy=zig-out/bin/petitpy" \\
        --interpreter "python3=/usr/bin/python3" \\
        --dispatches 100 --runs 5

The label convention matters for one thing only: labels containing "nano"
(case-insensitive) get PETITPY_LIB pointing at the built shim tree;
everything else gets PYTHONPATH pointing at the raw hop3-rootd source.
Rename the interpreter labels accordingly if you have unusual paths.

No interpreter args? Defaults to zig-out/bin/petitpy and $(which python3).
"""

from __future__ import annotations

import argparse
import os
import platform
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# Sibling tool in tools/ (sys.path[0] when this runs as a script);
# reused for build_shim + the shared HOP3_SRC default.
import hop3_rootd_smoke as smoke

REPO = Path(__file__).resolve().parent.parent
DEFAULT_HOP3_SRC = smoke.DEFAULT_HOP3_SRC


# ── measurement primitives ────────────────────────────────────────────────


def rss_bytes(rusage) -> int:
    """Normalise struct_rusage.ru_maxrss to bytes across platforms."""
    r = rusage.ru_maxrss
    return r * 1024 if platform.system() == "Linux" else r


def format_bytes(n: int) -> str:
    if n < 1024:
        return f"{n} B"
    if n < 1024 * 1024:
        return f"{n / 1024:.1f} KB"
    return f"{n / (1024 * 1024):.1f} MB"


GNU_TIME = "/usr/bin/time"


def _linux_time_wrapper_available() -> bool:
    return platform.system() == "Linux" and os.access(GNU_TIME, os.X_OK)


def run_once(argv: list[str], env: dict[str, str]) -> tuple[int, int, float]:
    """Spawn the interpreter, return (returncode, peak_rss_bytes, wall_seconds).

    Linux: wrap the target with `/usr/bin/time -f "%M" -o <file>` so
    the kernel accounts peak RSS against the target's own address
    space, not against the Python harness's COW-inherited pages
    (which is what rusage-via-wait4 and short-poll /proc/VmHWM both
    got wrong — see module docstring).

    macOS: os.posix_spawn + os.wait4 rusage.ru_maxrss directly. GNU
    time isn't installed by default on Darwin, and Darwin's rusage
    accounting does not exhibit the fork-COW inflation."""
    start = time.monotonic()
    if _linux_time_wrapper_available():
        fd, rss_path = tempfile.mkstemp()
        os.close(fd)
        try:
            pid = os.posix_spawn(
                GNU_TIME,
                [GNU_TIME, "-f", "%M", "-o", rss_path, *argv],
                env,
            )
            _, status = os.waitpid(pid, 0)
            elapsed = time.monotonic() - start
            with open(rss_path) as f:
                text = f.read().strip()
            peak_kb = int(text) if text.isdigit() else 0
            rc = os.WEXITSTATUS(status) if os.WIFEXITED(status) else -1
            return rc, peak_kb * 1024, elapsed
        finally:
            os.unlink(rss_path)
    # Darwin / BSD path.
    pid = os.posix_spawn(argv[0], argv, env)
    _, status, rusage = os.wait4(pid, 0)
    elapsed = time.monotonic() - start
    rc = os.WEXITSTATUS(status) if os.WIFEXITED(status) else -1
    return rc, rss_bytes(rusage), elapsed


def measure(label: str, argv: list[str], env: dict[str, str], runs: int) -> dict | None:
    """Run `runs` times. Return {rss_min, rss_median, rss_max, time_median}
    or None on non-zero exit."""
    rss, times = [], []
    print(f"  {label:24s} ", end="", flush=True)
    for i in range(runs):
        rc, r, t = run_once(argv, env)
        if rc != 0:
            print(f"FAILED (rc={rc}) after {i + 1} run(s)")
            # Re-run once with output capture so the user sees what broke.
            try:
                p = subprocess.run(
                    argv,
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=10,
                    check=False,
                )
                tail = (p.stderr or p.stdout or "").strip().splitlines()[-5:]
                if tail:
                    print("    " + "\n    ".join(tail))
            except (OSError, subprocess.SubprocessError):
                pass
            return None
        rss.append(r)
        times.append(t)
        print(".", end="", flush=True)
    print(" ok", flush=True)
    return {
        "rss_min": min(rss),
        "rss_median": int(statistics.median(rss)),
        "rss_max": max(rss),
        "time_min": min(times),
        "time_median": statistics.median(times),
    }


# ── workload scripts ──────────────────────────────────────────────────────

# Version-injection prelude. hop3_rootd/__init__.py does
# ``version("hop3-rootd")`` at import time; that has to succeed under both
# interpreters. petitpy path uses the frozen module's _VERSIONS dict;
# CPython path monkey-patches importlib.metadata.version. Whichever
# branch matches the running interpreter fires; the other silently
# passes through.
PRELUDE = """\
try:
    from importlib.metadata import _VERSIONS
    _VERSIONS["hop3-rootd"] = "0.6.2"
except (ImportError, AttributeError):
    pass
try:
    import importlib.metadata as _md
    _real_version = _md.version
    def _patched_version(name):
        if name == "hop3-rootd":
            return "0.6.2"
        return _real_version(name)
    _md.version = _patched_version
except (ImportError, AttributeError):
    pass
"""

# Silent — the harness doesn't need output; a print() would interleave with
# the progress dots each subprocess writes to the parent's terminal.
WORKLOAD_COLD = "pass\n"

WORKLOAD_IMPORT = (
    PRELUDE
    + """
from hop3_rootd import cgroup, proxy, audit, mount, reconcile, server, state
from hop3_rootd.nft import rule as nft_rule
from hop3_rootd.nft import table as nft_table
from hop3_rootd.ops import cgroup as ops_cgroup, firewall as ops_firewall
from hop3_rootd.ops import mount as ops_mount, nginx as ops_nginx
from hop3_rootd.ops import postfix as ops_postfix, proxy as ops_proxy, daemon as ops_daemon
"""
)


def make_dispatch_workload(n_dispatches: int) -> str:
    """Build the dispatch workload — imports everything, then runs
    `n_dispatches` cycles of build-Request / lookup-handler / call /
    json-serialise-response, i.e. what an accept loop does per client
    request minus the socket I/O."""
    # Doubled braces so the surrounding f-string leaves the Python
    # dict/format literals alone.
    return (
        PRELUDE
        + f"""
from hop3_rootd import cgroup, proxy, audit, mount, reconcile, server, state
from hop3_rootd.nft import rule as nft_rule
from hop3_rootd.nft import table as nft_table
from hop3_rootd.ops import cgroup as ops_cgroup, firewall as ops_firewall
from hop3_rootd.ops import mount as ops_mount, nginx as ops_nginx
from hop3_rootd.ops import postfix as ops_postfix, proxy as ops_proxy, daemon as ops_daemon
from hop3_rootd.ops._base import OpContext
from hop3_rootd.ops import get_handler
from hop3_rootd.protocol import Request
from hop3_rootd.state import State
import json

s = State()
def _now_iso():
    return "2026-07-21T00:00:00+00:00"
def _new_rule_id():
    return "rule-1"
def _save():
    pass

ctx = OpContext(state=s, save_state=_save, now_iso=_now_iso, new_rule_id=_new_rule_id)

for _ in range({n_dispatches}):
    req = Request(v=1, id="r1", op="daemon.health", args={{}})
    handler = get_handler("daemon.health")
    if handler:
        result = handler(req, ctx)
        json.dumps({{"ok": True, "result": result}})
"""
    )


# ── environment plumbing ──────────────────────────────────────────────────


def parse_interpreter_arg(spec: str) -> tuple[str, str]:
    """LABEL=PATH → (label, path). Bare PATH → (basename, path)."""
    if "=" in spec:
        label, path = spec.split("=", 1)
        return label, path
    return os.path.basename(spec), spec


def is_petitpy(label: str) -> bool:
    return "nano" in label.lower()


def env_for(label: str, shim_dir: Path, hop3_src: Path) -> dict[str, str]:
    """Build subprocess env. PETITPY_LIB targets the built shim tree;
    PYTHONPATH targets the raw hop3-rootd source; each interpreter honours
    the variable it recognises. Setting both keeps this script agnostic
    to the interpreter's specific import protocol."""
    env = os.environ.copy()
    if is_petitpy(label):
        env["PETITPY_LIB"] = str(shim_dir)
    else:
        pypath = env.get("PYTHONPATH", "")
        env["PYTHONPATH"] = str(hop3_src) + ((os.pathsep + pypath) if pypath else "")
    return env


# ── output ────────────────────────────────────────────────────────────────


def print_table(headers: list[str], rows: list[list[str]], markdown: bool) -> None:
    if markdown:
        print("| " + " | ".join(headers) + " |")
        print("|" + "|".join("---" for _ in headers) + "|")
        for row in rows:
            print("| " + " | ".join(row) + " |")
        return
    widths = [
        max(len(h), *(len(r[i]) for r in rows)) + 2 for i, h in enumerate(headers)
    ]
    print("  " + "".join(h.ljust(widths[i]) for i, h in enumerate(headers)))
    print("  " + "-" * sum(widths))
    for row in rows:
        print("  " + "".join(row[i].ljust(widths[i]) for i in range(len(row))))


# ── main ──────────────────────────────────────────────────────────────────


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__.split("\n\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="\n".join(__doc__.split("\n\n")[1:]),
    )
    parser.add_argument(
        "--hop3-src",
        type=Path,
        default=DEFAULT_HOP3_SRC,
        help=f"hop3-rootd/src directory (default: {DEFAULT_HOP3_SRC}).",
    )
    parser.add_argument(
        "--interpreter",
        action="append",
        default=[],
        metavar="LABEL=PATH",
        help="Interpreter to measure — repeatable. Labels containing "
        "'nano' get PETITPY_LIB; others get PYTHONPATH. "
        "Defaults: zig-out/bin/petitpy and $(which python3).",
    )
    parser.add_argument(
        "--dispatches",
        type=int,
        default=100,
        help="daemon.health dispatch cycles per run (default: 100).",
    )
    parser.add_argument(
        "--runs",
        type=int,
        default=5,
        help="Measurement repeats per (interpreter, workload) cell (default: 5).",
    )
    parser.add_argument(
        "--markdown",
        action="store_true",
        help="Emit tables as Markdown instead of aligned text.",
    )
    parser.add_argument(
        "--keep-tmp",
        action="store_true",
        help="Don't delete the shim / workload temp directories on exit "
        "(useful for debugging).",
    )
    args = parser.parse_args()

    # Default interpreter list.
    if not args.interpreter:
        cands = []
        nano = REPO / "zig-out/bin/petitpy"
        if nano.exists():
            cands.append(f"petitpy={nano}")
        py = shutil.which("python3")
        if py:
            cands.append(f"python3={py}")
        args.interpreter = cands

    if not args.interpreter:
        print(
            "error: no interpreter to measure (defaults not found, none passed)",
            file=sys.stderr,
        )
        return 2

    if not (args.hop3_src / "hop3_rootd").exists():
        print(
            f"error: hop3-rootd source not found under {args.hop3_src}", file=sys.stderr
        )
        return 2

    # Header.
    print(
        f"System:         {platform.system()} {platform.release()} ({platform.machine()})"
    )
    print(f"Python (host):  {sys.executable} — {sys.version.split()[0]}")
    print(f"hop3-rootd src: {args.hop3_src}")
    print(f"Runs per cell:  {args.runs}   Dispatches per run: {args.dispatches}")
    print()

    # Build the petitpy shim tree — reuses build_shim() from the smoke
    # tool so the patched sources match what the runner produces. CPython
    # workloads don't touch this tree.
    print("Building petitpy shim tree…", flush=True)
    shim_dir = Path(tempfile.mkdtemp(prefix="hop3-footprint-"))
    shim_ok = True
    try:
        smoke.build_shim(shim_dir, args.hop3_src)
        print(f"  shim: {shim_dir}", flush=True)
    except OSError as e:
        print(f"  build_shim failed: {e}", flush=True)
        shim_ok = False
    print()

    # Workload scripts on disk.
    workdir = Path(tempfile.mkdtemp(prefix="hop3-footprint-work-"))
    workloads = [
        ("cold-start", workdir / "cold.py", WORKLOAD_COLD),
        ("import-tree", workdir / "import.py", WORKLOAD_IMPORT),
        (
            f"dispatch-{args.dispatches}",
            workdir / f"dispatch_{args.dispatches}.py",
            make_dispatch_workload(args.dispatches),
        ),
    ]
    for _, path, body in workloads:
        path.write_text(body)

    # Binary sizes.
    print("Binary sizes:")
    for spec in args.interpreter:
        label, path = parse_interpreter_arg(spec)
        try:
            size = os.path.getsize(path)
            print(f"  {label:20s} {format_bytes(size):>10s}  {path}")
        except OSError as e:
            print(f"  {label:20s} ERROR: {e}")
    print()

    # Run every (interpreter, workload) cell.
    results: dict[tuple[str, str], dict | None] = {}
    for spec in args.interpreter:
        label, path = parse_interpreter_arg(spec)
        if is_petitpy(label) and not shim_ok:
            print(f"Skipping {label}: no shim tree available.")
            continue
        print(f"Measuring {label}  ({path})")
        env = env_for(label, shim_dir, args.hop3_src)
        for wl_name, wl_path, _ in workloads:
            results[(label, wl_name)] = measure(
                wl_name, [path, str(wl_path)], env, args.runs
            )
        print()

    # ── result tables ────────────────────────────────────────────────────
    print("=" * 72)
    print("PEAK RSS (median across runs)")
    print("=" * 72)
    headers = ["Workload"] + [parse_interpreter_arg(s)[0] for s in args.interpreter]
    rows = []
    for wl_name, _, _ in workloads:
        row = [wl_name]
        for spec in args.interpreter:
            label = parse_interpreter_arg(spec)[0]
            stats = results.get((label, wl_name))
            row.append(format_bytes(stats["rss_median"]) if stats else "—")
        rows.append(row)
    print_table(headers, rows, args.markdown)

    print()
    print("=" * 72)
    print("WALL TIME (median across runs)")
    print("=" * 72)
    rows = []
    for wl_name, _, _ in workloads:
        row = [wl_name]
        for spec in args.interpreter:
            label = parse_interpreter_arg(spec)[0]
            stats = results.get((label, wl_name))
            if stats is None:
                row.append("—")
            else:
                t = stats["time_median"]
                row.append(f"{t * 1000:.0f} ms" if t < 1 else f"{t:.2f} s")
        rows.append(row)
    print_table(headers, rows, args.markdown)

    # ── ratios (only when there are >= 2 interpreters) ───────────────────
    if len(args.interpreter) >= 2:
        print()
        print("=" * 72)
        print("RATIOS (RSS other/first)")
        print("=" * 72)
        first_label = parse_interpreter_arg(args.interpreter[0])[0]
        rest = args.interpreter[1:]
        ratio_headers = ["Workload"] + [
            f"{parse_interpreter_arg(s)[0]} / {first_label}" for s in rest
        ]
        rows = []
        for wl_name, _, _ in workloads:
            row = [wl_name]
            first_stats = results.get((first_label, wl_name))
            for spec in rest:
                label = parse_interpreter_arg(spec)[0]
                other_stats = results.get((label, wl_name))
                if first_stats and other_stats and first_stats["rss_median"] > 0:
                    ratio = other_stats["rss_median"] / first_stats["rss_median"]
                    row.append(f"{ratio:.2f}x")
                else:
                    row.append("—")
            rows.append(row)
        print_table(ratio_headers, rows, args.markdown)

    # Cleanup.
    if not args.keep_tmp:
        shutil.rmtree(shim_dir, ignore_errors=True)
        shutil.rmtree(workdir, ignore_errors=True)
    else:
        print(f"\ntmp dirs kept: {shim_dir}  {workdir}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
