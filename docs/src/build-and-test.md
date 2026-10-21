# Build & Test

_For contributors and embedded/systems developers. The Makefile drives the build, the test pyramid, the metrics tool, and the docs site. Embedded/systems developers wanting to ship a feature-tailored binary will care about the [Build](#build) section + the per-feature flags ([Getting Started: Embedded](getting-started.md#for-embedded-and-systems-developers)). Contributors will care about everything._

## Makefile reference

`make help` produces this listing dynamically. The targets, by category:

### Build

| Target | What |
|---|---|
| `make build` | Debug build (`zig build -Dconfig=$(CONFIG)`, and `CONFIG` defaults to `full`). ~3.9 MB binary, full DWARF, no inlining. |
| `make build-release` | ReleaseFast (`-Doptimize=ReleaseFast`). ~1150 KB, full inlining + optimization. |
| `make build-small` | ReleaseSmall (`-Doptimize=ReleaseSmall`). ~541 KB on `full`, ~475 KB on `nano`. The native shipping size. |
| `make build-frozen` | ReleaseFast + frozen-tiny stdlib bundled: what `make web` builds against. |
| `make build-release-frozen` | Same, but ReleaseSmall. Used by the metrics tool. |
| `make rebuild` | `clean` + `build`. Use after a config change. |
| `make port` | Regenerate `vendor/micropython_embed/` from `vendor/micropython` via the upstream `embed.mk`. Automatic prerequisite of `build`. |
| `make wasm` | `zig build -Dtarget=wasm32-wasi -Dconfig=nano`. The raw wasm artifact. |
| `make web` | `make wasm` + `wasm-opt -Oz` (when binaryen is installed). Produces `web/nanopython.wasm`, the shipping artifact, **346 KB**. |

Set `CONFIG=full` on any of these to select the everything-on config arm. Per-feature `-Dfeature-*=on/off` flags ([ADR 002](adrs/002-feature-selection.md)) compose freely with `-Dconfig`.

### Test

The pyramid runs fast-first: unit → integration → e2e.

| Target | What | Result expected |
|---|---|---|
| `make test` | Native-only test pyramid (unit + integration + e2e) | All pass |
| `make test-unit` | Zig unit tests for the compiler + VM tracks | pass |
| `make test-unit-compiler` | Compiler-track tests only | pass |
| `make test-unit-vm` | VM-track tests only | pass |
| `make test-integration` | `tests/integration.py` smoke suite, native | **37/37** |
| `make test-integration-wasm` | Same suite, run via wasmtime | **37/37** |
| `make test-e2e` | Corpus + compile-exec-test | 541/541 + 540/542 |
| `make check` | Strict invariant gate (native corpus) | **541/541** byte-identical |
| `make verify` | Detailed per-test PASS/FAIL list | exits 0 |
| `make wasm-check` | Wasm gate against the 51-entry baseline | **GREEN** at 490/541 raw |
| `make` (the aggregate) | All four gates, both arms, plus lint | exit 0 in ~37s |

### Metrics

Longitudinal recording of size + coverage + (opt-in) perf.

| Target | What |
|---|---|
| `make metrics-record` | Append a row to `metrics/history.ndjson` capturing the current binary sizes + corpus pass counts + golden-bucket sizes |
| `make metrics-record-perf` | Same, plus run the perf benchmarks (p2w subset) and append geomean ratios |
| `make metrics-report` | Print recent rows as a trend table |
| `make metrics-latest` | Just print the most-recent row |

### Coverage

Requires `kcov` (`brew install kcov` on macOS, `apt-get install kcov` on Linux):

| Target | What | Report at |
|---|---|---|
| `make test-coverage` | Unit-test coverage, merged | `coverage/unit/merged/index.html` |
| `make test-coverage-compiler` | Compiler-track only | `coverage/unit/compiler/merged/index.html` |
| `make test-coverage-vm` | VM-track only | `coverage/unit/vm/merged/index.html` |
| `make test-coverage-e2e` | Corpus coverage (the meaningful number) | `coverage/e2e/merged/index.html` |

### Compatibility surface

| Target | What |
|---|---|
| `make compatibility` | Regenerate [`docs/COMPATIBILITY.md`](COMPATIBILITY.md) from the current `golden-programs/` bucket assignments |
| `make golden` | Rebootstrap the `golden-programs/` buckets (slow: runs every program through three oracles) |

### Browser smoke

The `tools/browser-smoke.py` harness drives the web demos under headless Chromium. Use it for catching DOM-side regressions that the corpus + integration suite can't see.

| Target | What |
|---|---|
| `make smoke` | Drive the standard demo set, checking key text + no errors |
| `make smoke-setup` | One-time: `pip install playwright` + download chromium (~150 MB) |

See `tools/browser-smoke.py` for the full step primitives (click, type, select, eval, assert-text, screenshot, etc.).

### Quality

| Target | What |
|---|---|
| `make lint` | `zig fmt --check` over our Zig + `py_compile` over `tools/*.py` |
| `make format` | Apply `zig fmt` to our sources (never touches `vendor/` or `corpus/`) |
| `make clean` | Drop `.zig-cache`, `zig-out`, `coverage/`. `vendor/` stays. |
| `make freeze` | **DANGER.** Refreeze corpus goldens from current binary. Only after an intended config change. |

## The strict invariant: `make check`

```sh
$ make check
zig build -Dconfig=nano
python3 tools/progress.py --config nano ./zig-out/bin/nanopython
nanopython progress:  100.0%  [########################################]
  passing 541/541 corpus tests (byte-identical to the frozen reference)
  command: ./zig-out/bin/nanopython
```

This is the gate every commit must pass.

- **Numerator**: tests whose stdout+stderr+exit-status matches the frozen oracle byte-for-byte.
- **Denominator**: tests in `corpus/nano/basics/` minus those in `EXCLUDED.txt`.
- **Exit status**: `make check` reports the count but always exits 0. `make verify` is the strict variant that exits non-zero on any miss.

If `make verify` reports any miss, **you broke something**. Identify the failing test and either fix it or revert. The 541/541 baseline is the long-standing strangler invariant; it's been at this level since the 2026-06-11 session closed `builtin_help` + `gc1` + `string_strip`.

## The wasm gate: `make wasm-check`

```sh
$ make wasm-check
nanopython wasm progress:  87.2% [###################################]
  passing 490/541 corpus tests
  GREEN — baseline holds: 68 known fails matched exactly
```

This gate is **strict in both directions**:
- A new fail not on `corpus/wasm-known-fails.txt` → exits non-zero (you regressed something on wasm).
- A test on the known-fails list that now passes → exits non-zero (you fixed something; remove the entry).

The list is documented in-place: each entry has a comment explaining why it's there (bignum needing MPZ, eval/exec hitting the longjmp wall, the two chosen `deque_*` divergences).

## The secondary differential gate: `compile-exec-test`

```sh
$ python3 tools/compile-exec-test.py
compile-exec-test: 540/542 pass, 2 fail, 0 compile-fail, 0 timeout, 0 runner-err
```

For each `.py` source, this compiles with our `zigpy-compile` (Zig frontend), then runs the resulting `.mpy` through the upstream MicroPython unix binary, and diffs stdout/stderr/exit-status against the frozen `corpus/full/basics/*.out`. Tests execution equivalence; catches cases where our compiler emits subtly-wrong bytecode that the byte-exact gate misses.

The "2 fail" are harness artifacts (mixed-sign bit-or constant folding), documented in the test runner's source.

## Optimization mode comparison

| Mode | Make target | Size (arm64) | Use case |
|---|---|---|---|
| `Debug` | `make build` | 3.9 MB | Development. Full DWARF, no DCE, runtime panics with stack traces. |
| `ReleaseFast` | `make build-release` | 1150 KB | Performance. Full inlining, all optimizations. Use for benchmarks. |
| `ReleaseSmall` | `make build-small` | 541 KB | Shipping. Size-optimized. |
| `ReleaseSafe` | (none) | ~1.2 MB | Same optimization as Fast, keeps runtime safety checks. |

For comparison, upstream MicroPython unix-standard (arm64, their `-Os` default) is 652 KB.

The wasm artifact: 346 KB raw post-`wasm-opt -Oz` (166 KB gzipped) (see [ADR 007](adrs/007-wasm-fat-loss.md) for the size arc and remaining targets).

## CI strategy

No CI is wired into the public-facing pipeline yet. The local-only quality gates are:

1. Before commit: `make`.
2. Before a tagged release: `make` on a fresh checkout (`make clean && make`) + a manual `make smoke` against the bundled web demos.

A future CI would run `make` on every PR. `make verify` and `make wasm-check` produce clean signals: diff the pass/fail list against `main` to localize any regression.

## Adding your own tests

### A Zig unit test

Add a `test "..." { ... }` block inline in any module under `src/`. Re-run `make test-unit-compiler` (for compiler-track files) or `make test-unit-vm` (for runtime-side files).

```zig
test "my_helper returns the right thing" {
    const std = @import("std");
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 42), myHelper());
}
```

### An integration smoke test

Edit `tests/integration.py`. Each entry is `(name, py_source, expected_stdout)` or `(name, py_source, expected_stdout, expected_exit)`:

```python
("my_test_case",
 "x = 5\nprint(x * 2)",
 "10\n"),

("my_exits_with_code",
 "import sys; sys.exit(7)",
 "",
 7),
```

Run with `make test-integration` (native) or `make test-integration-wasm` (wasm). The output of running `py_source` via the chosen binary is compared to `expected_stdout`.

Every bug fix lands with at least one regression pin here. If a wasm-only bug slipped past the corpus, that's the right place to plug the gap.

### A corpus test

Corpus tests live in `corpus/basics/*.py`, verbatim copies of upstream MicroPython's `tests/basics/` at the `MICROPY_REV` the Makefile pins. Bumping that revision means re-copying them and re-freezing the goldens in the same commit. Adding one is non-trivial: the goldens have to come from a known-good reference. See `tools/corpus.py` for the freeze logic; in practice, new corpus tests follow upstream MicroPython's test additions.

### A golden program

Drop a `.py` file into the appropriate `golden-programs/<bucket>/` directory with the per-program header comment:

```python
# golden: source=mysource; needs=heapq,recursion
# golden: works-on=micropython,nanopython-native,nanopython-wasm
"""What this program demonstrates."""
```

Then `make golden` rebootstraps the buckets and re-verifies the annotations against three oracles (MicroPython, petitpy native, petitpy wasm). See [ADR 008](adrs/008-golden-programs.md) for the bucket semantics.
