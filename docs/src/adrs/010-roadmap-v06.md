# ADR 010. v0.6 roadmap: closing the wall, broadening the surface

- **Status**: Superseded by [ADR 021](021-roadmap-v09.md) (2026-10-23). Drafted 2026-06-11 and never accepted; ADR 021 says which of its items were done, restated or left out of scope.
- **Decider**: project maintainers
- **Supersedes**: ADR 009 §3-§7 open items (eval/exec wall, A3b multi-inheritance, A3c MPZ on wasm32, D1 P2-P4 size cuts, D2 timing harness, Lane C). v0.5's Phase α + first slice of Phase β shipped; the remainder is this ADR.
- **Branches from**: the same lane decomposition ADR 009 §3-§6 introduced. **The lanes and their priority order do not change.** Only the specific commitments within them do.
- **Consequences**: commits the project to closing the eval/exec wall as the v0.6 headline arc; commits to a ≤285 KB wasm shipping size; commits to one MPZ-on-wasm32 decision (ship or defer based on measured size budget after the cuts land); defers the parts of Lane C outside the web-dev use case (full dataclasses, full typing, match statements, async generators). **Amended 2026-09-01: match statements shipped (see §5).**

## 1. Context

The v0.5 roadmap (ADR 009) named four lanes and three sequenced phases. Phase α closed (Lane B at 541/541; ADR 007 P6 in production; `docs/COMPATIBILITY.md` generator). The first slice of Phase β shipped (Lane A3a additions; Lane D1 P6; two runtime bug fixes; a class-of-bugs closure on wasm32 ABI mismatches). The wasm shipping artifact dropped from 354 KB to **305 KB** (-14%); the `golden-programs/works/` filesystem count moved from 543 to 546.

Three signals motivate this ADR's scoping.

**First**, the headline structural blocker for the primary goal (usable WASM for web devs) is the eval/exec longjmp wall. Approximately 50 programs in `golden-programs/works-native-only/` sit there because their code path calls `eval()`, `exec()`, or `compile()`, all of which route through vendor C's `nlr_jump` machinery, which wasm32's relevant ABI cannot unwind. Until this wall closes, the gap between native-arm capability and wasm-arm capability stays open. ADR 009 §A1 named the gap; v0.6 commits to closing it.

**Second**, the cold-load size gap has not closed. ADR 007's 228 KB raw target sits about 25% below the current 305 KB shipping size. ADR 009 §A2 deferred P2–P4 (export strip, WASI cull, terse errors) to the next cycle. Their estimated combined saving (~16-19 KB) does not by itself reach 228 KB; it lands somewhere near 285 KB. v0.6 has to either accept a softer target (≤285 KB and call ADR 007 closed) or commit to additional work beyond Phase 1 (the sub-component carveout from ADR 007 Phase 2, which lands around 170-200 KB but with material complexity cost). This ADR proposes the softer-target path and gives explicit reasoning.

**Third**, the metrics tool now records longitudinal data per session. The v0.5 cycle produced six data points. For v0.6 to compound on size, perf, and coverage, every working session should record at the start and end. This shifts how progress is measured, from "did we hit X by deadline" to "is the trend monotone."

## 2. Goals, in priority order

Unchanged from ADR 009 §2:

1. **Primary**: usable WASM port for web developers.
2. **Secondary**: MicroPython parity for embedded. **Now at 541/541 (Debug)**; v0.6 maintains this and documents the deque MP-strict divergence and leaves it in place.
3. **Tertiary**: selective Python 3.x features beyond MicroPython.
4. **Cross-cutting**: size, then performance (including startup time).

The vision behind these priorities is unchanged from ADR 009. A web developer should be able to write idiomatic Python (with the stdlib bits they actually use) and see helpful errors. Their code should run in <1 s cold-cache and use eval/exec/compile when it needs to. Embedded users keep MP byte-exact compatibility. Selective Python 3.x features are added where they intersect the web-dev use case. Size is the dominant cost in the cold-cache scenario.

## 3. Lane A. Usable WASM for web devs (primary)

### A1. Close the eval/exec longjmp wall *(the v0.6 headline)*

**Scope.** Vendor `py/builtinevex.c` exports `mp_builtin_eval`, `mp_builtin_exec`, `mp_builtin_compile`. Each currently routes a compile-failure or execute-failure through `nlr_jump`. On wasm32 (`MICROPY_ENABLE_SCHEDULER=0`, no native sjlj), the `nlr_jump` either traps or executes an `unreachable`. The 50 programs in `golden-programs/works-native-only/` that use these surfaces are blocked.

**Approach.** Port `builtinevex.c` to the polled-sentinel convention (the pattern the rest of the runtime uses). Concretely:

- Replace the three vendor entry points with Zig implementations that produce `PyError!Obj` returns and route raises through `pyerr.pending_exc`. Estimated surface: ~200-400 LOC of Zig.
- The compiler entry path (the parser → compiler → `mp_compiled_module_t` chain that eval/exec depend on) is already strangled to Zig; the wall sits specifically at the *vendor* exec entry, downstream of compilation.
- Wire the new entries through `mp_obj_int_make_new`-style polled bridges so vendor C callers (e.g. `mp_obj_new_exception_msg`-using fallback paths) see consistent semantics.

**Success criterion.** `golden-programs/works-native-only/` drops below **10** (from 23). A dedicated `tests/integration.py` case calling `eval('1+1')` and `exec('print(42)')` runs on both arms. A new test pin verifies that `f"{a!x}"` (the f-string conversion-spec test that uses eval internally) raises a clean ValueError and never hits a wasm trap.

**Fallback.** If the port balloons beyond ~600 LOC, fall back to the emscripten-sjlj build-mode variant (ADR 009 §A1.b). This is more invasive (requires a vendored sjlj shim and a build-time toggle) and is documented but not preferred. At the decision point, if the polled-sentinel work is not at integration-suite-passing state within two focused sessions, we switch to the fallback.

**Why this is the headline.** Closing this wall unblocks more golden programs than any other single arc, AND removes the largest qualitative difference between the native and wasm experience. A web dev who hits `eval` today gets a confusing trap; after this, they get a normal Python ValueError. The arc is well-scoped (one vendor file) and the methodology (polled-sentinel, three stages) is already established.

### A3a. Frozen stdlib expansion, slice 2

**Scope.** Three concrete additions, picked by web-dev demand frequency from `golden-programs/needs-stdlib/` analysis:

- **`re`** (regular expressions). Vendor `extmod/modre.c` is ~400 LOC. Carve into the nano build similar to how `objfloat.c` was carved in v0.4 (ADR 002 Theme F). Cost: ~10-15 KB of binary (this is real but acceptable given `re` is the single most-asked-for stdlib module). Approach: vendor C carveout, gated on `feature-re=true` (default true under nano).
- **`itertools`** (lazy iteration helpers). Pure-Python implementation in `nanopython-lib/`. Covers: `chain`, `repeat`, `count`, `islice`, `takewhile`, `dropwhile`, `accumulate`, `groupby`. Cost: ~5 KB compiled. The `tee` and `cycle` family deferred because they need iterator caching that is awkward in pure Python.
- **`string`** (constants + small helpers). Pure-Python. Covers: `ascii_letters`, `ascii_lowercase`, `ascii_uppercase`, `digits`, `hexdigits`, `octdigits`, `whitespace`, `printable`, `punctuation`, plus `Template` and `Formatter` (subset). Cost: <1 KB compiled.

**Success criterion.** `from re import compile; compile(r'\d+').match('123').group()` works on both arms. Add ≥2 integration pins per module.

**Out of scope for v0.6 slice 2** (deferred to v0.7 or later): `argparse` (small but takes ~100 LOC and adds error-message complexity), `enum` (micropython-lib has one; sequencing question), `pathlib`, `os.path`, network modules.

### A3b. Multiple inheritance

**Scope.** 10 programs in `golden-programs/needs-stdlib/` use multi-inherit class hierarchies. The MP class-lookup path under `objtype.zig` is single-inheritance only; vendor MP's `mp_obj_class_lookup` walks a base-classes list, but the slot-walker we have inlines the single-base case.

**Approach.** Extend `npy_ty_class_lookup` to walk `bases` (currently the parent is a single pointer). The MRO is C3 linearization (CPython's algorithm); our version can use vendor's MP-simplified MRO (left-to-right depth-first) since that's what MP programs expect.

**Success criterion.** Programs using `class C(A, B):` resolve `C().__init__()` correctly via MRO. 10 needs-stdlib programs move to works/.

**Risk.** This touches the most-used path in the VM (every attribute access). The discipline is to run `make check` after every commit and revert if any of the 541 corpus tests regress.

### A3c. MPZ on wasm32 (gated on size budget). DEFERRED to v0.7

**Scope.** Vendor `py/objint_mpz.c` is the multi-precision int library. On native nano we use NONE (62-bit smallint); on wasm32 nano we use LONGLONG (64-bit machine word). Bignum tests (27 in `golden-programs/needs-stdlib/` + several in the corpus) hit OverflowError because LONGLONG caps at 2^63.

**Decision criterion.** If the v0.6 size cuts (D1 P2-P4) reduce the wasm shipping artifact to ≤270 KB AND the project decides 27 newly-passing programs justify ~40-80 KB cost, ship MPZ. Otherwise defer to v0.7.

**Approach if shipped.** Add a build-mode toggle `-Dlongint-impl=mpz` for wasm32-nano. Carve in `py/mpz.c` + `py/objint_mpz.c` under that toggle, gated alongside the existing LONGLONG carveout. Re-bench against the 27 programs.

**Decision: defer to v0.7.** The size criterion isn't met and won't be met by D1 alone: the P3 + P4 best case leaves headroom too tight for a 40-80 KB MPZ addition on top. The `_intbig`-named entries in `corpus/wasm-known-fails.txt` come to ~21 corpus rows, a low-leverage payoff relative to the size cost.

**What flips the decision later.** v0.7 would need one of two things. Either the wasm baseline falls well below 220 KB through aggressive Lane D work, so MPZ fits inside a 270 KB headroom. Or a user makes a concrete request for arbitrary-precision arithmetic that LONGLONG (wasm) and 62-bit smallint (native) can't satisfy. Bignum is currently absent on both arms; adding MPZ to one arm only would diverge the two, a coherence cost the size budget doesn't fund this cycle.

### A4. DX polish

Continuous and opportunistic. Wins this cycle:
- Better tracebacks: include the function name and line number from the bytecode prelude (the qstr-table machinery from `mp_obj_fun_get_name` is already in place; the print path needs wiring).
- REPL: command history via `readline` (currently absent on nano). The vendor `lib/mp-readline/` is small; carveout.
- Browser smoke per demo: extend `tools/browser-smoke.py` with one case per `web/<demo>/` page.

These are small individual items; the cycle takes whichever ones come up at low cost.

## 4. Lane B. MicroPython parity for embedded (secondary)

**Status: maintenance.** Native byte-exact corpus is at 541/541. The discipline is "every commit holds the count."

Three specific maintenance items:

- **The `deque_micropython` and `deque_slice` corpus tests fail on wasm** because v0.5 shipped a CPython-compatible `collections.deque` that overrides vendor MP's strict-API deque. They're documented in `corpus/wasm-known-fails.txt` with a comment block. v0.6 preserves the choice; the MP-strict deque remains reachable via `from ucollections import deque` for embedded use cases.
- **The 539/541 (Release+frozen)** divergence: the metrics tool measures the release-frozen binary which has the deque override, so it sees 2 fewer tests pass than the Debug build (which falls through to MP's deque). The two numbers report two different binaries.
- **No new vendor strangler arcs** in v0.6. The strangler convergence is done. New porting work happens in Lane A or Lane C with explicit purpose.

## 5. Lane C. Python 3.x features (tertiary)

This lane adds five small features, each ~1 hour of work and each justified by a specific use case:

- **`__missing__` on dict subclasses.** The current workaround uses a `__getitem__` override (see `nanopython-lib/collections.py`). The vendor subscr dispatch reads the inner dict storage; fixing it requires runtime changes that pass the outer instance through.
- **`str[::step]` with step ≠ 1.** A common CPython idiom (`"abc"[::-1]`). Absent in vendor MP and absent here; closing the gap is a small slice-impl extension in `objstr.zig`.
- **`bin()`, `hex()`, `oct()` returning strings with prefix.** We have these; verify they match CPython exactly on negative integers (where MP and CPython have small format divergences).
- **`bytes.fromhex` and `bytes.hex` with separator argument.** CPython 3.5+ adds optional `sep` parameter. We have these without `sep`.
- **Improved error messages.** `NameError`, `AttributeError` already include the identifier name (v0.5 fix). Add: `TypeError` in arithmetic mentions which operand. `KeyError` shows the key.

Out of scope: walrus (we have it), async generators (Path B deferral stands), dataclasses, typing.

**Amended 2026-09-01: match statements shipped.** This ADR listed them out of scope as a "grammar gap, large arc". The arc turned out to be bounded once the capability matrix separated the two parts of the question: both VMs already ran match *semantics*, because the desugaring needs no opcode that is not already there. Only the parser was missing. What it took:

- a token replay buffer in `lexer.zig`, so `match (x):` can be told from `match(x)` (`match` and `case` get no `TokenKind` of their own, which keeps the token stream vendor-identical and `NUMBER_OF` pinned at 96);
- extension grammar rules in `src/compiler/grammar_ext.zig` at ids 183+, running on the unmodified parser engine, leaving `grammar_data.zig` generated from vendor `grammar.h` with its SHA-256 pin intact;
- a lowering to if/elif in `compile.zig`, following the reference implementation in `projects/pyfront/src/pyfront/patterns.py`.

Covered: literals, singletons (compared by identity, per PEP 634), captures, wildcards, or-patterns, sequences including `*rest`, mapping patterns, class patterns with keyword sub-patterns, `as` bindings, guards. Still refused by name in both front-ends: two stars in one sequence, `**` captures in a mapping, positional class sub-patterns, dotted class names, and captures inside alternatives.

## 6. Lane D. Size, then performance (cross-cutting)

### D1. Size, continued

**P2. Export-section strip.** Audit every `pub export fn` in `src/`. Demote it to `pub fn` where the symbol is only called from Zig. Risk: anything called from C shim / JS bridge / WASI startup must stay exported; sanity-check by running `make check` + `make wasm-check` after every batch. The estimated saving is ~10 KB of Export plus downstream DCE.

**P3. WASI import cull.** Zig's stdlib declares 38 WASI imports; the runtime path uses ~6. Force `--no-import=` for dead names at link time, OR provide trivial stubs that the linker DCEs. The risk is that any std path that lazily uses one of these traps. The estimated saving is ~1 KB of Import plus a few hundred bytes of Code.

**P4. Terse-errors build flag.** `-Dterse-errors=true`. Swap verbose error strings for short codes; ship a code→message lookup table that tools/tests can use. Default stays verbose (the DX commitment). Terse mode is for the production distribution. The estimated saving is 5-8 KB of Data section.

**Combined target for v0.6 size work**: ≤**285 KB** raw, post-`wasm-opt -Oz`, with P2+P3+P4 landed. This is softer than ADR 007's 228 KB target; §7 justifies it.

### D2. Cold-load timing harness

**Scope.** Add a small `tools/timing.py` that measures cold-cache wasm parse + instantiate + first-print on a representative program. Output: a single number in ms, recorded in `metrics/history.ndjson`.

**Why.** The 305 KB shipping artifact's cold-load time is currently unmeasured. Anything ADR-001-style ("page loads in <1 s") needs measurement infrastructure first.

**Success criterion.** Every `metrics-record` produces a `cold_load_ms` field. Trend visible in `metrics-report`.

### D3. Bench-driven perf

Defer to v0.7 *unless* a bottleneck surfaces in D2's data. The metrics tool already records `geomean_native_vs_cpython` (1.7×) and `geomean_wasm_vs_cpython` (2.5×) when `--with-perf` is passed; v0.6 adds enough timing measurements to identify whether the bottleneck is parse, allocator, dispatch, or stdlib.

## 7. Sequencing

### Phase 1. A1 + D1 P2 (the headline cycle)

Both items are well-scoped and independent. A1 is the dominant value win; P2 is a no-fanfare size cut that compounds for v0.6.

- **A1 (eval/exec wall).** Two focused sessions estimated. Phase 1 closes when `golden-programs/works-native-only/` drops below 10 AND integration suite has eval/exec cases passing on wasm.
- **D1 P2 (export strip).** One focused session estimated. Phase 1 closes when wasm-raw drops ≥8 KB without any corpus regression.

Done state: `works-native-only/` <10; wasm shipping ≤295 KB; integration 40+/40+ both arms; metrics rows recorded at start and end.

### Phase 2. A3a slice 2 + A3b + D1 P3+P4

- **A3a slice 2 (re + itertools + string).** Three modules, three sessions. Re carveout sequencing first because it's the user-facing win; the pure-Python ones land alongside.
- **A3b (multi-inherit).** One focused session. Risk: regression to corpus; if any of 541 corpus tests regress, the change reverts in the same commit.
- **D1 P3 + P4 (WASI cull + terse errors).** One session combined. Both small, and both measurable.

Done state: `golden-programs/works/` ≥ 580; wasm shipping ≤285 KB; integration 50+/50+ both arms.

### Phase 3. D2 + Lane C selectives + A3c decision

- **D2 (cold-load timing).** One session. Wires `tools/timing.py` into the metrics flow.
- **Lane C selectives.** Each is small (~1 hour). Two sessions accumulate 5-10 features.
- **A3c (MPZ decision).** Read current wasm size from metrics. If ≤270 KB, ship MPZ behind `-Dlongint-impl=mpz` and re-bench. If >270 KB, defer to v0.7 with explicit reasoning.

Done state: `cold_load_ms` recorded longitudinally; Lane C features pinned in integration; MPZ decision committed.

## 8. Why the size target softened

ADR 007 §2 set ≤228 KB as the Phase 1 acceptance criterion. v0.6 commits to ≤285 KB. The 57 KB gap is real; we explain it explicitly so future maintainers can revisit.

The hard cuts (P2-P4) save 16-19 KB combined. To get from there (~286 KB) to 228 KB, we'd need ADR 007 Phase 2: the sub-component carveout that splits `compile.wasm` and `vm.wasm`. That's a multi-session architectural arc with material complexity: it intersects ADR 003's frozen-tiny boundary, requires a deployment story for which-wasm-do-you-use, and changes the demo loading mechanics.

The judgment for v0.6 is that ≤285 KB delivers the user-visible win (cold-load <1 s on a representative connection) without the architectural cost. v0.7 or later can attack 228 KB via Phase 2 if the cold-load measurements from D2 indicate that 285 KB remains too slow.

The size budget is not to be relaxed without justification.

## 9. Out of scope for v0.6

- **Async/await wiring under nano.** ADR 002 Path B deferral stands. Async generators stay out of scope.
- **Match statements.** Real grammar work. Wait for v0.7 or later.
- **Walrus operator iteration features.** We have walrus; PEP 654 ExceptionGroups stay out.
- **GIL / threading semantics.** `_thread` stays a stub.
- **pip / packaging.** Frozen-tiny + `nanopython-lib/` is the shipping path.
- **Native binary as a standalone product.** Native is the development companion.
- **CPython C-API extension loading.** The scope stays at "interpreter"; a "platform" is out of scope.
- **A web framework.** The demos remain the demonstrations; users build their own.
- **Comprehensive CPython 3.15 stdlib.** v0.6's A3a is `re` + `itertools` + `string`. Other modules (`socket`, `subprocess`, `multiprocessing`, etc.) stay out.

## 10. Consequences

**Wins:**

- Closing A1 collapses the largest qualitative gap between native and wasm experience. After v0.6, a web dev can use `eval`, `exec`, `compile` in their browser code with normal Python semantics.
- A3a slice 2 adds `re` (the most-asked-for stdlib module) plus two pure-Python modules that compound on existing infrastructure.
- A3b unblocks multi-inheritance, a common idiom in algorithm and OO code.
- D1 P2-P4 + the softer 285 KB target deliver a credible cold-load story without the architectural cost of Phase 2.
- D2 makes the cold-load story measurable, so future size work can be data-driven.

**Costs:**

- A1 is the longest single arc. If it balloons (the fallback condition), v0.6 absorbs schedule risk.
- A3c (MPZ) defers to a measured decision. The 27 bignum-blocked programs stay blocked unless the size budget allows.
- The softened size target (285 KB vs 228 KB) is a retreat, by choice, from ADR 007 §2's commitment. Future maintainers may disagree.

**What this ADR preserves:**

- The strangler discipline (541/541 native, byte-exact).
- The integration-suite-on-both-arms commitment (every fix pinned).
- The metrics-tool longitudinal recording habit.
- The compatibility surface guarantees in `docs/COMPATIBILITY.md`.
- The lane priority order from ADR 009.

## 11. See also

- ADR 001: v0.4 roadmap (closed)
- ADR 007: WASM fat loss (Phase 1 in progress, this ADR sets the Phase 1 acceptance bar)
- ADR 008: golden-programs (the bucket signal that drives prioritization)
- ADR 009: v0.5 roadmap (now retrospective; §11 of that ADR documents what this ADR builds on)
- `docs/COMPATIBILITY.md`: the user-facing "what works" view
- `tools/metrics.py`: the longitudinal recording instrument
