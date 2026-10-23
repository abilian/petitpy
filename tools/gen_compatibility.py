#!/usr/bin/env python3
"""gen_compatibility — render docs/src/COMPATIBILITY.md from golden-programs/.

The golden-programs/ directory ([ADR 008](docs/src/adrs/008-golden-programs.md))
buckets real Python programs by what they need to run. Buckets are
file-system directories; each program has a small header comment with
metadata (source corpus, needed features, interpreters where it works).

This tool walks the buckets and emits a single markdown doc readers
can scan to answer 'does my program work in petitpy today?'.

Usage:
    python3 tools/gen_compatibility.py [-o docs/src/COMPATIBILITY.md]
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GP = ROOT / "golden-programs"

# Ordered: works first (the answer), then native-only, then the gap buckets.
BUCKET_ORDER = [
    "works",
    "works-native-only",
    "needs-stdlib",
    "needs-grammar",
    "needs-async",
    "needs-fs",
    "needs-mpz",
    "disagreement",
]

BUCKET_BLURB = {
    "works": "Runs on **both** native and wasm, with the same output as MicroPython or CPython.",
    "works-native-only": "Runs on native but not wasm, usually because wasm stores array, memoryview and struct values in a 32-bit word.",
    "needs-stdlib": "Needs a stdlib module petitpy does not ship yet. The header of each "
    "program names it. See [ADR 003](adrs/003-library-and-module-loading.md).",
    "needs-grammar": "Uses syntax petitpy does not parse.",
    "needs-async": "Needs more `async` support than petitpy has "
    "([ADR 002](adrs/002-feature-selection.md)).",
    "needs-fs": "Uses `open()`, `sys.stdin` or other file system access.",
    "needs-mpz": "Needs integers beyond 64 bits on wasm.",
    "disagreement": "MicroPython and CPython print **different** output for these "
    "programs, so there is no single expected result.",
}

HEADER_RE = re.compile(r"^#\s*golden:\s*(.+)$")


def parse_header(path: Path) -> dict:
    """Read the leading `# golden:` comment lines from a program."""
    info: dict = {}
    try:
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.strip()
            if not line:
                continue
            if not line.startswith("#"):
                break
            m = HEADER_RE.match(line)
            if not m:
                continue
            for chunk in m.group(1).split(";"):
                chunk = chunk.strip()
                if "=" in chunk:
                    k, v = chunk.split("=", 1)
                    info[k.strip()] = v.strip()
    except OSError:
        pass
    return info


def collect_bucket(bucket: str) -> list[dict]:
    """Walk a bucket dir and return per-program metadata."""
    bdir = GP / bucket
    if not bdir.exists():
        return []
    rows: list[dict] = []
    for p in sorted(bdir.glob("*.py")):
        info = parse_header(p)
        rows.append(
            {
                "name": p.stem,
                "source": info.get("source", "?"),
                "needs": info.get("needs", ""),
                "works-on": info.get("works-on", ""),
            }
        )
    return rows


def render_bucket_section(bucket: str, rows: list[dict]) -> str:
    """Render one bucket as a markdown section."""
    blurb = BUCKET_BLURB.get(bucket, "")
    out = [f"### `{bucket}/`: {len(rows)} program{'s' if len(rows) != 1 else ''}", ""]
    if blurb:
        out += [blurb, ""]
    if not rows:
        out.append("_No programs in this bucket._")
        out.append("")
        return "\n".join(out)

    # Per-source breakdown for context.
    by_src = Counter(r["source"] for r in rows)
    src_str = ", ".join(f"`{s}`={n}" for s, n in by_src.most_common())
    out.append(f"By source corpus: {src_str}")
    out.append("")

    # If `needs` is informative (not empty everywhere), surface a top-N.
    needs_counter = Counter()
    for r in rows:
        if r["needs"]:
            for n in r["needs"].split(","):
                n = n.strip()
                if n:
                    needs_counter[n] += 1
    if needs_counter:
        top = ", ".join(f"`{k}`×{v}" for k, v in needs_counter.most_common(8))
        out.append(f"Top requirements: {top}")
        out.append("")

    # Compact program list — first 30, then "+N more".
    PREVIEW = 30
    sample = rows[:PREVIEW]
    out.append("Programs (first " + str(min(PREVIEW, len(rows))) + "):")
    out.append("")
    out.append(", ".join(f"`{r['name']}`" for r in sample))
    if len(rows) > PREVIEW:
        out.append("")
        out.append(
            f"_…and {len(rows) - PREVIEW} more; see `golden-programs/{bucket}/`._"
        )
    out.append("")
    return "\n".join(out)


def render(buckets: dict[str, list[dict]]) -> str:
    total = sum(len(v) for v in buckets.values())
    works = len(buckets.get("works", []))
    native = len(buckets.get("works-native-only", []))
    pct_works = works * 100 / total if total else 0
    pct_runnable_native = (works + native) * 100 / total if total else 0

    out = [
        "# What works on petitpy",
        "",
        (
            "_Auto-generated from `golden-programs/` by `tools/gen_compatibility.py`. "
            "Don't edit by hand; re-run `make compatibility` after changing "
            "the bucket assignments._"
        ),
        "",
        (
            'This page answers **"does my program work on petitpy?"** for a collection of '
            "real programs taken from MicroPython's tests, CPython's tests, PEP examples "
            "and project demos. [ADR 008](adrs/008-golden-programs.md) explains the buckets."
        ),
        "",
        "## Headline",
        "",
        f"- **{works} / {total} programs ({pct_works:.1f}%) run on both native AND wasm.**",
        f"- **{works + native} / {total} ({pct_runnable_native:.1f}%) run on native (incl. native-only).**",
        f"- The remaining {total - works - native} programs are bucketed by what they need; see below.",
        "",
        "## How to read this",
        "",
        (
            "Each bucket names what its programs need. `make check` and `make wasm-check` "
            "run the programs in `works/` on every build."
        ),
        "",
        "## The buckets",
        "",
    ]
    for bucket in BUCKET_ORDER:
        rows = buckets.get(bucket, [])
        out.append(render_bucket_section(bucket, rows))
    return "\n".join(out) + "\n"


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument(
        "-o",
        "--output",
        default="docs/src/COMPATIBILITY.md",
        help="output path (default: docs/src/COMPATIBILITY.md)",
    )
    args = p.parse_args()

    if not GP.exists():
        print("golden-programs/ missing — run `make golden` first", file=sys.stderr)
        return 1

    buckets = {b: collect_bucket(b) for b in BUCKET_ORDER}
    out_text = render(buckets)
    out_path = ROOT / args.output
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(out_text, encoding="utf-8")

    total = sum(len(v) for v in buckets.values())
    works = len(buckets.get("works", []))
    print(
        f"wrote {out_path} ({total} programs across {len(buckets)} buckets; "
        f"{works} in works/)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
