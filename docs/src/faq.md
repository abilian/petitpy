# FAQ

## Why "petitpy", and why "nanopython"?

The project started from MicroPython's **nano** configuration, and the codename nanopython stuck. PyPI refused that name as too close to an existing project, so releases are published as **petitpy** ("small Python"), with `ppy` as the short command. The repository and its internals still say nanopython.

## How does it relate to CPython and MicroPython?

petitpy does not build on CPython. It builds on [MicroPython](https://micropython.org/), a much smaller Python by Damien P. George and contributors. petitpy shares MicroPython's `.mpy` bytecode and much of its design, and MicroPython's test suite checks it on every commit.

On top of that, petitpy adds a runtime that compiles to plain wasm, a DOM bridge, and more of CPython's language and stdlib: `match`, Unicode strings, exception chaining, dataclasses, `pathlib`, `subprocess`. [vs MicroPython](comparison-micropython.md) lists where the two differ, and [Differences from CPython](differences.md) what still behaves differently from CPython.

## Is it a competitor to MicroPython?

No. MicroPython targets microcontrollers; petitpy targets the browser and Linux or macOS daemons and scripts. For STM32, ESP32, RP2040 and other boards, use MicroPython. petitpy has no plans for microcontroller ports.

## Why Zig?

Zig ships a C compiler, so MicroPython's C could be built with the same toolchain and replaced by Zig one module at a time, under one build system. Zig's explicit allocators fit MicroPython's memory model, and its error unions replace MicroPython's `setjmp`/`longjmp` exceptions, which plain wasm cannot express. Rust would also have worked; the choice was pragmatic.

## Is it fast?

It is somewhat faster than MicroPython and somewhat slower than CPython on the benchmark programs, with a wide spread between programs. [Benchmarks](benchmarks.md) has the measurements. Size still takes priority over speed.

## Does it work in a browser?

Yes. The browser build is a wasm module of about 350 KB that loads in well under a second, and drives the DOM through the `js` module. Install it with `npm install petitpy`, or try the [playground](/play/demos/playground/). [Getting Started](getting-started.md#python-in-the-browser) shows how to use it.

## Can I use it in production?

petitpy is an alpha, maintained by one person. It runs real programs on both native and wasm, and a privileged Linux daemon runs on it ([case study](case-study-daemon.md)). Check [Differences from CPython](differences.md) and the [Compatibility matrix](COMPATIBILITY.md) against your code before you depend on it.

## How do I report a bug?

Open an issue on [GitHub](https://github.com/abilian/petitpy/issues) with the smallest program that shows the problem, what it printed, and what CPython prints. Say whether you ran the native build (`petitpy --version`) or the browser one.
