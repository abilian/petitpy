# Build & Test

_For contributors, and for embedded or systems developers who want a binary tailored to their needs. The Makefile drives the build, the test gates and the docs site. `make help` lists the everyday targets; `make help ALL=1` lists all of them._

## Build

| Target | What it builds |
|---|---|
| `make build` | Debug build of `zig-out/bin/petitpy` and `zigpy-compile` |
| `make build-release` | ReleaseFast: use it for benchmarks |
| `make build-small` | ReleaseSmall: the native shipping size |
| `make build-frozen` | Bakes the frozen stdlib modules (`json`, `random`, ...) into the binary |
| `make wasm` | Debug wasm32-wasi binary, for wasmtime |
| `make wasm-small` | ReleaseSmall wasm with the frozen modules |
| `make web` | The browser artifact `web/petitpy.wasm`, shrunk with `wasm-opt -Oz` when binaryen is installed |
| `make port` | Regenerates `vendor/micropython_embed/` from `vendor/micropython`. Runs automatically before a build |
| `make rebuild` | `clean` then `build`, after a config change |

`CONFIG` selects the configuration and defaults to `full`; use `CONFIG=nano` for the minimal arm. The wasm targets always build nano. Per-feature `-Dfeature-*` flags ([ADR 002](adrs/002-feature-selection.md)) combine with either config when you call `zig build` directly.

## The gates

Each gate answers a different question, and passing one says nothing about the others. Run the aggregate `make` before every commit: it builds, runs `make test`, `check-all`, `wasm-check`, `test-integration-wasm` and `lint`.

| Target | Question |
|---|---|
| `make check` | Does the full build match the corpus, apart from the failures listed in `corpus/full-known-fails.txt`? |
| `make check CONFIG=nano` | Does the nano build match the frozen MicroPython reference byte for byte? |
| `make check-all` | Both of the above, plus the split check: `petitpy-vm` running bytecode from `zigpy-compile` and from MicroPython's `mpy-cross` |
| `make wasm-check` | Does the wasm build match the corpus, apart from `corpus/wasm-known-fails.txt`? |
| `make test-integration` | Does the native binary start and run real Python correctly? |
| `make test-integration-wasm` | The same suite, run under wasmtime |
| `make test-wheel-layout` | Does every stdlib module import from the layout `pip install` ships? |
| `make check-capability` | Do both front ends and both back ends agree, construct by construct? |
| `make check-release` | Do the corpus and integration gates hold on ReleaseFast builds? Debug fills undefined memory with a fixed pattern that can hide bugs |
| `make wasm-gc-check` | Does wasm collect garbage between JS callbacks without losing live state? Needs Node |

The nano gate must always pass in full: a regression there is fixed before the commit. The full and wasm gates are strict in both directions. A new failure that is not on the known-fails list fails the gate, and so does a listed test that now passes: when you fix one, remove its entry in the same commit. Every entry on a known-fails list carries a comment explaining why it is there.

`make verify` prints the per-test PASS/FAIL list for the selected config, which helps find what broke.

### Other tests

| Target | What |
|---|---|
| `make test` | Unit tests, native integration, the corpus, the stdlib tests and the wheel-layout check |
| `make test-unit` | Zig unit tests; `test-unit-compiler` and `test-unit-vm` run one side |
| `make test-e2e` | The corpus for the selected config. Under `CONFIG=nano` it also runs `tools/compile-exec-test.py`, which compiles each corpus program with `zigpy-compile`, runs the bytecode on upstream MicroPython and compares the output |
| `make test-stdlib` | The tests under `tests/stdlib/` for the bundled Python library |
| `make smoke` | Loads every web demo and game in headless Chromium and fails on any console error. Run `make smoke-setup` once first |

## Other targets

| Target | What |
|---|---|
| `make lint` | `zig fmt --check`, plus Python and JS checks when ruff and prettier are installed |
| `make format` | Applies `zig fmt` (and prettier) to project sources; never touches `vendor/` or `corpus/` |
| `make clean` | Removes build outputs; `make clean ALL=1` also removes the generated embed package and the web wasm |
| `make freeze` | Re-freezes the corpus reference output from the current binary. Only after a deliberate change that justifies it |
| `make compatibility` | Regenerates [`COMPATIBILITY.md`](COMPATIBILITY.md) from `golden-programs/` |
| `make test-coverage`, `make test-coverage-e2e` | Line coverage of the unit tests or of the corpus, with kcov |
| `make metrics-record`, `make metrics-report` | Records binary sizes and pass counts to `metrics/history.ndjson` and prints the trend |

## CI

CI runs on SourceHut from the manifests in `.builds/`: the nano gates, the full gates including `check-release`, and cross-compilation for other targets. CI starts from a clean clone with no `vendor/` directory, so a change must build from a fresh checkout.

## Adding tests

### A Zig unit test

Add a `test "..." { ... }` block in any module under `src/`, then run `make test-unit-compiler` or `make test-unit-vm`.

```zig
test "my_helper returns the right thing" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 42), myHelper());
}
```

### An integration test

Add a case to the `CASES` list in `tests/test_integration_core.py` (or `tests/test_integration_os.py` for `os`). A case is `(name, source, expected_stdout)` or `(name, source, expected_stdout, expected_exit)`:

```python
("my_test_case",
 "x = 5\nprint(x * 2)",
 "10\n"),

("my_exits_with_code",
 "import sys; sys.exit(7)",
 "",
 7),
```

Run it with `make test-integration` or `make test-integration-wasm`. Every bug fix should come with a case here, especially a bug the corpus missed.

### A corpus test

`corpus/basics/*.py` are verbatim copies of upstream MicroPython's `tests/basics/` at the revision the Makefile pins (`MICROPY_REV`). New corpus tests come from upstream; bumping the revision means copying the files again and re-freezing the reference output in the same commit.

### A golden program

Put a `.py` file in the right `golden-programs/<bucket>/` directory with a header:

```python
# golden: source=mysource; needs=heapq,recursion
# golden: works-on=micropython,petitpy-native,petitpy-wasm
"""What this program demonstrates."""
```

[ADR 008](adrs/008-golden-programs.md) explains the buckets.
