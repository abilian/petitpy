# petitpy

*Published as petitpy (`pip install petitpy`, `npm install petitpy`); developed as nanopython.*

**Python where CPython doesn't fit.** It runs in a browser tab, as a small Linux daemon, and as a native scripting target on macOS or Linux. Anywhere a multi-megabyte CPython install or a 30 MB Pyodide download is too much, but you still want real Python (floats, dicts, classes, comprehensions, `dataclasses`, the everyday stdlib), petitpy is a small runtime that fits.

## Why petitpy exists

There are three good ways to run Python today. Each has a place it doesn't belong.

- **CPython** is where Python is real. It's also multi-megabyte at rest, hundreds of milliseconds cold, and comes with a stdlib that assumes a full operating system.
- **Pyodide** brings CPython to the browser at roughly 30 MB of wasm plus a stdlib download. Excellent for scientific-computing kernels; heavy for a page that just wants a Python snippet.
- **MicroPython** proved a small Python is possible. Its target is 256 KB flash on a microcontroller, and its distribution ecosystem, its stdlib coverage, and its wasm story all reflect that focus.

Between those, there's a gap: the surfaces where you want *real* Python, but where "multi-megabyte" is too much and "microcontroller" is the wrong shape: a browser tab, a stdlib-only Linux daemon, a native binary you want to ship at under a megabyte. petitpy is aimed at that gap.

## What you get

Three concrete outcomes today:

- **In a browser tab.** ~346 KB of wasm after `wasm-opt -Oz`, loads in well under a second on a typical connection. Python code touches the DOM directly through `import js` ([ADR 006](adrs/006-js-interop.md)): `js.document.body.textContent = "hi"` works from Python.
- **As a small Linux daemon.** [hop3-rootd](https://github.com/abilian/hop3) is a 6.7 KLOC stdlib-only privileged Linux daemon (systemd-managed, Unix-socket RPC, real cgroup / mount / firewall orchestration). On Linux it uses **3.9 MB of RAM on petitpy vs 17.3 MB on CPython 3.11: a 4.4× reduction**, and stays at 4.0 MB after 10,000 requests ([case study](case-study-daemon.md)).
- **As a native scripting target.** A static binary on arm64/x86_64 macOS or Linux: ~850 KB as `pip` installs it, optimized for speed, or ~540 KB built for size. Ships the POSIX subset a Python daemon reaches for: `os`, `socket`, `select`, `signal`, `subprocess`, `pwd`, `grp`, plus `pathlib`, `datetime`, `dataclasses`, `logging`, `unittest.mock`, `pytest_lite`.

## Who this is for

- **Web developers** who want Python running in a browser tab without a 30 MB toolkit and a WASI shim they didn't choose.
- **Systems developers** with a stdlib-only Linux daemon or a small scripting target, who care about RAM and startup time.

## What's here now

| | Native | Wasm |
|---|---|---|
| Byte-exact against MicroPython's test outputs (nano config) | **541/541** | 490/541 (51 documented walls) |
| Extended-semantics corpus (full config) | 545/552 (98.7%) | n/a |
| Integration smoke (both arms) | 189/189 | 189/189 |
| RAM of a real Linux daemon after 100 requests | **3.9 MB** vs CPython 3.11's 17.3 MB | n/a |
| Shipping artifact size | ~850 KB ReleaseFast (~540 KB ReleaseSmall) | **~346 KB** post-`wasm-opt -Oz` |

v0.7.1 is the current release; v0.8 is in flight, headline is the [full-unix profile](adrs/index.md) that made the hop3-rootd result possible.

## Where to go next

- **See it run.** The [demos](/play/) run petitpy in your browser: [games](/play/games/), small [apps](/play/demos/), and a [playground](/play/demos/playground/) to type Python into.
- **Try it out.** [Getting Started](getting-started.md) walks from an empty page to `hello world` running in wasmtime and in the browser.
- **Decide whether to use it.** [vs MicroPython](comparison-micropython.md) has the compatibility surface; [Compatibility matrix](COMPATIBILITY.md) has per-program status.
- **Read the design.** [Architecture](architecture.md) covers the runtime's shape; [How it was built](strangler-journey.md) tells the engineering story.
- **Read the decisions.** The [ADR series](adrs/index.md) records every architectural call.

---

## What petitpy adds

petitpy's own work is in what a small Python can do outside a microcontroller:

- **A runtime in Zig.** The lexer, parser, compiler, VM, object model and garbage collector are Zig. Exceptions travel as Zig error unions (`PyError!T`) instead of `setjmp`/`longjmp`, which is what lets the same runtime compile to plain wasm, with no Emscripten layer.
- **Python in the browser.** A 346 KB wasm module, a direct DOM bridge (`import js`, [ADR 006](adrs/006-js-interop.md)), a garbage collector that runs safely between JavaScript callbacks ([ADR 019](adrs/019-garbage-collector.md)), an npm package, and a [playground](/play/demos/playground/) that shows the bytecode of your program.
- **More of CPython's language.** `match` statements, Unicode strings on every build, exception chaining, class annotations and dataclass fields, `from __future__` imports: code that MicroPython does not accept or treats differently.
- **An everyday stdlib.** `dataclasses`, `pathlib`, `json`, `logging`, `unittest.mock` and a small `pytest`, plus the POSIX modules a daemon needs on native: `os`, `socket`, `select`, `signal`, `subprocess` ([ADR 011](adrs/011-everyday-stdlib.md)).
- **Packaging.** `pip install petitpy`, `uvx petitpy`, `npm install petitpy`, with prebuilt wheels for macOS and Linux ([ADR 016](adrs/016-distribution.md)).

## Thanks to MicroPython

petitpy builds on [MicroPython](https://micropython.org/), by Damien P. George and its contributors, and owes it a great deal. MicroPython showed that a complete, small Python is possible. petitpy's [Zig](https://ziglang.org/) runtime builds on its C code and its design. MicroPython's test suite checks petitpy byte for byte on every commit ([How it was built](strangler-journey.md) tells that story). petitpy still uses MicroPython's `.mpy` v6 bytecode format, so `zigpy-compile` output runs on MicroPython and `mpy-cross` output runs on petitpy. For where the two differ today, see [vs MicroPython](comparison-micropython.md). Thank you, MicroPython.
