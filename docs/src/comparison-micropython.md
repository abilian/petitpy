# petitpy vs MicroPython

_For developers choosing between the two runtimes for a native Linux or macOS target, embedded scripting, or the browser._

## Quick answer

petitpy builds on MicroPython's design and goes its own way, toward the browser, Linux daemons and more of CPython's language. Its one compatibility promise is the **bytecode format**: `.mpy` v6, byte-for-byte compatible with upstream in both directions. Any change to that would come through an ADR.

There is **no C-level ABI compatibility**. The object model, struct layouts and exported symbols are internal and may change. Do not link against petitpy as a MicroPython replacement.

Python-level behaviour tracks MicroPython closely. The `nano` profile matches the vendor MicroPython reference byte for byte on the corpus, checked on every commit. The `full` profile, which `pip install petitpy` ships, departs from MicroPython where CPython's behaviour suits real programs better. Those departures are listed below. A program that runs on MicroPython's `unix-standard` build usually runs on `full` with the same output.

To pick between the two, skip to [When to use petitpy](#when-to-use-petitpy).

## At a glance

| | petitpy | MicroPython unix-standard |
|---|---|---|
| Source language | Zig, with some vendor C kept (float, `re`, bignums) | C |
| Native binary size | under 1 MB | under 1 MB |
| Wasm size | about 350 KB | no wasm32-wasi build; a webassembly port built with Emscripten |
| Compiler as a standalone tool | `zigpy-compile` | `mpy-cross` |
| Bytecode format | `.mpy` v6, byte-for-byte compatible | `.mpy` v6 |
| C-level ABI compatibility | not provided | no external ABI promise either |
| Arbitrary-precision integers | under `full` on native; 64-bit on wasm | optional (`MICROPY_LONGINT_IMPL_MPZ`) |
| `os`, `socket`, `select`, `signal`, `subprocess`, `pwd`, `grp` | under `full` (POSIX subset, Linux and macOS) | in `unix-standard` |
| Extended stdlib (`pathlib`, `datetime`, `uuid`, `ipaddress`, `dataclasses`, `unittest.mock`, `logging`, a small `pytest`) | pure Python, shipped with petitpy | partly, via `micropython-lib` |
| Threading | out of scope | yes, on supporting ports |
| `async` / `await` | coroutines run; no `asyncio` event loop | yes, with `asyncio` |
| Interactive REPL | yes | yes |
| License | MIT | MIT |

## What still matches

The bytecode format is the contract. `zigpy-compile` and upstream `mpy-cross` emit equivalent bytecode for the same source, though not always identical, and `tools/compile-exec-test.py` runs the output of `zigpy-compile` through upstream MicroPython's VM to catch wrong emissions.

The lexer, parser, opcode set and object model follow MicroPython's design. `src/mp_mirrors.zig` mirrors vendor C structs field for field, with size and offset checks, so a vendor update that moves a field fails the build. The check keeps the vendor C that `full` still links working. It makes no ABI promise.

## Where petitpy differs

### Ecosystem

`micropython-lib` packages and `mip install` workflows are not tested on petitpy. The stdlib petitpy ships is written for it.

### Wasm as a primary target

The browser build is a first-class distribution alongside native, the reverse of MicroPython's microcontroller-first priorities. This shaped the runtime: MicroPython's `setjmp`/`longjmp` exception mechanism (NLR) is replaced by Zig error unions ([Internals: PyError](internals/pyerror.md)), so the wasm build needs no setjmp support. Upstream's webassembly port relies on Emscripten's setjmp lowering, which works but costs size.

### The `full` profile

Under `full`, petitpy ships `os`, `time`, `socket`, `select`, `signal`, `subprocess`, `pwd` and `grp` in C or Zig, covering the POSIX subset a stdlib-only Linux daemon uses, plus pure-Python `pathlib`, `datetime`, `uuid`, `ipaddress`, part of `shutil`, `unittest.mock`, `logging` and a small `pytest`. The [daemon case study](case-study-daemon.md) runs a real privileged Linux daemon and its test suite on this profile. MicroPython's `unix-standard` covers an overlapping but different POSIX subset.

### CPython-shaped library behaviour

Where MicroPython's stricter behaviour made real code awkward, petitpy follows CPython:

- `collections.deque` takes an iterable at construction and supports indexing. MicroPython's `deque` is a smaller subset.
- `re.IGNORECASE` works: petitpy widens each letter of the pattern to both cases. Upstream `re` has no such flag.
- `@dataclass` accepts `frozen`, `slots`, `kw_only`, `order`, `unsafe_hash` and `match_args`, though not all of them change behaviour. Upstream's `dataclass` is narrower.
- `class Color(Enum)` works for enums whose members are plain values.
- PEP 448 unpacking (`{**a, **b}`, `[a, *b]`) works in more positions.
- The PEP 570 positional-only marker `/` is accepted and has no effect, as in MicroPython.

A program that relies on MicroPython's strict behaviour, such as failing on `re.IGNORECASE`, behaves differently on petitpy.

### Browser DOM access

petitpy's `js` module ([ADR 006](adrs/006-js-interop.md)) gives Python direct DOM access through synchronous host calls. Upstream's webassembly port has its own `js` and `jsffi` modules with a different API, so code that uses `js` is not portable between the two. Code that does not import `js` runs on either.

### Build flags and profiles

`build.zig` takes independent `-Dfeature-*` flags ([ADR 002](adrs/002-feature-selection.md)) and named profiles that bundle them ([ADR 012](adrs/012-profiles-and-feature-matrix.md)). MicroPython solves the same problem with one `mpconfigport.h` per port.

## Strengths and weaknesses

### Where petitpy is ahead

- **Safety checks.** Debug builds trap on integer overflow, null dereference and out-of-bounds access.
- **One build system.** `make build` works from a clean checkout and `zig build` cross-compiles, without autoconf or per-platform configuration.
- **Gates.** Corpus, integration and wasm checks run under one `make`.
- **Compatibility tracking.** [`COMPATIBILITY.md`](COMPATIBILITY.md) is generated from a collection of real programs, grouped by what each one needs.
- **Memory footprint.** On the daemon of the [case study](case-study-daemon.md), petitpy uses about a quarter of CPython's memory.

### Where MicroPython is ahead

- **Reach.** MicroPython runs on dozens of microcontroller ports, with many more modules through `micropython-lib`. petitpy runs on x86_64 and arm64 Linux and macOS, and on wasm32-wasi.
- **Maturity.** MicroPython has more than ten years of production use and a large contributor base. petitpy is young and mostly written by one maintainer with AI assistance.
- **Distribution.** MicroPython has package tools and prebuilt firmware for many boards. petitpy ships wheels on PyPI and an npm package ([ADR 016](adrs/016-distribution.md)).
- **Threads and async.** MicroPython implements both. petitpy runs coroutines but has no event loop, and `_thread` is a stub.
- **Embedding in C.** MicroPython's C API is better documented, and its ports keep it stable in practice. petitpy makes no C-level promise.

### About the same

- **Speed.** Both run the same bytecode through similar handlers. The [benchmarks](benchmarks.md) put petitpy somewhat ahead of MicroPython's default size-optimized build, with spread between benchmarks.
- **REPL.** Both support multi-line input and paste. Neither has tab completion.
- **Error messages.** Both are terse; petitpy names the identifier in `NameError` and `AttributeError`.

## When to use petitpy

petitpy fits when:

- **You want Python in a browser** without the download size of Pyodide.
- **You want a small native Python on Linux or macOS** and can accept that `full` differs from strict MicroPython as described above.
- **You write a stdlib-only Linux daemon** and CPython's footprint is too large. See the [case study](case-study-daemon.md).

MicroPython is the better choice when:

- **You target microcontrollers.** petitpy has no microcontroller port.
- **You need a module petitpy does not ship**, such as `multiprocessing`, `ssl`, `sqlite3`, `curses`, full `typing` or `asyncio`.
- **You ship to production today.** MicroPython has years of deployments behind it.
- **You need threads or an async runtime.**
- **You embed the runtime from C.**

## See also

- [`COMPATIBILITY.md`](COMPATIBILITY.md): what runs, program by program.
- [Differences from CPython](differences.md).
- [How it was built](strangler-journey.md).
- [Architecture](architecture.md).
- [ADR 003](adrs/003-library-and-module-loading.md): library and module loading.
- [Case study: a Linux daemon](case-study-daemon.md).
