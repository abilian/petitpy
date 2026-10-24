# Architecture Decision Records

_Each ADR records one architectural decision: its context, the alternatives, the choice and its consequences. [How ADRs are written](000-readme.md) explains the format and the statuses._

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
| [ADR 010](010-roadmap-v06.md) | v0.6 roadmap: closing the wall, broadening the surface | Superseded by ADR 021 |
| [ADR 011](011-everyday-stdlib.md) | Everyday stdlib: dataclasses, pytest, and the eight modules a CPython script reaches for daily | Implemented in v0.7 |
| [ADR 012](012-profiles-and-feature-matrix.md) | Build profiles and the feature matrix: full as default, profiles as named feature bundles | Implemented |
| [ADR 013](013-exception-unwind-vendor-c.md) | Restoring exception unwinding across vendor-C frames (the try/except-over-MPZ wall) | Implemented in v0.7.0 (native `full`) |
| [ADR 016](016-distribution.md) | Distribution: PyPI wheels and sdist, built by Zig from one machine | Accepted |
| [ADR 019](019-garbage-collector.md) | A garbage collector: vendor's heap, conservative roots, safe points on wasm | Implemented |
| [ADR 020](020-quickening.md) | Quickening and the interpreter's next speed step | Implemented |
| [ADR 021](021-roadmap-v09.md) | v0.9 roadmap: fewer surprises for a CPython user | Implemented in v0.9.0 |
| [ADR 022](022-embedding.md) | Embedding: a small C API over a static library | Accepted |

## Reading order

- **Roadmap**: ADR 009, ADR 010, then ADR 021.
- **A new feature**: ADR 002 (build flags), ADR 003 (module loading), ADR 008 (compatibility tracking).
- **The browser build**: ADR 001, ADR 006 (JS bridge), ADR 007 (size).
- **Performance**: ADR 004 (method), ADR 005, ADR 020.
- **Embedding**: ADR 022, with ADR 019 (the collector) and ADR 013 (exceptions raised in C).
