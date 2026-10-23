# WASM composition: what's inside `petitpy.wasm`

`scripts/wasm_composition.py` reports what a wasm binary is made of. It reads the WebAssembly format directly, has no dependencies, and inspects `web/petitpy.wasm` unless given another path:

```sh
make web
python3 scripts/wasm_composition.py                       # the shipping artifact
python3 scripts/wasm_composition.py zig-out/bin/petitpy.wasm
```

It prints section sizes, the function-size distribution, a breakdown of the Code section by subsystem, the printable strings in the Data section, and the imports. The output format is stable, so diffing two runs is a fair way to see whether a change made the binary smaller.

## What the binary looks like

`make web` builds the wasm32-wasi binary with the `nano` config, `ReleaseSmall`, frozen-tiny modules and the JS bridge, then runs `wasm-opt -Oz` on it when binaryen is installed.

- **Code** is about three quarters of the file. Most functions are small, and a handful of large ones (the compiler driver, the bytecode dispatch loop) account for a disproportionate share.
- **Data** is most of the rest: qstr strings, error messages and the version banner, plus binary tables (the qstr hash table and length arrays, ROM type structs, slot tables, the module registry).
- **Imports** are the WASI preview1 functions that Zig's standard library and wasi-libc declare, plus the JS bridge functions when `-Dfeature-js=true`.
- **Exports** are almost empty. `build.zig` exports only the WASI entry point and, with the JS bridge, `npy_dispatch_callback` and `m_malloc`.

The subsystem breakdown classifies functions by their export names. Since the shipping binary has almost no exports and `ReleaseSmall` strips the name section, nearly all code shows up as "unnamed (internal Zig)". The section sizes, the function-size distribution and the Data strings remain useful.

## Ways to make it smaller

[ADR 007](../adrs/007-wasm-fat-loss.md) plans the size work and refers to these items by number. They are ordered by cost.

**Easy (mechanical)**

1. **Post-link `wasm-opt -Oz`.** Done: `make web` runs it, and `make wasm-opt` does the same for a local build.
2. **Strip the Export section.** Done: the build no longer exports every `pub export fn`, which also lets the linker drop unreferenced functions.
3. **Cull unused WASI imports.** Much of the WASI surface is imported because the standard library declares it, not because the browser path calls it. Stubbing the unused functions would shrink Import and let some library code be removed.
4. **Shorter error messages.** A build flag could swap verbose messages for short codes, at a cost in message quality. Not implemented.

**Medium (architectural)**

5. **A VM-only binary.** `zig build` already produces `petitpy-vm`, which loads precompiled `.mpy` and has no compiler. It suits deployments whose Python source is fixed ahead of time.
6. **Merge the printf-family paths** into one formatting entry point.
7. **Compact type slot tables.** Most slots are null for any given type; a bitmap plus the non-null entries would be smaller, at the cost of an extra step on every slot dispatch.
8. **More feature flags** for language features (generators, f-strings, comprehensions), each a small saving that adds up, at the price of a larger CI matrix ([ADR 002](../adrs/002-feature-selection.md)).

**Hard (research)**

9. **Split compiler and VM into two wasm modules,** loaded together by the page, so a run-only deployment ships only the VM.
10. **Curate `--gc-sections` with explicit exports** to find more dead code. Every forgotten export becomes a runtime trap.
11. **A denser qstr table format.** Many qstrs are short, so per-entry metadata is a large share; a denser format makes the qstr hot path more complex.

**What won't help**

- `ReleaseFast`: larger, for little runtime gain in the browser.
- Waiting for a newer Zig: LLVM already optimizes for size.
- Hand-written wasm: Zig's output is already wasm-friendly.
- Transport compression: servers already gzip or brotli the file.

## See also

- [ADR 007](../adrs/007-wasm-fat-loss.md): the size-reduction plan
- [ADR 002](../adrs/002-feature-selection.md): per-feature `-D` flags
- [`scripts/wasm_composition.py`](https://github.com/abilian/petitpy/blob/main/scripts/wasm_composition.py)
