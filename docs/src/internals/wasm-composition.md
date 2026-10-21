# WASM composition: what's inside `nanopython.wasm`

A snapshot of the wasm binary's layout, what each subsystem contributes, and where the remaining size budget is hiding. Numbers below were measured at the project state of this commit. Re-running `python3 scripts/wasm_composition.py` regenerates the report against the current binary. The snapshot below explains the layout, and the metrics history tracks it.

The companion script `scripts/wasm_composition.py` is the canonical tool for this analysis. It has no external dependencies and reads `web/nanopython.wasm` by default; pass an alternate path to inspect a different build.

---

## Snapshot

`web/nanopython.wasm` is 343,714 bytes raw (~336 KB) and ~140 KB compressed. It is built with `zig build -Dtarget=wasm32-wasi -Doptimize=ReleaseSmall` against the `nano` config + `-Dfeature-js=true`. No name section (ReleaseSmall strips it), no debug info, no sourcemaps.

### Section-level breakdown

| Section | Bytes | % | Notes |
|---|---:|---:|---|
| **Code** (function bodies) | 260,153 | 75.7% | 1,453 defined Zig functions |
| **Data** (initial memory) | 52,394 | 15.2% | qstr strings + ROM tables + error messages |
| **Export** (symbol names) | 23,347 | 6.8% | 1,026 exported names (the strangler's C-ABI surface) |
| **Global** (mutable slots) | 3,271 | 1.0% | 408 globals (qstr table base, builtin singletons, ROM addresses) |
| **Import** (host functions) | 1,571 | 0.5% | 46 imports: 38 WASI shims + 8 J5 JS bridge externs |
| **Function** (signatures) | 1,460 | 0.4% | 1,453 type indices |
| **Element** (indirect-call table) | 1,088 | 0.3% | vtable entries for type slots |
| **Type** (signatures dedup) | 423 | 0.1% | 55 unique function signatures |
| **Table** + **Memory** | 15 | 0.0% | declarations |

### Function-size distribution

| Bucket | # funcs | Total bytes | % of Code |
|---|---:|---:|---:|
| ≤32 bytes | 400 | 6,439 | 2% |
| 32–128 | 536 | 38,884 | 15% |
| 128–512 | 427 | 106,006 | 41% |
| 512–2,048 | 81 | 66,658 | 25% |
| 2,048–8,192 | 8 | 30,002 | 11% |
| 8,192+ | 1 | 10,185 | 4% |

Median function: 74 bytes. Average: 177 bytes. The single largest is `npy_zig_compile_to_mpy` at 10 KB (the parse-tree → bytecode pipeline as one big switched dispatch).

### Code section by inferred subsystem

604 of the 1,453 functions have export names; the other 849 (68% of the code section) are internal Zig static helpers and slot dispatchers that ReleaseSmall stripped names for. Classifying by export-name prefix:

| Subsystem | Bytes | % | # funcs | Notes |
|---|---:|---:|---:|---|
| Unnamed internal Zig | 177,971 | 68% | 849 | static helpers, closure bodies, the bulk of VM dispatch, parser internals, GC mark/sweep |
| Compiler driver | 10,266 | 3% | 3 | `npy_zig_compile_to_mpy` parse→emit |
| Misc `mp_*` utilities | 8,236 | 3% | 86 | hash, qstr lookup, type predicates |
| Object: str | 7,991 | 3% | 97 | str slot ops, vstr, mpprint (97 named functions) |
| Object: list/tuple/array | 6,861 | 2% | 44 | seq ops, indexing, slicing |
| WASI startup | 6,701 | 2% | 3 | `_start`, `__main_argc_argv` + Zig std runtime bootstrap |
| Strangler bridges (`npy_*`) | 4,389 | 1% | 46 | C-ABI shim wrappers around `pyerr.bridge(...)` |
| Object: int/bool/bignum | 4,279 | 1% | 32 | int slot ops, bignum (compiler track) |
| Object: dict/map/set | 4,251 | 1% | 46 | hash maps + set ops |
| Object: iter | 3,449 | 1% | 31 | generator/enumerate/filter/zip/reversed |
| Modules: builtins | 2,828 | 1% | 36 | print, len, abs, … |
| Object: type/instance/module | 2,807 | 1% | 19 | metaclass machinery |
| Runtime dispatch | 2,724 | 1% | 25 | `mp_binary_op`, `mp_call_*`, `mp_load_*`, `mp_subscr` |
| qstr pool | 1,899 | 1% | 12 | interning + hash table |
| VM bytecode | 1,883 | 1% | 3 | `mp_execute_bytecode` (most VM body is inside the unnamed-internal pool) |
| Exception machinery | 1,782 | 1% | 22 | `mp_raise_*` + polled-sentinel bridge |
| Print / format | 1,088 | 0% | 1 | `mp_vprintf` |
| Object: fun/closure | 1,420 | 0% | 13 | callable machinery |
| Parser | 980 | 0% | 7 | most parser is inside the unnamed pool |
| Other (deque, GC, m_*, range, stream, modules) | <1 KB each | ~4% | scattered | small surfaces |

### Source-LOC → wasm bytes ratio

The 34,103 lines of Zig become a 258 KB Code section, about 7.6 bytes per source line after `-Doptimize=ReleaseSmall`. The Code section is roughly traceable to source-tree subdirectories:

| `src/` subdir | LOC | Estimated wasm contribution |
|---|---:|---:|
| `runtime/` (VM + dispatch + builtins-host) | ~10,000 | ~75 KB |
| `objects/` (all Python types) | ~8,000 | ~60 KB |
| `compiler/` (lexer + parser + emit + scope + mpy) | ~7,000 | ~50 KB |
| `modules/` (sys, math, struct, gc, collections, …) | ~3,500 | ~25 KB |
| `mp_mirrors.zig` + `pyerr.zig` + `mp_layout_check.zig` + `mp_type_roms.zig` + `entry/` | ~2,000 | ~15 KB |
| `memory/` (gc, alloc, pairheap, ringbuf) | ~1,500 | ~10 KB |
| `support/` (smallint, unicode, stream, readline) | ~1,500 | ~10 KB |
| `main.zig`, `main_vm.zig`, `vendor_stubs.zig`, glue | ~600 | ~5 KB |

### Data section composition (51 KB)

| | Bytes | Content |
|---|---:|---|
| Printable ASCII strings | ~12,500 | 967 distinct strings: error messages, version banner, qstr-pool seed strings, builtin module names, ROM type names |
| Binary tables | ~39,500 | qstr hash table + qstr length/offset arrays, builtin module registry, ROM type structs, slot vtables, dispatch tables |

Two data segments: one for `.rodata` (constants), one for the initial `.data` (mutable globals starting state).

### Imports: the host surface

| | |
|---|---|
| WASI shims | 38: full WASI preview1 surface (`fd_*`, `path_*`, `clock_*`, `proc_exit`, `random_get`, `poll_oneoff`, …) |
| J5 JS bridge | 8: `js_call`, `js_get_global`, `js_get_attr`, `js_set_attr`, `js_new`, `js_to_string_len`, `js_from_string_len`, `js_dispatch_callback` |

If you build with `-Dfeature-js=false`, the 8 JS imports disappear and any js.py-only Python disappears from the qstr pool.

---

## Opportunities for fat loss

Roughly ordered by cost-to-implement vs. expected payoff. Theme F's per-feature flags already produced an 8.95% reduction (286 KB → 262 KB); the techniques below extend beyond that.

### Easy wins (mechanical; estimated 10–25% reduction combined)

1. **Run `binaryen wasm-opt -Oz` post-link**. Mentioned in ADR-001 Theme F. Typically 5–15% on a Zig-produced wasm binary with no source changes: peephole optimization, function-body simplification, dead-instruction removal. Plug into the build as a `make wasm-opt` target after `zig build -Dtarget=wasm32-wasi`.

2. **Strip the Export section more aggressively**. We currently export 1,026 names (23 KB). Many `npy_*` strangler bridges were exported so vendor C could call them; with vendor C gone under nano, only the bridges still consumed by Zig-from-Zig or by the JS bridge actually need export. An audit pass that finds unreferenced `pub export fn` and demotes them to `pub fn` could halve this section (~10 KB savings + the function body itself becoming DCE-eligible). The audit is mechanical: dump exports, grep for callers outside the strangler, demote the rest. Risk: anything called from the `m_layout_check_*` runtime path, the `mp_state_ctx` accessors, or the WASI startup must remain exported.

3. **Cull unused WASI imports**. We import 38 WASI functions; the runtime path used by `web/*` demos calls perhaps 6 (`fd_write`, `proc_exit`, `clock_time_get`, `random_get`, the fd-related ones for stdin). The other ~32 (filesystem path operations, polling, environment access) come in because Zig's std library declares them in case any path through std happens to use them. Forcing `--export=foo` flags + `--no-import` for unused WASI names (or providing trivial stub Zig code that doesn't reach those) would cut the Import section by perhaps 1 KB and let the linker DCE the std-library code paths that reference them. Possibly a few hundred bytes inside Code too.

4. **Shorten error message strings**. The 12.5 KB of strings in Data includes verbose user-facing messages like `"unsupported value type for js bridge (must be str, int, bool, callable, or JsProxy)"` (84 bytes). Replacing with error codes + a small lookup table in user space would compact this, though at the cost of message quality. A middle ground: a `-Dterse-errors=true` flag that swaps the verbose strings for short codes; tools/tests look up the codes for human display. Potential savings: 5–8 KB.

### Medium wins (architectural; another 5–15%)

5. **Sub-component carveouts**. The Theme F notes mention an experimental `nanopython-vm.wasm` at 217 KB that strips the compiler and ships only the VM (loads `.mpy` files at startup). A formal `make vm-only` target would produce this artifact: the compiler track moves to a separate compile-time toolchain; the runtime wasm gets ~50 KB lighter. Trade-off: users can't compile Python at runtime; they pre-compile via `make build-mpy yourfile.py`. Good for "ship a fixed Python program" workflows like the ci-build-monitor extension, where the source is known at deploy time.

6. **Combine printf-family code paths**. `mp_vprintf` is 1 KB, and the wrapping helpers (`mp_print_str`, `mp_print_int`, `mp_print_mp_int`, `mp_printf` with different signatures) collectively account for several KB across Print/format. A single `mp_format` entry point with type-tag dispatch, replacing N specialized formatters, could save ~2 KB. Architectural cost: changing the Print protocol breaks the strangler's exact-mirror discipline. Defer until the strangler discipline no longer applies.

7. **Object slot dispatcher consolidation**. Each Python type owns a `mp_obj_type_t` struct with print/binary_op/unary_op/subscr/getiter/iternext/buffer_p/protocol slots: ~30 fields per type, many of which are null for any given type. With ~25 types in nano, the slot tables are 25 × 30 × 8 bytes = ~6 KB of mostly-null ROM. A compact format (bitmap + non-null entries) could halve this. Trade-off: an extra indirection on every slot dispatch; the per-call cost is small (one cmp + one load) but it changes the hot path.

8. **More per-feature flags**. Theme F gates 8 modules; the same mechanism can extend to language features (generators, comprehensions, f-strings, decorators) where the compile + runtime cost can be skipped per-build. Each gate is small (1–4 KB) but additive. Risk: combinatorial explosion in CI matrix; the per-feature build registry from ADR-002 Path C addresses this.

### Harder wins (research-grade; 10%+ each but with significant cost)

9. **Move the compiler to a separate wasm**. Same idea as #5 but stricter: split into `nanopython-compile.wasm` (lexer + parser + emit, runs only when the user changes source) and `nanopython-vm.wasm` (runtime, loads `.mpy` from preopen). A loader page coordinates. Two-binary architecture is more complex to deploy but lets users pay ~217 KB, down from 336 KB, for the "run mode," and the compile pipeline becomes optional. The playground demo would still ship both; the production-extension use case would ship just the VM.

10. **Aggressive `--gc-sections` curation**. The Zig build already enables `-fno-stack-check` and `-fLLVMSize=4`. Adding explicit `--export=` listings + `--no-entry`-style aggressive DCE might find unreachable code in the std library and the strangled-but-still-linked vendor stubs. Cost: each new `--export=` is a manual decision; if anything is forgotten the runtime traps. Worth ~3–8 KB if done carefully.

11. **Compress / dedup the qstr table**. The qstr pool has the ~12.5 KB of string content + several KB of length+offset arrays. Many qstrs are short (3–10 bytes); the per-entry metadata is significant relative to the entry. A more compact format (4-bit-length prefix + variable-byte offsets) could save ~3 KB. Cost: the qstr hot path becomes more complex; the strangler convention assumes the existing format.

### What probably won't help

- **Switching to ReleaseFast.** Larger by ~20% (~50 KB) for marginal runtime gains. We're already on ReleaseSmall for a reason.
- **Switching to a different Zig version.** Zig 0.16 → 0.17 is unlikely to give >5% size delta on its own; Zig is already aggressive with LLVM size optimization.
- **Manual hand-coded assembly.** wasm32's text format isn't friendlier to size-tuning than Zig's IR is. The pipeline is already wasm-friendly.
- **Compressing the wasm in transit.** Already done via standard gzip/brotli; the 140 KB compressed figure is the practical download cost.

---

## How to reproduce

```sh
make web    # build web/nanopython.wasm
python3 scripts/wasm_composition.py web/nanopython.wasm
```

For a `wasm-tiny`-built binary:

```sh
make wasm-tiny
python3 scripts/wasm_composition.py zig-out/bin/nanopython.wasm
```

The script's output format is stable; diffing two runs against different builds is a fair proxy for "did my change make the binary smaller?"

---

## See also

- ADR-001 §Theme F: per-feature flag mechanism + wasm-tiny target
- ADR-002: per-feature `-D` flags; oracle role shift post-convergence
