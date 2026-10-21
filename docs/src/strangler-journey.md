# How it was built

_How petitpy's interpreter moved from MicroPython's C to Zig, one module at a time, without ever breaking, using the "strangler" pattern. This is the short version._

## The setup

MicroPython is a self-contained Python implementation in C. Its `unix/standard` port compiles to ~652 KB and runs a corpus of ~550 small Python programs whose outputs are known. Deviations are real bugs.

The strangler starts by freezing that corpus's output. From then on, every petitpy build is checked against those frozen bytes. Any drift fails the build. That single byte-exact oracle kept a full-runtime rewrite in a different language correct for the whole arc.

## The arc

The rewrite replaced the C runtime one subsystem at a time (lexer, parser, compiler, emitter, `.mpy` loader, VM dispatch, object model, allocator, GC). Each subsystem got a Zig module matching the vendor C file's link surface, then the vendor `.c` file was dropped from the compile graph and the Zig module linked in its place. If the binary still linked and the corpus stayed green, the port shipped.

Three later arcs finished the extraction:

- **The `.mpy` loader** (~940 LOC). Ported field-for-field against the vendor loader's binary format, then the C file was removed, leaving no vendor C behind the core interpreter.
- **The qstr / module registration tooling.** MicroPython's build tools scan `.c` files for `MP_QSTR_*` markers to build the qstr table. A small tooling extension (`tools/zig_qstr_shadow.py`) lifts markers out of `.zig` files into a generated shim that the upstream scanner can see. Nine tombstone C files disappeared; one remained after that arc, `src/objects/objtype/objmodule_shim.c` (86 LOC), which holds `MICROPY_REGISTERED_MODULES` (a preprocessor macro expanding to a C struct initializer).
- **Non-local return.** MicroPython uses `setjmp`/`longjmp` for exception propagation. Zig has no `setjmp`; it has `error{PyRaise}!T`. Every raise site converted to `return error.PyRaise`; every catch site converted to `try` or `catch`. When the last vendor NLR file was deleted, the runtime was exception-propagating end-to-end without `setjmp`. That change made the wasm target possible: wasm lacks native `setjmp` and the NLR-elimination sidestepped a wall the project would have hit later.

## The result

| | Before | After |
|---|---|---|
| Vendor C, core interpreter | ~53,000 LOC | 0 |
| Vendor C, default-on feature carveouts (`float`, `re`) | 0 | ~1,900 LOC |
| Project-local C | 0 | 616 LOC in 3 files |
| Corpus byte-identical (nano) | 534/541 at the start | **541/541** |

The strangler's own residue is the 86-LOC qstr-gen tombstone; removing it needs either upstream tooling changes or a Zig-native module-table generator, and it's not in current scope. The other two files arrived later and for unrelated reasons: a `va_list` surface that Zig 0.16 cannot compile on `aarch64-linux`, and ADR 013's NLR trampoline, which is dead under nano. [Architecture](architecture.md#the-residual-c) breaks them down.

## The methodology, in three primitives

- **A byte-exact differential oracle.** The corpus lives frozen; every build checks against it; drift fails. A large mechanical rewrite can then proceed without a design phase.
- **The type-mirror pattern** (`src/mp_mirrors.zig`). Zig `extern struct` declarations mirror vendor MicroPython C structs field-for-field, with `@sizeOf` / `@offsetOf` checks so a layout drift fails the build at the right place. Zig code reads and writes vendor structs directly, no shim layer.
- **Polled-sentinel error propagation.** Every function that can raise returns a `PyError!T` union; every caller polls or propagates via `try`. Across the C↔Zig boundary the sentinel is a status word, which lets both sides participate in the same discipline without one having to speak the other's exception convention.

## What the strangler taught

A handful of rules held across the whole arc:

- Corpus goldens are binary fixtures. Never run formatters over them. A trailing-newline tool silently broke the invariant once.
- `_ = &func;` forces Zig to analyze a function's body; `_ = func;` does not. Using the wrong form gave "fake green" builds that shipped uncompiled code.
- When fanning out N mechanical conversions in parallel, do one first as a pattern-locker. The remaining N-1 copy the pattern exactly. Independent adversarial verification on each conversion caught issues the porting agents missed.
- Bail early; never ship a broken tree. Two attempts at the allocator-NLR removal bailed on architectural couplings the audit missed. The third succeeded because the earlier bails localized the coupling exactly.
