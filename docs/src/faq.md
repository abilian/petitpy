# FAQ

_Common questions, grouped by audience. **Q1–Q4** are for web developers and embedded/systems developers (the "should I use this?" questions). **Q5–Q9** are technical context. **Q10–Q13** are about the project itself (mostly for contributors)._


## Q1: Why "petitpy", and why "nanopython"?

The project started from MicroPython's **nano** config preset, its minimal feature set, and the codename nanopython stuck. PyPI refused it as too close to an existing project, so releases are published as **petitpy** ("small Python"), with `ppy` as the short command. The repository and its internals still use nanopython. Both names read "small," though the size positioning has shifted: the wasm shipping artifact is 346 KB today. The binding constraint is the cold-load budget more than bytes on disk.

## Q2: How does this differ from porting CPython to Zig?

petitpy does not build on CPython. It builds on **MicroPython**, a much smaller Python implementation written by Damien P. George and contributors over the past decade: CPython is about 600,000 lines of C, MicroPython about 53,000. petitpy shares MicroPython's `.mpy` v6 bytecode, its opcode set and much of its design, and on the nano build it matches MicroPython's output byte for byte on all 541 tests of MicroPython's basic suite.

petitpy adds its own work on top: a runtime that compiles to plain wasm, a DOM bridge, a garbage collector that is safe between JavaScript callbacks, and more of CPython's language and stdlib (`match`, Unicode strings, exception chaining, dataclasses, `pathlib`, `subprocess`). The [home page](index.md#what-petitpy-adds) lists what petitpy adds, and [vs MicroPython](comparison-micropython.md) where the two differ.

## Q3: Why Zig and not Rust?

Three reasons:

1. **`zig cc`**: Zig ships a C compiler. We could compile MicroPython's C package with Zig's toolchain, drop in Zig modules one at a time, and have a single build system. Rust would have required separate cargo + a C build system.

2. **Manual memory management.** MicroPython is GC'd at the Python layer but the C layer is `malloc`/`free` plus a custom bump allocator. Zig's allocator-aware std lib matches that shape closely; Rust's ownership model would have required wrapping every `mp_obj_t` in `unsafe`.

3. **Smaller binary.** Zig's `ReleaseSmall` produces smaller code than Rust's `opt-level=z` in our experience.

Rust would also work. The choice was pragmatic.

## Q4: Is it faster than MicroPython?

In the same ballpark. The latest benchmark snapshot ([`benchmarks.md`](benchmarks.md)) puts petitpy at **1.28× geomean** vs MicroPython unix-standard and **1.96× geomean** vs CPython 3.14 across 6 perf_bench programs. Per-benchmark spread is wide: strops is faster than MicroPython (0.79×); sieve is slower (2.04×). The geometric mean sits in the green band per [ADR 004](adrs/004-benchmarking.md) §D8.

The interpreter keeps MicroPython's bytecode and much of its overall design, so the gap reflects implementation details and compiler code generation more than different algorithms. There's no dedicated perf optimization arc yet; size is the cross-cutting goal that takes priority.

## Q5: Can I use this in production?

For browser use cases, you increasingly can. The wasm artifact ships at 346 KB, the integration suite + corpus harness both run green on wasm, and the JS bridge ([ADR 006](adrs/006-js-interop.md)) handles DOM access. The remaining gaps are documented in [`COMPATIBILITY.md`](COMPATIBILITY.md); the headline blocker is the eval/exec longjmp wall on wasm, closing in v0.6.

For native/embedded systems use cases, you increasingly can too. The build cross-compiles to x86_64 / arm64 macOS + Linux and to wasm32-wasi. The production caveats sit around process maturity: no CI yet, no formal release process, solo-maintained. On 541/541 of MicroPython's basic test suite, native petitpy is byte-identical to MicroPython unix-standard.

## Q6: Does it work in a browser?

Yes: wasm is one of two co-primary distributions (64-bit native is the other). `make web` produces `web/nanopython.wasm` (346 KB) and the bundled demos under `web/` show it driving the DOM via the `js` module. The cold-load story is "load and start running in well under a second on a typical connection"; longitudinal measurements are recorded via `make metrics-record`. wasm32-wasi is the current wasm target; wasm64 (memory64) is the strategic wasm target, gated on Zig toolchain support.

What opened the path was replacing MicroPython's `setjmp`/`longjmp` exception machinery, which plain wasm lacks, with Zig's `error{PyRaise}!T` error union. Once that landed, wasm targeting became straightforward.

## Q7: Why is the native Debug binary 3.9 MB?

Zig's Debug mode keeps every function alive (no DCE) and emits full DWARF debug symbols. That's the right tradeoff for development: you want stack traces when things crash. For shipping, use `make build-small`:

```sh
make build-small      # ReleaseSmall — ~541 KB (full) / ~475 KB (nano)
make build-release    # ReleaseFast — ~1150 KB
```

The DWARF symbols are stripped automatically in Release modes.

## Q8: Why does the corpus say 541/541 and not "all 541"?

It is "all 541" now. The denominator (541) is the in-scope test count; the numerator (541) counts tests that pass byte-identical to the frozen reference. The three pre-existing gaps that were listed for years (`builtin_help`, `gc1`, `string_strip`) closed in the 2026-06-11 session, so the nano build now matches on every test. See the v0.5 retrospective in [ADR 009 §11](adrs/009-roadmap-v05.md).

The wasm arm reports **490/541 raw** with a 51-entry documented baseline (`corpus/wasm-known-fails.txt`). The wasm-known-fails entries are explicit deferrals (bignum tests blocked on MPZ, eval/exec tests blocked on the longjmp wall, two `deque_*` tests blocked by a chosen CPython-compat API divergence). The wasm gate is **strict in both directions**: a new fail not on the list and a now-passing test still on the list both fail the gate.

## Q9: How was the Zig runtime built?

Module by module, with a byte-exact test oracle checking every commit, so the runtime kept working at every step (see [How it was built](strangler-journey.md)). That phase ended in mid-2026.

## Q10: What about microcontroller ports (STM32, ESP32, RP2040, etc.)?

Out of scope. MicroPython's home turf is bare-metal embedded; petitpy's distinguishing value is the wasm story. We're optimized for a different cold-load constraint, a different sandbox, a different user. If you need Python on a microcontroller, use MicroPython: it has dozens of mature ports + a community + ecosystem.

The native binary's scope is "Linux/macOS scripting target + development companion." Microcontroller targeting is a separate (large) arc that the project hasn't taken on.

## Q11: How do I report a bug?

If `make` drops below the documented gates on your machine, that's a bug. Steps:

1. Run `make verify` to identify which corpus test regressed.
2. Open the failing `.py` file under `sandbox/micropython/tests/basics/` and the corresponding `.out` golden in `corpus/nano/basics/`.
3. Diff the binary's output against the golden:
   ```sh
   ./zig-out/bin/nanopython sandbox/micropython/tests/basics/foo.py | diff - corpus/nano/basics/foo.out
   ```
4. The diff names what changed.

For wasm-specific bugs, `make wasm-check` produces the same kind of pass/fail list (filtered against `corpus/wasm-known-fails.txt`). For "the binary started but crashed" type issues, the integration suite (`tests/integration.py`) is the right place to add a regression pin.

## Q12: Is this trying to compete with MicroPython?

No. The two aim at different places: MicroPython at microcontrollers, petitpy at the browser and at Linux and macOS daemons and scripts, with more of CPython's language and stdlib.

If you want a production-grade small Python implementation for embedded work, use MicroPython. If you want Python in a browser without 30 MB of Pyodide, petitpy is a credible option.

## Q13: Why so many docs?

Because the project is a *journey* more than a *product*. The interpreter at the end is small; the discipline that produced it is the interesting part. Future readers benefit from understanding the discipline alongside the artifact.

For a quick answer: the README is the short version, and [`COMPATIBILITY.md`](COMPATIBILITY.md) is the "does my code work?" answer.
