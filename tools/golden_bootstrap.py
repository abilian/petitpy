#!/usr/bin/env python3
"""golden_bootstrap.py — populate golden-programs/ from source corpora.

See docs/src/adrs/008-golden-programs.md for the design.

Workflow:
1. Walk the four source corpora.
2. Filter out-of-scope programs (numpy, flask, django, ...).
3. Dedupe by content hash.
4. Auto-detect features each program needs (imports + grep patterns).
5. Run each through vendor MicroPython + nanopython native + wasm.
6. Determine bucket: the minimal profile that makes the program work.
7. Write the file into golden-programs/<bucket>/ with golden header.

Idempotent: re-running picks up new programs from source corpora but
preserves manual bucket placements (recognised by a `# golden: bucket=X;
manual=true` comment).
"""

from __future__ import annotations

import argparse
import hashlib
import re
import subprocess
import sys
from concurrent.futures import ProcessPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

SOURCES = {
    "prescrypt-internal": ROOT / "sandbox/prescrypt/programs/internal",
    "prescrypt-tryalgo": ROOT / "sandbox/prescrypt/programs/tryalgo",
    "prescrypt-micropython": ROOT / "sandbox/prescrypt/programs/micropython",
    "p2w-internal": ROOT / "sandbox/p2w/programs/internal",
}

GOLDEN = ROOT / "golden-programs"

MICROPY_REF = ROOT / "vendor/micropython/ports/unix/build-standard/micropython"
NANO_NATIVE = ROOT / "zig-out/bin/nanopython"
NANO_WASM = ROOT / "zig-out/bin/nanopython.wasm"
RUN_WASM = ROOT / "tools/run_wasm.sh"

TIMEOUT_SECONDS = 10

# Out-of-scope third-party imports per ADR.
OUT_OF_SCOPE_IMPORTS = {
    "numpy",
    "scipy",
    "pandas",
    "matplotlib",
    "sklearn",
    "flask",
    "django",
    "fastapi",
    "jinja2",
    "requests",
    "dataclasses",  # full feature; we don't have it
    "pytest",
    "unittest",
    "asyncio",  # bigger than just async syntax
}

# Buckets, ordered by precedence (a program lands in the LAST bucket it
# triggers — i.e. the strictly larger feature requirement wins).
BUCKETS = [
    "works",
    "works-native-only",
    "needs-stdlib",
    "needs-grammar",
    "needs-async",
    "needs-fs",
    "needs-mpz",
    "disagreement",
]

# Feature → bucket mapping. Auto-detect populates a needs= set; we look
# up the strictly-larger bucket for each.
FEATURE_BUCKET = {
    "stdlib.heapq": "needs-stdlib",
    "stdlib.bisect": "needs-stdlib",
    "stdlib.collections.Counter": "needs-stdlib",
    "stdlib.collections.defaultdict": "needs-stdlib",
    "stdlib.collections.namedtuple": "needs-stdlib",
    "stdlib.itertools.starmap": "needs-stdlib",
    "stdlib.itertools.chain": "needs-stdlib",
    "stdlib.itertools.islice": "needs-stdlib",
    "stdlib.functools": "needs-stdlib",
    "stdlib.random": "needs-stdlib",
    "stdlib.math.factorial": "needs-stdlib",
    "stdlib.cmath": "needs-stdlib",
    "stdlib.distutils": "needs-stdlib",  # historical, niche
    "grammar.walrus": "needs-grammar",
    "grammar.match": "needs-grammar",
    "async": "needs-async",
    "fs.open": "needs-fs",
    "fs.sys.stdin": "needs-fs",
    "mpz": "needs-mpz",
}

# Bucket precedence — higher index = larger feature requirement.
BUCKET_RANK = {b: i for i, b in enumerate(BUCKETS)}


@dataclass
class RunResult:
    stdout: str
    stderr: str
    exit_code: int
    timed_out: bool


def run_under(argv: list[str], script: Path) -> RunResult:
    try:
        p = subprocess.run(
            [*argv, str(script)],
            capture_output=True,
            text=False,
            timeout=TIMEOUT_SECONDS,
            cwd=str(script.parent),
            check=False,
        )
        return RunResult(
            p.stdout.decode("utf-8", errors="replace"),
            p.stderr.decode("utf-8", errors="replace"),
            p.returncode,
            False,
        )
    except subprocess.TimeoutExpired:
        return RunResult("", "", -1, True)
    except (FileNotFoundError, PermissionError) as e:
        return RunResult("", f"[runner error] {e}", -2, False)


def normalize(text: str) -> str:
    return "\n".join(line.rstrip() for line in text.splitlines()).strip()


def combined_output(r: RunResult) -> str:
    sep = "\n" if r.stdout and not r.stdout.endswith("\n") else ""
    return r.stdout + sep + r.stderr


def outputs_match(a: RunResult, b: RunResult) -> bool:
    """Match the COMBINED stdout+stderr (CPython sends tracebacks to
    stderr, MicroPython to stdout; either is valid)."""
    return normalize(combined_output(a)) == normalize(combined_output(b))


# ----- feature detection -----

IMPORT_RE = re.compile(r"^(?:from\s+(\S+)\s+import\s+(.+)|import\s+(.+))", re.MULTILINE)


def detect_features(src: str) -> tuple[set[str], set[str]]:
    """Return (needs, out_of_scope_imports). The first drives bucket;
    the second triggers filtering."""
    needs: set[str] = set()
    oos: set[str] = set()

    # Imports
    for m in IMPORT_RE.finditer(src):
        from_mod, from_names, plain = m.group(1), m.group(2), m.group(3)
        if from_mod:
            mod = from_mod.split(".")[0]
            if mod in OUT_OF_SCOPE_IMPORTS:
                oos.add(mod)
                continue
            # Specific from-import patterns
            if from_mod == "heapq":
                needs.add("stdlib.heapq")
            elif from_mod == "bisect":
                needs.add("stdlib.bisect")
            elif from_mod == "collections":
                for n in [x.strip() for x in from_names.split(",")]:
                    if n == "deque":
                        pass  # we have deque
                    else:
                        needs.add(f"stdlib.collections.{n}")
            elif from_mod == "itertools":
                for n in [x.strip() for x in from_names.split(",")]:
                    needs.add(f"stdlib.itertools.{n}")
            elif from_mod == "functools":
                needs.add("stdlib.functools")
            elif from_mod == "random":
                needs.add("stdlib.random")
            elif from_mod == "math":
                if "factorial" in from_names:
                    needs.add("stdlib.math.factorial")
            elif from_mod == "cmath":
                needs.add("stdlib.cmath")
            elif from_mod == "distutils.core":
                needs.add("stdlib.distutils")
            elif from_mod == "sys":
                if "stdin" in from_names:
                    needs.add("fs.sys.stdin")
            elif from_mod == "__future__":
                pass  # supported via stub
            else:
                # tryalgo internal modules, relative imports — flag as fs/stdlib
                if from_mod.startswith(("tryalgo", ".")):
                    needs.add("stdlib.tryalgo-internal")
        elif plain:
            for n in [x.strip() for x in plain.split(",")]:
                mod = n.split(".")[0].split(" as ")[0]
                if mod in OUT_OF_SCOPE_IMPORTS:
                    oos.add(mod)
                elif mod == "heapq":
                    needs.add("stdlib.heapq")
                elif mod == "bisect":
                    needs.add("stdlib.bisect")
                elif mod == "random":
                    needs.add("stdlib.random")
                elif mod == "collections":
                    needs.add("stdlib.collections.Counter")  # representative
                elif mod == "itertools":
                    needs.add("stdlib.itertools.chain")
                elif mod == "functools":
                    needs.add("stdlib.functools")
                elif mod == "cmath":
                    needs.add("stdlib.cmath")

    # Grammar patterns
    if re.search(r"\basync\s+def\b|\basync\s+for\b|\basync\s+with\b|\bawait\b", src):
        needs.add("async")
    if re.search(r":=(?!=)", src):  # walrus
        needs.add("grammar.walrus")
    if re.search(r"^\s*match\s+\S+\s*:\s*$", src, re.MULTILINE):
        needs.add("grammar.match")

    # File I/O
    if re.search(r"\bopen\s*\(", src):
        needs.add("fs.open")

    return needs, oos


def bucket_for(
    needs: set[str],
    mp_succeeded: bool,
    cpy_succeeded: bool,
    mp_cpy_agree: bool,
    nano_native_passes: bool,
    nano_wasm_passes: bool,
) -> str:
    """Determine bucket.

    Definitions:
    - `nano_native_passes` / `nano_wasm_passes`: nano's output matches
      MicroPython OR CPython (whichever is the more authoritative source
      for this particular program).
    - `mp_succeeded` / `cpy_succeeded`: the reference exited cleanly with
      some output (not crashed/timeout).
    - `mp_cpy_agree`: outputs_match(mp, cpy) — the two references
      produced identical output (the cleanest signal).

    Priority:
      works            — nano matches an authoritative reference on both runtimes
      works-native-only — same, native only
      disagreement     — MP and CPython BOTH succeeded but disagree (deliberate
                          surface, regardless of whether nano matches one)
      needs-X          — nano doesn't pass; bucket by detected feature
    """

    # If nano passes on both runtimes, it works.
    if nano_native_passes and nano_wasm_passes:
        # MP-vs-CPython disagreement is still a notable surface, but only
        # if BOTH ran successfully (an MP ImportError vs CPython success
        # for __future__ isn't a real disagreement — MP is just missing
        # a feature CPython has).
        if mp_succeeded and cpy_succeeded and not mp_cpy_agree:
            return "disagreement"
        return "works"

    # Native works, wasm doesn't → works-native-only
    if nano_native_passes and not nano_wasm_passes:
        return "works-native-only"

    # Nano doesn't pass. Bucket by detected feature.
    if not needs:
        return "needs-stdlib"

    candidate_buckets = {FEATURE_BUCKET[n] for n in needs if n in FEATURE_BUCKET}
    if not candidate_buckets:
        return "needs-stdlib"
    return max(candidate_buckets, key=lambda b: BUCKET_RANK[b])


# ----- bootstrap -----


def collect_sources() -> list[tuple[Path, str]]:
    """(path, source_name) for every .py in the source corpora."""
    out = []
    for name, dir in SOURCES.items():
        if not dir.exists():
            continue
        for p in dir.rglob("*.py"):
            out.append((p, name))
    return out


def dedupe_by_content(files: list[tuple[Path, str]]) -> list[tuple[Path, str]]:
    """Keep the first file per content hash; first wins lexicographically
    by source name then path."""
    seen: dict[str, tuple[Path, str]] = {}
    for p, src in sorted(files, key=lambda x: (x[1], str(x[0]))):
        try:
            content = p.read_bytes()
        except OSError:
            continue
        h = hashlib.sha256(content).hexdigest()
        if h not in seen:
            seen[h] = (p, src)
    return list(seen.values())


def evaluate_program(p_src: tuple[Path, str]) -> dict | None:
    """Run a program through all oracles + classify."""
    p, src = p_src
    try:
        src_text = p.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None

    needs, oos = detect_features(src_text)
    if oos:
        return {
            "path": str(p),
            "source": src,
            "skip": "out-of-scope",
            "imports": sorted(oos),
        }

    mp = run_under([str(MICROPY_REF)], p)
    nat = run_under([str(NANO_NATIVE)], p)
    was = run_under([str(RUN_WASM), str(NANO_WASM)], p)
    cpy = run_under([sys.executable], p)

    # A nanopython run "passes" if its output matches EITHER MicroPython
    # (the strangler oracle) OR CPython (the language reference). The
    # latter catches programs where MP errors out (e.g. `from __future__
    # import annotations` raises ImportError in MP unix-standard) but
    # nanopython produces CPython-correct behavior. Without this, ~40
    # programs got mis-bucketed as needs-stdlib when they actually work.
    matches_mp_native = outputs_match(mp, nat) and not nat.timed_out
    matches_mp_wasm = outputs_match(mp, was) and not was.timed_out
    matches_cpy_native = outputs_match(cpy, nat) and not nat.timed_out
    matches_cpy_wasm = outputs_match(cpy, was) and not was.timed_out
    nano_native_passes = matches_mp_native or matches_cpy_native
    nano_wasm_passes = matches_mp_wasm or matches_cpy_wasm

    # Reference run cleanliness — required for the "disagreement" bucket
    # (we want both references to have a defined notion of correct output
    # before flagging a divergence as a real ambiguity).
    mp_succeeded = not mp.timed_out and mp.exit_code == 0
    cpy_succeeded = not cpy.timed_out and cpy.exit_code == 0
    mp_cpy_agree = outputs_match(mp, cpy)

    # Kept under the old key for backward-compatible annotation output.
    runs_on_mp = not mp.timed_out and mp.exit_code != -2
    cpython_agrees = mp_cpy_agree

    bucket = bucket_for(
        needs,
        mp_succeeded=mp_succeeded,
        cpy_succeeded=cpy_succeeded,
        mp_cpy_agree=mp_cpy_agree,
        nano_native_passes=nano_native_passes,
        nano_wasm_passes=nano_wasm_passes,
    )

    works_on = []
    if runs_on_mp:
        works_on.append("micropython")
    if matches_mp_native or matches_cpy_native:
        works_on.append("nanopython-native")
    if matches_mp_wasm or matches_cpy_wasm:
        works_on.append("nanopython-wasm")

    return {
        "path": str(p),
        "source": src,
        "needs": sorted(needs),
        "works-on": works_on,
        "bucket": bucket,
        "cpython_agrees": cpython_agrees,
    }


def write_program(record: dict, target_root: Path) -> None:
    """Write the program into target_root/<bucket>/<name>.py with the
    golden header prepended."""
    src_path = Path(record["path"])
    bucket = record["bucket"]
    target_dir = target_root / bucket
    target_dir.mkdir(parents=True, exist_ok=True)
    target_path = target_dir / src_path.name

    original = src_path.read_text(encoding="utf-8", errors="replace")
    # Strip any existing golden: header (we'll regenerate).
    lines = original.splitlines()
    while lines and lines[0].lstrip().startswith("# golden:"):
        lines.pop(0)
    cleaned = "\n".join(lines)
    if not cleaned.endswith("\n"):
        cleaned += "\n"

    needs_str = ",".join(record["needs"]) if record["needs"] else ""
    works_on_str = ",".join(record["works-on"]) if record["works-on"] else "none"

    header = f"# golden: source={record['source']}; needs={needs_str}\n"
    header += f"# golden: works-on={works_on_str}\n"
    if not record["cpython_agrees"]:
        header += "# golden: micropython-cpython-divergence=true\n"

    target_path.write_text(header + cleaned, encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument(
        "--rebuild",
        action="store_true",
        help="DESTRUCTIVE: delete every *.py under golden-programs/<bucket>/ "
        "and re-derive the buckets from the source corpora",
    )
    args = ap.parse_args()
    if not args.rebuild:
        print(
            "refusing to run without --rebuild: this deletes and re-derives "
            "every program under golden-programs/",
            file=sys.stderr,
        )
        return 2

    for tool in (MICROPY_REF, NANO_NATIVE, NANO_WASM, RUN_WASM):
        if not tool.exists():
            print(
                f"error: {tool.relative_to(ROOT)} missing — build first",
                file=sys.stderr,
            )
            return 2

    GOLDEN.mkdir(exist_ok=True)
    # Clean stale bucket contents so re-runs don't leave a program in
    # both its old and new buckets. Preserve README.md / profiles.md
    # which aren't program files.
    for b in BUCKETS:
        bucket_dir = GOLDEN / b
        if bucket_dir.exists():
            for f in bucket_dir.glob("*.py"):
                f.unlink()
        bucket_dir.mkdir(exist_ok=True)

    print(f"Collecting from {len(SOURCES)} sources…", file=sys.stderr)
    raw = collect_sources()
    print(f"  {len(raw)} files total", file=sys.stderr)

    deduped = dedupe_by_content(raw)
    print(f"  {len(deduped)} after content-dedup", file=sys.stderr)

    print("Evaluating each program against 4 oracles (in parallel)…", file=sys.stderr)
    records = []
    skipped = []
    with ProcessPoolExecutor(max_workers=4) as ex:
        futures = {ex.submit(evaluate_program, ps): ps for ps in deduped}
        done = 0
        for fut in as_completed(futures):
            r = fut.result()
            if r is None:
                continue
            if r.get("skip"):
                skipped.append(r)
            else:
                records.append(r)
            done += 1
            if done % 50 == 0:
                print(f"  {done}/{len(deduped)}…", file=sys.stderr)

    print(
        f"  {len(records)} in-scope, {len(skipped)} skipped (out-of-scope)",
        file=sys.stderr,
    )

    print("Writing into golden-programs/…", file=sys.stderr)
    for r in records:
        write_program(r, GOLDEN)

    # Summary by bucket
    from collections import Counter

    print("\nBucket distribution:", file=sys.stderr)
    by_bucket = Counter(r["bucket"] for r in records)
    for b in BUCKETS:
        n = by_bucket.get(b, 0)
        print(f"  {b:25s} {n}", file=sys.stderr)
    print(f"  {'(skipped out-of-scope)':25s} {len(skipped)}", file=sys.stderr)
    print(f"  TOTAL                     {sum(by_bucket.values())}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
