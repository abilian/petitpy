# ADR 012. Build profiles and the feature matrix: full as default, profiles as named feature bundles

- **Status**: Accepted. Phase 4 (default flip) implemented; `make build` / `make check` default to `full`; nano reachable via `CONFIG=nano`. Exact full-profile lineup beyond `nano` / `full` (D7) still deferred.
- **Decider**: project maintainers
- **Supersedes**: ADR 002 §3 (the "one frozen `nano` profile" framing). Keeps per-feature `-D` flags as the implementation primitive; replaces the single-profile assumption with a multi-profile mapping.
- **Branches from**: this is the strategic decision. ADR 011 (everyday stdlib) inherits from it the question of which profile each module targets.
- **Consequences**: shifts the default build target from `nano` to `full` (the CPython-familiar Python experience); commits to per-feature flags as the only durable gate (deprecates `build_options.is_full` as a feature predicate); commits to a profile manifest as the single source of truth; restructures the test pipeline so shipping-size discipline becomes a profile-specific CI gate, where it was the implicit default; introduces a stdlib-module dependency declaration so we can mechanically answer "what runs on which profile?"

## 1. Context

### 1.1 The reframing

The point of petitpy, restated: give users a familiar "Python experience" by default. If parts of that power have to be weakened to address embedded or web use cases, the feature-switch mechanism that lets us do that is itself a major feature of the project. Profile names today (`nano`, `full`) are placeholders; the eventual lineup (speculation: `full / mini / micro / nano`, or `full / web / embedded / nano`, or something else) is open.

The *direction*, though, is fixed. Default = full. Profiles weaken the default for specific use cases. Each profile is a named bundle of feature flags. The feature × use-case matrix is the artifact developers consult.

### 1.2 What we have today

`-Dconfig=nano` is the default. `-Dconfig=full` is the comparison arm. ADR 002 established per-feature `-D` flags but, in practice, `build_options.is_full` got used everywhere as a shortcut for declaring per-feature flags. The single-`is_full` shortcut conflates two distinct ideas:

1. *"Is this build the full preset?"*: a profile-name check (rarely needed)
2. *"Is feature X enabled in this build?"*: a feature predicate (needed everywhere)

Conflating them created the recurring class of bugs the v0.6 cycle had to fix.

### 1.3 The signal from the v0.6 cycle

Four user-visible features were silently nano-over-trimmed (the test goldens had been frozen against the broken-on-nano behavior since v0.3+):

- `MULTIPLE_INHERITANCE`
- Property descriptor dispatch in `mp_obj_instance_load_attr`
- Property dispatch in `mp_obj_instance_store_attr` (needed two passes)
- `DELATTR_SETATTR` dispatch

Each was found, fixed, and the golden was re-frozen. None was caught by `make check` because the gate was anchored to a broken-on-nano baseline. The pattern is the same throughout: nano was over-trimmed against vendor MP's nano. Vendor MP's nano targets 256 KB Flash microcontrollers, a constraint that doesn't apply to browser wasm, let alone the dev binary developers run on their laptop.

The pattern is a leading indicator. Reading it: the project's nano-default forces a shipping-target discipline at the cost of a developer-experience mismatch. That mismatch keeps creating bugs that ship.

### 1.4 What the reframing buys

- **Default workflow matches CPython expectations.** A developer typing `import dataclasses` or `object.__setattr__(...)` doesn't have to learn that some features are flag-gated off by default.
- **The "wrongly is_full-gated" bug class disappears.** With full as default, every feature is on unless a profile explicitly turns it off. The question used to be "did we accidentally turn this off everywhere?"; it becomes "do we *need* this off in profile X?"
- **Feature switches become a first-class architectural feature.** Each switch's existence is justified by a specific use case (web wasm size, embedded RAM, etc.). The matrix shows what each costs and saves.
- **The stdlib has a natural per-module home.** Each `nanopython-lib/*.py` declares its feature requirements; profiles declare what they have; the matrix tells us which modules run where. ADR 011 inherits this question; the matrix answers it.

## 2. Decision space

### 2.1 Default profile

Three candidates:

**A. Keep nano as default.** Status quo. Forces shipping-size discipline at the test gate. Creates the developer-experience mismatch documented in §1.3.

**B. Make full the default.** Aligns with CPython expectations. Moves shipping-size discipline from "the default" to "an explicit CI gate." Adds one step to the contributor workflow (knowing which profile to test against for which question).

**C. Introduce a "dev" profile as default**: a curated middle ground between nano and full. Avoids both ends. Splits the single-profile maintenance into two and creates the question of what specifically "dev" includes.

Decision: **B**. The CPython-expectation alignment is the headline; (C) buys nothing (B) doesn't, at the cost of one more profile to maintain.

### 2.2 Profile lineup

How many profiles should there be, and which?

Today: `nano`, `full`. The reframing implies at least three. Speculation: `full / mini / micro / nano` or `full / web / embedded / nano`. The naming distinction matters because:
- Size-axis names (`full / mini / micro / nano`) read as "different sizes of the same idea." Easier to reason about as a lattice.
- Use-case names (`full / web / embedded / nano`) make the matrix more legible: each profile maps to a specific deployment context.

This ADR does **not** commit to the final lineup. It commits to "more than two" and leaves the choice to a follow-up ADR after the §3 D4 audit work surfaces the natural breakpoints.

The rest of this document works on the assumption of `full + nano + web (TBD)`.

### 2.3 Source of truth for {profile → flag bundle}

Currently spread across:
- `build.zig`: the `ConfigPreset` enum and the per-flag `addOption` calls
- `port/mpconfigport.h`: the `#ifdef NANOPYTHON_CONFIG_FULL` blocks
- `src/objects/*.zig`: the `if build_options.is_full` and per-feature checks

For a multi-profile world, this needs a single canonical mapping. Options:

**A. Zig source file** (`build/profiles.zig`): typed, integrates with build.zig naturally.
**B. JSON or TOML manifest** (`build/profiles.json`): language-agnostic; can be read by Python tools too.
**C. Comments in build.zig** with per-profile preset functions: minimal new files; harder to tooling.

Decision: **A**. The Zig file is the canonical mapping. A Python tool reads it (via either parsing or a generated JSON dump) to produce `docs/feature-matrix.md`.

### 2.4 What `is_full` becomes

After the per-feature-flag split, the picture is:

- **Deprecated as a feature predicate.** Every site that uses `build_options.is_full` to make a feature decision either splits into a per-feature flag or is bug.
- **Optionally retained as a profile-name check.** Code that genuinely wants "am I building the full preset?" (e.g., docs strings that mention CPython compatibility) can use `build_options.profile == .full`. Rare.

## 3. Decision

### D1. Default profile is `full`

`zig build` (with no `-Dprofile`) builds the full preset. `make build` likewise. The `make smoke` + `make test` pipeline runs against full unless explicitly overridden via `PROFILE=nano` etc.

Explicit `make build-nano` (and other profile builds) still exists as an explicit invocation; the default no longer covers them. The wasm shipping pipeline (`make web`) uses the profile appropriate for shipping (today: `nano`; eventually: `web`).

### D2. Per-feature flags as the only durable gate

Each feature gets its own `build_options.<feature>` flag. Profiles are bundles of flag values. `build_options.is_full` is deprecated as a feature predicate; every existing site is audited and either:

- Split into a per-feature flag with the appropriate default-true setting (most cases)
- Replaced with `build_options.profile == .full` (rare profile-name checks)
- Removed if it was wrong (some cases; see §1.3)

ADR 002 §3 D1 retained.

### D3. Single source of truth at `build/profiles.zig`

A single Zig file holds the canonical {profile → flag bundle} mapping. Sketch:

```zig
// build/profiles.zig — single source of truth for profile feature bundles.
const std = @import("std");

pub const Profile = enum { full, nano /* + future profiles */ };

pub const FeatureSet = struct {
    multiple_inheritance: bool,
    delattr_setattr: bool,
    feature_re: bool,
    feature_json: bool,
    complex: bool,
    mpz: bool,
    // ... one field per gateable feature
};

pub fn featuresFor(profile: Profile) FeatureSet {
    return switch (profile) {
        .full => .{
            .multiple_inheritance = true,
            .delattr_setattr = true,
            .feature_re = true,
            .feature_json = true,
            .complex = true,
            .mpz = true,
            // ...
        },
        .nano => .{
            .multiple_inheritance = false,
            .delattr_setattr = false,
            .feature_re = false,
            // ...
        },
    };
}
```

`build.zig` reads from this module. `port/mpconfigport.h` is generated from it by a small Python tool (so we don't have to keep two source-of-truth files in sync by hand).

### D4. Sweep every `is_full` site

Concrete punch list. Each site gets one of three labels:

- **PER-FEATURE**: split into its own flag with appropriate per-profile defaults.
- **PROFILE-NAME**: legitimate profile-name check; keep as `build_options.profile == .full`.
- **WRONG**: was a bug; remove.

The expected ratio (based on the v0.6 evidence) is roughly 80% PER-FEATURE, 5% PROFILE-NAME, 15% WRONG.

This becomes a tracked work item, comparable in shape to the v0.6 corpus closures. Estimated 2-4 days for the audit + splits.

### D5. Stdlib modules declare their feature dependencies

Each `nanopython-lib/*.py` declares what it requires at the top:

```python
# nanopy:profile-requires DELATTR_SETATTR, MULTIPLE_INHERITANCE
"""dataclasses — @dataclass decorator (ADR 011)."""
```

The build pipeline reads these headers. For each profile that bundles a given module, all the flags listed in `profile-requires` must be true in that profile's `FeatureSet`. A new CI gate `make check-profiles` enforces this.

Two-way usefulness: the matrix doc can list each stdlib module's minimum profile, and `pytest_lite tests/stdlib/test_dataclasses.py` knows whether the current binary supports the module before running.

### D6. Byte-exact corpus contracts per profile

The 541/541 byte-exact invariant against vendor MP's nano config stays as the contract for the **nano profile**. Each other profile gets its own byte-exact-or-strict-superset contract against its vendor MP equivalent:

- `full` ← vendor MP unix-standard (with caveats for features petitpy adds that vendor doesn't)
- `web` ← TBD; presumably a curated subset between `full` and `nano`

`make check` runs against the default profile, full; `make check-PROFILE` runs against the named one. `make check-all` runs both (the new aggregate gate, for "I'm about to commit").

### D7. Profile lineup deferred

This ADR commits to "more than two" without picking the final set. The lineup decision becomes a follow-up ADR (or a revision of this one) once D4 + D5 surfaces the natural breakpoints. The working assumption is at least `full + nano`, possibly with `web` for the browser and `embedded` for actual microcontrollers if those become a target.

## 4. Sequencing

The work splits into seven items, ordered by dependency:

1. **Audit.** Walk every `if build_options.is_full` site under `src/`; classify as PER-FEATURE, PROFILE-NAME, or WRONG. No behavior change.
2. **Per-feature flag splits.** For each PER-FEATURE site, add a new `build_options.<feature>` flag and flip the gate. Land in small per-feature commits to keep corpus discipline tight.
3. **Profile manifest.** Create `build/profiles.zig` with the canonical `{profile → flag bundle}` mapping. `build.zig` reads from it; a small tool generates `port/mpconfigport_profile.h` from the manifest.
4. **Default flip.** `zig build` (no `-Dprofile`) defaults to `full`. `make check` runs against full; `make check-nano` becomes the nano-arm gate.
5. **Stdlib module dependencies.** Add `# nanopy:profile-requires` headers to each `nanopython-lib/*.py`; a check tool cross-verifies each module's requirements against each profile that bundles it.
6. **Doc generation.** A tool reads the manifest plus module headers and emits `docs/feature-matrix.md` (features × profiles and modules × profiles).
7. **Profile lineup ADR.** Once steps 4 and 5 surface the natural breakpoints, draft the follow-up ADR naming the final lineup. The working assumption (`full + nano + web`) is a starting point; the final lineup is an open choice.

## 5. Consequences

### Positive

- Default workflow matches CPython expectations. The most common user experience is "Python works the way you expect."
- The "wrongly is_full-gated" bug class disappears. The v0.6 fix pattern (find a gap → flip a gate → re-freeze the golden) becomes unneeded.
- Feature switches become explicit. Each `-Dfeature=...` flag has a documented use case and a documented profile impact.
- Stdlib modules ship coherently. ADR 011's per-module work has a concrete target: "smallest profile that supports it".
- The matrix is the artifact. New contributors understand "what's in" by reading one doc.

### Negative

- Shipping-size discipline moves from "the default build does it" to "an explicit CI gate." Contributors need to remember to run `make check-nano` (or wait for CI) when they touch shipping-relevant code. The mitigation: bake it into `make all` / `make check-all`.
- Profile-manifest plumbing is real work. Phase 3 + 5 + 6 together is probably 1-2 weeks of careful refactoring with the corpus discipline on every change.
- More moving parts at the build layer. Two profiles → N profiles is a real complexity increase; the matrix doc tames it.
- The byte-exact corpus story splits: one per profile. The discipline tool's effort multiplies by N profiles, though each profile's corpus is independent so they can be maintained in parallel.

### Open questions

- **Exact profile lineup** (D7, deferred).
- **How the lazy-fetch model from ADR 003 interacts with profiles**: different profiles might want different lazy-fetch behavior (e.g., `nano` might not lazy-fetch at all to keep cold-load deterministic, while `web` and `full` might be more permissive).
- **Whether the WASI shipping artifact wants its own profile or can use `nano` / `web`**: depends on which features the gallery actually needs and how aggressive the wasm-opt cuts get.
- **The `make smoke` story**: should it run against full (matching the default) or against the wasm-shipping profile? Probably the latter, but it's its own decision.

## 6. Out of scope

- Picking the final profile lineup (D7).
- The `web` profile specifically (gets its own ADR once design settles).
- Module-level lazy-fetch routing changes (separate concern from the profile question).
- Reconciling `MICROPY_FLOAT_FORMAT_IMPL` and other multi-valued (non-bool) compile-time settings across profiles: handled per-feature as they arise.

## 7. See also

- [ADR 002](002-feature-selection.md): Feature selection. This ADR succeeds the "frozen single nano profile" framing while keeping the per-feature `-D` flag mechanism intact.
- [ADR 003](003-library-and-module-loading.md): Library and module loading. The lazy-fetch model interacts with profiles (Phase 7 open question).
- [ADR 011](011-everyday-stdlib.md): Everyday stdlib. Now inherits per-module profile assignment as a question this ADR makes answerable.
