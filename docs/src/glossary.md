# Glossary

_This page is reference material for contributors. It defines the terms that come up in the source code, ADRs, and notes. If a term in the codebase is opaque, this page is the first place to look._

## A – C

**ABI**: Application Binary Interface. It is the link-level contract between a Zig function with `callconv(.c)` and the C code that calls it. It stayed stable across the strangler arc: the calling convention doesn't change even when the implementation moves from C to Zig.

**addCSourceFiles**: `zig build`'s API for including C files in the compile graph. The build uses explicit per-arm lists (nano default, longint carveout, float carveout, full carveout); each arm names exactly which vendor C files it pulls in.

**B2**: Pre-NX naming for the architectural "drop setjmp/longjmp, use PyError propagation end-to-end" arc. Goal achieved in NX-3.

**B2DEBT**: A pre-NX-3 shim category: a Zig file's `_shim.c` companion that's known-to-be-removable but waiting for cleanup. Eliminated entirely by NX-3.

**Bridge**: Two meanings. (1) `pyerr.bridge(T, r)`: the inline fn that converts `PyError!T` to a C-ABI-shaped polled-sentinel return. (2) `zig_compile_bridge.zig` is the file that connects the Zig compiler track to the Zig VM track.

**`build_options.is_full`**: A comptime constant from `build.zig` that's `true` when `-Dconfig=full` is passed, `false` for `-Dconfig=nano` (default). Used in `if (build_options.is_full)` blocks that DCE under nano.

**`callconv(.c)`**: Zig syntax marking a function with the C calling convention. Required for any Zig function that's called from C-ABI code or via `@ptrCast` from a function-pointer table.

**`@cImport`**: Zig builtin that runs C headers through `translate-c` and exposes the result as a Zig namespace. The project uses it sparingly: once for `py/qstr.h` to access generated qstr enum values, once for `py/mpconfig.h` to access C-side config macros.

**Compile-exec-test**: Secondary gate (`tools/compile-exec-test.py`). Compiles each test `.py` to `.mpy` via `zigpy-compile`, runs the `.mpy` through upstream MicroPython's VM, diffs the result against the full-config golden. Tests execution equivalence (different peephole optimizers can produce different bytecode for the same semantics).

**Compiler track**: `src/compiler/`. It is made of pure Zig modules: lexer, parser, scope analyzer, bytecode emitter, compile driver. It ships as the `zigpy-compile` binary AND links into the main interpreter.

**Corpus**: `corpus/nano/basics/*.out` (or `corpus/full/basics/*.out`). Frozen stdout/stderr/exit-status fixtures for each Python test program in `sandbox/micropython/tests/basics/`. `make check` measures the byte-identity comparison against these fixtures.

## D – H

**DCE**: Dead Code Elimination. Zig's release modes aggressively delete unreachable code. `if (build_options.is_full) { ... }` blocks DCE under nano because `is_full` is a comptime `false`.

**Differential test**: The strangler's primary technique. Run two implementations on the same input, compare output byte-for-byte. The corpus is the differential test set.

**E2E / End-to-end test**: `make check` is the E2E gate. Runs the actual binary against the actual frozen goldens.

**Embed package**: `vendor/micropython_embed/`. A self-contained MicroPython C library generated from upstream by `make port`. Originally what the strangler compiled wholesale; today, only the per-feature carveouts (longint, float, full's MPZ + IO + warning + builtin_help) compile from it. Under `-Dconfig=nano` with default flags the core interpreter pulls nothing from it, but the default-on `float` and `re` carveouts do (~1,900 LOC); see [Architecture](architecture.md#the-residual-c).

**`extern fn`**: Zig declaration of a function defined elsewhere (typically a C symbol or another Zig module). Used pervasively to declare vendor MicroPython functions that the strangler hasn't yet ported.

**Full**: Config arm enabling everything-on (float, complex, io, longint via MPZ, ranges-with-attributes, etc.). It builds and runs as of v0.5. Its parity target is upstream MicroPython unix-standard.

**Force-analyze block**: `comptime { _ = &fn; _ = &fn2; ... }`. Forces Zig to compile-check the bodies of `pub export fn`s that wouldn't otherwise be analyzed (because nothing calls them at compile time). Required to catch type errors in exports the VM only reaches at runtime.

**`grammar_data.zig`**: Parsing grammar table, generated at build time by `tools/gen_grammar.py` from vendor MicroPython's `grammar.h` after `port/grammar-patched/patch_grammar.py` has extended it. The patch adds PEP 448 dict/list unpack in more positions and PEP 570 positional-only `/` markers (added to unblock hop3-rootd). Upstream's grammar rejects both.

## I – N

**Integration test**: `tests/integration.py` + `make test-integration` / `make test-integration-wasm`. It is a 189-case smoke suite of small Python programs run through the binary, with output (and exit code) diffed against expected. It is runner-pluggable via `--runner`, so the same suite drives both arms.

**Invariant gate**: `make check`. The forcing function. Every commit must keep `make check` at the same byte-identical pass count.

**Keystone**: In the NX-3 N4a workflow, the central function whose conversion drives the rest. For N4a it was `mp_obj_str_get_str` + `bad_implicit_conversion`. Converting the keystone forced 9 callers across 5 files to change atomically.

**`MICROPY_*` macros**: MicroPython config macros. Live in `port/mpconfigport.h` (with both nano and full arms) + the vendor `mpconfig.h` (defaults). Read by Zig via `@cImport` in a handful of files where the gate is shared with vendor C.

**Mirrors / `mp_mirrors.zig`**: The file (~1,200 lines, ~40 `extern struct` declarations) matching every vendor MicroPython C struct petitpy touches. Each has `@sizeOf` / `@offsetOf` checks so Zig and C agree on the byte layout.

**`mp_obj_t`**: MicroPython's universal object type. On REPR_A it is a `usize` with a low-bit tag (small-int) or a pointer with tags. petitpy uses `Obj = usize` for the Zig side; conversions via `mirrors.objFromQstr`, `mirrors.objFromPtr`, etc.

**`mp_state_ctx`**: MicroPython's global state singleton. Holds the VM stack pointer, the qstr pool, the GC state, the dict_main, the NLR top, etc. Mirrored by `MpStateCtx` in `mp_mirrors.zig`.

**`MP_BC_*`**: MicroPython bytecode opcodes. `MP_BC_LOAD_CONST_NONE`, `MP_BC_BINARY_OP`, etc. The VM is a giant switch over these.

**`MP_QSTR_*`**: Generated qstr enum values. Each unique string used by the interpreter (method names, attribute names, module names, error messages) is assigned an integer at build time. `MP_QSTR_print`, `MP_QSTR___init__`, etc.

**`mpy-cross`**: Upstream MicroPython's standalone bytecode compiler. petitpy's equivalent is `zigpy-compile`.

**Nano**: Config arm enabling a subset of features. The frozen invariant runs against nano (**541/541** byte-identical to `corpus/nano/basics/`). Default for `make build`. The wasm shipping artifact is built nano.

**NLR / Non-Local Return**: MicroPython's exception unwinding mechanism: `nlr_push` / `nlr_pop` / `nlr_jump` using `setjmp`/`longjmp`. Replaced by Zig's `PyError!T` error union in NX-3. The `nlr.c` + `nlrsetjmp.c` + `nlr_trampoline.c` files were deleted in NX-3 N4.

**NX-1, NX-2, NX-3**: The three-arc strangler push of 2026-06. NX-1 ported `persistentcode.c` (the last vendor C in the compile graph), NX-2 extended qstr-gen tooling to read `.zig` files, NX-3 rewrote the NLR boundary. The full arc reduced compiled C from 1,554 to 86 LOC.

## O – R

**`Obj`**: `usize` in Zig. It holds either a tagged small-int, a tagged qstr, or a pointer to a heap object. It is the universal type-erased reference, equivalent to `mp_obj_t` in MicroPython C.

**`objmodule_shim.c`**: The 86-LOC qstr-gen tombstone. It holds `MICROPY_REGISTERED_MODULES`, the macro-table that lists every available module. It can't be eliminated without upstream tooling changes, so it is the architectural floor.

**Oracle**: The reference implementation against which output is compared. The strangler's primary oracle is upstream MicroPython unix-standard (for corpus/full goldens) and the frozen nano-C reference build (for corpus/nano goldens).

**Polled sentinel**: Pre-NX-3 error propagation pattern. A fn returns a sentinel value (`0` / `OBJ_NULL`) and sets `pyerr.pending_exc` to the raised exception. Caller checks `pyerr.pending_exc` to detect raise. Largely replaced by `PyError!T` in NX-3 but lives on at C-ABI boundaries where Zig's error union can't cross.

**`pub export fn`**: Zig syntax marking a function as a public C-ABI export. C callers reach it via the link-level symbol. It is used for every fn the vendor C runtime expects to call (when it existed) + every fn the integration tests / REPL reaches.

**`PyError`**: `error{PyRaise}`. The single Zig error type representing "a Python exception was raised; pending_exc holds the exception object." Every internal Zig fn that can raise returns `PyError!T`.

**`pyerr.zig`**: The error-propagation glue module. Defines `PyError`, the `pending_exc` threadlocal, and the `bridge(T, r)` inline fn that converts `PyError!T` to a polled-sentinel C-ABI return.

**qstr**: Interned string, MicroPython's universal string-interning mechanism. Every `__init__`, `print`, `foo`, etc. is assigned a small-integer ID at build time (`MP_QSTR_*`) or runtime (`qstr_from_strn`). A qstr is cheap to compare and expensive to allocate.

**qstr-gen**: The build-time machinery that scans source files for `MP_QSTR_*` references and produces `qstrdefs.generated.h`. Lives in `sandbox/micropython/py/makeqstrdefs.py`; the project extends it via `tools/zig_qstr_shadow.py` to also read Zig files.

**REPR_A**: MicroPython's default object representation. Tagged `usize`: low bit set = small-int, low byte `0b...010` = qstr, otherwise pointer to a heap object whose first word is the type pointer. petitpy uses REPR_A under both nano and full.

**`raise.zig`**: `src/runtime/raise.zig`. Exception-construction helpers. Post-NX-3, contains polled-sentinel `mp_raise_*_polled` siblings plus a handful of remaining `noreturn` exports for memory exhaustion and a few stream paths.

## S – Z

**`sandbox/micropython`**: Symlink to a local MicroPython git checkout. Gitignored. Provides the upstream tree from which `make port` regenerates the embed package.

**Shim**: A small `.c` file paired with a Zig module, holding macros or static-inline functions the Zig side can't reach. Most `_shim.c` files were eliminated during NX-1/NX-2/NX-3. The remaining `objmodule_shim.c` is the architectural floor.

**Smallint**: A `mp_obj_t` with the low bit set, encoding a 63-bit signed integer. Python-semantic arithmetic on these is in `src/support/smallint.zig`.

**Strangle**: Two meanings. (1) The strangler pattern itself: incremental replacement under a behavior-preserving oracle. (2) It also names a specific commit that deletes the vendor C version of a subsystem after the Zig replacement is wired. The NX-1 strangle deleted `persistentcode.c`; the NX-3 N4 strangle deleted `nlr.c` + `nlrsetjmp.c` + `nlr_trampoline.c`.

**`strangled[]`**: Historical. An array in `build.zig` (now removed) that listed vendor C files excluded from the compile graph. The build now uses explicit per-arm `addCSourceFiles` lists; the inverse view is implicit (anything not in the per-arm lists is excluded).

**`tests/integration.py`**: The integration smoke suite. 37 hand-curated programs, each a tuple of (name, py-source, expected-stdout) or (name, py-source, expected-stdout, expected-exit). Runner-pluggable via `--runner`, run via `make test-integration` (native) or `make test-integration-wasm` (wasm).

**`tools/`**: Python scripts. `corpus.py` (freeze + verify), `progress.py` (the percentage display), `compile-exec-test.py` (the secondary differential gate), `gen_grammar.py` (regenerate `grammar_data.zig`), `zig_qstr_shadow.py` (qstr scanner that reads `.zig` files), `wasm_gate.py` (the strict wasm regression detector), `gen_compatibility.py` (auto-generates `docs/COMPATIBILITY.md` from `golden-programs/`), `metrics.py` (longitudinal size/coverage/perf recording), `browser-smoke.py` (headless Chromium harness for web demos), `golden_bootstrap.py` (golden-programs bucketer).

**Translate-c**: Zig's built-in C-to-Zig source translator. Used via `@cImport`. Slow but works for most headers. petitpy uses it minimally.

**Unit test**: `make test-unit` runs ~100 tests inline in Zig source files, in `test "..." { ... }` blocks. Per-module targets exist (`make test-unit-compiler` / `test-unit-vm`).

**Validator pattern**: The locked code-shape for the NX-3 N1 leaf conversions, named after `objslice.zig` (the first leaf, commit `6752953`). Internal `xImpl(...) PyError!T` + small `raiseX() PyError!void` helper + `pub export fn x(...) callconv(.c) Obj { return pyerr.bridge(Obj, xImpl(...)); }`. Every subsequent leaf copies this exact shape.

**Vendor C**: Code in `vendor/micropython_embed/`, the auto-generated upstream MicroPython embed package. Under `-Dconfig=nano` with default flags the core interpreter uses no vendor C; the default-on `float` and `re` carveouts compile ~1,900 LOC of it (wasm adds ~861 more for longint). Per-feature carveouts (longint, float, full's MPZ + IO + warning + builtin_help) selectively pull individual vendor `.c` files back in. The directory always exists for `@cImport`-time header lookups.

**VM track**: `src/runtime/` + `src/objects/` + `src/modules/` + `src/memory/`. It holds the bytecode interpreter, object model, builtin modules, allocator + GC. Contrast it with the **Compiler track**.

**Worktree**: A separate git checkout sharing the underlying object store. Used by AI-orchestrated parallel agents (via `.claude/workflows/`) so each agent can work in isolation, commit, then have the main loop cherry-pick the chain back. See workflow scripts under `.claude/projects/.../workflows/`.

**`zigpy-compile`**: Standalone binary at `zig-out/bin/zigpy-compile`. Compiles a `.py` file to a `.mpy` v6 file. It is the Zig equivalent of upstream's `mpy-cross`, and it powers the `compile-exec-test.py` differential gate.
