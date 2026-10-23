# petitpy

petitpy is a small Python interpreter written in [Zig](https://ziglang.org/), for two places where CPython is too heavy. In the browser, it is a 352 KB wasm module that drives the DOM from Python. On native Linux or macOS, a 6.7 KLOC system daemon runs on it in 4 MB of memory instead of CPython's 17 MB. It speaks more of CPython's language than its small size suggests: Unicode strings, `match`, exception chaining, dataclasses, and an everyday stdlib with `pathlib`, `json`, `logging`, `subprocess` and `unittest.mock`. It installs with `pip` or `npm`, as **petitpy**, with `ppy` as the short command.

petitpy builds on [MicroPython](https://micropython.org/): it shares MicroPython's `.mpy` bytecode format and much of its design, and uses MicroPython's test suite as a conformance check. See [Acknowledgments](#acknowledgments).

```sh
$ petitpy --version
petitpy 0.7.1

$ echo 'print("hello from", 0.1 + 0.2)' | petitpy /dev/stdin
hello from 0.30000000000000004

$ ppy                     # interactive REPL
petitpy 0.7.1 — interactive REPL (Ctrl-D to exit)
>>> def fib(n):
...     return n if n < 2 else fib(n-1) + fib(n-2)
>>> [fib(i) for i in range(10)]
[0, 1, 1, 2, 3, 5, 8, 13, 21, 34]
```

## Install

```sh
uvx petitpy script.py           # run once, no install
uv tool install petitpy         # or pip install petitpy: installs `petitpy` and `ppy`
npm install petitpy             # the browser build, see npm/README.md
```

Prebuilt wheels cover macOS (arm64, x86_64) and Linux (x86_64, aarch64); elsewhere pip builds from the sdist with Zig, in about a minute. This is an alpha: see the [differences from CPython](docs/src/differences.md).

## Who is this for?

Three audiences are served, in priority order:

- **🌐 Web developers**: Python in the browser. The shipping artifact is `web/petitpy.wasm` (352 KB). Direct DOM access via the `js` module ([ADR 006](docs/src/adrs/006-js-interop.md)). See [`docs/src/getting-started.md#for-web-developers`](docs/src/getting-started.md#for-web-developers).
- **🛠️ Embedded + systems developers**: a small native Python for daemons and scripts. Build cross-compiles to arm64/x86_64 macOS/Linux + wasm32-wasi. Per-feature build flags shrink the binary to your use case ([ADR 002](docs/src/adrs/002-feature-selection.md)). See [`docs/src/getting-started.md#for-embedded--systems-developers`](docs/src/getting-started.md#for-embedded--systems-developers).
- **🔧 Contributors**: read [Contributing](docs/src/contributing.md) and the [ADR series](docs/src/adrs/). See [`docs/src/getting-started.md#for-contributors`](docs/src/getting-started.md#for-contributors).

## Status

The runtime works end to end on both native and wasm. Active work is on user experience, language and stdlib reach, size, and speed. The current roadmap is [`docs/src/adrs/010-roadmap-v06.md`](docs/src/adrs/010-roadmap-v06.md) (009 is the previous cycle).

| Headline | Value |
|---|---|
| Native corpus, nano (byte-exact vs. MicroPython's test outputs) | **541/541**, held |
| Native corpus, full | **545/552**, 7 documented known-fails |
| WASM corpus (under wasmtime) | **536/541**, baseline + skip list green |
| Integration smoke (native + wasm, hand-written) | **202/202** on both arms |
| Real-world Python programs that work on both arms | **580** in `golden-programs/works/`; see [`docs/src/COMPATIBILITY.md`](docs/src/COMPATIBILITY.md) for the bucket-by-bucket breakdown |
| wasm32-wasi shipping size (`web/petitpy.wasm`) | **352 KB** (post-`wasm-opt -Oz`, integrated into `make web`) |
| Native arm64 shipping size (ReleaseFast) | **1170 KB** |

## Gate state

The harness has four independent gates plus an aggregate. Each answers a different question, and none substitutes for another. See [Build & Test](docs/src/build-and-test.md) for the full breakdown.

| Gate | What it answers | Result |
|---|---|---|
| `make check` | Does the full-arm binary match the corpus minus its documented baseline? | **545/552**, green |
| `make check CONFIG=nano` | Does the nano binary match the frozen MicroPython reference byte-exact? | **541/541**, invariant |
| `make wasm-check` | Does the wasm binary match the corpus minus the documented wasm baseline? | **GREEN** at 536/541 (5-test known-fails baseline matches exactly) |
| `make test-integration` | Does the native binary actually start up and run real Python? | **189/189** |
| `make test-integration-wasm` | Same question, against the wasm binary via wasmtime. | **202/202** |
| `make check-capability` | Do both front-ends and both back-ends agree on 67 language constructs? | **GREEN**, 0 gaps; not in the aggregate (needs vendor MicroPython + uv) |
| `make` (the aggregate) | Runs all of the above bar the last, both arms. The "I'm about to commit" gate. | exit 0 |

## Quick start

Needs [Zig 0.16](https://ziglang.org/) and [wasmtime](https://wasmtime.dev/) (for running wasm locally). A MicroPython source tree is required at `vendor/micropython`; if it's missing, `make port` (and everything downstream: `make build`, `make check`, …) will run `make bootstrap`, cloning MicroPython at the pinned `MICROPY_REV` into that path on first use. If you already keep MicroPython checked out elsewhere, symlink it at `vendor/micropython` before the first build to skip the auto-clone.

```sh
make build               # Debug native binary → zig-out/bin/petitpy
make build-small         # ReleaseSmall native (development companion)
make web                 # production wasm → web/petitpy.wasm

make                     # the aggregate gate (all 4 + lint, both arms)
make test                # native-only test pyramid (faster)
make check               # native byte-exact corpus only
make wasm-check          # wasm gate against the corpus baseline

make metrics-record      # snapshot size + coverage to metrics/history.ndjson
make metrics-report      # print recent rows as a trend table
make help                # list all targets
```

## Test harness: why four gates

Each gate is small, fast, and answers a question the others can't. The recent float-print signature mismatch (commit `7d5131c` → `571b1d6`) shipped because the wasm corpus had the failing tests on a known-fails list for unrelated reasons. The integration suite was native-only at the time. The fix adds orthogonal gates: under the both-arms integration suite, the float bug would have surfaced at commit time.

- **byte-exact corpus** catches regressions in the Zig front-end + VM + the few remaining vendor C bridges.
- **integration smoke** catches "does the binary actually run real Python": small, hand-written, runs in ~1 s, regression-pin cases for every wasm-only bug we've shipped.
- **integration-wasm** is the same suite via wasmtime; it would have caught the float bug atomically at commit time.
- **golden-programs** ([ADR 008](docs/src/adrs/008-golden-programs.md)) is the **strategic** signal: 756 real Python programs sourced from MicroPython's tests, CPython's tests, PEP examples, and curated demos, bucketed by what they need.

## Binary size

All measurements were taken on macOS arm64. wasm and native are co-primary distributions; both ship.

| Build | Size | Notes |
|---|---|---|
| **wasm32-wasi `make web`** | **352 KB** | the shipping artifact (ReleaseSmall + frozen-tiny + post-`wasm-opt -Oz`); [ADR 007 §4 P6](docs/src/adrs/007-wasm-fat-loss.md) wires the optimizer into the release pipeline |
| wasm32-wasi raw (pre-optimizer) | 384 KB | what `zig build` produces before `wasm-opt`, for inspection |
| native `make build` (Debug) | 3.9 MB | dev default (`full` profile), with DWARF symbols and no DCE |
| native `make build-release` (ReleaseFast) | 1170 KB | inlined, full optimization (`full` profile) |
| native `make build-small` (ReleaseSmall) | 558 KB `full`, 492 KB `nano` | smallest native: the same arm with `-Doptimize=ReleaseSmall` |
| upstream MicroPython unix-standard | 652 KB | their default, a feature superset of nano |

The wasm size is the metric that matters most: raw bytes drive both parse time and download cost. Trends are tracked over time in `metrics/history.ndjson` ([`tools/metrics.py`](tools/metrics.py)).

## What works

**Core types**: `int` (arbitrary precision on native `full` and on wasm32; 63-bit small on native `nano`), `float` (IEEE 754 double), `str` (Unicode code points), `bytes`, `bytearray`, `bool`, `None`, `list`, `tuple`, `dict`, `set`, `frozenset`, `range` (with `start`/`stop`/`step` attributes and `[a:b]` slicing), `slice`, `memoryview`, `array.array`.

**Control flow + classes**: full `try`/`except`/`finally`/`raise`, generators with `.send()`/`.throw()`/`.close()`, walrus (`:=`), `match` statements (literals, singletons, captures, or-patterns, sequences with `*rest`, mappings, class patterns, `as`, guards; vendor MicroPython parses none of it), all comprehensions, `async def` coroutines; classes with single and multiple inheritance, descriptors, properties, all dunder methods including `__getitem__` override on `dict` subclasses.

**Strings**: f-strings, `%`-formatting (`%d`/`%f`/`%s`/`%r`), `.format()`, all `str.*` methods including `.title()`, `.center(width, fillchar)`, `.zfill(n)`, named-field formatting on tuples, bytes ↔ bytearray interop everywhere it matters.

**Modules**: `sys`, `math` (including `hypot` and `gcd`), `errno`, `struct`, `gc`, `micropython`, `array`. Plus pure-Python `_thread`, `js`, `json`, `types`, `heapq`, `bisect`, `functools`, `itertools` (including `permutations`, `combinations`, `product`, `groupby`, `zip_longest`), `collections` (with `Counter` and `defaultdict`), `random`, `re`, `string`, `typing`, `datetime`, `pathlib`, `enum`, all frozen-tiny ([ADR 003](docs/src/adrs/003-library-and-module-loading.md)). Native `full` adds `os` (with `os.path`), `time`, `socket`, `select`, `signal`, `subprocess`, `open()` and file I/O.

**Directives**: `from __future__ import ...` is consumed by the compiler and emits nothing, as CPython does. There is no `__future__` module to import; vendor MicroPython raises `ImportError` for the whole statement.

**Process semantics**: `petitpy script.py` and `petitpy -c CODE`; uncaught exceptions exit 1 (not 0); `sys.exit(N)` propagates correctly; SystemExit with no arg or None exits 0.

**Embedding** (experimental): a C API, `petitpy.h`, over a static library, `libpetitpy.a`, to run Python inside another program: values cross as handles, host functions are callable from Python, and errors come back as statuses. See [`docs/src/embedding.md`](docs/src/embedding.md).

## What doesn't work yet

The full list, by build, is [Differences from CPython](docs/src/differences.md). Tracked by bucket in `golden-programs/`. The headline gaps:

- **Arbitrary-precision ints on native `nano`**: `2**100` raises `OverflowError` (63-bit small ints).
- **`asyncio`**: coroutines run, but there is no event loop module.
- **Float literals in the browser build** can parse one ulp off with 17 significant digits (vendor's parser, kept for size); native parses them correctly rounded.
- **Complex literals**: `2j` fails to compile, although `full` has the complex type.
- **`open()` and file I/O on `nano`**: no HAL; wasm sees stdout/stderr via WASI.
- **Insertion-ordered dicts on `nano` and wasm**: a `dict` iterates in hash order, as in MicroPython (`list({"b": 1, "a": 2})` is `['a', 'b']`). `full` keeps insertion order.
- Implicit exception chaining (`__context__`; `raise ... from` works).
- **Unicode case mapping**: `upper()`/`lower()` change ASCII letters only, as in MicroPython.
- Threading.

## Documentation

| Document | Purpose |
|---|---|
| [`docs/src/adrs/`](docs/src/adrs/) | Architecture Decision Records; [`010-roadmap-v06.md`](docs/src/adrs/010-roadmap-v06.md) is the next-step plan |
| [`docs/src/case-study-daemon.md`](docs/src/case-study-daemon.md) | Case study: running hop3-rootd (6.7 KLOC Linux daemon) under petitpy: tests, memory, disk and speed vs CPython 3.11 |

Built docs live under `docs/`. Render via [Zensical](https://zensical.org/):

```sh
make doc-setup       # one-time: pip install zensical
make doc-serve       # dev server with live reload at http://localhost:8000
make doc-build       # render to ./site/ (gitignored)
```

## Layout

| Path | What |
|---|---|
| `src/*.zig` | Zig subsystems + `main.zig` entry point |
| `src/runtime/`, `src/objects/`, `src/modules/`, `src/memory/` | VM track |
| `src/compiler/`, `src/frontend/` | Compiler track |
| `src/mp_mirrors.zig` | Type mirrors for vendor MicroPython C structs |
| `src/pyerr.zig` | `PyError!T` error union + polled-sentinel bridge |
| `build.zig` | Build script; explicit per-arm `addCSourceFiles` lists drive vendor C inclusion |
| `port/` | `mpconfigport.h` (nano + full arms) + Makefile generating the embed package |
| `petitpy-lib/` | Pure-Python frozen-tiny stdlib modules |
| `tools/` | Build, test, metrics scripts (`corpus.py`, `progress.py`, `wasm_gate.py`, `metrics.py`) |
| `tests/integration.py` | 189-case integration smoke (runs against any binary via `--runner`) |
| `benchmarks/`, `sandbox/p2w/programs/benchmarks/` | Benchmark programs (used by `tools/metrics.py`) |
| `corpus/nano/basics/` | Frozen byte-exact goldens for native |
| `corpus/wasm-known-fails.txt` | Documented expected wasm failures (51 today) |
| `golden-programs/` | 756 real Python programs bucketed by what they need ([ADR 008](docs/src/adrs/008-golden-programs.md)) |
| `metrics/history.ndjson` | Append-only size/coverage/perf history |
| `web/` | Browser demos + shipping wasm artifact |
| `docs/` | User-facing documentation (Zensical) |
| `examples/` | Small runnable example programs |

## Acknowledgments

petitpy would not exist without [MicroPython](https://micropython.org/), by Damien P. George and its contributors. Its design showed that a complete, small Python is possible. petitpy's Zig runtime builds on its C code and its design, and its test suite still checks petitpy on every commit. Its `.mpy` bytecode format is still petitpy's, so the compilers of both projects produce code that runs on either. A little of its C remains, for floats, `re` and, on some builds, big integers. Thank you.

## License

MIT, shared with MicroPython, on which petitpy builds. The `heapq`, `bisect` and `types` modules come from micropython-lib, which derives them from CPython, and are under the Python license. Both texts are in [`LICENSE`](LICENSE).
