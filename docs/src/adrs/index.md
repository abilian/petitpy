# Architecture Decision Records

_Each ADR here records one architectural decision for contributors: the context that prompted it, the alternatives considered, the choice made, and the consequences. Reading them chronologically is the canonical way to understand "why is X this way?"._

| # | Title | Status |
|---|---|---|
| [ADR 001](001-roadmap-v04.md) | v0.4 roadmap: WASM-primary positioning + feature completeness | Closed |
| [ADR 002](002-feature-selection.md) | Feature selection: per-feature `-D` flags with one frozen `nano` profile | Accepted |
| [ADR 003](003-library-and-module-loading.md) | Library and module loading: micropython-lib direct + frozen-tiny + lazy-fetch | Accepted |
| [ADR 004](004-benchmarking.md) | Benchmarking methodology | Accepted |
| [ADR 005](005-future-optimization-proto.md) | Future optimization: landscape map (PROTO) | Proto |
| [ADR 006](006-js-interop.md) | JS interop: direct DOM bridge via sync host calls | Accepted |
| [ADR 007](007-wasm-fat-loss.md) | WASM fat loss: the size-reduction roadmap | In Progress |
| [ADR 008](008-golden-programs.md) | Golden program tracking: what runs on petitpy | In Progress |
| [ADR 009](009-roadmap-v05.md) | v0.5 roadmap: usable WASM + selective Python parity + size-then-perf | Implemented |
| [ADR 010](010-roadmap-v06.md) | v0.6 roadmap: closing the wall, broadening the surface | Proposed |
| [ADR 011](011-everyday-stdlib.md) | Everyday stdlib: dataclasses, pytest, and the eight modules a CPython script reaches for daily | Accepted (implemented 2026-06-12) |
| [ADR 012](012-profiles-and-feature-matrix.md) | Build profiles and the feature matrix: full as default, profiles as named feature bundles | Implemented 2026-06-13 |
| [ADR 013](013-exception-unwind-vendor-c.md) | Restoring exception unwinding across vendor-C frames (the try/except-over-MPZ wall) | Implemented in v0.7.0 (native `full`) |
| [ADR 016](016-distribution.md) | Distribution: PyPI wheels and sdist, built by Zig from one machine | Accepted 2026-10-19 |
| [ADR 019](019-garbage-collector.md) | A garbage collector: vendor's heap, conservative roots, safe points on wasm | Implemented 2026-10-11 |
| [ADR 020](020-quickening.md) | Quickening and the interpreter's next speed step | Implemented 2026-10-12 (B declined) |

## Reading order

- **New contributor orientation**: ADR 009 (v0.5 roadmap) → ADR 010 (current roadmap).
- **Designing a new feature**: ADR 002 (build flags) + ADR 003 (module loading) + ADR 008 (compatibility tracking).
- **Working on the wasm story**: ADR 001 (positioning) → ADR 006 (JS bridge) → ADR 007 (size reduction).
- **Benchmarking or perf work**: ADR 004 (methodology) → ADR 005 (landscape PROTO).

## Conventions

Each ADR has the same skeleton:

- **Status**: Proposed / Accepted / Implemented / Closed / Proto / In Progress
- **Decider**: usually "project maintainers"
- **Supersedes**: what older decision this replaces (if any)
- **Branches from**: what other ADR this builds on
- **Consequences**: one-sentence summary of what this commits the project to
- **Numbered sections**: Context, Decision, Implementation plan, Consequences, See also

The numbered prefix (`NNN-`) reflects creation order; the Status line gives the status. ADRs aren't superseded silently: a newer ADR that replaces an older one updates the older one's Status to "Superseded by …".
