# ADR 007. WASM fat loss: post-link size reduction beyond Theme F

- **Status**: In Progress. Phase 1 partial: `wasm-opt -Oz` post-link pass wired into `make web`. Shipping artifact at 304 KB (from 354 KB baseline). Remaining Phase 1 items (2-4) and Phases 2-3 open.
- **Decider**: project maintainers
- **Supersedes**: nothing
- **Branches from**: [ADR 005 §3](005-future-optimization-proto.md) (WASM-specific size row). ADR 005's hypothetical "wasm-tiny-2 ADR" was preempted by [ADR 006](006-js-interop.md); this ADR is that deferred decision.
- **Consequences**: commits the project to the ADR 001 20% size goal via post-link tooling, in phases; adds one external tool (binaryen) with graceful degradation; commits zero language-compatibility risk because every technique is post-link transformation or build-time flag.

## 1. Context

[ADR 001](001-roadmap-v04.md) made WASM the primary distribution target. [ADR 002](002-feature-selection.md)'s per-feature `-D` flags (Theme F) closed about half the size delta ADR 001 called for: 286 KB → 262 KB, an 8.95% reduction against a 20% goal. The remaining headroom needs different techniques: post-link transformation (binaryen `wasm-opt`), aggressive linker flags, and per-subsystem carveouts.

[ADR 005 §3](005-future-optimization-proto.md) catalogued "WASM-specific size" as a first-class optimization row, scored 10-30% reduction at high confidence, and named the techniques. Its §6.1 sketched what a follow-on ADR would look like, with a numerical target of ≤228 KB. That ADR was deferred a cycle when ADR 006 (JS interop) preempted the slot. This ADR is the deferred decision, with the same 228 KB target adopted here.

### 1.1 Prior infrastructure

Two artifacts landed before this ADR was written and inform the decision:

- **`scripts/wasm_composition.py`**: parses a `.wasm` binary and reports section sizes, per-function distribution, code-by-subsystem classification, data and imports. Reusable for any size-tracking work.
- **[`docs/internals/wasm-composition.md`](../internals/wasm-composition.md)**: snapshot + interpretation. Its "Opportunities for fat loss" section enumerates 11 techniques by cost tier (Easy 1-4, Medium 5-8, Hard 9-11), each with an estimated saving and trade-off note. This ADR references those items by number.

The composition doc also documents what *won't* help (ReleaseFast, newer Zig versions, hand-coded wasm, in-transit compression), heading off recurring "have you tried..." suggestions.

## 2. Decision

Close ADR 001's 20% size goal via post-link tooling, in two committed phases plus one open question.

**Phase 1: Easy techniques (composition doc items 1-4). Target: ≤228 KB raw.**

Combined estimate 10-25% reduction, spanning conservative and optimistic ends. The ADR 001 target of 228 KB sits in the middle. Commit to landing item 1 (`wasm-opt -Oz`, prototyped at −14.3%) plus enough of items 2-4 to clear the target.

**Phase 2: Medium techniques (items 5-8), with a stretch target of ≤200 KB raw.**

Sub-component carveout (item 5) is the highest-payoff single technique; splitting `compile.wasm` and `vm.wasm` lets VM-only deployments ship at ~167-200 KB. [ADR 003](003-library-and-module-loading.md)'s frozen-tiny boundary intersects this work: every frozen-module audit is also a size audit.

**Phase 3: Hard techniques (items 9-11). Open question.**

Not part of this ADR's commitment. Whether they justify the effort depends on Phase 1+2 outcomes and whether the demo-loading story is still size-bound.

### 2.1 Why not commit to everything at once

Items 5-8 are architectural: the carveout in particular requires deciding the runtime split, which interacts with ADR 003's library-loading decisions. Locking a target now invites bad architecture. Items 9-11 are "would help but with significant cost": each individually exceeds all of Phase 1 combined. Phase 1 is independently shippable: even if Phase 2 and 3 never happen, `make wasm-opt` is permanent infrastructure every release benefits from.

### 2.2 Why `wasm-opt -Oz` is the bedrock

It's post-link. Operates on the linked binary. Requires no source changes. Composes with everything else: Phase 2 and Phase 3 changes will themselves go through `wasm-opt`. The measured 14.3% reduction is on top of whatever source-level work produces. The earlier this lands, the earlier every subsequent change benefits.

## 3. Phase 1 work items

Six concrete tasks. Each independently revertible; each produces a measurable size delta.

| # | Item | Status | Estimated saving |
|---|---|---|---|
| P1 | `make wasm-opt` target (binaryen post-link) | Landed | −14.3% raw / −5% gzipped |
| P2 | Strip Export section (audit `pub export fn`) | Not started | ~10 KB Export + downstream DCE |
| P3 | Cull unused WASI imports | Not started | ~1 KB Import + a few hundred bytes Code |
| P4 | `-Dterse-errors` build flag (opt-in, verbose default) | Not started | 5-8 KB Data |
| P5 | Verify the 228 KB target after P1-P4 | Blocked on P2-P4 | n/a |
| P6 | Wire `wasm-opt` into `make web` (release artifact) | Landed | −14% download for every user |

### 3.1 Acceptance criteria

- Moves to **Accepted** when P1 has landed on `main`, at least one of P2-P4 has landed, and size is measurably below the 286 KB baseline by at least the P1 delta.
- Moves to **Closed (Phase 1 done)** when the wasm binary is ≤228 KB raw and the release artifact is post-`wasm-opt`.

## 4. Consequences

**When Phase 1 lands:**
- Closes ADR 001's open 20% size goal.
- Demo cold-start improves for every user.
- `wasm-opt` integration lets future size work compound with the post-link pass.
- Sets up the VM-only carveout as the next natural step if size is still binding.

**Risks:**
- binaryen is a third-party tool. Mitigation: `make wasm-opt` is opt-in; the un-opt binary still works.
- Terse errors would regress DX if the default flipped. Mitigation: the default stays verbose; only release pipelines opt in.
- Export strip + Import cull risk removing something the runtime needs on a less-exercised path. Mitigation: gated by `make check` (byte-exact corpus) and `make compat` (real-program tracker).

**What this ADR preserves:**
- The strangler discipline (byte-exact corpus remains the invariant).
- The benchmark contract (ADR 004): size work leaves speed numbers untouched.
- The compatibility commitment (ADR 003): `.mpy` format, language semantics, and extension protocols untouched.

## 5. Open questions

1. **Phase 2 trigger.** Commit to Phase 2 before or after Phase 1 measurement closes? Pre-committing risks architectural mistakes; post-committing risks the next session's priority displacing it. Default: post-commit. Revisit if Phase 1 lands strictly below 228 KB with demand for further reduction.
2. **The `nanopython-vm.wasm` carveout boundary.** ADR 003 placed the frozen-tiny boundary based on demo imports. The carveout (item 5) wants a different boundary: what does the VM need at runtime, never at compile time. The two boundaries diverge. Reconciliation deferred to a Phase 2 ADR.
3. **Size-regression gate in CI.** `make check` catches functional regressions; `make compat` catches user-visible ones. Neither catches size regressions. A `--regress` mode on the composition tool, comparing against a tracked baseline (mirroring `corpus/wasm-known-fails.txt`), would close the gap. Deferred to Phase 1 P5.

## 6. See also

- [`docs/internals/wasm-composition.md`](../internals/wasm-composition.md): technical plan + measurements snapshot.
- `scripts/wasm_composition.py`: the analysis tool. Reproducible measurements.
- [ADR 001](001-roadmap-v04.md): the 20% size goal this ADR is the path to closing.
- [ADR 002](002-feature-selection.md): Theme F per-feature flags, the 8.95% that landed.
- [ADR 003](003-library-and-module-loading.md): the frozen-tiny boundary that intersects Phase 2 item 5.
- [ADR 005 §3, §6.1](005-future-optimization-proto.md): the proto this ADR descends from.
