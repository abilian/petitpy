"""Shared runner for tests/test_integration_*.py.

Each `test_integration_*` module exposes a `CASES` list of tuples:
    (name, source, expected_stdout)
    (name, source, expected_stdout, expected_exit)

`expected_stdout=None` skips the stdout check (used when only the exit
code matters — e.g. "raise → exit 1" without committing to exact
traceback text).

Runner-pluggable: default invokes the binary directly (right for
native). For wasm, pass `--runner "tools/run_wasm.sh path/to.wasm"` —
the runner argv is split on whitespace and the script path is
appended as the last argument.

Usage:
    python3 tests/integration.py [--runner CMD] [BINARY]

The top-level `tests/integration.py` shim collects CASES from every
`test_integration_*` module and hands them here. Individual modules
can also be run directly:
    python3 tests/test_integration_os.py [--runner CMD] [BINARY]
"""

from __future__ import annotations

import argparse
import os
import shlex
import subprocess
import tempfile


def resolve_runner_argv(
    binary: str | None, runner: str | None
) -> tuple[list[str], str]:
    """Return (argv_prefix, label) for the case runner.

    Relative paths in --runner are resolved against the repo root so
    e.g. `tools/run_wasm.sh` works from any cwd. Bare commands (like
    `wasmtime`) pass through untouched.
    """
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    if runner:
        argv = shlex.split(runner)
        if not argv:
            raise SystemExit("FAIL: empty --runner")
        argv = [
            os.path.abspath(os.path.join(root, a))
            if not a.startswith("/") and os.path.exists(os.path.join(root, a))
            else a
            for a in argv
        ]
        return argv, f"runner: {' '.join(argv)}"
    bin_path = binary or os.path.join(root, "zig-out", "bin", "petitpy")
    bin_path = os.path.abspath(bin_path)
    if not os.path.exists(bin_path):
        raise SystemExit(
            f"FAIL: interpreter not found: {bin_path}\n"
            f"      build it first (make build)"
        )
    return [bin_path], f"binary: {bin_path}"


def run_case(
    runner_argv: list[str], src: str, flags: list[str] | None = None
) -> subprocess.CompletedProcess[str]:
    """Run `src` as a script. `flags` go before the script path, which is
    where the binary's own options live (`--emit-mpy IN.py`)."""
    with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False) as f:
        f.write(src + "\n")
        path = f.name
    try:
        return subprocess.run(
            runner_argv + (flags or []) + [path],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
    finally:
        os.unlink(path)


def run(cases: list[tuple], label_prefix: str = "integration smoke") -> int:
    """Execute CASES against argv from argv-parse. Return exit code."""
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("binary", nargs="?", default=None)
    parser.add_argument("--runner", default=None)
    # The build under test. A case whose behaviour differs by build (dict
    # order: insertion on full, hash order on nano) gives its expected
    # stdout as {"full": ..., "nano": ...}.
    parser.add_argument("--config", choices=["full", "nano"], default="full")
    args = parser.parse_args()

    runner_argv, label = resolve_runner_argv(args.binary, args.runner)
    print(f"{label_prefix} ({label})")

    npass = 0
    failures = []
    for case in cases:
        name, src, expected = case[:3]
        if isinstance(expected, dict):
            expected = expected[args.config]
        expected_exit = case[3] if len(case) >= 4 else None
        # A 5th element is argv for the binary itself, before the script.
        flags = case[4] if len(case) >= 5 else None
        out = run_case(runner_argv, src, flags)
        ok_stdout = (expected is None) or (out.stdout == expected)
        ok_exit = (expected_exit is None) or (out.returncode == expected_exit)
        if ok_stdout and ok_exit:
            npass += 1
            print(f"  PASS  {name}")
        else:
            failures.append(
                (name, expected, out.stdout, out.stderr, expected_exit, out.returncode)
            )
            print(f"  FAIL  {name}")

    print(f"\nintegration: {npass}/{len(cases)} passed")
    for name, exp, got, err, ex_exit, ac_exit in failures:
        print(f"\n--- {name} ---\n expected stdout: {exp!r}\n got           : {got!r}")
        if ex_exit is not None:
            print(f" expected exit  : {ex_exit}\n got            : {ac_exit}")
        if err.strip():
            print(f" stderr         : {err.strip()[:300]}")
    return 0 if not failures else 1
