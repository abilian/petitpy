# ADR 004. benchmarking: vs MicroPython + CPython, reuse p2w runner with adapters

- **Status**: Accepted (Proposed 2026-06-07; benchmark suite lives under `benchmarks/` and the current comparison table is in [Benchmarks](../benchmarks.md))
- **Decider**: project maintainers
- **Supersedes**: nothing
- **Consequences**: commits the project to producing a benchmark suite + comparison story, with the p2w alioth runner forked and adapted as the framework; defers a fully generic extraction until a third user materializes

## 1. Context

ADR-001 anchors the WASM-primary story. ADR-002 makes feature surfaces composable. ADR-003 settles where the stdlib comes from. None of them say anything about *speed*. That gap is now overdue: ADR-001's Theme E ("performance baseline") was demoted to optional and never landed.

What we already know about petitpy's footprint:

| Surface | Measurement | Reference |
|---|---|---|
| WASM binary, `ReleaseSmall` | 286 KB | README |
| MicroPython unix-standard binary | 652 KB | same hardware, comparable build flags |
| Compiled C under nano | 86 LOC | — |
| Corpus parity (arm64-macos) | 537/541 byte-identical | nano-C oracle |

What we do *not* know:

- Wall-clock time on any benchmark, against any reference.
- Whether the Zig port pays a per-opcode cost, breaks even, or wins on dispatch overhead.
- Whether the small-binary win comes at a startup-time win (less code to load) or a wash (slower dispatch absorbing the savings).
- How peak RSS compares (relevant for the embedded-future audience and for browser tabs).

Under WASM-primary positioning (ADR-001 §1.4) this gap is sharper than it would be under a native-first project. A browser visitor running a 1000-iteration loop expects responsiveness; a tab that locks for 4 seconds where MicroPython locks for 1 is a story we want to know about *before* a user reports it.

### 1.1 What MicroPython provides

Upstream provides `tests/perf_bench/`, a small in-tree microbenchmark suite whose ~10 files cover loops, dict access, string ops, recursion and builtin calls. It's tuned for microcontroller speeds; on a modern host the runs are short but the relative ordering is stable. It runs unmodified under both MicroPython and CPython, which makes it the obvious shared substrate.

### 1.2 What CPython provides

`pyperformance` is the canonical CPython suite (50+ benchmarks, real-world workloads), built on `pyperf` for statistically-careful timing. It is not a candidate for direct use: it pulls in `setuptools`, `dulwich`, `pip`, and a sizable transitive closure of pure-Python deps. Most of those will not import under petitpy today (ADR-003 has not landed). `pyperf` itself, the timing harness, is small and useful, but adopting it directly would couple our suite to CPython's package ecosystem.

### 1.3 Existing infrastructure in adjacent projects

The maintainer runs two other Python-related projects in `sandbox/`:

- **`sandbox/aopyc`**: Python compiler experiment. Grep-checked: no benchmark code. The project's plans mention benchmarking; nothing is written.
- **`sandbox/p2w`**: Python-to-WASM compiler. Two runners exist:
  - `programs/benchmarks/run_benchmarks.py` (782 LOC): p2w vs CPython, SQLite session DB, geomean comparisons, warmup+timed runs, Node.js WASM harness inlined.
  - `programs/benchmarks-alioth/run_benchmarks.py` (944 LOC) compares p2w, CPython and native GCC on programs from the Computer Language Benchmarks Game (binarytrees, fannkuchredux, fasta, mandelbrot, nbody, spectralnorm, knucleotide, revcomp), with a YAML suite config and per-language source directories. It uses the same SQLite/geomean infrastructure as the older runner.

The p2w runners are tightly coupled to p2w (`from p2w.compiler import compile_to_wat`, hardcoded Node.js WASM import shims), but the *structural* parts (suite YAML, warmup+timed loops, SQLite session DB, geomean+median reporting, markdown table emit) are reusable. Sample size of "frameworks worth lifting from": one.

## 2. Decision space

### 2.1 What do we compare against?

| Reference | Comparison shape | Verdict |
|---|---|---|
| **MicroPython unix-standard** | Apples-to-apples (same VM lineage, comparable feature surface) | Primary |
| **CPython 3.11+** | Cost-of-being-small (informational; users know CPython numbers) | Secondary |
| PyPy | JIT vs interpreter; different category | Out of scope |
| MicroPython embedded variants | Speed-from-hardware-constraint dominates speed-from-code | Out of scope |

### 2.2 Which benchmark suite?

| Suite | Coverage | Will it run on petitpy? | Verdict |
|---|---|---|---|
| **micropython/tests/perf_bench (chosen)** | ~10 micros: loops, dict, string, recursion | Yes (designed for it) | Primary suite |
| pyperformance / pyperf | 50+ broad real-world | Mostly no (heavy deps; ADR-003 not landed) | Defer |
| pypy benchmark suite | Mid-size, classic numeric | Probably no (some C exts) | Defer |
| **Custom subset (chosen, small)** | Fill gaps perf_bench leaves uncovered (startup, simple arith, GC pressure) | Yes (we author them) | Supplement |
| Alioth Benchmarks Game subset | nbody, fannkuch, mandelbrot, etc. | Mostly yes, requires careful porting | Deferred |

### 2.3 What do we measure?

| Metric | Why it matters | In scope |
|---|---|---|
| **Wall-clock time** | The primary metric. What the user feels. | Yes (median + min over N runs) |
| **Peak RSS** | Memory footprint; embedded-future + browser-tab budget | Yes |
| **Binary size** | Already in README; include for completeness alongside speed | Yes |
| **Startup time** | Short scripts in browser feel the cold-start cost | Yes |
| CPU cycles, perf counters | Platform-specific, harder to interpret | No |
| Microbenchmarks per opcode | Too low-signal at our scale; one big optimization can flip them all | No |
| Allocator throughput in isolation | Coupled to workload; emerges from wall-clock | No |

### 2.4 Where does the framework come from?

| Option | LOC cost | Generality | Verdict |
|---|---|---|---|
| **REUSE_P2W (chosen, with adapters)** | Fork the p2w alioth runner (~900 LOC); add an interpreter-strategy interface; point it at three binaries | Low (still p2w-shaped) | Pragmatic; sample-size-one extraction is premature abstraction |
| EXTRACT_GENERIC `benchmark-tools` repo | ~600 LOC shared lib + per-project thin runner | High (Rule of Three would be honored) | Defer until aopyc or another consumer needs it too |
| Custom from scratch | ~800 LOC | Low | Wasteful; p2w runner already solves the hard parts (SQLite, geomean, multi-process timing) |
| `pyperf` directly | 0 LOC, but couples us to CPython ecosystem and not designed for sub-second startup-heavy comparisons | High | No |

Justification for picking REUSE_P2W over EXTRACT_GENERIC: extracting a shared library requires *two* working consumers to validate the abstraction. We have one (p2w). aopyc has plans on paper. Building the shared lib now means abstracting against a sample size of one, almost guaranteed to encode p2w-specific assumptions and need rework when aopyc actually arrives. The cheaper path is to fork the runner into petitpy, do the work that lets petitpy benchmark itself, and *then*, when aopyc reaches the point of wanting its own runner, extract the shared parts as a third step with three concrete users to triangulate against. This is the Rule of Three applied to benchmarking infrastructure.

A secondary consideration: the reusable parts of the p2w runner (SQLite session DB, geomean, multi-process timing harness, YAML-driven suite config) are the *least* p2w-specific parts. Fork-and-adapt keeps them intact while paying down the p2w-specific code (Node.js WASM shim, `p2w.compiler` import) once. The two-pay path is gone. If the eventual EXTRACT_GENERIC happens, those reusable cores become the seed crystal: they will have already been used by two projects (p2w + petitpy) without modification, the strongest signal that a shared lib is the right shape.

## 3. Decision

We adopt MicroPython unix-standard and CPython 3.11+ as the reference implementations, and micropython/tests/perf_bench plus a small custom subset as the suite. We measure wall-clock time, peak RSS, binary size and startup time, and nothing platform-specific. We fork the p2w alioth runner into petitpy as the framework, wire it through an interpreter-strategy interface, and defer extraction of a shared `benchmark-tools` library until a third consumer materializes. Benchmarks run locally per session and in CI per tagged release. The report is a markdown table in `docs/benchmarks.md` with relative-to-MicroPython and relative-to-CPython ratios, backed by a JSON archive for trend analysis.

### D1. Reference implementations: petitpy + MicroPython + CPython

Every results table has three rows:

- **petitpy**: the project under test. Built in `ReleaseFast` for benchmarking (we use `ReleaseSmall` for distribution; speed comparisons should reflect what an optimized native build looks like, distinct from what we ship to the wasm tab).
- **MicroPython unix-standard**: the apples-to-apples comparison. Same VM lineage, comparable feature surface (the byte-exact corpus already proves this). Built from a pinned upstream tag.
- **CPython 3.11+**: the "cost of being small" baseline. The reader will mentally normalize against CPython whether we publish the comparison or not; explicit beats implicit. The framing measures the cost of a 286 KB Python against a 30 MB Python: a measurement of trade, distinct from a target to beat.

This is consistent with ADR-003's commitment to MicroPython compatibility: we benchmark against the implementation we are wire-compatible with. We also publish the CPython delta so a CPython-fluent reader can calibrate.

### D2. Suite: micropython perf_bench + a small custom supplement

micropython/tests/perf_bench is the primary substrate, designed to run on a microcontroller-class interpreter, no external deps, ~10 small benchmarks that exercise the core dispatch loop and common builtins. We adopt it unmodified.

A small custom supplement (3-5 files in `benchmarks/custom/`) covers what perf_bench under-tests:

- **Startup time**: `print("hello")` measured cold (`time interp script.py`); matters for short browser scripts.
- **Import latency**: `import json` once frozen-tiny ships (ADR-003); informational.
- **GC pressure**: a small allocator-churn loop, complementary to perf_bench's recursion micros.

The supplement is intentionally tiny; it fills perf_bench's blind spots without becoming "our own benchmark suite to maintain." If micropython adds a new perf_bench upstream, we pick it up at the next sync.

This ADR leaves out pyperformance, the Computer Language Benchmarks Game subset (Alioth), and any benchmark requiring C extensions or heavy stdlib (`numpy`, `regex`, etc.).

### D3. Metrics: wall-clock, RSS, binary size, startup; nothing else

For each benchmark and interpreter, the runner records the following:

- **Wall-clock**: median + min of N timed runs after K warmup runs. Defaults: K=2 warmup, N=10 timed (the p2w alioth runner's defaults; conservative for the low-noise local case).
- **Peak RSS**: sampled via `/usr/bin/time -v` on Linux / `/usr/bin/time -l` on macOS. Best-of-N to remove cold-cache noise.
- **Binary size**: measured once per release; included alongside the per-benchmark table for context.
- **Startup time**: `print("hello")` wall-clock. Browser-tab users feel the minimum case.

These stay out of scope at this stage:

- CPU cycles / perf counters / cache misses: too platform-specific; results stay local to one architecture and fail to transfer across the macOS-arm64 / Linux-x86_64 boundary the project actually runs on.
- Per-opcode micro-benchmarks: too low-signal; one allocator change can flip every number without telling us anything actionable.
- Power consumption: irrelevant until an embedded story exists (ADR-001 §3 defers).

### D4. Framework: fork the p2w alioth runner; add an interpreter-strategy interface

Lift `sandbox/p2w/programs/benchmarks-alioth/run_benchmarks.py` into `benchmarks/runner.py`. Strip the p2w-specific paths (the p2w compiler import, the Node.js WASM shim, the GCC compile path). Keep the SQLite session DB, geomean, and median+stddev reporting and the YAML suite config. Replace the compiler-in / interpreter-out coupling with an `Interpreter` strategy class implementing `version() -> str`, `binary_size() -> int`, and `run(source, args, timeout) -> (output, time, peak_rss)`; three implementations wrap petitpy, MicroPython unix-standard, and CPython.

Future generalization (open question §9): if and when aopyc wants its own benchmark runner, three consumers (p2w, petitpy, aopyc) triangulate the shared abstraction, and extracting a `benchmark-tools` package becomes well-defined work.

### D5. Where do benchmarks run?

| Venue | Cadence | Purpose |
|---|---|---|
| **Local (maintainer's machine, arm64-macos M-class)** | Per session, ad-hoc | Primary numbers in the published report |
| **SourceHut CI (debian/trixie, x86_64-linux)** | Per tagged release | Cross-arch sanity check; archived JSON |
| **Per-PR CI** | Skipped | Noise-to-signal too high; would dominate CI time |
| **WASM (wasmtime / browser harness)** | Per major release | Separate report; less rigorous |

Per-PR runs are excluded by design. Wall-clock variance on shared CI runners is large enough that single-run regressions are dominated by noise; a "speedup of 1.04x" cannot be distinguished from a system-load blip. We optimize for *information* (release-time snapshots that contextualize the project); *gating* (PR-time guardrails) is out of scope. If a future ADR adds perf-gating, it would need its own dedicated hardware budget.

### D6. Reporting: markdown table + JSON archive

Per release, regenerate `docs/benchmarks.md` with:

- **Header block**: host platform (arm64-macos M-series, kernel, RAM, CPU governor), interpreter versions + commit SHAs, build flags, framework version, run timestamp.
- **Main table**: benchmark × interpreter, wall-clock median in ms, with **ratio columns** vs MicroPython and vs CPython. Bold the slowest cell per row so regressions pop visually.
- **Geomean row**: geometric mean of speedup ratios (geomean is the right mean for ratios: it treats 2× faster and 2× slower symmetrically).
- **RSS table** (separate, smaller): peak RSS per interpreter per benchmark.
- **Startup table** (one-row-per-interpreter): `print("hello")` wall-clock.

Behind the markdown, a JSON archive at `docs/benchmarks/history/<YYYY-MM-DD>-<sha>.json` keeps every run for trend analysis. The SQLite DB inherited from the p2w runner stays as the working format; the JSON archive is the long-term log.

### D7. Reproducibility

Every reported number is reproducible from the published metadata:

- **Pinned interpreter versions**: MicroPython at a specific upstream tag (recorded in the report header) with the commit SHA alongside, CPython at a specific point release (e.g., `3.11.9`). Bumps to either are noted in the release changelog with a one-line rationale.
- **Pinned host platform**: arm64-macos M-series for the primary report, x86_64-linux for the CI-archived cross-check. Each report file declares its platform in the header; we do not mix-and-match cells across platforms.
- **Build commands published**: the report header includes `make build` for petitpy, `make` for MicroPython unix-standard, and `./python` for CPython, with the exact flags used (`ReleaseFast` for petitpy, `MICROPY_GCREGS=0` and equivalent defaults for MicroPython, `--enable-optimizations` for CPython). A reader who clones the project and follows the recipe should land within noise of the published numbers.
- **Run conditions**: laptop on AC power, default CPU governor, no other foreground apps. The header records the macOS / Linux version and the CPU model. The published numbers reproduce on equivalent hardware; a different hardware class will produce different numbers. We make no claim about that case.

The reproducibility story aims for practitioner-level rigor, without clinical-trial control. A reader who follows the recipe should land in the same band as our published numbers. If a serious performance comparison is needed for a research paper or release-go decision, the published numbers are the starting point for further work.

### D8. Acceptance criteria for petitpy performance

We adopt a coarse three-band rubric:

| Geomean ratio vs MicroPython unix-standard | Color | Interpretation |
|---|---|---|
| ≤ 2× slower | green | Acceptable; the smaller binary is the trade we made |
| 2× to 5× slower | yellow | Investigate at a release boundary; not blocking |
| > 5× slower | red | Investigate before next release; potential regression |

Two caveats. First, the bands are calibrated to "what the project would tolerate before someone would notice in normal use": internal judgment based on project experience. Second, absent a dedicated optimization arc, our most likely landing zone is yellow. That is fine. The benchmarks are *exploratory* (bound to that role and never a release gate). D8 lets us look at a fresh report and quickly answer *"did something get dramatically worse since last release?"*; the answer is informational and does not gate.

This bands-based framing leaves room for ADR-001's WASM-primary positioning: a 4× slowdown on an interpreter that ships at 44% of MicroPython's size *is* a valid trade. The published bands should say so.

## 4. Implementation plan

Phased without version anchoring (ADR-002/003 precedent; phases follow dependency order, with no calendar slots):

- **P1. Framework**: fork the p2w alioth runner; strip p2w/GCC paths; introduce the `Interpreter` strategy interface; wire petitpy, MicroPython unix-standard, CPython 3.11+. Verifies as: `python benchmarks/runner.py --benchmark fib` produces a three-row table.
- **P2. Suite**: select perf_bench files; author the 3-5 custom supplements (`startup`, `import`, `gc-pressure`, ...); make them all runnable across all three interpreters. Verifies as: every benchmark prints valid output on all three; failures are explicit `[SKIP: reason]` not silent.
- **P3. First report**: run the full suite locally; commit `docs/benchmarks.md` + initial JSON archive as the baseline. This is the data this ADR was written to produce.
- **P4. CI step**: add a SourceHut CI job that runs on tag pushes only; uploads the JSON to the run archive and posts a link in the release notes. Informational only.
- **P5. Documentation**: two sections. "How to read these numbers" covers the CPython baseline, the MicroPython comparison and what the bands mean; "How to add a benchmark" fits on one screen, since the runner already takes a YAML config.
- **P6. WASM track**: separate runner that drives wasmtime and a headless-browser harness (Playwright or playwright-stable). Less rigorous than native; published alongside but clearly labeled.

## 5. Out of scope

Open questions deferred:

- **Performance optimization.** A benchmark is not an optimization plan. Identifying that fib runs at 4× MicroPython does not commit us to closing that gap. Optimization work, if scheduled, gets its own arc and its own ADR.
- **Hardware acquisition.** We benchmark on the maintainer's machine + a shared CI runner. No purchase of dedicated perf hardware is implied.
- **Continuous-benchmark-on-PR.** D5 explicitly defers this; the noise floor of shared runners makes single-run PR comparisons unreliable.
- **PyPy comparison.** PyPy is a JIT, a different category. A nano-Python that ships with no JIT and 86 LOC of compiled C against a sophisticated tracing JIT is a comparison that misinforms.
- **Microbenchmarking individual opcodes.** D3 explains why; too low-signal at our scale.
- **Benchmarking per-feature stripping** (`-Dfeature-X=off`). Interesting question (does removing `async` materially change the dispatch loop?), but distinct from the cross-interpreter comparison this ADR is about. A future ADR can layer it on top.

## 6. Risks

**The reference implementations might not represent what users care about.** MicroPython unix-standard runs on a desktop; the embedded MicroPython variants run on hardware that imposes the speed constraint independently of code quality. A petitpy user who eventually targets embedded will care about a different reference than the one we publish. *Mitigation*: the published header makes the choice explicit; a future ADR can add a second reference if a user audience materializes.

**Wall-clock noise.** Even with K=2 warmup + N=10 timed + median+min reporting, run-to-run variance on a laptop is 5-10% on small benchmarks. *Mitigation*: report median; the SQLite session DB preserves all raw runs so a reader who doubts a number can inspect the distribution.

**Framework drift across projects if we *do* eventually extract.** Open question §9 hedges this; if the extraction happens, the shared lib will need a maintainer commitment that remains unallocated. *Mitigation*: deferring extraction today (D4) sidesteps the drift problem for now. When extraction happens, an ADR on the shared lib settles the ownership question.

**Inconsistency between local-arm64-macos and CI-x86_64-linux numbers.** Different ISAs, different compilers, different optimizers. The two report files (D7) are not directly comparable. *Mitigation*: each report's header pins its platform; readers know not to compare across files. The cross-arch sanity-check value (does petitpy work on Linux at all?) is real even without numeric comparability.

**MicroPython upstream version drift.** If we pin to a tag and the tag moves out from under us (force-push, repo rename), the reproducibility story breaks. *Mitigation*: the report header records the pinned commit SHA alongside the tag name. The submodule discipline from ADR-003 (D8 of that ADR) extends here.

**Benchmark suite becoming a release commitment.** If users start treating `docs/benchmarks.md` as such, every release that skips a refresh will look like a regression. *Mitigation*: P5's "how to read these numbers" section is explicit that the report is exploratory information and never a release gate. Bands (D8) reinforce that yellow is normal.

## 7. Success criteria

The work ships when:

| Criterion | Verified by |
|---|---|
| `benchmarks/runner.py` produces a three-row markdown table for at least one benchmark | manual smoke |
| The full perf_bench suite runs on all three interpreters end-to-end | `benchmarks/runner.py --suite perf_bench` exits 0 |
| `docs/benchmarks.md` exists with a baseline table for petitpy vs MicroPython unix-standard vs CPython 3.11+ | docs review |
| The JSON archive has at least one historical run committed | `git log -- docs/benchmarks/history/` |
| The CI step runs on a tag push and uploads the JSON | observation on a release-candidate tag |
| The framework is documented well enough that a contributor can add a benchmark without reading the runner source | one screen in `docs/benchmarks.md` |
| The byte-exact regression detector stays at 537/541 | `make check` on every commit |
| At least one reported regression (or non-regression) has informed a subsequent ADR or release note | first ADR/release-note that cites a benchmark number |

## 8. Open questions (deferred to future ADRs)

- **JIT.** Should petitpy ever JIT-compile? Probably never: different category, would explode the binary, conflicts with WASM-primary positioning. If this question reopens, it gets its own ADR; this ADR does not pre-commit.
- **Per-feature performance.** Does `-Dfeature-async=off` materially change dispatch overhead? Measure once ADR-002 is fully landed; distinct from upstream comparison.
- **SourceHut CI integration shape.** D5 specifies tag-only runs but not the workflow YAML. The CI ADR (when written) settles the runner choice, secrets, and artifact retention.
- **Generalization into `benchmark-tools`.** D4 defers. The trigger: aopyc (or any third project) reaching the point of wanting its own benchmark runner. At three concrete consumers we have enough signal to extract a shared lib without prematurely abstracting.
- **PyPy / other-implementation comparison.** Out of scope §5; if the audience for "how does petitpy compare to PyPy on real workloads" materializes, a separate ADR scopes that work and acknowledges the JIT-vs-interp framing problem.
- **Benchmark deprecation.** If a benchmark stops being informative (e.g., is dominated by syscall overhead that none of the interpreters control), we need a way to retire it without breaking historical comparability. The JSON archive's per-run schema-version field is the lever; an ADR can settle the policy if it bites.
- **Embedded benchmarking.** ADR-001 §3 defers embedded; benchmarking against embedded MicroPython variants follows that deferral. If embedded comes into scope, a separate ADR adds a reference implementation row for it.

## 9. References

- `001-roadmap-v04.md`: Theme E was the optional perf-baseline slot that this ADR finally fills.
- `002-feature-selection.md`: per-feature stripping is the lever for the deferred "per-feature perf" question (§8).
- `003-library-and-module-loading.md`: the MicroPython-compatibility commitment that motivates picking MicroPython unix-standard as the primary reference.
- `micropython/tests/perf_bench/`: primary benchmark substrate (D2).
- `pyperformance` and `pyperf`: broader CPython suite + timing harness; D2 explains why we defer.
- `sandbox/p2w/programs/benchmarks-alioth/run_benchmarks.py`: the runner we fork (D4); 944 LOC, with a SQLite + geomean + warmup+timed structure we can reuse.
- `sandbox/p2w/programs/benchmarks/run_benchmarks.py`: earlier p2w runner; same structure, smaller suite scope.
- `sandbox/aopyc/`: checked for benchmark infrastructure; none found (plans-only).

---
