#!/usr/bin/env python3
"""ADR-003 L2 — frozen-tiny module compiler.

Walks the frozen-tiny module list, locates each module's `.py` source
(in `petitpy-lib/`), and compiles it to
`.mpy` via `./zig-out/bin/zigpy-compile`. Output lands in `build-frozen/`.

Driven by `make freeze`. After this runs, `zig build -Dfrozen-tiny=true`
bakes the bytes into the petitpy binary via `@embedFile`.

The module list is hard-coded here for L1+L2. It will move to
`frozen.zon` or an equivalent build-time data file when the set grows.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

# Top-level repo root = parent of this tools/ directory.
ROOT = Path(__file__).resolve().parent.parent
ZIGPY_COMPILE = ROOT / "zig-out" / "bin" / "zigpy-compile"
OUT_DIR = ROOT / "build-frozen"


# (module_name, relative_path_from_root) — order matches the table in
# src/runtime/frozen_modules.zig. Sources picked for L1+L2:
#
#   json       — petitpy-lib (micropython-lib has no python-stdlib json;
#                upstream MicroPython exposes json as a C extension module).
#                See ADR-003 §D1 — local additions go under petitpy-lib/.
#   types      — petitpy-lib/types.py, a verbatim copy from micropython-lib.
#   __future__ — REMOVED. `from __future__ import …` is a directive, not an
#                import, and compile.zig consumes the statement now, so the
#                module was only carrying `import __future__` and attribute
#                introspection — which nothing here does. Put it back from
#                micropython-lib if that changes.
#   _thread    — petitpy-lib stub (single-thread runtime). Many stdlib
#                modules import it conditionally; the stub keeps those
#                imports working. ADR-003 §D6.
MODULES = [
    ("json", "petitpy-lib/json.py"),
    ("types", "petitpy-lib/types.py"),
    ("_thread", "petitpy-lib/_thread.py"),
    # ADR-006 J2/Q4 — JS interop Python front. The frozen .mpy is baked
    # into every binary (size impact ~2-3 KB compiled); whether `import
    # js` succeeds depends on the runtime having the `_petitpy_js`
    # builtin (-Dfeature-js=true at build time).
    ("js", "petitpy-lib/js.py"),
    # Algorithm/data-science stdlib slice — the modules ~200 programs
    # in golden-programs/needs-stdlib/ depend on. heapq, bisect,
    # functools have no upstream deps and copy straight from
    # micropython-lib (heapq and bisect verbatim, see ADR-003 §D7). collections does `from ucollections import *`
    # and ucollections is always live under nano (PY_COLLECTIONS=1).
    # random is a local pure-Python LCG — micropython-lib's relies
    # on `urandom` which we don't ship.
    ("heapq", "petitpy-lib/heapq.py"),
    ("bisect", "petitpy-lib/bisect.py"),
    # petitpy-lib supersedes vendor: adds lru_cache + cache on top of
    # partial/wraps/reduce. tests/stdlib/test_functools.py pins the full
    # surface (ADR 011 Phase 2). The vendor file has only 4 functions.
    ("functools", "petitpy-lib/functools.py"),
    ("collections", "petitpy-lib/collections/__init__.py"),
    # collections.abc — dotted-name frozen entry. The import machinery's
    # frozen lookup was extended to try the full dotted name (not just
    # the current level), so `from collections.abc import Callable`
    # resolves. Surfaced by tools/hop3_rootd_smoke.py (finding A.1).
    ("collections.abc", "petitpy-lib/collections/abc.py"),
    ("random", "petitpy-lib/random.py"),
    # petitpy-lib supersedes vendor: micropython-lib's itertools plus
    # permutations, combinations, product, groupby, zip_longest and the
    # other CPython functions it lacks, and a tee() whose copies are
    # independent. No external deps.
    ("itertools", "petitpy-lib/itertools.py"),
    # ADR 010 §A3a slice 2 — string (ctype constants + list-based
    # translate + capwords). Adapted from micropython-lib (the upstream
    # translate uses io.StringIO which is full-only). ~40 LOC compiled
    # to <1 KB. No external deps.
    ("string", "petitpy-lib/string.py"),
    # petitpy-lib/re.py — thin shim that adds CPython flag constants
    # (IGNORECASE / DOTALL / MULTILINE / VERBOSE) to the C-side `ure`
    # module. Vendor re1.5 doesn't honor these flags; the shim lets
    # CPython idioms like `re.compile(pat, re.IGNORECASE)` import and
    # run (case-sensitive under the hood). Registered as `re` — wins
    # over the extensible C `re` per MicroPython's search order.
    # Surfaced by tools/hop3_rootd_smoke.py (finding A.2).
    ("re", "petitpy-lib/re.py"),
    # petitpy-lib/subprocess.py — Python wrapper on top of the C-side
    # low-level `_subprocess._spawn_and_wait` primitive. Exposes
    # CompletedProcess, CalledProcessError, TimeoutExpired, and the
    # kwargs-accepting run() function.
    ("subprocess", "petitpy-lib/subprocess.py"),
    # Pure-Python shims.
    ("typing", "petitpy-lib/typing.py"),
    ("uuid", "petitpy-lib/uuid.py"),
    ("shutil", "petitpy-lib/shutil.py"),
    ("pathlib", "petitpy-lib/pathlib.py"),
    ("datetime", "petitpy-lib/datetime.py"),
    # Dotted-name entries — resolved via the frozen full-name lookup in
    # runtime/import_search.zig (works for both `import pkg.sub` and
    # `from pkg import sub`).
    ("importlib", "petitpy-lib/importlib/__init__.py"),
    ("importlib.metadata", "petitpy-lib/importlib/metadata.py"),
    # enum — @enum decorator (real member semantics) + Enum/IntEnum/StrEnum
    # base-class stubs so CPython `class X(str, Enum):` idiom parses. See
    # module docstring for the (deliberate) semantic mismatch under
    # subclass form. Unblocks hop3-rootd's protocol.ErrorCode (finding A.10).
    ("enum", "petitpy-lib/enum.py"),
    # ipaddress — minimal PEP 3144 subset for CIDR validation.
    # hop3-rootd's validation.py imports it for IPv4Address/IPv4Network
    # isinstance checks + ip_network(strict=False). IPv6 stored as 8-group
    # tuple so this imports under nano (no bignum).
    ("ipaddress", "petitpy-lib/ipaddress.py"),
    # os.path — deferred. Needs a mutable os globals dict so
    # mp_store_attr(os, "path", …) can wire the loaded submodule as an
    # attribute; the current fixed-ROM dict rejects the store. Requires
    # MICROPY_MODULE_BUILTIN_INIT + a runtime-allocated globals dict.
    # File petitpy-lib/os_path.py stays as reference implementation.
]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Compile frozen-tiny .py to .mpy")
    parser.add_argument(
        "--zigpy-compile",
        type=Path,
        default=ZIGPY_COMPILE,
        help="path to zigpy-compile binary (default: zig-out/bin/zigpy-compile)",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=OUT_DIR,
        help="output directory (default: build-frozen/)",
    )
    args = parser.parse_args(argv)

    if not args.zigpy_compile.exists():
        print(
            f"error: {args.zigpy_compile} not found.\n"
            f"  Build it first: `zig build` (the zigpy-compile artifact is installed by default)",
            file=sys.stderr,
        )
        return 2

    args.out_dir.mkdir(parents=True, exist_ok=True)

    total_bytes = 0
    for modname, relpath in MODULES:
        src = ROOT / relpath
        if not src.exists():
            print(f"error: source {src} not found", file=sys.stderr)
            return 2
        out = args.out_dir / f"{modname}.mpy"
        cmd = [
            str(args.zigpy_compile),
            str(src),
            "-s",
            f"{modname}.py",
            "-o",
            str(out),
        ]
        print(f"  freeze {modname:10s} <- {relpath}")
        result = subprocess.run(cmd, capture_output=True, text=True, check=False)
        if result.returncode != 0:
            print(f"error: compile failed for {modname}:", file=sys.stderr)
            print(result.stdout, file=sys.stderr)
            print(result.stderr, file=sys.stderr)
            return 1
        size = out.stat().st_size
        total_bytes += size
        print(f"           -> {out.relative_to(ROOT)} ({size} bytes)")

    # Concatenate the per-module .mpy files into a single blob and
    # emit a small generated Zig index. Downstream this collapses
    # build.zig's 25 addAnonymousImport calls to 2, and the resulting
    # zig build-exe cmdline's `--dep frozen_X_mpy` + `-Mfrozen_X_mpy=…`
    # pairs (× 25) to just two.
    bundle_path = args.out_dir / "frozen-bundle.bin"
    index_path = args.out_dir / "frozen-index.zig"

    offsets: list[tuple[str, int, int]] = []
    with bundle_path.open("wb") as bundle:
        for modname, _ in MODULES:
            mpy_path = args.out_dir / f"{modname}.mpy"
            data = mpy_path.read_bytes()
            off = bundle.tell()
            bundle.write(data)
            offsets.append((modname, off, len(data)))

    lines = [
        "// AUTO-GENERATED by tools/freeze_modules.py — do not edit.",
        "//",
        "// Single-blob frozen-tiny index: instead of one anonymous Zig",
        "// import per .mpy file (25+ --dep + -M pairs on the zig",
        "// build-exe cmdline), all .mpy bytes concatenate into",
        "// frozen-bundle.bin and get referenced here via comptime",
        "// slices. build.zig adds two imports (frozen_bundle,",
        "// frozen_index); src/runtime/frozen_modules.zig picks up",
        "// `table` from here.",
        "",
        'const bundle = @embedFile("frozen_bundle");',
        "",
        "pub const table = [_]struct { name: []const u8, bytes: []const u8 }{",
    ]
    for name, off, size in offsets:
        lines.append(
            f'    .{{ .name = "{name}", .bytes = bundle[{off}..{off + size}] }},'
        )
    lines.append("};")
    lines.append("")
    index_path.write_text("\n".join(lines))

    print(f"\nfrozen-tiny total: {total_bytes} bytes across {len(MODULES)} modules")
    print(
        f"  bundled: {bundle_path.relative_to(ROOT)} + {index_path.relative_to(ROOT)}"
    )
    print("  next: zig build -Dfrozen-tiny=true (bake bytes via @embedFile)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
