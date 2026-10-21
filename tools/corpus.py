#!/usr/bin/env python3
"""nanopython differential-test corpus harness.

The strangler invariant is: every build must produce byte-identical output to
the MicroPython reference oracle. This tool freezes the oracle's output for the
`tests/basics/` corpus as golden files, then verifies any other binary against
them.

Two parallel corpora (Phase 4, 2026-05-26):
  corpus/nano/basics/   -- nano build, reference = nano-C binary
  corpus/full/basics/   -- full build, reference = upstream standard oracle

Subcommands:
  gen [cmd...]       Run the reference (default: standard oracle for --config
                     full; explicit binary required for --config nano) over
                     the corpus, freeze deterministic outputs to
                     corpus/<config>/basics/<name>.out.
                     Non-deterministic tests are excluded -> EXCLUDED.txt.
  verify <binary>    Run <binary> over the frozen corpus, diff against goldens.
  stats              Print corpus size / exclusion counts.

Options:
  --config nano|full  Which corpus to operate on (default: nano).

Layout (relative to repo root):
  sandbox/micropython/tests/basics/*.py        source tests
  sandbox/micropython/ports/unix/build-standard/micropython   standard oracle
  corpus/<config>/basics/*.out                 frozen golden output
  corpus/<config>/EXCLUDED.txt                 excluded tests + reason
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MPY = ROOT / "sandbox" / "micropython"
TESTS = MPY / "tests" / "basics"
ORACLE = MPY / "ports" / "unix" / "build-standard" / "micropython"

# Per-config corpus paths. Set by `set_config()` before any other module
# entry point reads CORPUS / EXCLUDED.
CONFIG: str = "full"  # ADR 012 Phase 4b — full is the default profile
CORPUS: Path = ROOT / "corpus" / CONFIG / "basics"
EXCLUDED: Path = ROOT / "corpus" / CONFIG / "EXCLUDED.txt"


def set_config(config: str) -> None:
    """Switch the active corpus to `config` (nano|full). Must be called
    before reading CORPUS/EXCLUDED from other modules (e.g. progress.py)."""
    global CONFIG, CORPUS, EXCLUDED
    if config not in ("nano", "full"):
        raise ValueError(f"unknown config: {config!r} (want nano|full)")
    CONFIG = config
    CORPUS = ROOT / "corpus" / config / "basics"
    EXCLUDED = ROOT / "corpus" / config / "EXCLUDED.txt"


TIMEOUT = 30


def run_cmd(argv: list[str], script: Path) -> bytes:
    """Run `argv` over `script`, return the canonical output blob.

    The script path replaces a literal `{script}` token in argv if present,
    otherwise it is appended. This blob format (combined stdout+stderr + exit
    marker) is what goldens are frozen as; every consumer MUST use this exact
    function so comparisons stay meaningful.
    """

    def fix(a: str) -> str:
        # The runner executes in the test's directory so file-relative tests
        # behave; resolve any argv element that is a real path (binary,
        # wrapper script, .wasm) to absolute, but leave bare command names
        # (`wasmtime`, `node`, `--`) alone for normal PATH resolution.
        p = Path(a)
        return str(p.resolve()) if p.exists() else a

    if "{script}" in argv:
        cmd = [str(script) if a == "{script}" else fix(a) for a in argv]
    else:
        cmd = [*(fix(a) for a in argv), str(script)]
    try:
        p = subprocess.run(
            cmd,
            capture_output=True,
            timeout=TIMEOUT,
            cwd=str(script.parent),
            check=False,
        )
        return p.stdout + p.stderr + f"\n[exit {p.returncode}]\n".encode()
    except subprocess.TimeoutExpired:
        return b"[TIMEOUT]\n"
    except (FileNotFoundError, PermissionError) as e:
        return f"[RUNNER ERROR: {e}]\n".encode()


def run(binary: Path, script: Path) -> bytes:
    """Run script under a single binary (oracle / native build)."""
    return run_cmd([str(binary)], script)


def gen(ref_cmd: list[str] | None) -> int:
    """Freeze the reference's deterministic output as the golden corpus.

    The reference is the strangler's ground truth: every C→Zig replacement
    must reproduce this output byte-for-byte. For --config full the default
    is the standard oracle (full-feature MicroPython upstream build); for
    --config nano you must pass an explicit binary (typically the nano-C
    build, whose disabled-feature errors form the nano contract).
    """
    if ref_cmd is None:
        if CONFIG == "nano":
            print(
                "--config nano requires an explicit reference command "
                "(e.g. the nano-C build). The standard oracle would freeze "
                "the full-feature output, which the nano build can't match.",
                file=sys.stderr,
            )
            return 1
        if not ORACLE.exists():
            print(f"oracle not found: {ORACLE}", file=sys.stderr)
            return 1
        ref_cmd = [str(ORACLE)]
    CORPUS.mkdir(parents=True, exist_ok=True)
    # Clear stale goldens so excluded tests don't leave an old reference's
    # output behind (which would silently never match).
    for old in CORPUS.glob("*.out"):
        old.unlink()
    scripts = sorted(TESTS.glob("*.py"))
    frozen, excluded = 0, []
    for s in scripts:
        a = run_cmd(ref_cmd, s)
        b = run_cmd(ref_cmd, s)
        if a != b:
            excluded.append(s.stem)
            continue
        (CORPUS / f"{s.stem}.out").write_bytes(a)
        frozen += 1
    EXCLUDED.write_text(
        "# Tests excluded from the corpus: reference output differs across two\n"
        "# runs (memory addresses, dict/set ordering, timing). One name/line.\n"
        f"# Reference: {' '.join(ref_cmd)}\n"
        + "\n".join(sorted(excluded))
        + ("\n" if excluded else "")
    )
    print(f"reference: {' '.join(ref_cmd)}")
    print(f"frozen: {frozen}   excluded (non-deterministic): {len(excluded)}")
    print(f"goldens -> {CORPUS}")
    print(f"exclusions -> {EXCLUDED}")
    return 0


def verify(binary: Path) -> int:
    goldens = sorted(CORPUS.glob("*.out"))
    if not goldens:
        print("no goldens; run `corpus.py gen` first", file=sys.stderr)
        return 1
    passed, failed = 0, []
    for g in goldens:
        script = TESTS / f"{g.stem}.py"
        got = run(binary, script)
        if got == g.read_bytes():
            passed += 1
        else:
            failed.append(g.stem)
    total = len(goldens)
    print(f"PASS {passed}/{total}   FAIL {len(failed)}")
    if failed:
        for name in failed[:25]:
            print(f"  FAIL {name}")
        if len(failed) > 25:
            print(f"  ... and {len(failed) - 25} more")
        return 1
    return 0


def stats() -> int:
    n_src = len(list(TESTS.glob("*.py")))
    n_gold = len(list(CORPUS.glob("*.out")))
    n_excl = 0
    if EXCLUDED.exists():
        n_excl = sum(
            1
            for ln in EXCLUDED.read_text().splitlines()
            if ln and not ln.startswith("#")
        )
    print(f"source tests : {n_src}")
    print(f"frozen corpus: {n_gold}")
    print(f"excluded     : {n_excl}")
    return 0


def _parse_config(argv: list[str]) -> tuple[str, list[str]]:
    """Extract --config nano|full from argv; return (config, remaining)."""
    out: list[str] = []
    config = "nano"
    i = 0
    while i < len(argv):
        if argv[i] == "--config" and i + 1 < len(argv):
            config = argv[i + 1]
            i += 2
            continue
        out.append(argv[i])
        i += 1
    return config, out


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2
    config, rest = _parse_config(argv[1:])
    set_config(config)
    if not rest:
        print(__doc__)
        return 2
    cmd = rest[0]
    if cmd == "gen":
        return gen(rest[1:] if len(rest) > 1 else None)
    if cmd == "verify":
        if len(rest) < 2:
            print(
                "usage: corpus.py [--config nano|full] verify <binary>", file=sys.stderr
            )
            return 2
        return verify(Path(rest[1]).resolve())
    if cmd == "stats":
        return stats()
    print(f"unknown command: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
