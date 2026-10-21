# Getting Started

Three audience-routed entry points. Pick the one closest to your case.

- [For web developers](#for-web-developers): Python in the browser
- [For embedded and systems developers](#for-embedded-and-systems-developers): small native Python
- [For contributors](#for-contributors): clone, build, test the full stack

The cross-cutting [Prerequisites](#prerequisites) section is at the bottom.

---

## For web developers

You're here because you want to run Python in a browser tab without 30 MB of Pyodide. The shipping artifact is `web/nanopython.wasm` (346 KB raw, post-`wasm-opt -Oz`; 166 KB gzipped). It boots in well under a second on a typical connection and can drive the DOM directly via a `js` module.

### Five minutes: try the bundled demos

```sh
git clone <repo> && cd nanopython
make port               # one-time: regenerate vendor/
make web                # build wasm + run wasm-opt; writes web/nanopython.wasm

cd web && python3 -m http.server 8000
# Open http://localhost:8000/playground/
```

The bundled demos under `web/`:

| Demo | What it shows |
|---|---|
| `playground/` | Python REPL in the browser, with a script library backed by `localStorage` |
| `life/` | Conway's Game of Life: DOM events + canvas updates driven from Python via the `js` module |
| `dashboard/` | Live dashboard with `setInterval`-driven Python computation |
| `simulation/` | Particle simulator in pure Python, rendering to a `<canvas>` |
| `snippets/`, `validation/` | Smaller examples (string ops, form validation) |

### Thirty minutes: write your own page

The `js` module ([ADR 006](adrs/006-js-interop.md)) gives Python code direct DOM access via a synchronous host-call bridge:

```python
import js

doc = js.document
btn = doc.getElementById("go")
btn.addEventListener("click", lambda e: js.alert("hello from Python!"))
```

The bridge wiring lives in `web/lib/js-bridge.js` and `web/lib/loader.js`; copy one of the bundled demos as a starting template, swap in your Python code, and serve.

### What you can write today

| ✓ Works | ✗ Out of scope today |
|---|---|
| Floats, dicts, classes, generators, comprehensions, f-strings, walrus, `match` | `eval()` / `exec()` / `compile()` from user code (vendor longjmp wall, ADR 010 §3) |
| All common builtins, `try`/`except`/`finally` | `2**100` overflows: wasm uses 64-bit `LONGLONG`, without MPZ |
| `import json` / `heapq` / `bisect` / `random` / `collections` / `functools` / `types` (pure-Python frozen-tiny) | Multiple inheritance |
| `import js` for DOM access | `async`/`await` runtime |
| `gc` module surface | File I/O (`open()`) |

Per-program coverage of 823 curated real-world Python programs in [`COMPATIBILITY.md`](COMPATIBILITY.md).

### Going further

- For DOM patterns beyond what the bundled demos show, the `js-bridge.js` source is well-commented.
- Cold-load measurements (parse + instantiate + first print) are recorded via `make metrics-record` if you want to track changes to your own page.

---

## For embedded and systems developers

You're here because you want a small Python binary you can ship on a Linux/macOS system, embed in a Zig project, or trim down to fit a flash budget. Per-feature build flags let you cut the runtime down to the slice your use case needs, and the nano build matches MicroPython's output byte for byte on all 541 tests of MicroPython's basic suite.

### Build a native binary

```sh
git clone <repo> && cd nanopython
make port            # one-time: regenerate vendor/
make build           # Debug native binary at zig-out/bin/nanopython (3.9 MB)
make build-release   # ReleaseFast (~1150 KB)
make build-small     # ReleaseSmall (~541 KB; ~475 KB with -Dconfig=nano) — the smallest native shipping size
```

### Run a program

```sh
./zig-out/bin/nanopython examples/fizzbuzz.py
echo 'print(2**10)' | ./zig-out/bin/nanopython /dev/stdin
./zig-out/bin/nanopython                              # interactive REPL (Ctrl-D to exit)
```

### Verify the build

```sh
make check       # native byte-exact corpus — reports 541/541
```

Anything less is a regression; `make verify` names the failing test. See [Contributing](contributing.md) for the regression-localization workflow.

### Per-feature builds: pick exactly what you ship

The build is decomposed into orthogonal feature flags ([ADR 002](adrs/002-feature-selection.md)). Each flag toggles one builtin module independently of the others.

```sh
# Example: ship only the language core + math, no struct/array/collections
zig build -Doptimize=ReleaseSmall \
          -Dfeature-collections=false \
          -Dfeature-struct=false \
          -Dfeature-array=false
```

| Flag | What it controls | Default (nano) |
|---|---|---|
| `-Dfeature-math` | `math` module | on |
| `-Dfeature-warning` | the warning subsystem | off |
| `-Dfeature-collections` | `collections` (namedtuple, OrderedDict, deque) | on |
| `-Dfeature-struct` | `struct` (binary pack/unpack) | on |
| `-Dfeature-array` | `array.array` | on |
| `-Dfeature-errno` | `errno` constants | on |
| `-Dfeature-micropython` | `micropython` module (heap_lock, opt_level) | on |
| `-Dfeature-gc-module` | `gc` module surface | on |
| `-Dfeature-js` | JS interop bridge (forced off for non-wasm) | wasm only |

Flipping a flag away from its preset default emits a build-time warning that the corpus invariant won't be enforced for that build: the byte-exact `make check` is calibrated against the default nano slice.

### Cross-compile

Zig's cross-compilation works without extra toolchains. The Linux ELFs are produced from a macOS host equally well:

```sh
zig build -Dtarget=x86_64-linux-gnu  -Doptimize=ReleaseSmall   # → ELF
zig build -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSmall   # → ELF
zig build -Dtarget=x86_64-macos      -Doptimize=ReleaseSmall   # → Mach-O
zig build -Dtarget=wasm32-wasi       -Doptimize=ReleaseSmall   # → .wasm
```

### When you need more than nano ships

- **MPZ arbitrary-precision ints (`2**100` etc.):** build with `-Dconfig=full`.
- **`io` module + `open()` + filesystem-backed scripts:** build with `-Dconfig=full`.
- **Real microcontroller ports (STM32, ESP32, RP2040, etc.):** use upstream MicroPython. Bare-metal targets are out of scope here.

The trade with `-Dconfig=full` is that the binary pulls in additional vendor C carveouts (MPZ, IO, complex, builtin_help, warning) for the parity surface. That count is a soft target; the strict 541/541 invariant belongs to the nano arm.

### Embedding in a Zig project

The compile + execute entry point is a stable Zig export: `npy_zig_compile_source(src: [*:0]const u8) → c_int`. Link `petitpy` as a library and call it directly. See [vs MicroPython](comparison-micropython.md) for the precise compatibility statement.

---

## For contributors

You're here because you want to understand or improve the runtime itself. The runtime was moved into Zig module by module, building on MicroPython's C, under a byte-exact differential test corpus.

### Five-minute orientation

```sh
git clone <repo> && cd nanopython
make port            # one-time: regenerate vendor/
make                 # the aggregate gate (4 test gates + lint, both arms) — ~37s
```

`make` is the "I'm about to commit" gate. It runs four independent test gates (corpus native, corpus wasm, integration native, integration wasm) plus lint plus build. Each gate answers a different question; [Build & Test](build-and-test.md) has the breakdown.

### The test pyramid

```sh
make test                    # native-only test pyramid (faster, used while iterating)
make check                   # native byte-exact corpus gate
make verify                  # same, but lists each failing test
make wasm-check              # wasm corpus + baseline regression detector (strict both ways)
make test-integration        # 37 hand-written cases, native
make test-integration-wasm   # 37 hand-written cases, wasm via wasmtime
make test-unit               # Zig unit tests for the compiler + VM tracks
make test-coverage           # kcov-driven coverage reports → coverage/
```

### Code orientation

| Path | What |
|---|---|
| `src/compiler/` | Pure-Zig lexer, parser, scope, bytecode emit; also ships as the `zigpy-compile` standalone tool |
| `src/runtime/` | VM dispatch, error propagation, allocator, GC |
| `src/objects/` | Type implementations (str, list, dict, int, …) |
| `src/modules/` | Builtin modules (sys, math, gc, …) |
| `src/mp_mirrors.zig` | Zig types mirroring vendor MicroPython C structs (~40 `extern struct` declarations) |
| `src/pyerr.zig` | `PyError!T` error union + polled-sentinel bridge |
| `nanopython-lib/` | Pure-Python frozen-tiny stdlib (json, heapq, bisect, etc.) |
| `port/mpconfigport.h` | The two MicroPython config arms (nano + full) |
| `corpus/nano/basics/` | 541 byte-exact frozen goldens for native |
| `golden-programs/` | 823 real-world Python programs bucketed by what they need |
| `tests/integration.py` | 37 hand-written integration cases, runner-pluggable |
| `tools/` | `corpus.py`, `metrics.py`, `wasm_gate.py`, `gen_compatibility.py`, … |

### Read these first

| Document | Purpose |
|---|---|
| [`docs/src/adrs/`](adrs/index.md) | Architecture decision records; [ADR 010](adrs/010-roadmap-v06.md) is the current roadmap |

### Your first change

1. Pick something small: a new `str` method, a builtin function, a `collections` helper. The v0.5 changelog has working examples (str.ljust/rjust/isalnum, full-Unicode `chr()`, `collections.deque`).
2. Add the implementation in the appropriate `src/objects/*.zig` or `src/modules/*.zig`.
3. Add at least one regression pin in `tests/integration.py` so the fix can't silently regress.
4. Run `make`. Green = commit. Red = debug.

The complete workflow + conventions are in [Contributing](contributing.md).

---

## Prerequisites

| Tool | Version | Notes |
|---|---|---|
| [Zig](https://ziglang.org/) | 0.16.0 | Newer versions may work; the build script targets 0.16's `std.Build` API |
| Python 3 | 3.9+ | for the test runners (`tools/*.py`) |
| GNU Make | any | for the top-level Makefile |
| `git` | any | the project assumes a git checkout |
| Upstream MicroPython | matching `embed.mk` API | symlinked at `sandbox/micropython` (gitignored) |
| [wasmtime](https://wasmtime.dev/) | any recent | for running the wasm binary locally |
| [binaryen](https://github.com/WebAssembly/binaryen) | any recent | for `wasm-opt -Oz` (optional; `make web` degrades gracefully without it) |

The MicroPython symlink feeds `make port`, which regenerates `vendor/micropython_embed/`. It's gitignored because it points outside the project tree. If you don't have a checkout:

```sh
make bootstrap   # clones sandbox/micropython at the pinned revision
make port
```

Prefer `make bootstrap` to cloning by hand. The tree must sit at the revision `MICROPY_REV` names in the Makefile, because `src/compiler/qstr.zig`'s `N_MAIN` / `N_STATIC` counts and the corpus goldens are calibrated against it. A checkout at upstream `master` regenerates a different `vendor/` and fails the build with a qstr count-drift `@compileError` or an undefined vendor symbol. To point at an existing clone, check it out first:

```sh
git -C ~/micropython checkout $(sed -n 's/^MICROPY_REV := *//p' Makefile)
ln -s ~/micropython sandbox/micropython
make port
```

### Common issues

**`make port` fails with "sandbox/micropython not found":** create the symlink as above.

**`make` reports < 541/541 on a fresh checkout:** likely a Zig version mismatch, a stale `vendor/`, or a `sandbox/micropython` that isn't at `MICROPY_REV`. Try `make rebuild`.

**Build fails with "qstrdefs.generated.h QDEF1 count drift" or an undefined `mp_obj_*` symbol:** `sandbox/micropython` is at the wrong revision. Check it out at `MICROPY_REV` and re-run `make port`.

**`make wasm` builds, but `wasmtime web/nanopython.wasm` errors:** check that `wasmtime` is on the path and recent enough to support the `wasi_snapshot_preview1` ABI.

**Debug build is 3.9 MB:** expected. Zig's Debug mode keeps every function alive and emits DWARF for nice panic traces. Use `make build-small` for the shipping size.

**Cold first build takes 1-2 minutes:** Zig has to compile + link a chunk of vendor C the first time. Incremental builds are seconds.

## Where things live

| Path | What |
|---|---|
| `zig-out/bin/nanopython` | The interpreter (Debug or Release) |
| `zig-out/bin/zigpy-compile` | Standalone `.py` → `.mpy` compiler |
| `zig-out/bin/mpy-roundtrip` | `.mpy` round-trip test tool |
| `web/nanopython.wasm` | The shipping wasm artifact |
| `.zig-cache/` | Zig's build cache (regenerable, safe to delete) |
| `vendor/micropython_embed/` | Generated MicroPython C package (via `make port`) |
| `metrics/history.ndjson` | Append-only size/coverage/perf history (via `make metrics-record`) |
| `coverage/` | Generated coverage reports (via `make test-coverage`) |

All generated directories are gitignored.
