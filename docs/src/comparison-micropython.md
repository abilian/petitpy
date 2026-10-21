# petitpy vs MicroPython

_For embedded and systems developers deciding between the two runtimes for a Linux or macOS native target, an embedded scripting target, or a wasm distribution._

## Quick answer

petitpy builds on MicroPython's design and goes its own way, toward the browser, Linux daemons and more of CPython's language. The single explicit adherence point today is the **bytecode format**: `.mpy` v6, byte-for-byte compatible with upstream. The upstream MicroPython VM runs the output of `zigpy-compile`. Upstream `mpy-cross` output also runs on petitpy. That contract holds for now; a future ADR could break it, and if that happens it will be by explicit decision.

Beyond bytecode, everything is best-effort at best. **No ABI compatibility is provided.** The Zig-side object model, C-mirror struct layouts, and export surface are internal, and reserving the right to change them was part of the design from day one. Do not link against petitpy as if it were a MicroPython replacement at the C level.

Semantic compatibility on user-visible Python behavior tracks the corpus. The nano config is at **541/541** byte-identical against the vendor MicroPython nano reference: an invariant held on every commit. Under the extended `full` config, petitpy ships CPython-friendly variants where the MicroPython-strict behavior was awkward for daemon-style code (CPython-shape `collections.deque`, permissive `re.IGNORECASE`, extended `@dataclass` flags). Those divergences are enumerated below; each one is a decision.

If you're trying to pick between the two runtimes, skip to [When to use petitpy](#when-to-use-petitpy).

## At a glance

| | petitpy 0.7.1 | MicroPython unix-standard |
|---|---|---|
| Source language | Zig + ~2,500 LOC C under a default nano build (616 project-local, ~1,900 vendor via the default-on `float`/`re` carveouts) | C |
| Native binary size (arm64, ReleaseSmall, `full` profile) | ~540 KB | ~650 KB |
| Wasm shipping size | ~346 KB (post-`wasm-opt -Oz`) | n/a natively; upstream ships a JavaScript port via Emscripten |
| Nano corpus byte-identical against vendor reference | 541/541 (held on every commit) | reference by definition |
| Full corpus (extended semantics) | 545/552 (98.7%), 7 documented divergences | n/a (this is petitpy's own target) |
| Wasm corpus | 490/541, 51 documented walls | n/a |
| Compiler standalone tool | `zigpy-compile` | `mpy-cross` |
| Bytecode format | `.mpy` v6, byte-for-byte compatible | `.mpy` v6 |
| C-level ABI compatibility | **not provided** | internal, no external ABI promise either |
| Object representation | REPR_A (tagged `Obj = usize`), internal | REPR_A by default, internal |
| Float support | yes | yes |
| Arbitrary-precision int (MPZ) | under `full` on native; LONGLONG (64-bit) on wasm | optional via `MICROPY_LONGINT_IMPL_MPZ` |
| `os` / `socket` / `select` / `signal` / `subprocess` / `pwd` / `grp` | shipped under `full` (POSIX subset, Linux + macOS) | shipped in `unix-standard` |
| Extended stdlib (`pathlib`, `datetime`, `uuid`, `ipaddress`, `dataclasses`, `pytest_lite`, `unittest.mock`, `logging`) | shipped as pure-Python under `nanopython-lib/` | partial via `micropython-lib` |
| Threading | out of scope | yes (on supporting ports) |
| `async` / `await` | parser yes, runtime deferred | yes |
| Interactive REPL | yes | yes |
| Wasm distribution | co-primary target with 64-bit native; wasm32-wasi today, wasm64 (memory64) strategic | upstream JavaScript port via Emscripten |
| License | MIT (inherited) | MIT |

## What still matches

The bytecode format is the explicit contract. Today `.mpy` v6 files cross-load in both directions. The compiler track's `zigpy-compile` and upstream `mpy-cross` emit semantically equivalent bytecode for the same source; the differential test `tools/compile-exec-test.py` compiles each corpus test with `zigpy-compile` and runs the result through upstream MicroPython's VM to catch subtly-wrong emissions.

The lexer, parser, VM opcode set, and object-model shape follow MicroPython's design and remain broadly similar. The `src/mp_mirrors.zig` file (~43 KLOC) holds `extern struct` mirrors of vendor MicroPython C structs field-for-field, with `@sizeOf` and `@offsetOf` checks, so any vendor `git pull` that shifts a layout fails the build at the right place. This is an internal invariant that keeps the `full` config's vendor-C carveouts (mpz, objint, modio) linking correctly. It is not a public ABI.

## Where petitpy has diverged (by design)

### The bytecode format is the only compatibility promise

Everything below this heading is a divergence petitpy has chosen. The bytecode format is not on the list because it hasn't diverged. Extension-ecosystem compatibility (the `micropython.org/pi/v2` registry, `mip`-compatible install) was aspirational in early ADRs; today the `nanopython-lib/` frozen and on-disk stdlib is written locally for petitpy's shape, and running `mip install`-style workflows unmodified is not tested. Consider it out of scope until it appears as a user request.

### Wasm-first distribution

The shipping artifact is `web/nanopython.wasm` at ~346 KB (post-`wasm-opt -Oz`). The native binary is a first-class distribution too, but the priority is inverted from MicroPython's microcontroller-first stance. This shaped the runtime: MicroPython's `setjmp`/`longjmp`-based NLR was replaced with Zig's `error{PyRaise}!T` error union plus a polled-sentinel bridge, which eliminated the wasm-setjmp dependency entirely. Upstream MicroPython on wasm uses Emscripten's setjmp/longjmp lowering, which works but costs bytes.

### The full-unix profile

Under `full`, petitpy ships C-side `os` / `time` / `socket` / `select` / `signal` / `subprocess` / `pwd` / `grp` covering the POSIX subset that stdlib-only Linux daemons reach for, plus pure-Python `pathlib` (with real `Path` methods), `datetime` (real calendar math), `uuid`, `ipaddress`, `shutil` subset, `unittest.mock`, `logging`, and a `pytest_lite` runner. The [hop3-rootd case study](case-study-daemon.md) runs a real 6 KLOC privileged Linux daemon against this profile; its own 383-test suite runs at ~98% pass under petitpy. Upstream MicroPython's `unix-standard` build has an overlapping but different POSIX subset with different divergences from CPython.

### CPython-friendly divergences on library shape

Where MicroPython-strict behavior made real code awkward, petitpy ships CPython-compatible shapes and documents the divergence:

- `collections.deque` takes an iterable at construction, extends via `append`, and supports the CPython slicing/indexing surface. Upstream MicroPython's `ucollections.deque` is a stricter subset.
- `re.IGNORECASE` is accepted as a no-op flag (matching is still case-sensitive under the hood). Upstream rejects the flag.
- `@dataclass` accepts `frozen`, `slots`, `kw_only`, `order`, `unsafe_hash`, `match_args` with silent semantics for the ones petitpy doesn't fully implement. Upstream `dataclass` is narrower.
- `class Foo(Enum)` subclass form is supported for opaque str-token enums.
- PEP 448 `{**a, **b}` and `[a, *b]` dict/list unpack in more positions. Grammar overlay in `port/grammar-patched/`.
- PEP 570 positional-only `/` marker is grammar-accepted (semantically a no-op, matching MicroPython's stance).

Each of these is documented in the corresponding known-fails file with a rationale. A Python program that would run on upstream MicroPython and depends on the strict behavior (fail on unknown `re.IGNORECASE`, reject `@dataclass(frozen=True)`) will behave differently on petitpy.

### Browser DOM access

petitpy ships a `js` module ([ADR 006](adrs/006-js-interop.md)) that gives Python code direct DOM access through a synchronous host-call bridge. Upstream MicroPython has no standard `js` module; its JavaScript port focuses on Node.js embedding. The `js` module is a project extension: Python code that omits `import js` runs on either interpreter (modulo the divergences above).

### Per-feature build flags and a profile mechanism

`build.zig` accepts orthogonal `-Dfeature-*` flags ([ADR 002](adrs/002-feature-selection.md)) plus a profile abstraction ([ADR 012](adrs/012-profiles-and-feature-matrix.md)). A downstream user picks the exact surface they need. Upstream MicroPython solves the same problem with per-port `mpconfigport.h` files (one per microcontroller target). The petitpy approach gives compositional flexibility without forking a header per audience.

### The compiler is a standalone tool

`zigpy-compile` is a separate binary that emits `.mpy` v6 from `.py` source. Upstream MicroPython has `mpy-cross` for the same job. The two produce semantically-equivalent bytecode (verified by `tools/compile-exec-test.py`). Peephole optimizations sometimes produce different-but-equivalent bytecode; constant-folding for big-ints uses Zig's `std.math.big.int` where it matches Python semantics and falls back to runtime evaluation in edge cases (mixed-sign bit-or).

### Error propagation

MicroPython uses `setjmp`/`longjmp`-based NLR. petitpy uses Zig's `error{PyRaise}!T` error union plus a polled-sentinel bridge. PyError propagates end to end; the nano build uses no setjmp. Detailed in [Internals → PyError](internals/pyerror.md).

## What's better, what's worse

### Better

- **Memory safety.** Zig's `@panic` on integer overflow, null-pointer-deref, out-of-bounds index. Zero undefined behavior in Debug builds.
- **Single build system.** `make build` from a clean checkout. `zig build` cross-compiles. The build needs neither autoconf nor configure scripts; it has no per-platform stdio gating.
- **Test infrastructure.** Four independent gates (nano corpus, full corpus, wasm corpus, integration on both arms) plus lint, all under `make`.
- **Longitudinal metrics.** `tools/metrics.py` records size + coverage + perf snapshots to `metrics/history.ndjson` per session.
- **Compatibility surface auto-generated.** `docs/COMPATIBILITY.md` ships from `golden-programs/` via `make compatibility`: 823 real programs bucketed by what they need.
- **Real-app footprint.** On the hop3-rootd Linux daemon, RAM after 100 requests on Linux is 3.9 MB vs CPython 3.11's 17.3 MB, a 4.4× reduction ([case study](case-study-daemon.md)).

### Worse

- **Feature breadth.** MicroPython runs on dozens of microcontroller ports and supports hundreds of modules via `micropython-lib`. petitpy runs on x86_64 / arm64 macOS/Linux and wasm32-wasi.
- **Maturity.** MicroPython is 10+ years old with thousands of contributors. petitpy is a solo + AI-assisted project.
- **Ecosystem.** MicroPython has package managers and pre-compiled binaries for dozens of boards. petitpy has none of that; the wasm distribution model is "load the binary on a page"; the native distribution model is "install from a wheel or a Homebrew tap" ([ADR 016](adrs/016-distribution.md)).
- **Threading and async runtime.** MicroPython supports both with real implementations. petitpy's async parser is wired, but the runtime is deferred ([ADR 002](adrs/002-feature-selection.md) Path B).
- **No ABI compatibility.** Do not link against petitpy at the C level as if it were a MicroPython drop-in. It isn't one; there is no plan to make it one.

### About the same

- **Performance.** Both interpreters dispatch the same bytecode through similar opcode handlers. The [benchmark snapshot](benchmarks.md) puts petitpy about 20% faster (0.79× geomean) on a small `perf_bench` subset, with per-benchmark spread, against MicroPython's default size-optimized build.
- **REPL quality.** Both support multi-line input, walrus, copy-paste. Neither has `rlcompleter` completion.
- **Error messages.** Both produce terse messages by default; petitpy has incremental improvements (`NameError` / `AttributeError` include the identifier name).

## When to use petitpy

Reasonable cases:

- **You want Python in a browser** without 30 MB of Pyodide.
- **You want a small native Python on x86_64 or arm64 Linux/macOS** and can accept that the extended `full` profile diverges from strict MicroPython on the items above.
- **You're embedding Python in a Zig project.** The `npy_zig_compile_source` entry point is a stable Zig export.
- **You're building a stdlib-only Linux daemon** and the CPython footprint is too heavy. See the [case study](case-study-daemon.md).

MicroPython is the better choice in these cases:

- **You're targeting microcontrollers.** MicroPython has dozens of mature ports; petitpy has zero.
- **You need any module not in the shipped surface** (`multiprocessing`, `ssl`, `sqlite3`, `curses`, full `typing`, richer `asyncio`). Upstream has more breadth via `micropython-lib`.
- **You're shipping something serious to production today.** MicroPython has years of production deployment behind it; petitpy is fresh.
- **You need threading or a real async runtime.**
- **You need to link against the runtime at the C level.** MicroPython doesn't promise an external ABI either. Its C-level integration surface is much better documented, though, and vendor ports have real API stability for embedding.

## Compatibility statement

A Python program that runs under upstream MicroPython `unix-standard` will *usually* run under petitpy's `full` profile with the same output. The exceptions are enumerated under "Where petitpy has diverged" above. The 541/541 nano corpus is the strongest evidence of matching semantics on the MicroPython-strict subset; the `full` corpus at 545/552 (with 7 documented divergences) tracks the extended profile.

Programs that use float, MPZ, threading, async, `re` groups or PEP 448 unpacking need a case-by-case answer, which appears for each program in [`COMPATIBILITY.md`](COMPATIBILITY.md).

## See also

- [`COMPATIBILITY.md`](COMPATIBILITY.md): per-program bucket breakdown.
- [How it was built](strangler-journey.md): the engineering story.
- [Architecture](architecture.md): internal structure.
- [ADR 003](adrs/003-library-and-module-loading.md): the compatibility commitment as originally scoped.
- [ADR 010](adrs/010-roadmap-v06.md): v0.6 roadmap.
- [Case study: a Linux daemon](case-study-daemon.md): hop3-rootd on petitpy.
