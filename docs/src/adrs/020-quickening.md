# ADR 020. Quickening and the interpreter's next speed step

- **Status**: Implemented (2026-10-12): option C done; option A rejected; option B declined on a browser profile (§3)
- **Decider**: project maintainers
- **Branches from**: ADR 017 (the bytecode boundary is a supported interface), [ADR 005](005-future-optimization-proto.md) (inline caching and superinstructions in the landscape map)
- **Consequences**: no quickening; the three cheaper steps landed; the shipped web build must keep `dispatchBody` out of line for V8 to tier it up (§3).

## 1. Context

The local interpreter work is done: inline small-int and `list[int]` paths, the full-switch dispatch threaded on native, the map lookup cache, the bool check in conditional jumps. Native nano is now about 1.4x faster than MicroPython on fibo and bubble. What is left is spread across the dispatch loop and the call path, with no single hot spot, and wasm runs at 1.5–3x native.

Quickening (CPython 3.11+: rewrite hot opcodes in place into specialised forms with inline caches, and fuse common sequences into superinstructions) is the usual next lever, and the only one identified for wasm. Before committing to it, this ADR records what the bytecode format allows and what the measurements say.

### 1.1 Measurements (2026-10-11, macOS arm64, ReleaseFast nano)

A temporary per-opcode counter in `fetch()` gives this dynamic opcode mix:

| | fibo(34) | bubble 10,000 | OO (1M `P(i,-i).norm1()`) |
|---|---|---|---|
| opcodes executed | 203M | 1331M | 38M |
| `LOAD_FAST_MULTI` | 22.7% | 30.3% | 26.3% |
| `LOAD_CONST_SMALL_INT_MULTI` | 18.2% | 11.3% | 2.6% |
| top pair | `LOAD_FAST → LOAD_CONST_SMALL_INT` 18.2% | `LOAD_FAST → LOAD_FAST` 15.1% | `LOAD_FAST → LOAD_FAST` 10.5% |
| other notable pairs | `LOAD_CONST_SMALL_INT → BINARY_OP` 18.2%, compare → `POP_JUMP_IF_FALSE` 9.1% | `LOAD_CONST_SMALL_INT → BINARY_OP[ADD]` 7.6% | `LOAD_GLOBAL → LOAD_FAST` 7.9%, `LOAD_ATTR → CALL_FUNCTION` 5.3% |

Wall time relative to native, for the same source and best of 3, is:

| | native | wasmtime (Cranelift) | Node 26 (V8) |
|---|---|---|---|
| fibo(34) | 0.72 s | 1.74x | 1.68x |
| bubble | 2.28 s | 1.54x | **2.97x** |
| OO | 0.23 s | 2.18x | 2.39x |

The browser is the wasm target that matters (the games, the playground), and V8 is markedly worse than wasmtime on bubble. Nothing here explains why yet.

### 1.2 What the bytecode format allows

- **The format is vendor's and stays so** (ADR 017: `.mpy` is an interface, and Q3 runs vendor `mpy-cross` output on our VM). Quickening must be a runtime-private transformation, never visible in emitted `.mpy`.
- **42 opcode values are free** (0x04–0x0f, 0x1d–0x1f, 0x38–0x3f, 0x41, 0x4c–0x4f, 0x60–0x61, 0x6a–0x6f, 0xfa–0xff): room for private opcodes.
- **The hottest opcodes hold their operand in the opcode byte.** `LOAD_FAST_MULTI` is `0xb0 + n`, `LOAD_CONST_SMALL_INT_MULTI` is `0x70 + k`. Overwriting that byte with a fused opcode loses the operand. The following bytes cannot be repurposed either: they may be a jump target. So in-place fusion cannot reach the top pairs above.
- **There is no room for inline caches.** CPython's format reserves cache slots after the opcode; vendor's has none, and vendor removed its own in-bytecode cache (`MICROPY_OPT_CACHE_MAP_LOOKUP_IN_BYTECODE`, upstream b326edf68) in favour of the global map lookup cache we already restored.
- **Frozen modules' bytecode is const data**, read-only on native.

### 1.3 Evidence that the wasm bottleneck lies elsewhere than dispatch count

Fusing a comparison with the `POP_JUMP_IF_*` after it at dispatch time (a peek, no bytecode change) saved one dispatch per comparison, about 9% of fibo's opcodes, and changed nothing on wasmtime while costing native 15% cycles. Threaded dispatch on wasm was 1.31x *slower* (one `br_table` per prong). If removing dispatches does not move wasm, superinstructions, whose main gain is removing dispatches, are unlikely to either. The per-opcode cost on wasm is in the prong bodies and the per-opcode bookkeeping (`csm.ip` store, `pending_exc` poll), or in how engines compile one very large function.

## 2. Options

**A. In-place quickening with private opcodes.** Rewrite opcodes with explicit operands (`LOAD_GLOBAL`, `LOAD_ATTR`, `LOAD_METHOD`, `CALL_FUNCTION`) into specialised forms, caches in a per-code-object side table keyed by bytecode offset. Cannot touch the top pairs (§1.2), needs a side-table lookup on every specialised execution, and needs writable bytecode (frozen modules excluded). Expected gain small; the cases it reaches are the ones the map lookup cache already serves.

**B. Translate each function to a private internal form on first call.** Decode vendor bytecode once into an internal array: operands widened out of opcode bytes, varints pre-decoded, room for inline caches and superinstructions, jump targets remapped. The VM runs only the internal form; vendor bytecode remains the interface and the source of line numbers and exception ranges. This is the design that can reach the top pairs and hold caches. It costs a translator, a second instruction encoding to maintain beside vendor's, memory per function, and the exception/line-info mapping between the two.

**C. Targeted work first, no quickening.** Cheaper steps the measurements point at:
1. Port vendor's `MICROPY_OPT_LOAD_ATTR_FAST_PATH` (instance attribute loads go straight to the members map; `vm.zig` notes it as dead today). Serves the OO workload directly. *Done (2026-10-11):* attribute-heavy loop 1.24x native, 1.37x wasmtime, 1.10x V8; OO microbenchmark 1.04x.
2. Find why V8 runs bubble at 3x native when wasmtime runs it at 1.5x: V8 tiering on a very large function, a slow path specific to its code generation, or our code. The browser is the real wasm target. *Done (2026-10-11):* V8 tiers a wasm function up to TurboFan only for its next call (no on-stack replacement), so a loop that never leaves one `dispatchBody` call ran on Liftoff baseline code; `node --no-liftoff` ran bubble 3.6x faster. On wasm, `dispatchBody` now returns to `mp_execute_bytecode` every 2^16 jumps and is re-entered. V8, relative to native: bubble 3.47x → 1.59x, an attribute loop 3.50x → 2.14x, an empty `range` loop 4.45x → 2.56x; wasmtime unchanged within noise. *Correction (2026-10-12):* those numbers came from builds before `wasm-opt`. In the shipped web build, `wasm-opt -Oz` inlined `dispatchBody` into its single caller, so the loop never re-entered a function and V8 stayed on Liftoff: bubble retired 112 G instructions against 62 G before `wasm-opt`. `make web` now passes `-ocimfs 1000`, which keeps functions over that size out of line when they have one caller (`dispatchBody` measures about 3950); the shipped build retires 62 G, 16 bytes larger raw and 250 bytes smaller gzipped.
3. Measure the per-opcode bookkeeping on wasm (`csm.ip` store and `pending_exc` poll in `fetch()`); vendor's `SELECTIVE_EXC_IP` (`py/vm.c`, off by default) updates `ip` only in opcodes that can raise, measured at 1–3% on microcontrollers with computed goto. *Measured (2026-10-11) in V8 retired instructions, as upper bounds from builds with each piece removed:* the `csm.ip` store is 2–3%, too little to act on. The `pending_exc` poll is 9–13% (bubble 13.2%, `range` loop 11.2%, attribute loop 9.5%), a load from linear memory on every opcode. About half the opcodes executed (`LOAD_FAST`, `LOAD_CONST_SMALL_INT`, `STORE_FAST`, the stack shuffles) call nothing that can raise; polling only after the others would recover roughly half of it. *Tried (2026-10-11):* skipping the poll after the 20 prongs that cannot leave an exception pending. On wasm, every prong returns to one shared `fetch`, so the skip has to travel as a local flag; that flag cost more than the load it saved (V8 instructions +1.5% to +7.5%), and was dropped. On native, where threaded prongs call `fetch` with `poll=false` directly, it stayed: bubble -13% instructions and -4% cycles, fibo -4% instructions.

## 3. Proposed decision

**Do C now, try B only through a spike with a decision gate, and reject A.**

- A cannot reach the hot pairs and duplicates the map lookup cache: rejected on the evidence in §1.2.
- C1–C3 are days, each measured on its own, and C2 may change the picture for the browser more than any interpreter redesign.
- B is spiked on a throwaway branch, translating only the opcodes needed by fibo, bubble and the OO benchmark, with a fallback to the vendor-bytecode loop for any function using anything else. Gate to continue: **at least 1.3x on wasm (both V8 and wasmtime) and on native for two of the three benchmarks, with memory per function within 2x of its bytecode**. Below the gate, B is recorded as measured-and-declined, like the threaded dispatch on wasm.

**Update (2026-10-11, after C).** The spike is deferred and has no date. C's results point away from dispatch count as the wasm bottleneck: removing dispatches (compare+jump fusion, §1.3) did nothing, while the two large wasm gains came from the engine side (C2, up to 2.2x on V8) and a fast path (C1). Option B's main payoff is fewer dispatches. It is reopened when a profile of a real browser workload (a game, the playground) shows the dispatch loop dominating after C2; the gate above stands for that spike.

**Decision (2026-10-12): B declined.** The condition for reopening it was a real browser workload where the dispatch loop dominates. Headless Chromium profiles (CDP sampling at 200 µs, 15 s of play with key presses, named build of the shipped wasm) show:

| | busy (share of wall time) | `dispatchBody` | rest of the wasm runtime | of which the collector | JS (bridge, canvas, WASI shim) | V8 (program, GC) |
|---|--:|--:|--:|--:|--:|--:|
| invaders-pro | 1.9% | 9.5% | 37.9% | 11.2% | 27.6% | 25.0% |
| tetris-pro | 0.5% | 4.8% | 38.1% | 22.2% | 21.9% | 35.2% |

The games are idle 98–99.5% of the time. The dispatch loop is a tenth of what remains. Making it twice as fast would save 0.1% of a game's wall time. The workload where dispatch dominates is CPU-bound code typed into the playground (bubble: 96% of samples in `dispatchBody`, its inlined fast paths included); there, wasm is 1.6–2.6x native, and B's gate (1.3x on two of three benchmarks) would buy less than the tier-up correction above did. B can be reopened on a new workload that runs the interpreter flat out in the browser, with the gate in §3.

## 4. Consequences

- The vendor bytecode format, `.mpy` emission and the Q1/Q3 gates are untouched by C, and by B as long as translation stays internal.
- If B goes ahead, the VM gains a second instruction encoding and a translator, and every exception and line-number path has to map back to vendor offsets; that maintenance cost is the price. The gate is set high enough to justify it.
- The opcode counter used for §1.1 was temporary; if B goes ahead, it becomes a build option so the mix can be re-measured.
