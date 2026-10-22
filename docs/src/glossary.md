# Glossary

_Terms that come up in these docs, the ADRs and the source code._

## A – F

**ABI**: Application Binary Interface, the link-level contract between a Zig function declared `callconv(.c)` and the C code that calls it. It is what let a C file be swapped for a Zig module during the port.

**Carveout**: A vendor MicroPython C file that the build compiles back in for a feature that has no Zig implementation, such as floats, `re`, or bignums under the full config. See [Architecture](architecture.md#the-residual-c).

**`@cImport`**: Zig builtin that translates C headers into a Zig namespace. The runtime uses it to read MicroPython's config macros and generated qstr values.

**Compile-exec test**: `tools/compile-exec-test.py`. It compiles each corpus program with `zigpy-compile`, runs the bytecode on upstream MicroPython, and compares the output, which catches compiler bugs on their own.

**Compiler track**: `src/compiler/`, the pure-Zig lexer, parser, scope analysis and bytecode emitter. It ships as `zigpy-compile` and is linked into the interpreter.

**Corpus**: The Python test programs in `corpus/basics/` (copied from upstream MicroPython's `tests/basics/`) and their frozen expected output in `corpus/nano/basics/` and `corpus/full/basics/`. `make check` compares the binary's output against it.

**DCE**: Dead code elimination. Code inside `if (build_options.is_full) { ... }` disappears from nano builds because `is_full` is a comptime constant.

**Differential test**: Running two implementations on the same input and comparing their output byte for byte. The corpus gates are differential tests.

**Embed package**: `vendor/micropython_embed/`, a self-contained MicroPython C library that `make port` generates from upstream. The build takes headers and carveout files from it.

**Full**: The configuration with every available feature on, tracking upstream MicroPython's unix port. It is the default for `make build`.

**Force-analyze block**: `comptime { _ = &f; ... }`. It makes Zig type-check the bodies of exported functions that nothing calls at compile time. `_ = f;` without the `&` does not.

## G – N

**Golden programs**: Real Python programs under `golden-programs/`, sorted by what they need and which runtimes run them. [`COMPATIBILITY.md`](COMPATIBILITY.md) is generated from them. See [ADR 008](adrs/008-golden-programs.md).

**Integration tests**: Small Python programs with expected output, in `tests/test_integration_*.py`, run by `make test-integration` (native) and `make test-integration-wasm`. They check that the binary actually runs real code.

**Known-fails list**: A file such as `corpus/full-known-fails.txt` or `corpus/wasm-known-fails.txt` naming the corpus tests a build is allowed to fail, each with its reason. The gate fails on any unlisted failure and on any listed test that passes.

**Mirrors**: Zig `extern struct` copies of vendor MicroPython C structs in `src/mp_mirrors.zig`, with layout checks so Zig and C agree on every field offset. See [Type Mirrors](internals/mirrors.md).

**`mp_obj_t` / `Obj`**: MicroPython's universal object reference: one machine word holding a tagged small integer, a tagged qstr, another immediate value, or a pointer to a heap object. The Zig side calls it `Obj` (`usize`).

**`mp_state_ctx`**: MicroPython's global interpreter state (the main dict, the qstr pool, GC state and so on). `MpStateCtx` mirrors it in Zig.

**`.mpy`**: MicroPython's compiled bytecode file format. `zigpy-compile` writes it, and the VM loads it. See [Persistentcode Loader](internals/persistentcode.md).

**`mpy-cross`**: Upstream MicroPython's standalone bytecode compiler. petitpy's equivalent is `zigpy-compile`.

**Nano**: The minimal configuration. Its output must match the frozen MicroPython reference byte for byte. The wasm builds always use it.

**NLR (non-local return)**: MicroPython's exception unwinding, built on `setjmp`/`longjmp`. petitpy replaced it with `PyError` error unions; a small trampoline restores it only around the full config's vendor C.

## O – Z

**Oracle**: The reference implementation whose output a test compares against. Here it is upstream MicroPython, through the frozen corpus output.

**Polled sentinel**: How errors cross into C. The function returns a zero value and sets `pyerr.pending_exc`; the caller checks `pending_exc` to see whether an exception was raised.

**`PyError`**: `error{PyRaise}`, the Zig error that means "a Python exception was raised and `pyerr.pending_exc` holds it". Every Zig function that can raise returns `PyError!T`. See [PyError Convention](internals/pyerror.md).

**qstr**: An interned string with a small integer ID, used for names, attributes and messages so that comparing them is an integer compare. Code refers to them as `MP_QSTR_<name>`. See [qstr Generation](internals/qstr-gen.md).

**qstr-gen**: The build step that scans sources for `MP_QSTR_*` references and generates the qstr table. `tools/zig_qstr_shadow.py` extends it to Zig sources.

**Shim**: A small C file paired with a Zig module, holding code that only works in C. Almost all were removed; `objmodule_shim.c` remains for the built-in module table.

**Small int**: An integer stored directly in the object word with a tag bit, so it needs no heap allocation.

**Strangler**: Replacing a system piece by piece while a behavior-preserving check runs after every step. petitpy replaced MicroPython's C this way. See [How it was built](strangler-journey.md).

**Vendor C**: MicroPython's own C sources, taken from `vendor/micropython_embed/`.

**`vendor/micropython`**: The upstream MicroPython checkout at the revision pinned by `MICROPY_REV` in the Makefile, cloned by `make bootstrap` or symlinked. It is not committed. `make port` generates the embed package from it.

**VM track**: `src/runtime/`, `src/objects/`, `src/modules/` and `src/memory/`: the bytecode interpreter, object model, built-in modules, allocator and garbage collector.

**`zigpy-compile`**: The standalone compiler binary (`zig-out/bin/zigpy-compile`), which turns a `.py` file into a `.mpy` file. It is petitpy's equivalent of `mpy-cross`.
