# ADR 009. v0.5 roadmap: usable WASM for web devs + selective Python parity + size-then-perf

- **Status**: Implemented in v0.5. Remaining open work fed into [ADR 010](010-roadmap-v06.md).
- **Decider**: project maintainers
- **Supersedes**: ADR 001 §6 (v0.4 success criteria); ADR 001 §7 (open questions for v0.5+); ADR 005 (optimization-landscape PROTO; this ADR commits to specific arcs from its §3 categories)
- **Branches from**: ADR 007 (wasm fat loss, In Progress) + ADR 008 (golden-programs, drives the priority signal)
- **Consequences**: sets four priority lanes for v0.5's arc; commits to size before perf; defers the major MicroPython-only embedded ports (settrace, larger error reporting); promotes the integration-suite-on-both-arms harness to primary regression detector going forward.

## 1. Context

The v0.4 roadmap (ADR 001) made WASM the primary distribution target and committed to feature completeness via Themes A (async/await), B (CI + releases), C (web demos), D (cross-platform), and F (per-feature size flags). Themes A/B/D/F shipped; Theme C is ongoing. The C→Zig strangler that motivated the original phasing is largely done: `corpus/nano/basics/` reports 538/541 native and `make wasm-check` reports green at the 468/541 baseline, the runtime works end-to-end, and `golden-programs/works/` holds 595 of 823 in-scope real programs (72.3%). The recent session arc closed a long tail of "is_full-gated bug-for-bug compat" defects (LONGLONG on wasm32, float wiring, bytearray ↔ bytes interop, range slicing, defaultdict, six "easy fill" stdlib additions, wasm float-print signature mismatch, …). Net +162 programs landed in `works/` in one session.

The shape of the work has shifted. We are no longer porting; we are improving a working runtime. The questions are different:

1. Is the WASM build actually pleasant for a web developer to use? (Not yet: float used to silently trap, eval/exec still hits the longjmp wall, the cold-start `.wasm` is 286 KB and ADR 007's 228 KB goal hasn't shipped.)
2. Are the remaining MicroPython parity gaps small and closable? (Yes: three corpus tests, plus the 27 known-fails on wasm that come from MPZ-needing arithmetic.)
3. Are we ready to start cherry-picking Python 3.x features beyond MicroPython? (Selectively, yes: this session showed `range.start`, `dict.fromkeys`, `str.title`/`.center(fill)`, `pow(b,e,m)`, `defaultdict`, modular `__getitem__` all land in well-under-an-hour each.)
4. Is size or performance the binding constraint? (Size first: 286 KB → 228 KB is the documented gap. Perf is green-band by ADR 004's benchmark; size is the visible loading cost.)

This ADR commits to a four-lane plan that answers each. The four lanes are sequenced by priority, but progress in any can proceed independently.

## 2. Goals, in priority order

1. **Primary: Usable WASM port for web developers.** A web dev who downloads the binary or visits a demo should be able to write idiomatic Python (with floats, bytes/bytearray fluency, dict literals, comprehensions, basic stdlib like `heapq`/`bisect`/`random`) without surprise crashes, see clean error messages when something goes wrong, and have the page load in <1s on a cold cache.
2. **Secondary: MicroPython parity for embedded.** Close the 3 remaining `make check` failures and reach the long-standing 541/541 byte-exact baseline. Keep the strangler discipline intact (no commit drops below baseline; the `make` aggregate gate stays green).
3. **Tertiary: Selective Python 3.15 features beyond the MicroPython baseline.** Pick features that help our use cases (web demos, algorithms, data-science workflows). Skip the rest (full `dataclasses`, all of the `typing` module, the GIL story). Includes shipping more pure-Python stdlib via the frozen-tiny mechanism (ADR 003) and porting/mimicking small C-side modules where the cost is low.
4. **Cross-cutting: Size, then performance.** ADR 007 Phase 1 (the wasm-opt + per-feature audit) lands first; if there's headroom afterward, attack benchmark hot paths. Performance includes startup time: a 4 MB Debug `.wasm` parses on the browser in ~30 ms cold-cache, but a 360 KB optimized `.wasm` parses in ~5 ms; the size-first sequencing reflects this.

Out of scope for the lanes: full async/await wiring under nano (ADR 002 Path B deferral stands), GIL/threading semantics (`_thread` stays a stub per ADR 003 §D6), CPython C-API extension loading, native-code-generation for hot Python.

## 3. Lane A. Usable WASM for web devs (primary)

The signal for "usable" is concrete: a web dev shouldn't have to learn petitpy-specific idioms to write a working demo. The remaining friction sits in three buckets.

### A1. Close the eval/exec longjmp wall

50 programs sit in `golden-programs/works-native-only/` because they use `eval()`, `exec()`, or `compile()` and those paths still go through vendor C's `nlr_jump`, which the wasm ABI cannot unwind. ADR 005 §3.1 noted this; ADR 007 §3 §1.2 acknowledged it as the "bucket-1 architectural blocker" left by the polled-sentinel arc.

Two paths:

- **A1.a** Port the eval/exec C code to PyError convention (the polled-sentinel pattern). Best-fit if the surface is small: probably ~200-400 LOC across `builtinevex.zig` plus the runtime entry. Closes the bucket without depending on emscripten tooling.
- **A1.b** Wire emscripten-sjlj as a build-mode alternative. Lets vendor C use longjmp on wasm via a vendored shim. Larger surface change but unblocks any future vendor C addition that also uses NORETURN raises.

The default position is to try A1.a first and treat the longjmp surface as a small, specific port. A1.b is the fallback if A1.a balloons.

**Success criterion**: `golden-programs/works-native-only/` drops below 10. The Python-program-level integration suite gains an eval-or-exec case that runs on wasm.

### A2. Close the cold-load size gap (size-first part of Lane D)

This lane is ADR 007 §4 Phase 1 (P1-P6). The wasm-opt prototype lives on `slim-wasm` at -14.3% / -5% gzipped; it has not yet landed on `main`. Ship it, along with the four "easy" techniques (1 through 4 in ADR 007 §1.3) that target ≤228 KB raw.

**Success criterion**: ADR 007 moves from "In Progress" to "Closed" (its Phase 1 acceptance criteria).

### A3. Wider feature surface: ship the next round of stdlib + finish the FLOAT-arm details

The "easy fills" from this session brought in 137 programs. The same approach has more headroom:

- **A3.a. Frozen stdlib expansion.** `re`, more of `itertools`, more `collections`, `argparse`, `string`, `enum`. Each is a vendor `micropython-lib` module or a small ~50-LOC pure Python.
- **A3.b. Multiple inheritance.** 10 programs in `needs-stdlib/` need it. Real Zig work on `objtype.zig`'s class-lookup path, but it's well-bounded.
- **A3.c. MPZ on wasm32.** 27 programs hit `OverflowError: long int not supported in this build` because we use LONGLONG, capping at 2^63. MPZ would cover those plus a futureproofing margin. The cost is ~40-80 KB of binary; tension with A2's size goal. Defer until A2 lands and we measure the budget.

**Success criterion**: `golden-programs/works/` reaches **650+** (from 595 today).

### A4. Polish the dev experience

- `make wasm` already produces a runnable binary (commit `571b1d6`); keep it that way. Same with `tests/integration.py` covering both arms (commit `5444662`).
- Wire the "what works" view: ship `docs/COMPATIBILITY.md` auto-generated from `golden-programs/`, linked from the README. ADR 008 §3 §Phase 2 already committed to this; just ship it.
- Browser smoke (`tools/browser-smoke.py`) gains a case per demo so a wasm regression visible-in-UI also surfaces.
- Improve startup time **only after A2 lands**; at the lower size the cold parse time may already be acceptable.

## 4. Lane B. MicroPython parity for embedded (secondary)

The 3 remaining corpus failures are documented in the project's known-failures list. Closing them is the path to 541/541: the long-standing strangler invariant.

- **B1. `builtin_help`.** Wire vendor `py/builtinhelp.c` into the nano carveout. Estimated 1-2 sessions; small.
- **B2. `gc1`.** Audit `src/memory/gc.zig` against vendor `py/gc.c` for the specific allocations the test counts. Small; needs careful attention to `gc.mem_alloc()` precision.
- **B3. `string_strip`.** Some Unicode whitespace handling difference. Tiny; not yet investigated, suspect a single bit-test in `str_strip`.

**Success criterion**: `make verify` exits 0. The 541/541 invariant is reached. (At that point we may want a `corpus/nano-known-fails.txt` parallel to the wasm-side discipline, empty file initially, so future regressions surface atomically.)

The 27 long-int / 19 small-int / 50 SKIP-on-feature programs in `golden-programs/needs-stdlib/` are work for Lane C and A3.

## 5. Lane C. Python 3.x features beyond MicroPython (tertiary)

The principle is **selective**. Pick features that help the priority use cases:

- **C1. More dict-subclass dispatch.** The `__getitem__` workaround in `collections.py` (commit `0b3cee0`) is fine, but the proper `__missing__` protocol dispatch on subscr would compose better. Probably needs runtime changes to pass the outer subclass instance through to the subscr slot.
- **C2. More iterator support.** Right now `reversed()` and `zip()` work; generators work; comprehensions work. Investigate the lazy-generator-method idioms `itertools` and the `yield from` story for nano (currently gated on full).
- **C3. Slice with step != 1 for strings.** `"abc"[::-1]` is a CPython idiom absent in vendor MicroPython and absent here; common enough that the question "is this the next investment?" deserves a numerical answer from `golden-programs/`.
- **C4. Better error messages.** `NameError`/`AttributeError` now name the offending identifier (commit `5b050a3`). `TypeError` in arithmetic could mention which side is wrong. `SyntaxError` already names the line.

Lane C leaves out full `dataclasses`, full `typing`, walrus operator (`:=`), match statements, async generators, `cm.contextmanager` decorator semantics beyond what `nanopython-lib/` already provides.

**Success criterion**: 5-10 features ship via small, individually-justified commits. Each adds a regression-pin case to `tests/integration.py`.

## 6. Lane D. Size, then performance (cross-cutting)

Reaffirms ADR 005 §6 (size-primary recommendation) and ADR 007 §2 (Phase 1 commitment).

- **D1. Ship ADR 007 Phase 1.** `wasm-opt -Oz` (already prototyped at -14.3%) lands on main; export strip + WASI cull; the size budget reaches ≤228 KB raw.
- **D2. Measure startup time end-to-end.** A small harness (timer.html or similar) measures cold-cache parse + instantiate + first-print. Goal: <1s cold on a mid-range laptop on a typical web demo.
- **D3. Bench-driven perf work, only if D1+D2 produce headroom.** Re-run ADR 004's benchmark against MicroPython unix-standard. If we slip materially, attack the hottest opcode (likely `MP_BC_BINARY_OP` or `MP_BC_LOAD_FAST`).

Out of scope for Lane D: LLVM-side optimizations (we're at Zig's ReleaseSmall ceiling); custom calling conventions; ahead-of-time compilation.

**Success criterion**: `web/nanopython.wasm` ≤228 KB raw; cold-cache demo load <1s (define "the bar" via `tools/browser-smoke.py` extended with a `--time` flag).

## 7. Sequencing

Phases are independent within a lane; lanes can run in parallel by different developers.

### Phase α (immediate; this is the next session's worth of work)

- Close B1, B2, B3 to hit 541/541 (Lane B is the smallest scope and most well-understood).
- Land ADR 007 P1 (wasm-opt integration): Lane D D1 first half.
- Ship the auto-generated `docs/COMPATIBILITY.md` from `golden-programs/`: Lane A A4.

### Phase β (next-after; assumes α green)

- Lane A A1 (eval/exec PyError port).
- Lane A A3.a (next round of frozen stdlib).
- Lane D D1 second half (export strip, WASI cull).
- Lane D D2 (cold-load timing harness).

### Phase γ (longer arc; pre-requires α + β)

- Lane A A3.b (multiple inheritance).
- Lane A A3.c (MPZ on wasm32); gated on D1's size delivery.
- Lane C selective features.

## 8. Out of scope for v0.5

- The MicroPython `async/await` arc under nano (ADR 002 Path B deferred it by choice; it stays deferred).
- A `requirements` / `pip`-style packaging story. The `nanopython-lib/` + frozen-tiny mechanism (ADR 003) is the shipping path for now.
- Native binary distribution as a standalone product. Native is a development companion only.
- Any GIL / threading semantics. `_thread` stays a stub.
- A web framework. The browser demo + ci-build-monitor extension are the demonstrations; users build their own apps.
- Coverage of every CPython 3.15 stdlib module. `re`, `argparse`, basic `string` and `enum` are in scope; the network stack, `subprocess`, `multiprocessing`, etc. are out.
- C-extension loading. The scope stays at "Python interpreter"; a "Python platform" is out of scope.

## 9. Consequences

**Wins:**

- Clear priorities for the next 3-6 months. Each lane has a measurable success criterion.
- The strangler discipline (the 3 known native failures) is now explicit and visible at the top of the doc.
- Size has primacy over performance; matches the user-visible "the demo loads fast" cost model.
- Phase α is concrete enough to start tomorrow.

**Costs:**

- The 50 `works-native-only/` programs from `eval`/`exec` remain visibly broken on wasm until A1 lands. That state predates this ADR.
- MPZ deferral means `print(2**100)` keeps failing on wasm until A3.c. The wasm-known-fails entry documents the trade, made by choice.
- We commit to skipping the long tail of CPython 3.15 stdlib modules. Some users will land on `import socket` or `import asyncio` and get `ImportError`. We accept that trade.

## 10. See also

- ADR 001: v0.4 roadmap (superseded by this for §6/§7).
- ADR 005: optimization landscape (this ADR commits to its size-primary recommendation).
- ADR 007: WASM fat loss (Phase 1 sits inside Lane D D1).
- ADR 008: golden-programs (drives the prioritization signal; the `works/823` ratio is the headline metric).

