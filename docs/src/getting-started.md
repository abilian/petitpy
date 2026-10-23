# Getting Started

## Install

```sh
pip install petitpy          # or: uv tool install petitpy
uvx petitpy script.py        # run once without installing
```

Both install two commands, `petitpy` and its short name `ppy`. Prebuilt wheels cover macOS and Linux on arm64 and x86_64; on other platforms pip builds petitpy from source with Zig, which takes about a minute.

## Run Python

```sh
petitpy script.py                                # run a file
echo 'print(2**100)' | petitpy /dev/stdin        # read the program from stdin
ppy                                              # interactive REPL (Ctrl-D to exit)
```

The native build has arbitrary-precision integers, Unicode strings, files, `os`, `subprocess`, sockets and an everyday stdlib (`json`, `re`, `dataclasses`, `pathlib`, `datetime`, `logging`, `unittest.mock`, …). Read [Differences from CPython](differences.md) before porting a program: the main surprises are that `str.upper()` is ASCII-only and that tracebacks have no line numbers.

## Python in the browser

The browser build is a wasm module of about 350 KB. Install it from npm:

```sh
npm install petitpy
```

```js
import { loadPetitpy } from "petitpy";

const py = await loadPetitpy();
const { stdout, stderr, exitCode } = await py.run('print("hello from", 6 * 7)');
```

Each `run(source, options)` gets a fresh instance. Options include `stdin`, `files` (extra files by path; modules under `lib/` are importable), `argv`, and `onStdout` / `onStderr` callbacks for programs that keep running through JS callbacks.

From Python, the `js` module reaches the page directly ([ADR 006](adrs/006-js-interop.md)):

```python
import js

btn = js.document.getElementById("go")
btn.addEventListener("click", lambda e: js.alert("hello from Python!"))
```

The browser build is smaller than the native one. There is no `open()` or `os`: programs see the files the page passes in. Everything else in the language works, including classes, generators, `match`, `eval` and `exec`, and the pure-Python stdlib modules. [Differences from CPython](differences.md) has the details.

To try it without installing anything, use the [playground](/play/demos/playground/). For a game on a canvas, see [Writing games](writing-games.md).

## Build from source

You need [Zig](https://ziglang.org/) 0.16, Python 3, GNU Make and git. [wasmtime](https://wasmtime.dev/) runs the wasm build locally, and [binaryen](https://github.com/WebAssembly/binaryen) (`wasm-opt`) makes the browser build smaller; both are optional.

```sh
git clone https://github.com/abilian/petitpy && cd petitpy
make build           # Debug binary at zig-out/bin/petitpy
make build-release   # optimized for speed
make build-small     # optimized for size
make web             # browser build at web/petitpy.wasm
```

The first build clones MicroPython into `vendor/micropython` at the revision the Makefile pins (`MICROPY_REV`). To use a checkout you already have, put it at that revision and symlink it there before building. The first build takes a minute or two; later builds take seconds. The Debug binary is several megabytes because it keeps debug symbols; use a release build to ship.

To run the bundled demos locally:

```sh
make web
python3 -m http.server -d web 8000
# open http://localhost:8000/
```

The binary defaults to the `full` profile. `-Dconfig=nano` builds the smaller profile the browser uses, and flags such as `-Dfeature-collections=false` or `-Dfeature-struct=false` drop single modules ([ADR 002](adrs/002-feature-selection.md)); `zig build --help` lists them. Zig cross-compiles without extra toolchains:

```sh
zig build -Dtarget=x86_64-linux-gnu  -Doptimize=ReleaseSmall
zig build -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSmall
```

petitpy does not target microcontrollers. For STM32, ESP32 or RP2040, use [MicroPython](https://micropython.org/).

## Contributing

`make` runs the full test suite and lint, and must pass before a commit. [Build & Test](build-and-test.md) explains the test gates, and [Contributing](contributing.md) the workflow.
