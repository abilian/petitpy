# petitpy

*Published on PyPI as petitpy; developed as nanopython.*

**Python where CPython doesn't fit.** petitpy is a small Python runtime written in [Zig](https://ziglang.org/). It runs in a browser tab, as a small Linux daemon, and as a native scripting target on macOS or Linux. It is meant for places where a CPython install or a Pyodide download is too much, but you still want real Python: floats, dicts, classes, comprehensions, `match`, `dataclasses` and the everyday stdlib.

```sh
pip install petitpy          # installs the `petitpy` and `ppy` commands
petitpy script.py
```

## What you get

- **In a browser tab.** A wasm module of about 350 KB that loads in well under a second. Python reaches the page through `import js`: `js.document.body.textContent = "hi"` works from Python ([ADR 006](adrs/006-js-interop.md)).
- **As a small Linux daemon.** [hop3-rootd](https://github.com/abilian/hop3), a stdlib-only privileged daemon, uses about 4 MB of RAM on petitpy against about 17 MB on CPython ([case study](case-study-daemon.md)).
- **As a native scripting target.** A static binary under a megabyte for macOS and Linux (arm64, x86_64), with the POSIX modules a daemon needs: `os`, `socket`, `select`, `signal`, `subprocess`, `pwd`, `grp`, plus `pathlib`, `datetime`, `dataclasses`, `logging` and `unittest.mock`.

MicroPython proved a small Python is possible, but it targets microcontrollers. Pyodide brings CPython to the browser at tens of megabytes. petitpy aims between the two, with more of CPython's language than MicroPython accepts: `match` statements, Unicode strings on every build, exception chaining, class annotations and dataclass fields.

## Where to go next

- **See it run.** The [demos](/play/) run petitpy in your browser: [games](/play/games/), small [apps](/play/demos/), and a [playground](/play/demos/playground/) to type Python into.
- **Try it out.** [Getting Started](getting-started.md) covers installing, running scripts, and putting Python on a web page.
- **Check your code.** [Differences from CPython](differences.md) lists what behaves differently; [vs MicroPython](comparison-micropython.md) and the [Compatibility matrix](COMPATIBILITY.md) say what runs.
- **Read the design.** [Architecture](architecture.md) covers the runtime's shape, [How it was built](strangler-journey.md) the engineering story, and the [ADR series](adrs/index.md) the decisions.

## Thanks to MicroPython

petitpy builds on [MicroPython](https://micropython.org/), by Damien P. George and its contributors, and owes it a great deal. MicroPython showed that a complete, small Python is possible. petitpy's Zig runtime builds on its C code and its design, and MicroPython's test suite checks petitpy on every commit. petitpy still uses MicroPython's `.mpy` v6 bytecode format, so `zigpy-compile` output runs on MicroPython and `mpy-cross` output runs on petitpy. Thank you, MicroPython.
