# ADR 008. Golden program tracking: what runs on petitpy

- **Status**: In Progress. Tooling (`tools/golden_bootstrap.py`) and directory skeleton landed; populated buckets tracked in `golden-programs/`.
- **Decider**: project maintainers
- **Supersedes**: nothing
- **Consequences**: gives users + contributors a filesystem-level answer to "what programs run on petitpy"; turns "should we add `heapq`/`bisect`/`random`?" from a vibes question into a numbers question (each feature makes N specific programs run); coexists with `corpus/wasm-known-fails.txt` and `make check` (different disciplines, different questions); adds ~3 MB of `.py` files to the repo (acceptable).

## 1. Context

ADR-001 made WASM the primary distribution target. ADR-003 committed to MicroPython compatibility on `.mpy` bytecode, language semantics, and the extension protocol. ADR-004 set up benchmarking. ADR-005 mapped the optimization landscape; ADR-007 picked up the size branch of that map.

The cross-cutting question none of those address:

> **"As a web developer evaluating petitpy, what Python programs will actually run? And if my program doesn't, what feature is missing to make it run?"**

Today the project has three artifacts that touch this question without answering it:

1. **`corpus/nano/basics/*.out`**: 541 byte-exact goldens. Measures strangler discipline (does our strangled code match vendor MicroPython exactly?). The right gate for its purpose; the user's question requires a different gate.
2. **`corpus/wasm-known-fails.txt`**: wasm-specific regression gate, 31 known-failing tests today. Documents what fails; the inverse view (what works) needs a separate artifact.
3. **The 4 program collections under `sandbox/` (prescrypt-internal, prescrypt-tryalgo, prescrypt-micropython, p2w-internal)**: 829 real Python programs. No one can tell at a glance which of them run on petitpy.

This ADR builds the missing answer.

### 1.1 What "running" means

A program "works on petitpy" when its output matches what **vendor MicroPython** (the project's reference implementation, `sandbox/micropython/ports/unix/build-standard/micropython`) produces. The strangler's contract is "match MicroPython behavior"; that's the natural oracle.

CPython is recorded as a secondary check. When MicroPython and CPython disagree, the program lands in `disagreement/` for explicit human triage: a conversation surface, by design, that defers the bucket decision until the project commits to one side.

### 1.2 The choice of oracle: MicroPython over CPython

Two reasons. First, the strangler's contract is MicroPython-compatibility (ADR-003); using CPython as the primary oracle would conflate "works on petitpy" with "matches CPython," and the latter is a strictly bigger ask. Second, MicroPython is the realistic surface: a program that requires CPython-only features (full `dataclasses`, `numpy`, `asyncio`) falls under §1.4 below as out of scope; tracking it would noise the report.

### 1.3 What "in scope" means

In scope are programs that petitpy could reasonably aim to run: pure Python, stdlib stdlibs, simple algorithms, basic types, classes, decorators, common idioms.

Out of scope (filtered at bootstrap): programs requiring third-party libraries we have no path to (`numpy`, `scipy`, `pandas`, `flask`, `django`, `fastapi`, `jinja2`, `requests`, the full `dataclasses` feature set, `pytest`, `unittest`, `asyncio`). Adding these is a multi-month port each; if a use case appears we can revisit, but tracking them today produces noise.

### 1.4 What changed since ADR-003

ADR-003 placed the frozen-tiny boundary based on what each demo imports. This ADR's `needs-stdlib/` bucket measures the SAME thing from a different angle: what would a typical algorithm program need to run. The two intersect:

- ADR-003 frozen modules (`_thread`, `js`, `json`) ship with every demo.
- `golden-programs/needs-stdlib/` lists every program that would graduate to `works/` if we shipped one more module.

The intersection is the natural prioritisation signal for "what's the next module to add."

## 2. Decision

Create `golden-programs/`: a curated directory of real Python programs that we explicitly want petitpy to run, organised by **profile** (the minimal feature bundle that makes each program work). Run them against vendor MicroPython AND petitpy native AND petitpy wasm. Generate (eventually) `docs/COMPATIBILITY.md` from the result.

### 2.1 Layout

```
golden-programs/
  README.md           — what this directory is, how to add programs
  profiles.md         — feature bundles & their semantics
  works/              — runs correctly on current petitpy (native AND wasm)
  works-native-only/  — runs on native but not wasm (e.g. wasm-specific gaps)
  needs-stdlib/       — would run with pure-Python stdlib stubs (heapq, bisect, …)
  needs-grammar/      — would run with parser features (walrus, match)
  needs-async/        — would run with async/await
  needs-fs/           — would run with file-system access
  needs-mpz/          — would run with arbitrary-precision integers (already exists empty on main as a placeholder)
  disagreement/       — MicroPython and CPython disagree on the program's behavior
```

Each program is in **exactly one bucket**: the profile it minimally needs to work. A program that needs both `heapq` AND async lands in `needs-async/` (the strictly larger feature requirement). The principle is that bucket names answer "what profile do I need to ship?"

### 2.2 Annotation

Inline header comment in each `.py` file:

```python
# golden: source=tryalgo; needs=heapq,recursion-depth-tolerant
# golden: works-on=micropython,nanopython-native,nanopython-wasm
"""Dijkstra's shortest paths algorithm."""
```

Format: `# golden: KEY=VALUE; KEY=VALUE; …` on contiguous lines. Keys:

- `source`: where the program came from (`tryalgo`, `prescrypt-internal`, etc.)
- `needs`: features it depends on (auto-detected from imports + grep; can be manually adjusted)
- `works-on`: verified by running; auto-maintained by the bootstrap / run tools
- `micropython-cpython-divergence`: explicit note when MP and CPython differ

Annotation is **auto-bootstrapped** from imports and known feature patterns (`async def` → `needs=async`; `import heapq` → `needs=stdlib.heapq`; etc.), then committed. The tool detects drift and proposes updates.

### 2.3 Deduplication

The 4 source corpora have filename overlap (e.g. `sort_advanced.py` appears in both `prescrypt-internal` and `p2w-internal`). Programs are **deduplicated by SHA-256 content hash** at bootstrap; the copy that remains keeps the lexicographically-first source name in its annotation. On `slim-wasm` this reduced 825 raw files to 823 unique programs.

### 2.4 Relationship to existing infrastructure

| Artifact | Question | Decision |
|---|---|---|
| `corpus/nano/basics/*.out` + `make check` | Does the strangler match vendor byte-exactly? | **KEEP**: different discipline (regression detector) |
| `corpus/wasm-known-fails.txt` + `make wasm-check` | Does main's wasm pass the corpus subset that wasm32 is expected to pass? | **KEEP**: wasm-specific regression gate |
| `golden-programs/` (this ADR) | What programs do users actually run on petitpy? | **NEW**: strategic source-of-truth |

These three layers answer three different questions. The layers are complementary.

## 3. Implementation plan

### Phase 1. Skeleton + bootstrap

- Create `golden-programs/` with `README.md`, `profiles.md`, and the empty bucket dirs.
- Write `tools/golden_bootstrap.py` per the design.
- Run the bootstrap once; commit the resulting bucket assignments.

### Phase 2. Run + matrix

- Write `tools/golden_run.py`: re-runs every program against three oracles, updates `works-on=` annotations, detects drift (a program now in the wrong bucket).
- Wire `make golden` (rebootstrap) + `make compat` (rerun + report) to the pipeline.
- Generate `docs/COMPATIBILITY.md`: the user-facing matrix + "what feature would unlock most programs" ranking.

### Phase 3. Iteration

- As features land, programs migrate from `needs-X/` to `works/`. The tooling proposes; humans review.
- The "what unlocks most" report drives prioritisation conversations: "Adding `heapq` would unlock 12 programs. Is the algorithm/data-science use case in scope?"

## 4. Consequences

**Wins:**

- Users (and prospective users) get a single, browseable answer to "what runs on petitpy."
- Feature decisions get a quantitative signal: "`heapq` unlocks N programs across tryalgo + M internal; yes/no decision is now grounded."
- Contributors can pick a `needs-X/` bucket and see exactly what landing X does for users.
- "Do we really need this for web apps?" conversations are grounded in `golden-programs/` content.

**Costs:**

- ~3 MB of `.py` files committed. Acceptable.
- `make golden` runtime grows with corpus size; expect ~30s for ~800 programs.
- Annotation discipline needs maintenance: when a feature lands, programs migrate. Tooling helps; manual review remains part of the loop.
- Some programs sit in `disagreement/` for a while as the project collectively decides on MP-vs-CPython semantics. That state is preferable to silent bucketing.

**What this preserves:**

- The strangler discipline. `corpus/nano/basics/*.out` byte-exact gate remains the invariant.
- The WASM regression gate. `corpus/wasm-known-fails.txt` remains the invariant.
- ADR-003's compatibility commitment. `golden-programs/` measures from the user's perspective; the strangler's contract is unchanged.
- ADR-001's WASM-primary positioning. The directory just states that position more legibly.

## 5. Open questions

1. **`works-native-only/` retention.** When a program fails on wasm because of a wasm-specific limitation (longjmp, smallint width), should it sit in `works-native-only/` indefinitely, or migrate to a `needs-X/` bucket where X names the specific blocker? Default position: keep `works-native-only/` simple (one bucket for "everything that works native but not wasm"); add more granular split only if the bucket grows past ~50 programs.
2. **Disagreement resolution policy.** When MicroPython and CPython diverge on a program, the default is to follow MicroPython (per ADR-003's compatibility commitment). Cases where MP is wrong remain open; the `disagreement/` bucket surfaces them for explicit per-case decisions.
3. **Maintenance cadence.** Run `make golden` (rebootstrap) on every commit, weekly, or only when a feature lands? Default: on demand, plus automated drift-check in CI.

## 6. See also

- `golden-programs/README.md`: user-facing entry point
- `golden-programs/profiles.md`: feature bundle definitions
- `tools/golden_bootstrap.py`: the bootstrap tool
- ADR 001: WASM-primary positioning that this ADR's `works-on=nanopython-wasm` annotation tracks
- ADR 003: frozen-tiny stdlib boundary, intersected by `needs-stdlib/`
- ADR 007: wasm fat loss; `golden-programs/` shows which user programs benefit from each fat-loss technique
- The `corpus/wasm-known-fails.txt` discipline that informs the wasm gate; together they answer "what works" from two angles.
