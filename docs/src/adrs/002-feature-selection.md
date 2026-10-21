# ADR 002. Feature selection: per-feature `-D` flags with one frozen `nano` profile

- **Status**: Accepted. Partially superseded by [ADR 012](012-profiles-and-feature-matrix.md): the per-`-D` flag mechanism is retained; the "one frozen `nano` profile" framing is replaced with a multi-profile mapping. See ADR 012 §1 for the reframing.
- **Decider**: project maintainers
- **Supersedes**: nothing
- **Consequences**: enables Theme F (size + per-feature stripping) in the revised ADR-001; opens or constrains the v0.5+ embedded story; preserves byte-exactness as a regression-discipline tool. **ADR 012 update**: byte-exact contracts now exist per profile, where there was a single `nano` baseline.

## 1. Context

At v0.3.0 the build accepts exactly two values for `-Dconfig`: `nano` and `full`. Everything else is downstream of that single boolean. `port/mpconfigport.h` holds one large `#ifdef NANOPYTHON_CONFIG_FULL` arm that flips dozens of `MICROPY_*` knobs. The Makefile threads `CONFIG=nano|full` to `zig build -Dconfig=$(CONFIG)`. The corpus oracle has two directories: `corpus/basics/` (nano-frozen, byte-exact, 537/541) and `corpus/full/basics/` (softer target, 517/552 ≈ 93.7%). That two-track split was the right shape for the strangler arc: nano was the floor we were paying down, full was the parity ceiling, and "everything in between" was undefined because no user had asked for it.

The revised ADR-001 introduces **Theme F: size and per-feature stripping** as the WASM-primary next step. Theme F is the moment when "everything in between" stops being hypothetical. Three forces are converging:

| Force | Why it matters now |
|---|---|
| **WASM is the primary target** | The web demo ships a 1.5 MB ReleaseSmall binary today. Half of that is feature surface a typical demo will never exercise (mpz, full I/O, threading). A ~600-800 KB binary is achievable with selective feature disabling. The size axis has a constituency. |
| **Embedded devs (future)** | Theme F's stated audience is the embedded user who, when they arrive, needs to fit the interpreter into a fixed flash budget, which "whatever happens to be in `full`" will rarely match. MicroPython itself solves this with per-port `mpconfigport.h` variants. We need an equivalent that fits our (single-port, single-maintainer) shape. |
| **The byte-exact corpus is now a regression detector** | The corpus has changed in kind: it used to compare our output against the vendor C reference (the strangler oracle); that role has retired. A regression detector remains, useful but with different requirements. One frozen profile is enough to preserve that discipline. See §1.1. |

The current two-profile system is a developer convenience. The web-demo and embedded audiences each need a shipping story that Theme F has yet to provide.

### 1.1 Byte-exactness: what it was, what it is now

An earlier draft of this ADR treated byte-exactness as a general invariant that any feature-selection mechanism had to "preserve for the shipping configurations." That framing was wrong. It distorted the rest of the document. The corrected view:

- **Byte-exactness was a strangler-discipline tool.** During the C→Zig port, we compared our output byte-for-byte against the vendor C reference. Any drift between the two binaries was, by definition, a bug, which was the point. The corpus was an *oracle*: a third party (vendor C) said what the right answer was. Our job was to match it.
- **The strangle is converged.** Vendor C no longer compiles in this repo. The corpus directory `corpus/basics/*.out` now compares our output against *our own past frozen output*. The oracle has degraded to a regression detector. It still catches "this PR accidentally changed `repr(1.0)`"; the external attestation that the old output was the *right* output has lapsed. Byte-for-byte stability is now an internal discipline; the external truth is gone.
- **Byte-exactness is internal.** No user of petitpy cares whether `print(1+1)` produces the same bytes today as it did in 2024. The discipline serves the maintainer (catches faithful-port regressions during ongoing refactors); it serves no user-facing requirement.
- **One frozen profile is sufficient.** Because the role is "catch regressions in the maintainer's own work," only *one* configuration needs its output frozen: the `nano` profile, which `corpus/basics/` already tracks. Every other configuration can be free without diluting the regression-discipline benefit: a regression that affects `nano` is caught by `nano`'s corpus. A regression that *only* affects non-`nano` configurations is, almost by definition, a feature interaction in the non-`nano` code paths, territory where unit tests serve better than corpus diffs.

This reframing changes what the rest of this ADR is choosing between. The earlier draft argued "Path B trades byte-exactness for compositional purity; that trade is wrong because byte-exactness is a need." That argument no longer holds: one frozen `nano` profile keeps the regression-detector benefit under **any** of the three paths. The real tradeoff is now about *complexity* (how much build-system machinery and CI matrix do we want?) and *UX* (do we want named, documented entry points, or are flag combinations fine?).

### Why now

A reasonable counterargument is to defer this decision to v0.5, ship the web demo with whatever `wasm-tiny` happens to mean at the time, and treat feature selection as future work. The reason to decide now is **the shape of `mpconfigport.h`**. Today's single `#ifdef NANOPYTHON_CONFIG_FULL` arm is the bottleneck: every feature lift that wants to be optional has to either (a) be added under both arms with duplicated logic, or (b) get its own ad-hoc define that does not compose with anything else. The first Theme-F PR will either decompose that arm into per-feature `#ifdef`s or it will work around it. Decomposition is the right shape; the question is which build-side mechanism drives those `#ifdef`s. Settling that now keeps the v0.4 work coherent; settling it later means a likely rewrite of however the first Theme-F PR did it.

### What problem are we actually solving

Two real users have two real asks:

- **Web-demo user**: "I want petitpy for the browser. Skip mpz, skip threading, skip filesystem I/O beyond what the WASI shim already gives me. Get me to <800 KB."
- **Embedded user (v0.5+)**: "I have a board with 256 KB of flash. I need float, I need `time`, I do not need asyncio. Tell me what's in your binary so I can budget."

Both users want a subset of the full feature surface, expressed declaratively, with a build that produces a working binary and (where possible) a test signal. The two-profile system gives them an all-or-nothing choice. We need granularity.

### What MicroPython does (for reference)

Upstream MicroPython solves this problem with **per-port `mpconfigport.h` files**. There is `ports/unix/mpconfigport.h`, `ports/stm32/mpconfigport.h`, `ports/esp32/mpconfigport.h`, and so on, one per physical target. Each port's header overrides whichever `MICROPY_PY_*` knobs that port needs to flip relative to the defaults. There are around 30 ports in the upstream tree, each maintained separately, each with its own corpus of "this works on this board" knowledge encoded in the file.

This pattern works for MicroPython for three reasons. Every port has a real human maintainer who owns the configuration. The corpus oracle is per-port (each port has its own `tests/` runs that pass on its board). Finally, the user-facing distribution model is "download a firmware blob for your board," where users never build their own combination. The selection mechanism is the port, which is forked by design.

petitpy's situation is different: there is one maintainer, one frozen-corpus profile (`nano`), and the distribution model is "build it yourself with `zig build`." We want compositional feature selection without forking a header per audience. The right shape borrows the *per-feature knob* idea from MicroPython's `MICROPY_PY_*` defines (and from how MicroPython's own configs are driven by orthogonal `#define`s, with no named bundles), while reserving the byte-exact regression-detector role for the single `nano` profile.

### Out of scope

This ADR leaves these out:

- A plugin/loader architecture (features loaded at runtime via shared objects). The strangler is statically linked end-to-end; that property is essential to the size story.
- Per-port `mpconfigport.h` variants in the MicroPython sense (one config per physical board). The embedded story may want this eventually; this ADR concerns the *selection mechanism* alone (the target catalog stays out of scope).
- Changing what `nano` means. The frozen-bug discipline of nano is independent of this ADR. See §11 open questions.

## 2. Decision space

Three reasonable mechanisms exist. Each is internally consistent. Each has a different relationship with the corpus oracle.

### Path A: Preset library

Ship a fixed set of named presets (4 to 8 of them), each backed by a checked-in `mpconfigport.h` variant. A preset is a discrete, named, testable artifact. Users pick `-Dpreset=nano`, `-Dpreset=nano-float`, `-Dpreset=full-nothreads`, `-Dpreset=wasm-tiny`, and so on. Composition is not supported: every preset is its own variant file. CI gates each one against its own frozen corpus directory.

The structural appeal is that every shipping configuration is byte-exactly testable. The corpus oracle stays clean: `corpus/nano/basics/` for nano, `corpus/wasm-tiny/basics/` for the small WASM build, and so on. Documentation is short: "Use `nano` if you want X, `wasm-tiny` if you want Y." The CI matrix is bounded (it is exactly the cardinality of the preset list), so the resource cost is predictable.

The structural cost is **inflexibility**. A user who wants "nano plus float but without asyncio" gets told to file an issue and wait for a new preset, or to maintain a fork. Each new preset is a maintenance burden: one more `mpconfigport.h` to keep in sync as features land, one more corpus directory to refreeze on any global change, one more CI job to run. The preset namespace grows monotonically with no compositional discipline. By v1.0 we could plausibly maintain 15 presets, most of them differing from each other by one or two knobs. Each one would be justified on its own; together they would be a mess. The combinatorial explosion is N presets × M architectures × R release modes: bounded, and large. For embedded targeting in particular, presets-only is painful: a board's exact flash budget rarely matches a preset's exact feature set, so embedded users end up forking anyway.

### Path B: Per-feature `-D` flags

Per-feature toggles flow through Zig's build system: `zig build -Dfeature-float=on -Dfeature-asyncio=off -Dfeature-mpz=off -Dfeature-io=on`. Each `-D` flag flows through `build.zig` and is converted at comptime into the right `MICROPY_*` define in a generated `mpconfigport.h`. The user picks any combination of features they want and the build produces a binary configured exactly to that combination.

The structural appeal is **maximum flexibility**. Embedded devs get exactly what MicroPython itself offers via its `mpconfigport.h` conventions: the full granular API surface, expressed declaratively in build flags. Features compose freely. There is no naming explosion because there are no named configurations: just a set of orthogonal toggles.

The structural cost is **the corpus oracle collapses**. The current byte-exact discipline says: "this exact `mpconfigport.h` produces this exact stdout for this exact input." If every combination of feature flags produces its own `mpconfigport.h`, every combination has its own oracle; and there are 2^N combinations for N features. Freezing a corpus per combination, running CI for every combination and documenting the matrix are all infeasible. The user is on their own. Their config either works or fails; only they can tell. Worse, **feature interactions break silently**. Float depends on certain arithmetic primitives, asyncio on generator machinery, and mpz on int representation choices. A user who picks `-Dfeature-float=on -Dfeature-int=small` may get a build that compiles but crashes at runtime in a hard-to-debug way. The project has no place to catch that: the only artifact is the cross product, lacking a central list of valid combinations.

### Path C: Hybrid (presets composed of feature sets, with `-D` overrides)

Define a small set of composable **feature sets** in `build.zig`: `float`, `io`, `asyncio`, `mpz`, `complex`, `threading`, and so on. Each feature set is a comptime-visible bundle of `MICROPY_*` defines. **Presets are named combinations of feature sets**: `nano` is the empty set, `nano-float = {float}`, `full = {float, io, asyncio, mpz, complex, threading}`, `wasm-tiny = {}` minus a few additional knobs. The user invokes a preset via `-Dpreset=nano` and optionally overrides individual features via `-Dfeature-float=on/off`.

The structural appeal is **composability without naming explosion**. The named presets are the supported, CI-gated, byte-exact-testable shipping configurations. Feature-set granularity gives embedded users (and tinkerers) the knobs they need without forcing the project to enumerate every plausible combination. The user who wants "nano + float but without asyncio" picks `-Dpreset=nano-float`; the user who wants something more idiosyncratic picks `-Dpreset=nano -Dfeature-float=on -Dfeature-foo=on`. When they cross the line into override mode, the build emits a clear warning and the corpus invariant relaxes from "byte-exact" to "user-tested." Migration from Path A is incremental: every preset that exists today stays valid, the only difference is that overrides become possible.

The structural cost is **complexity**. There is more code in `build.zig` and more documentation to write (both presets and the override surface). There is also a categorical line we have to draw and defend between "supported" (preset-only) and "buyer beware" (overrides). The boundary between feature sets has to be designed thoughtfully: too coarse and overrides are useless, too fine and the interaction graph becomes unmanageable. Path C is also the path that requires us to decide *now* which features belong together: which knobs cluster into the `float` set, what counts as `asyncio` versus `coroutines`, how to factor out `mpz` from `complex`. Those decisions are easier to defer with Path A or Path B, harder to defer with Path C.

### Comparison table

| Property | Path A presets | Path B flags | Path C hybrid |
|---|---|---|---|
| User flexibility | low | high | medium-high |
| Corpus oracle preserved | yes, per preset | no | yes, per preset; relaxed under overrides |
| CI matrix bounded | yes | no | yes |
| Documentation burden | low | high | medium |
| Naming explosion risk | yes (long-term) | no | low |
| Embedded fit | poor | good | good |
| Web-demo fit | adequate | adequate | good |
| Compositionality | none | full | partial |
| Implementation complexity | low | medium | high |

## 3. Decision

**Adopt Path B (per-feature `-D` flags) with one frozen `nano` profile holding the byte-exact regression-detector discipline. Named entry points (e.g. `wasm-tiny`) ship as thin Makefile aliases or a small const table, sized below a first-class preset registry.**

This is a reversal from the earlier draft of this ADR, which recommended Path C. The reversal follows directly from §1.1: under the corrected understanding of what byte-exactness now is (an internal regression-discipline tool, no longer an external oracle), one frozen profile gives the full benefit. The per-preset corpus matrix that justified Path C's complexity stops paying for itself.

Here is the reasoning, in order of weight:

**Path A is still ruled out: too rigid for WASM size optimization.** The web demo's size budget is the most-immediate driver: a `wasm-tiny` preset is necessary; embedded users (when they arrive) will want a different variant of "tiny" with a slightly different feature mix beyond what one preset can express. Enumerating every plausible target ahead of time is infeasible. The embedded angle in v0.5+ becomes painful with presets-only: every embedded discussion turns into "should we add another preset?", to which the answer is always yes. Same argument as before; this part of the analysis was always right.

**Path B with one frozen profile preserves what byte-exactness now buys us.** The corpus invariant has shifted away from "every shipping configuration must produce a known-correct output," because (a) the external oracle of correctness has retired, and (b) "shipping configuration" was always a developer-discipline concept, never a user-visible contract. One task remains: keep `nano` byte-exact so that ordinary refactors are caught when they accidentally change observable behavior. Path B does exactly this. The `nano` profile is the regression-detector; everything else (`-Dfeature-float=on -Dfeature-asyncio=off`) is per-feature without a corpus gate, the same way most build systems work for most projects.

**Path B's "the corpus oracle collapses" problem is moot.** The §2 description of Path B argued that "the corpus oracle collapses" because every flag combination would need its own corpus. Under the corrected framing, that argument loses its premise: a corpus per combination was never the goal. The goal is a corpus for one combination (`nano`); the others can be tested by unit tests and smoke builds, exactly as `full` is tested today. The "feature interactions break silently" sub-argument from §2 applies equally to Path C-with-overrides; both paths rely on comptime assertions in `build.zig` and on the dependency graph being small. Path B keeps the same surface as Path C on that axis.

**Path C's complexity needs a different justification, which is thin.** With byte-exactness handled by the single `nano` profile, Path C's remaining selling points are (a) named, documented, CI-tested entry points and (b) a curated list of "supported configurations." Both are legitimate UX wins. Neither earns its cost today against the preset registry, the per-preset corpus directories (which would now be regression detectors duplicating `nano`'s job for slight variations), the CI matrix expansion, and the categorical line between "supported" and "buyer beware" that has to be designed and defended. We have one shipping configuration today (`nano`) and one parity target (`full`). Theme F adds one more (`wasm-tiny`). That is a list of three, addressable by three Makefile targets or three const entries in `build.zig`, sized well below a framework.

**Defer the preset registry to v0.5+, when there is real evidence we need it.** Under Path B, named entry points remain allowed: `wasm-tiny` can exist as a Makefile alias that expands to the right `-Dfeature-*` combination. If we later find ourselves accumulating named combinations and wanting first-class presets, the upgrade path from Path B to Path C is mechanical (collect the existing aliases into a `presets` const, add the override-warning logic). The *registry* and the *per-preset corpora* are the speculative work; the *per-feature flags* are needed regardless. Decomposing `mpconfigport.h` into per-feature `#ifdef`s is shared between Path B and Path C; it is the irreducible Theme-F core.

The earlier draft framed Path B as "a one-way door we should not walk through" because relaxing byte-exactness was characterized as unrecoverable. That framing was wrong. Byte-exactness is preserved by the `nano` profile regardless of which path we pick. The door is two-way. The hinge is whether we want a *registry* of supported configurations, which can land later as cheaply as now.

### 3.1 What Path B buys for each audience

To make the choice concrete, each user gets the following under Path B:

| Audience | What they invoke | What they get |
|---|---|---|
| Existing nano user | `make build` or `zig build` | Identical behavior to today. Default is `nano` (all features off). The byte-exact corpus is unchanged. |
| Existing full user | `make build CONFIG=full` | Identical behavior to today. `CONFIG=full` resolves to the set of `-Dfeature-*=on` flags equivalent to today's full build. The soft-target `corpus/full/` discipline is unchanged. |
| Web-demo maintainer | `make wasm-tiny` (Makefile alias) or `zig build -Dtarget=wasm32-wasi -Dfeature-io=on -Doptimize=ReleaseSmall` | A new size-optimized build. No per-preset corpus; correctness is established by `nano`'s corpus (for shared code paths) plus a smoke run of the demo's preloaded scripts (for the demo-specific behavior). |
| Tinkerer/embedded explorer | `zig build -Dfeature-float=on -Dfeature-io=on` | A build configured exactly to their flags. It emits no warning and has no corpus gate: the same support contract as any other build system. Comptime assertions catch incoherent combinations (e.g. `complex` without `float`). |
| Future embedded port maintainer | `zig build -Dfeature-…` (or a future `-Dpreset=stm32-bluepill` if/when we add a registry) | A working binary today via flags. If named ports become a real category in v0.5+, they get an ADR of their own and we add a preset mechanism at that point. |

The audiences who exist today (nano user, full user) get zero behavior change at the user-facing surface. The web-demo maintainer gets a working `wasm-tiny` build via a Makefile alias; no registered preset is needed. The tinkerer gets the flexibility of Path B without the "non-standard configuration" warning that Path C would have emitted (under the corrected framing there is no central list of "standard" configurations beyond `nano`, so there is nothing to be non-standard relative to). The future embedded port maintainer is no worse off: if their work justifies a preset registry, the registry is straightforward to add.

## 4. Shape

Three moving parts:

1. Each feature is an orthogonal `-Dfeature-<name>` build option declared in `build.zig`. Each option corresponds to a cluster of `MICROPY_*` defines that flip together.
2. `port/mpconfigport.h` decomposes from a single `#ifdef NANOPYTHON_CONFIG_FULL` arm into a flat set of `#ifdef NANOPYTHON_FEATURE_<X>` blocks. `build.zig` passes the matching `-D` flags to the C compiler; the header itself is never rewritten.
3. Feature dependencies are encoded as build-time assertions in `build.zig` (e.g. `complex` requires `float`), with error messages that name the constraint and the workaround.

The `-Dconfig=nano|full` interface is kept as a compatibility shim resolving to the equivalent feature set. Named combinations that see enough use to warrant an entry point live as Makefile aliases; if that alias list ever grew past a handful, a `presets` table in `build.zig` would be the escalation. There is no preset registry, no per-preset corpus directory, no override-warning machinery.

The `nano` config is the byte-exact regression detector. Every other flag combination either builds and runs or fails at build time on the dependency assertions. See the current `build.zig` and `port/mpconfigport.h` for the shipped form.

## 5. Corpus impact

The byte-exact corpus is now a regression detector (§1.1). Path B preserves it exactly as it stands today, with no per-preset duplication and no override-mode bookkeeping.

| User invocation | Corpus behavior |
|---|---|
| `zig build` (default, all features off) | Strict: byte-exact comparison against `corpus/basics/*.out`. CI gates this on every push. This is the regression detector. |
| `zig build -Dconfig=full` (or the equivalent feature-flag combination) | Soft target: `corpus/full/basics/` reports `N/552` against the upstream-MicroPython oracle. No gate change. |
| Any other flag combination (`-Dfeature-float=true`, etc.) | No corpus comparison. The build either succeeds or fails; correctness is the user's problem, the same as for any other build system. Comptime-style assertions in `build.zig` catch incoherent combinations at configure time. |

Practical consequences:

- **Existing corpus layout is unchanged.** `corpus/basics/*.out` stays where it is. There is no rename to `corpus/nano/`. There are no new per-preset corpus directories. `corpus/full/` keeps its soft-target semantics.
- **`make freeze` is unchanged.** It still freezes `corpus/basics/*.out` against the default (no-features) build, which is the only configuration whose output we promise to track byte-for-byte. The `port/mpconfigport.h` discipline still applies (regenerate corpus only when the default build's config changes on purpose).
- **Theme-F builds (`wasm-tiny`, etc.) get a smoke test, with no frozen corpus.** A new build target's correctness story is: (a) it compiles, (b) the demo's preloaded scripts run end-to-end, (c) shared code paths are exercised by the `nano` corpus on every push. A freshly frozen corpus directory lands *only* on evidence of need: when a non-`nano` configuration exercises code that `nano` skips and the project wants a regression detector for that specific path. The earlier draft assumed every new shipping target needed its own corpus by default; under the corrected framing that assumption was speculative work.
- **No "override mode" with a special warning exists.** Under Path B, anything beyond `nano` and (softly) `full` falls outside a "standard configuration" list. Anything else is just a flag combination. The build emits the same diagnostics for any combination. The corpus stays silent for non-`nano` builds.

### 5.1 What happens if we *do* later want a second frozen corpus

If, in v0.5+, we find ourselves wanting a second byte-exact regression detector (say, `wasm-tiny` has diverged enough from `nano` that the `nano` corpus has stopped catching `wasm-tiny`-specific regressions), the upgrade is small: add a `corpus/wasm-tiny/basics/` directory, freeze it, add a CI row that runs `make check` with the `wasm-tiny` Makefile alias. That work is identical under Path B and under Path C. Both paths have the same cost. The difference is that Path B defers that cost until the evidence appears, while Path C pays it speculatively in v0.4.

## 6. Sequencing

Theme F lands in three phases. Each phase is a defensible commit point: if Theme F gets paused after any phase, the project is still in a coherent state.

| Phase | Scope | Sessions | Deliverable |
|---|---|---|---|
| **F1** | Add the per-feature `b.option(...)` declarations in `build.zig` (the feature-set boundaries). Encode dependency assertions. Keep `-Dconfig=nano\|full` working as a compat shim. `mpconfigport.h` stays unchanged at this stage; features have no visible effect yet. | 1 | `build.zig` declares the feature options + dependency checks. `-Dfeature-*` flags accepted but no-op until F2. |
| **F2** | Decompose `port/mpconfigport.h`'s single `NANOPYTHON_CONFIG_FULL` arm into per-feature `#ifdef` blocks. `build.zig` emits `-DNANOPYTHON_FEATURE_<X>` per active feature. The default build and `-Dconfig=full` both stay byte-equivalent to today (both corpora unchanged). | 1-2 | `mpconfigport.h` is decomposed; the `NANOPYTHON_CONFIG_FULL` arm is gone. |
| **F3** | Add the `wasm-tiny` Makefile alias. Measure the resulting binary size. Document the feature surface in `docs/configuring.md` (the feature list + dependency graph + how to invoke the supported configurations). | 1 | `make wasm-tiny` produces a size-optimized WASM build; docs name the supported configurations. |

**Total**: 3-4 sessions. Phase F1 is mechanically small but conceptually important (it commits to the feature-set boundaries); Phase F2 is the critical refactor (every line of the new header needs to round-trip the existing two corpora).

The earlier draft had a four-phase plan ending in a CI matrix expansion + per-preset corpus freezing. Phase F4 of that plan is dropped here: under Path B, the only frozen corpus is `corpus/basics/` (already gated), and `corpus/full/` (already soft-tracked). There are no new corpus directories and no new CI rows. If we later decide we want a second frozen corpus (§5.1), it gets its own follow-on PR; it is not Theme F's responsibility.

**Where in the roadmap**: Theme F can start any time after ADR-001's Themes A-D have begun. F1 is independent and can be done in parallel; F2 is best done after Theme A (async/await) lands so that `asyncio` is a real toggle by then. F3 (the WASM size work) wants Theme E (web demo) to exist as a smoke target. Plausibly F1 lands in v0.4 and F2-F3 in early v0.5.

## 7. Risks

**Feature interactions.** Float requires certain arithmetic primitives. Complex requires float. Asyncio requires the generator machinery. mpz interacts with `MICROPY_LONGINT_IMPL`. If users pick incompatible combinations they get cryptic build errors or runtime crashes. *Mitigation*: encode the dependency graph as build-time assertions in `build.zig` (§4.3). The error message names the constraint and points at this ADR. The dependency graph itself is documented in `docs/configuring.md` (a new page added in F3).

**Build complexity.** In `build.zig` we add ~6 `b.option(...)` calls, a small block of dependency assertions and the `-Dconfig=full` compat shim. Reviewers see more code, but the total LOC growth is bounded (~50-80 LOC, all in `build.zig`). Path B keeps this materially smaller than the earlier Path C sketch, which added a preset registry, override-warning machinery, and per-preset corpus dispatch on top of the same feature-flag plumbing.

**Untested flag combinations break silently.** With per-feature flags, the cross product is large (2^6 = 64 initial combinations, more as features are added). Some will fail to compile; others will compile and then crash at runtime. We do not CI them and we do not promise they work. *Mitigation*: this is the same support contract any flag-driven build system has. The two combinations whose behavior we *do* promise (the default `nano` build and `-Dconfig=full`) get the same CI treatment they have today. Anything else is "if it compiles and runs your code, great; if not, file a bug and we will triage." Comptime-style assertions catch the categorical incoherencies (`complex` without `float`); the long tail of subtle runtime issues is accepted as user territory, the same as for `cmake` projects or `autoconf` projects.

**Pull to add more entry points.** Even without a registry, there is a pull to add more Makefile aliases: `make wasm-medium`, `make nano-io`, `make embedded-cortex-m4`. Each one is cheap individually but they accumulate. *Mitigation*: the threshold for a new alias is low (one Makefile line), but the threshold for a new *frozen corpus* is high: it needs a real reason that the existing `nano` regression detector is not enough. Aliases are documentation; corpora are commitments. Path C mixed the two. This ADR keeps them separate.

**The F2 migration moment is sensitive.** F2 converts a single `#ifdef NANOPYTHON_CONFIG_FULL` arm into ~10 per-feature `#ifdef` blocks. The risk is that the refactor introduces a behavioral change: a knob ends up flipped the wrong way under the default build or under `-Dconfig=full`, and the corresponding corpus drops. *Mitigation*: F2 lands with a strict regression check: `make check` under both the default (`nano`) build and `-Dconfig=full` must report identical numbers before and after the refactor. The PR is a no-op semantically, so a corpus drop indicates a bug in the decomposition. F2 omits `make freeze` on purpose: its job is to protect the existing corpora.

**Dependency graph encoding is up-front design work.** Deciding what depends on what (does `complex` require `float`, does `asyncio` require some specific generator extension, does `mpz` interact with `MICROPY_LONGINT_IMPL` in ways that matter) requires reading the existing `mpconfigport.h` carefully and the upstream MicroPython header documentation. This work is required by Path B, Path C, or any other path that admits per-feature granularity at all. *Mitigation*: time-box the dependency-graph design to one session during F1. If it takes longer, the feature-set boundaries are wrong and we go back to a coarser carve.

**If we later wish we had a registry.** It is possible that v0.5+ surfaces a real need for a presets-with-overrides mechanism (more named entry points than Makefile aliases comfortably scale to, support requests for "supported configurations," a embedded-port pattern that wants its own ADR). If so, the upgrade from Path B is mechanical: collect the existing aliases into a `presets` const, optionally add an override-warning step. The work is the same whether we do it now or later, so deferring it costs nothing and risks nothing. The "one-way door" framing in the earlier draft was wrong: what we have is a const table we can add when there is real demand for it.

## 8. Alternatives considered and rejected

A handful of variants of the three paths surfaced during discussion. Each is listed with the reason it was rejected:

- **Path A': preset library with "experimental" presets (untested).** Same as Path A but accept that some presets ship without a corpus. Rejected for the same reason Path A is rejected (too rigid for the WASM size axis), plus the additional issue that the "experimental" tag becomes a permanent home for half-finished work, leaving an undefined number of differently-trustworthy build outputs.

- **Path C: hybrid presets composed of feature sets, with `-D` overrides.** The earlier draft of this ADR recommended Path C; this revision walks that back (see §3). In short, Path C is a defensible answer to "what shape should a presets-with-overrides mechanism take?" but it pre-pays for machinery (the preset registry, per-preset corpora, override-warning surface, supported/buyer-beware distinction) we cannot yet justify. We may want it eventually; we do not want it now. The upgrade path from Path B to Path C is small if we change our mind.

- **Path B': flags with a "frozen combo" registry.** Same as Path B but maintain a `presets` const table in `build.zig` from day one, used purely as named entry points (no per-preset corpora, no override warnings). This is a half-step toward Path C. Rejected for now on simplicity grounds: Makefile aliases cover the same ground for our current list of three named configurations (default `nano`, `full`, `wasm-tiny`). Promote to Path B' if the alias list exceeds (say) five names or if a use case for in-Zig preset resolution emerges. This is a viable later evolution, and Path B leaves it open.

- **Path D: runtime feature detection.** Build one fat binary, expose `import sys; sys.builtins` style introspection at runtime, let the user query what's available. Rejected because the size axis is the primary driver: a fat binary defeats the whole point of `wasm-tiny`. Runtime introspection is orthogonal and can be added on top of any path later.

- **Path E: per-port forks (MicroPython-style).** Maintain one `mpconfigport.h` per "port" (web, desktop, embedded-cortex-m4, embedded-esp32). Rejected for now because we have one port. When we have more than one port (if we ever do), this becomes a live question, but it adds a layer of indirection that the current single-port codebase does not need.

## 9. Open questions

These are flagged for follow-on decisions and do not block this ADR's acceptance:

- **`wasm-tiny` feature set.** What flags does the Makefile alias actually pass? Probably it leaves out float, complex, mpz, asyncio and threading. Possibly: `feature-io=true` for stdio only. The exact set wants its own micro-discussion once we measure binary sizes. The first cut should be guided by "what does the web demo actually exercise?"; anything outside the demo's preloaded-script coverage is a candidate for removal. A measure-first discipline avoids the trap of guessing what's expensive (mpz is expensive; complex is cheap; threading is absent from the build today; asyncio is the big one once Theme A lands).
- **Feature-set granularity.** Is `asyncio` a single toggle, or three (async-await syntax, asyncio-stdlib, coroutines runtime)? Initial proposal: one toggle. Revisit after Theme A lands and we know what falls naturally out of the implementation.
- **Surfacing "what was this binary built with?"** Useful for bug triage. Should `petitpy --version` report the active feature set? Probably yes: small thing, can be added in F3. Especially valuable under Path B because there is no preset name to identify a build, so the flag-set summary is the only ground truth.
- **Per-port `mpconfigport.h` variants.** MicroPython has hundreds of per-board `mpconfigport.h` files. Does Path B foreclose that pattern for our future embedded port? No: a future "stm32-bluepill" port could either (a) be a Makefile target that passes the right `-Dfeature-*` flags, or (b) introduce a preset registry at the moment it becomes worth it. This ADR leaves embedded targeting uncommitted (see ADR-001 §3; embedded is out of scope for v0.4 and needs its own ADR) and keeps both doors open.
- **Promoting `wasm-tiny` (and friends) from Makefile alias to first-class preset.** The current plan is "Makefile alias today, preset registry only if and when we have a reason." The trigger for promotion would be: three or more named configurations whose feature set is non-trivial *and* whose users want a single CLI flag to invoke. Reassess at the v0.5 cut.
- **Documentation home.** A new page is needed (`docs/configuring.md`) that lists every feature, the dependency graph, and the recommended invocations (the default `nano` build, `-Dconfig=full`, `make wasm-tiny`). Owned by Theme F's F3 phase. Should link back here for the rationale.
- **Interaction with the `make freeze` discipline.** The current hard rules say "Regenerate only via `make freeze` and only if `port/mpconfigport.h` deliberately changed." After F2, `port/mpconfigport.h` is still hand-written (the `#ifdef` blocks live in the source), but the *set of `-D` flags* driving those blocks moves into `build.zig`. The rule wants a small update in the F2 PR: something like "regenerate corpus when the default-build feature set in `build.zig` changes, or when `port/mpconfigport.h` changes."

## 10. References

- `001-roadmap-v04.md`: v0.4 roadmap (this ADR's parent; Theme F is the work this ADR enables)
- `port/mpconfigport.h`: current single-arm config (the artifact this ADR decomposes)
- `build.zig`: current `-Dconfig=nano|full` plumbing (the entry point this ADR extends)

---

*This ADR is Proposed. Accept by editing the Status field once the maintainers agree.*
