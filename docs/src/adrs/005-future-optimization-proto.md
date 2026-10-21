# ADR 005 (PROTO). future optimization: a landscape map

- **Status**: Proto, a landscape map (preceding any decided ADR).
- **Decider**: project maintainers (this proto is opened for direction; the real ADRs branch from here).
- **Consequences**: none yet; this document sets out the optimization-decision space *before* any specific arc is started.

## 1. Why this proto exists

The first benchmark report has landed with actual numbers, geomean and per-benchmark, against MicroPython unix-standard and CPython 3.x. Almost immediately the question changes from *"how fast is petitpy?"* (answered: 1.24× MicroPython geomean, 1.88× CPython) to *"what should we work on to make it faster, smaller, or both?"* That second question is the one this proto exists to map. Without a framework, every future optimization arc is reactive (fix whichever number looked worst in the most recent report). The project would then tune microbenchmarks with no coherent performance story. The deliverable here is the *terrain*. The real ADRs (006, 007, …) will branch from this and commit to one category at a time, with the user's direction on the open questions below.

### 1.1 The case for a proto

First, this document is structured around a decision *space*, with no single decision at its end. An ADR ending with "and therefore we will do X" has a clear acceptance criterion (X ships; X works; X closed). A proto's acceptance criterion is softer: the proto has done its job when the maintainer can point at it and confidently say "yes, this optimization is the next move" (or "this one is). 

Second, the §5 questions need user direction before *any* implementation can start, and writing a proposal-and-decide ADR before that direction lands would be putting the cart before the horse: the resulting "decision" would be the author guessing what the maintainer wants. 

Third, the ADR series so far (001-004) has been about commitments that the project can live with for years. Optimization decisions are by nature shorter-lived: a "we use threaded-code dispatch" choice may be revisited if the implementation language changes underneath us, while a "we are MicroPython-compatible on bytecode" choice has staying power. The proto status acknowledges that distinction.

### 1.2 Reading this proto

The structure is: §2 the baseline data, §3 the categories themselves (the meat), §4 the constraints, §5 the open decisions (the lever the user pulls), §6 the positions the author *will* defend, §7 what is excluded, §8 the path to ADR-006. Readers who already know the categories can skim §3. Readers who already know the constraints can skim §4. The critical parts for the proto-to-ADR transition are §5 and §6.

### 1.3 What changed since ADR-004

ADR-004 (a few days ago) committed the project to producing the benchmark data; this proto exists because that data now exists. ADR-004 §4.1 listed four hypotheses to be checked against the first report: dispatch overhead at parity, startup time wins, memory floor measurement, CPython gap shape. The first report partially answers each: fannkuch is at parity (1.00×), while fib and sieve are above it (1.27×, 1.98×), so dispatch overhead varies across benchmarks. Startup was folded into the per-benchmark numbers (a separate row remains a future report iteration). Memory floor remains a separate report. The CPython gap is benchmark-shape dependent (strops 3.53× vs dictops 1.47×), so the gap is structural and varies by benchmark, which informs §3's category choice. The hypotheses being partially confirmed and partially complicated is exactly the value of running the benchmark, and exactly why writing this proto now is worth it.

## 2. The benchmark baseline

The summary below comes from `docs/benchmarks.md` (host: arm64-macos, `ReleaseFast` petitpy, MicroPython unix-standard, CPython 3.14.5; K=2 warmup, N=5 timed, median):

| benchmark | nano / MicroPython | nano / CPython | notable |
|---|---|---|---|
| dictops | 1.58× | 1.47× | dict-write-heavy |
| fannkuch | 1.00× | 1.56× | tied with MicroPython |
| fib | 1.27× | 1.98× | call-heavy recursion |
| listops | 1.37× | 1.33× | list-write-heavy |
| sieve | 1.98× | 2.07× | int-arithmetic loop |
| strops | **0.67×** | 3.53× | **faster than MicroPython** |
| **geomean** | **1.24×** | **1.88×** | green per ADR-004 D8 |

We are in the green band of ADR-004's three-color rubric (≤2× geomean vs MicroPython is the agreed-acceptable trade for shipping a 286 KB binary against MicroPython's 652 KB). The headroom from "trivial wins" is small: every benchmark sits in the green or yellow zone. The interesting question is therefore *which class of optimization* to pursue, and to what end (speed vs size; native vs WASM; matched-behavior vs divergent). A green-band baseline reframes optimization from "fix what is broken" to "pick what to invest in next." That reframing raises the difficulty: it requires saying no to most categories, which means knowing what the categories *are*.

## 3. Optimization categories: the landscape

Each row names a category, a rough sense of expected gain and a cost estimate in sessions. The compatibility column says whether the optimization preserves the ADR-003 commitment to MicroPython bytecode, language and extension model. The WASM-relevance column says whether the savings transfer from the native build to the wasm build or stay native-only. The "maturity" column asks whether the optimization has been proven in adjacent interpreter projects: a category proven in CPython 3.11, MicroPython upstream, or PyPy is less risky than one that would be novel here.

| Category | What it is | Rough gain | Cost (sessions) | Compat impact | WASM-relevance | Maturity |
|---|---|---|---|---|---|---|
| **Interpreter dispatch** | Computed-goto / direct-threaded code in the opcode loop; today our switch-based dispatch likely costs ~10-20% vs a threaded loop | 10-25% on dispatch-bound benchmarks (fib, sieve) | 2-4 | None (pure mechanism) | High (native + wasm both benefit; wasm dispatch is currently switch-based too) | Proven (CPython, MicroPython, every serious interp) |
| **Inline caching** | Per-call-site type/method caches; CPython 3.11+ "specializing adaptive interpreter" | 15-40% on call-heavy code | 6-10 (complex) | Some: cache invalidation has to compose with MicroPython's type-mutation rules | Medium (helps both; relative gain similar) | Proven recently (CPython 3.11+, V8) |
| **Allocator + GC** | Until 2026-10, libc `malloc` with no collection, a leftover of the zigonly bootstrap; [ADR 019](019-garbage-collector.md) replaced it with vendor's heap design and conservative roots. Slab / free-list / generational variants reduce per-alloc cost | 5-15% on allocator-heavy benchmarks (listops, dictops) | 4-8 | Medium: GC semantics observable through `gc.collect()` thresholds | High under wasm (no mmap; allocator behavior is the floor) | Proven (V8, CPython) |
| **Constant folding + peephole** | Compile-time optimization in `compile.zig`. MicroPython has a richer peephole pass than we currently expose | 2-8% across the board, more on synthetic code | 2-3 | None (output is still valid bytecode) | Medium (smaller code = smaller `.mpy` = smaller frozen modules) | Proven (every compiler ever) |
| **String operations (specific)** | strops is 0.67×, *faster* than MicroPython. Whether the win generalizes or is a fluke of our particular string-method shim is unknown | Possibly 0 (already won); possibly transferable to other ops | 1 (investigation) | None (it's a measurement question first) | High (transferable patterns benefit both) | Project-specific |
| **mpz → Zig** | We link vendor `mpz.c` under full (~2,800 LOC). A Zig port via `std.math.big.int` would close the "zero vendor C" gap | 0 to negative (vendor mpz is hand-tuned; std.math.big.int is correctness-first) | 8-12 | Low (interface stays); risk: performance regression | Low (mpz is full-only; nano wasm leaves it out) | Unproven for this case |
| **WASM-specific size** | `wasm-opt -Oz` post-link (Binaryen tool), more aggressive linker flags, sub-component carveouts. Theme F's 20% target is currently at 8.95% | 10-30% wasm binary size reduction; ~0 speed | 2-3 | None (post-link transformation) | High (this is the whole point) | Proven (every wasm project) |
| **Profile-guided optimization (PGO)** | Compiler PGO with representative workloads; hot path identification + targeted tuning | 5-10% across the board | 4-6 (mostly infra) | None | Limited (wasm PGO tooling is immature) | Proven on native (CPython, V8) |
| **JIT** | Tracing or method JIT a la PyPy / V8 | 5-50× on numeric code | 50+ (different project class) | **Conflicts with ADR-003** (bytecode-only) and ADR-001 (binary-size) | Negative (wasm-in-wasm JIT is a research problem) | Out of scope |

Two observations land before any decision. First, the highest-value rows (dispatch, wasm-size, strops investigation) are also the lowest-cost; the project's most expensive options (inline caching, GC overhaul, mpz port) are also the ones with the most compat and maintenance risk. Second, several rows address something other than "going faster": wasm-size work leaves benchmark numbers untouched; constant folding's gains are tiny on the cross-interp comparison. The categories are mostly orthogonal, and a coherent optimization story picks at most one or two per arc.

Each row's evidence base differs. The dispatch row rests on a quick check of `src/runtime/vm.zig` (switch-based, 965 LOC) and `port/mpconfigport.h` (no `MICROPY_OPT_COMPUTED_GOTO`). The 10-25% gain figure comes from CPython's well-documented threaded-code work and MicroPython's own configurable opt; it is a literature value, unmeasured on our codebase. The inline-caching row is harder to pin down on a small interpreter. CPython's specialization machinery is substantial. MicroPython has historically declined to ship it because the per-site memory cost dominates on microcontrollers. The 15-40% range reflects what *CPython* sees on its own benchmarks (a CPython literature value). The allocator row is the most speculative: petitpy inherits MicroPython's allocator more or less verbatim, and untangling per-alloc cost from per-collection cost requires profiling infrastructure the project lacks. The strops row is a measured anomaly (0.67×) that the proto leaves unexplained on purpose; the investigation is one of §6's recommendations. The mpz row sits in a different drawer entirely: a strangler-completion task that *might* cost a small amount of speed, included only because someone reading this without context will ask "what about mpz?" and the table needs to give an answer.

### 3.1 Why these categories and not others

A few categories that a perf-literate reader might expect to see are left out of the table on purpose. **Lazy-allocation of generator state** is too narrow to be its own category; it would land as part of allocator work or as a one-off lift triggered by a specific benchmark. **Stack-allocation of small dicts/lists** has a related shape and same disposition. **SIMD / vectorization** would land under inline-caching's specialization (the cache could fast-path a vectorized add); a standalone category at this scale would be premature. **Multithreading / parallelism** is out twice over: ADR-001 §3 defers threading; and even if it landed, the single-thread benchmarks in `docs/benchmarks.md` would stay still. **Different reference counting** is also out: petitpy uses mark-sweep from MicroPython. Switching to refcounting would be a rewrite of the memory manager. **AOT compilation to native code** is JIT-adjacent and falls under the same out-of-scope rubric.

### 3.2 What MicroPython does in each row (for calibration)

A useful exercise before deciding what to do *here* is to look at what MicroPython does *there*. The proto is comparing against a reference that has its own answers. Where its answers differ from the available options, the difference is informative.

| Category | What MicroPython does upstream | Implication for us |
|---|---|---|
| Dispatch | `MICROPY_OPT_COMPUTED_GOTO` configurable; on for unix-standard when the host compiler supports it | We are likely paying a 10-20% dispatch tax relative to MicroPython right now |
| Inline caching | None; explicitly declined; memory cost would dominate on MCUs | If we add it, we diverge from MicroPython's "tiny everywhere" choice; OK on native+wasm, problematic if embedded becomes a real audience |
| Allocator | Bump + mark-sweep; carefully tuned for MCU memory floors | We kept its heap design but not its root registration ([ADR 019](019-garbage-collector.md)); deviating from vendor's design would need a story for the embedded future |
| Constant folding | Moderate peephole pass in `py/emitcommon.c` | We have less; partial-port opportunity |
| String operations | Standard mp_obj_str; no special tuning | The 0.67× result we see is therefore unexpected and unexplained |
| mpz | Hand-tuned C; explicit "do not port to a library" decision | Confirms our caution above |
| WASM size | No first-party wasm port; not applicable | We are alone on this category; no upstream to mirror |
| PGO | Build flag exists on some host ports | Low priority upstream too |
| JIT | None; explicitly declined | Mirror their position |

The pattern is that where MicroPython has a position, that position is informed by 10+ years of running on real hardware against real users. The categories where MicroPython has *not* taken an obvious position (WASM-size, our specific dispatch state, the strops anomaly) are exactly the ones where this proto has the most freedom to choose.

## 4. Constraints we operate under

Four hard constraints shape every optimization category above. They apply to *all* categories and warrant a separate section:

- **MicroPython compatibility** (per ADR-003). We commit to `.mpy` v6 bytecode wire-compatibility, MicroPython language semantics, and the upstream extension model. Any optimization that changes the bytecode wire format, the visible language surface, or the extension protocol breaks this commitment. Inline caching is allowed (the bytecode stays the same; caches live alongside); a new opcode is not (it diverges the wire format). JIT is out partly for this reason.
- **WASM-primary positioning** (per ADR-001). Size matters more than on native. A 30% native speedup that costs 50 KB on wasm is a bad trade for the browser-demo audience; the same speedup at zero wasm cost is a good trade. Every category above is filtered through the wasm-relevance column for this reason.
- **Byte-exact corpus invariant for the nano profile** (per ADR-002). The `nano` configuration's stdout has to stay frozen against `corpus/basics/*.out` (today: 537/541). Optimizations that change observable behavior (different rounding, reordered iteration, different repr of edge values) break the invariant on supported configs and have to either (a) not affect nano output or (b) re-freeze with a documented rationale (the high bar from ADR-002).
- **One-maintainer project.** Work has to be triagable into focused sessions. An optimization arc that requires "a clean run of 6 weeks" is not actually available; one that lands as "a 2-session investigation followed by a 1-session lift" is. This is a hard constraint; it determines which categories are reachable from the maintainer's actual schedule.

Three of these are external (set by prior ADRs); the fourth (one-maintainer) is structural to the project. None of them are negotiable inside this proto, but they directly determine the answer to several of the questions below.

### 4.1 What we already do (to avoid double-counting)

A landscape map that lists pending optimizations should also enumerate what we *are* already doing, so future ADRs avoid proposing work that has already shipped. From a quick read of `port/mpconfigport.h`:

- `MICROPY_OPT_LOAD_ATTR_FAST_PATH`: enabled. Hot path for the common attribute-load case.
- `MICROPY_OPT_MAP_LOOKUP_CACHE`: enabled. Per-call-site cache for dict lookups. (Loosely related to inline caching from §3; a future inline-caching ADR would extend this.)
- `MICROPY_OPT_MATH_FACTORIAL`: enabled. A specific math function fast-path.
- `MICROPY_EMIT_BYTECODE_USES_QSTR_TABLE`: enabled. Compresses bytecode by storing qstrs in a separate table.

We do *not* enable:

- `MICROPY_OPT_COMPUTED_GOTO`: not present. The §6 recommendation for dispatch threading targets exactly this.

The set is small enough that future ADRs should briefly check whether their proposed mechanism is already covered by one of the above; extending a config knob is cheaper than landing a new mechanism from scratch. The strangler porting work means most of MicroPython's existing optimizations come along for the ride; the question is which of the ones it *didn't* turn on by default we should turn on for our default config.

## 5. Open decisions: what makes this a PROTO

The following are explicitly *not* decided here. Each is a fork in the road that needs user direction before the next ADR (006, 007, …) can commit to a concrete arc. The structure mirrors ADR-003's "open questions" but is more central: those questions deferred edge cases; these questions determine which optimization category gets touched at all. Each question below states what is at stake, lists the options, and (where useful) names the consequence chain: the dependency from one answer to the next.

### Q1. Speed, size, or both?

We are green-band on speed; the 20% wasm-size target from Theme F remains open at 8.95%. Both are pursuable; each session has to pick one because the implementations diverge (dispatch threading helps speed only; `wasm-opt -Oz` helps size only). The question is which axis leads the project's narrative for the next arc.

- **Speed-primary**: pursue dispatch + inline caching; accept that wasm size stays where it is until a later arc.
- **Size-primary**: close Theme F's 20% target via `wasm-opt -Oz` + linker flags + frozen-module carveouts; defer dispatch work.
- **Alternating**: one speed-arc, one size-arc, repeating. Higher coordination cost; matches a "balanced product story" framing.

Consequence chain: a "speed-primary" answer pulls Q2 toward "native" or "both"; a "size-primary" answer pulls Q2 toward "WASM" by default, since size on native is not a project goal.

### Q2. Native, WASM, or both?

Several categories help only one of the two (PGO is native-only; `wasm-opt` is wasm-only; dispatch helps both but its relative weight differs). The decision frames every future ADR's success metric: "10% faster" on what build?

- **Native-primary**: optimize for `ReleaseFast` benchmarks; treat wasm as the size story handled separately.
- **WASM-primary**: align with ADR-001's positioning; measure speed *and* size on wasm; native is secondary.
- **Both, weighted**: e.g., 60% wasm / 40% native; report both axes per arc.

### Q3. Compatibility constraint

The hard rule is "byte-exact on nano corpus, MicroPython-compatible on bytecode" (§4). But some optimizations open divergent modes with no signal at the boundary: for example, a `--fast-math` flag that breaks strict NaN handling for a 5% numeric win, or an inline-cache regime that produces visibly different stack traces. The question is whether petitpy is willing to ship clearly-named non-default modes that diverge for performance, or whether the project is strictly behavior-matched on every supported config.

- **Strict**: every supported config matches MicroPython exactly on observable behavior. Optimizations have to be invisible.
- **Non-default divergent modes allowed**: `-Doptimize-numeric=fast` and similar are OK if they are off by default and clearly named.
- **Defer**: cross the bridge when an actual optimization wants it.

The "non-default divergent" option is more attractive than it sounds: it would let us ship surprisingly aggressive optimizations to users who explicitly opt in, without breaking the default story. But it has a real cost: every supported divergent mode is a new test surface, a new doc page, and a new "did this work in the mode I had set?" support burden. The "strict" option is the cleanest; "defer" is the cheapest. The author leans strict-with-explicit-defer: hold off on inventing divergent modes preemptively, while keeping the door open for them.

### Q4. Cadence

Two shapes are coherent and the project has done both before:

- **Focused arc** (Theme L for library, Theme F for size): one named theme, multiple sessions, ships when a stated metric trips. Best for categories with a clear end-state (dispatch threading; wasm size target).
- **Opportunistic single-session tunings**: notice a benchmark looks off, file a one-session investigation, land or revert. Best for the strops 0.67× investigation, peephole tweaks, constant folding additions.

The two can coexist (a project could pursue one arc while leaving slack for opportunistic work). The resourcing question (how many sessions per month go to which) still needs an answer. Historically, the project has done focused arcs better than opportunistic tunings; the F-rehab and NX-1/2/3 arcs both shipped cleanly because they had named themes and clear acceptance criteria, while ad-hoc "let me look at this one thing" tweaks have a higher rate of getting stuck mid-investigation. That history weakly favors "focused arc" as the default cadence.

### Q5. Profiling infrastructure first?

Without an instrumented mode we are guessing where the hot paths are. Adding profiling support (`perf` integration on Linux, a simple instrumented host mode that dumps per-opcode counts and per-allocation sizes) is cheap (~2-3 sessions) and would inform every later category decision. The cost is the opportunity cost: that's 2-3 sessions not spent on the optimization itself.

- **Profile-first**: land profiling, then decide which category from data.
- **Skip profiling**: commit to a category from the benchmark report alone, trusting that dispatch/inline-cache/etc. are well-enough understood elsewhere to start without our own profiler.
- **Lightweight profiling**: a single-session "add opcode counters under a build flag" lift, sized below a full perf-integration arc.

### Q6. The success metric

ADR-004's three-band rubric (green ≤2× / yellow 2-5× / red >5× geomean vs MicroPython) is calibrated for *regression detection*. *Optimization-arc completion* needs its own measure. If a future ADR commits to dispatch threading, how does that ADR know it shipped? Options:

- **Absolute geomean target**: "land at ≤1.10× geomean vs MicroPython." Clean, but might be unachievable on any one category, which makes the success criterion hostage to whatever the next category is.
- **Per-category relative target**: "the dispatch arc closes when fib + sieve each move by ≥10%." Specific to each arc, has to be re-stated each time, less risk of overshoot-or-miss.
- **No numeric target; ship when the diff looks right**: matches the strangler discipline of "ship when the invariant holds." Easier to commit to, harder to know when to stop.

This question is genuinely deferred: *starting* an optimization arc proceeds without it, while *closing* an arc cleanly requires the answer in place.

## 6. Opinionated recommendations: where the proto DOES take positions

The author is willing to commit on five points; the rest stay genuinely open above.

- **JIT is OUT.** Both for ADR-003 (compat: a JIT changes the runtime surface in ways that affect the extension model) and as a category mismatch (JIT is a different project class: different binary size, different memory floor, different maintenance burden, different testing story). If the JIT question reopens, it gets its own ADR; this proto does not pre-litigate.
- **Profile-first is cheap.** Even the lightweight version of Q5 (a host-only `-Dinstrument=on` build that dumps opcode counters) costs ~1 session and saves several later by directing attention. The proto recommends this as the next concrete step regardless of which of Q1-Q4 lands.
- **The strops 0.67× datapoint is the most interesting result in the report.** A 33% advantage over MicroPython on a benchmark we did not specifically tune for is either (a) a transferable pattern we should learn from, (b) an artifact of the particular benchmark's shape, or (c) a sign MicroPython is doing extra work we can also skip. Worth ~1 session of investigation regardless of which other category gets priority. Possible hypotheses to check: do our Zig-side string methods avoid an allocation MicroPython's C-side does? Does the strops benchmark stress an operation where MicroPython's mp_obj_str_split (or the equivalent) has a quadratic copy path that we sidestep? Is there a difference in how the two interpreters handle small-string interning? These are answerable in a session and the answer is interesting regardless of direction.
- **WASM-specific size work is high-ROI.** Closing Theme F's 20% target via `wasm-opt -Oz` + linker tuning is a 2-3 session arc, fully proven elsewhere, zero compat risk, and directly serves ADR-001's WASM-primary positioning. If size is in scope at all (Q1), the arc starts here. The Theme F follow-up arc would also be a natural place to revisit the frozen-tiny boundary from ADR-003: every byte of frozen module that does not actually ship in the wasm build is recoverable size. The boundary was drawn before benchmarks existed to tell us which frozen modules a typical demo actually imports.
- **Interpreter dispatch (computed-goto / threaded loop) is the likely sweet spot for speed work.** Confirmed not yet present in the codebase (no `MICROPY_OPT_COMPUTED_GOTO` in `mpconfigport.h`; `src/runtime/vm.zig` uses a switch-based dispatch); proven 10-25% gain in every comparable project; small in code change; benefits native and wasm together. If speed is in scope (Q1), this is the first arc. Two mechanisms are available: turning on MicroPython's existing `MICROPY_OPT_COMPUTED_GOTO` knob (cheaper; relies on the C-side dispatch we already inherited), or refactoring the Zig-side dispatch loop in `src/runtime/vm.zig` to use Zig 0.14's `continue :sw label(opcode)` pattern (more invasive; cleaner long-term shape). The choice between them is itself an ADR-006 decision; spike both first.

These five do not add up to a plan; they delineate which categories the author would defend in a code review. The actual sequencing depends on Q1-Q5.

### 6.1 What an actual ADR-006 would look like, hypothetically

To make the proto-to-ADR transition concrete: if Q1 lands as "speed-primary" and Q2 as "both", the natural ADR-006 is *"interpreter dispatch: enable threaded-code dispatch in the opcode loop."* It would commit to one of two mechanisms: Zig's `continue :sw` tail-call dispatch (proven in Zig 0.14's stdlib) or MicroPython's `MICROPY_OPT_COMPUTED_GOTO` (proven upstream). Its success metric would be "fib + sieve each move by ≥10% on `make benchmark` median." It would explicitly preserve the 537/541 corpus invariant and the `.mpy` wire compat. The arc length would be 2-4 sessions: one to spike both mechanisms in a branch, one to lift the chosen mechanism in, one or two to chase fallout in `make check` and the wasm build.

Conversely, if Q1 lands as "size-primary", the natural ADR-006 is *"wasm-tiny-2: closure of Theme F's 20% size target via post-link tooling."* It would commit to `wasm-opt -Oz`, targeted linker flags and a per-feature audit of unreachable code. It would leave every benchmark number where it is. It would close when the wasm binary is ≤228 KB (the 20% reduction from today's 286 KB / 5%-margin baseline).

These are illustrative; ADR-006 will hold whatever the user picks, drawn from the §5 questions. Sketching them here shows that both are *reachable* from the §3 landscape; picking between them is deferred to ADR-006.

### 6.2 Risks of opening this proto without immediately following it with a real ADR

A reasonable critique: a landscape map without a commitment is just a TODO list dressed up in section headers. If the proto sits open for too long, it becomes archival reference. Three mitigations:

- The proto is dated 2026-06-07 and references the benchmark report at commit `402cbfd`. If it sits open past a major release boundary without an ADR-006 branching from it, the dates make the staleness obvious.
- §6 takes positions (JIT out, profile-first cheap, strops open, wasm size high-ROI, dispatch likely sweet-spot) that are independently actionable as one-session lifts; even if no ADR-006 happens, those positions can ship.
- The §5 questions are framed as binary or trinary choices, sized below essays. The barrier to picking is intentionally low.

If those mitigations fail and the proto stays open without action for a long period, the right move is to close it as "deferred: no optimization priority at present" and stop it accumulating further commentary. A proto that lives forever undermines the trust the ADR series asks for.

## 7. Out of scope for this proto

- **Specific optimization commitments.** Future ADRs (006+) will commit to one category at a time. This proto is the map; the ADRs are the routes.
- **Performance targets.** No "X% faster by date Y" goal. Targets follow the category decision in that order.
- **The "do we need a JIT?" question for some far-future v1.0+.** Out of scope; the project is well below that horizon. The §6 recommendation against JIT applies to the foreseeable horizon; the eternal question stays open.
- **Embedded-targeting performance.** Embedded comes later (per ADR-001 §3); benchmarking on a hypothetical embedded target would dilute the categories above. If embedded materializes, a separate ADR scopes its perf story.
- **Pre-PR perf gating.** ADR-004 §D5 already explicitly defers this; we do not re-open it here.
- **Hardware acquisition for benchmarking.** ADR-004 already declines a dedicated perf rig; nothing in this proto changes that.
- **Cross-Python-implementation comparisons beyond MicroPython + CPython.** PyPy is out (different category: JIT-vs-interp). Pyston, GraalPython, RustPython etc. are out for the same reason or because they target audiences petitpy does not address.
- **Optimization of build-time tooling.** `make build` taking 4 seconds vs 2 seconds is not a project goal. Build-time perf only matters insofar as it affects the maintainer's iteration speed; that is a separate concern from interpreter perf.
- **Documentation of past optimization decisions.** Several MicroPython-side optimizations come with us via the strangler; documenting their history is a different exercise.

## 8. Next steps from this proto

The trigger for the next document depends on which direction is chosen:

- **User picks directions on Q1-Q5** → write the next ADR (likely ADR-006) on the chosen optimization category. Title: `ADR 006 — <category>: <chosen-mechanism>`.
- **A benchmark report shows a red-band (>5×) result on something** → triggers a focused investigation ADR independent of this proto; ADR-004's D8 catching an unplanned regression.
- **WASM size becomes the priority** → triggers an ADR on WASM-tiny-2 (closure of Theme F's 20% target), inheriting §6's WASM-size recommendation as its starting point.
- **strops investigation lands** → its findings may motivate a generalization arc; or may close as "yes, it's an artifact, no further action."
- **Profile-first lands** → its output may sharpen which category the next big ADR commits to. The numbers might point unambiguously at one row of §3's table; or they might confirm what we already suspect.

The proto closes (graduates to a real ADR) when the open decisions are resolved. Until then, this document is the lookup table the next session reaches for when the user says "let's pick what to optimize next."

### 8.1 What "resolved" looks like

For each of the open questions, the resolution is whichever option the user circles plus a one-line rationale. The following examples of resolution would close the proto into ADR-006:

- Q1 → "speed-primary; size revisited in a separate later arc when 20% target is in reach." Q2 → "both, weighted equally; arc closes when both ratios move." Q3 → "strict; no non-default divergent modes until at least one is concretely justified." Q4 → "focused arc; opportunistic single-session tunings allowed in between." Q5 → "lightweight profiling first: one session to add opcode counters under a build flag." Q6 → "per-category relative target; restated in each ADR."
- With those answers, ADR-006 writes itself: dispatch threading via `MICROPY_OPT_COMPUTED_GOTO`, success metric "fib + sieve each ≥10% faster on `make benchmark` median," with a small profiling lift as P1.

Other answer combinations are coherent too. "Size-primary, wasm-primary, strict, focused arc, skip profiling, no numeric target; ship when wasm binary is ≤228 KB" would produce a wasm-tiny-2 ADR-006. The proto does not advocate one resolution over another except where §6 makes the author's positions explicit; the framework itself matters most.

### 8.2 Anti-goals for the next ADR

A useful exercise when transitioning from proto to ADR is to name the discipline the next ADR should hold to. Whichever direction Q1-Q6 lands on, ADR-006 should:

- **Stay focused.** One category per ADR. If the answer is "alternating speed and size", that becomes two ADRs.
- **Reuse the existing benchmark suite.** Use `docs/benchmarks.md` as-is. Adding a benchmark so an optimization looks better is the worst-possible failure mode for a perf ADR.
- **Preserve the 537/541 corpus invariant.** The existing project gate stands; an optimization that breaks it is reverted before landing.
- **Avoid expanding the build matrix.** A `-Doptimize-mode=aggressive` would expand the CI matrix permanently; the cost is paid forever, the benefit of any single optimization is paid once.
- **Record the negative result.** If the arc lands and the benchmark numbers stay put, the ADR records that; the next ADR-007 needs to know which categories have already been tried and found unrewarding.

These anti-goals are inherited from the project's broader discipline (ADR-002's frozen-corpus rule, ADR-001's no-feature-creep) and from the maintainer's stated preferences elsewhere. Naming them explicitly in this proto means the next ADR-006 author can cross-check against them without re-derivation.

## 9. Risks specific to this proto being a proto

A proto has three risks that a regular ADR avoids:

- **The landscape map becomes a wish list.** Without the discipline of a "we will do X" ending, the rows in §3 can accumulate without anyone ever picking one. Mitigation: §6 commits the author to positions, and §8 names the trigger conditions for the next ADR. If those triggers do not fire within a reasonable cadence, the proto closes as "deferred."
- **The questions in §5 are read as TODO items.** A future maintainer might treat Q1-Q6 as "things to think about" when they are "things to answer before ADR-006 can start." Mitigation: the option lists are intentionally short and the questions are framed as binary/trinary choices. The cost of picking is low; the cost of not picking is the proto staying open.
- **The proto's framing pre-shapes the next ADR.** By laying out the categories the way §3 does, the proto subtly constrains what ADR-006 can be about. Mitigation: §3.1 explicitly names categories that are *not* in the table and explains why; an ADR-006 that picked one of those would have to argue against §3.1, which is exactly the kind of friction that surfaces hidden assumptions.

The mitigations are imperfect but the alternative (skipping the proto and writing ADR-006 directly with whichever direction the author currently favors) is worse: it would pre-commit the project to a category before the user's perspective on Q1-Q6 has been registered. The proto exists to put that decision in the user's hands. The cost of doing so is the risks above; the proto accepts those costs.

## 10. References

- `001-roadmap-v04.md`: WASM-primary positioning; Theme F (size + per-feature stripping) sets the wasm size baseline this proto inherits.
- `002-feature-selection.md`: per-feature `-D` flags and the Path-B corpus invariant; constrains what observable behavior optimizations can change.
- `003-library-and-module-loading.md`: the MicroPython-compatibility commitment (bytecode + language + extension model) that filters several categories in §3.
- `004-benchmarking.md`: where the baseline numbers come from; D8's three-band rubric places us in green today.
- `docs/benchmarks.md`: first report (commit `402cbfd`). The numbers cited in §2 are from this file.
- `port/mpconfigport.h`: searched for `MICROPY_OPT_COMPUTED_GOTO`; not present. Confirms the §6 claim that dispatch threading is an available, unclaimed win. Also lists the three `MICROPY_OPT_*` knobs we already have on (§4.1).
- `src/runtime/vm.zig`: switch-based dispatch confirmed; computed-goto / labels-as-values not currently used. 965 LOC; the dispatch hot path is the natural target for the §6 threaded-loop recommendation.

