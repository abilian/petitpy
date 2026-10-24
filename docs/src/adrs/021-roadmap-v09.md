# ADR 021. v0.9 roadmap: fewer surprises for a CPython user

- **Status**: Implemented in v0.9.0 (2026-10-23). Every item of §2 landed; §8 records the outcome.
- **Decider**: project maintainers
- **Supersedes**: ADR 010 (v0.6 roadmap), which was never accepted; its open items are either done, restated here, or listed as out of scope in §5.
- **Branches from**: the 0.8 release decisions of 2026-10-19 (browser and CLI as co-primary audiences, Alpha status, a published differences page), and [ADR 016](016-distribution.md) for distribution.
- **Consequences**: commits v0.9 to closing the most-hit differences from CPython on the native build, starting with insertion-ordered dicts, and to letting early users' reports reorder that list; keeps nano byte-exact with MicroPython, so most of this work lands on `full` only; renames the project to petitpy throughout; publishes the npm package and a Homebrew tap; takes the MPZ-on-wasm decision with a measured size; and starts an embedding API, behind the CPython-facing work.

## 1. Context

petitpy 0.8.0 is on PyPI (2026-10-21) as an Alpha: four prebuilt wheels and an sdist, the `petitpy` and `ppy` commands, and a [differences page](../differences.md). The npm package is built and checked but not published. The release is announced to a few people, not publicly.

The last roadmap, ADR 010, planned v0.6 with the browser as the primary goal and native as "the development companion". Two cycles later that no longer describes the project. The 0.8 scope decision made browser and CLI co-primary; the CLI is what `pip install` delivers, and the hop3-rootd case study shows it running a real daemon in 4 MB. ADR 010 stayed Proposed throughout, and the gates and the weekly plans did the steering. A release with users needs a written plan they can read.

Three signals shape v0.9:

**First, the differences page is the user's list of surprises.** Some of its rows are cheap (`sys.platform`, `import os.nope`, `slice()`), some are deep (dict order, exception text, traceback line numbers). Dict order is the one most programs hit: it changes printed dicts, `json.dumps` output, `**kwargs` order and, until annotations fixed it, `@dataclass` fields. It was deferred from 0.8 on 2026-10-19 because it changes every dict.

**Second, running real code finds gaps the corpus does not.** Porting hop3-rootd's test suite found keyword arguments on built-in methods, `.value` on `str` enums, a real `os.environ`, and evaluating `list[str]` and `int | None` at runtime. The native `json` module (0.8) still keeps the Python path's differences: `ensure_ascii`, non-string keys, `str` subclasses (which crash), lenient numbers and error messages.

**Third, the browser build's largest known-fail group is bignums.** wasm32 nano uses 64-bit integers, so `2**100` raises `OverflowError`. ADR 010 deferred MPZ on wasm32 to a size-budget decision that was never taken.

## 2. Decision

v0.9 is a reach cycle aimed at CPython users, in this order.

### 2.1 Early-user feedback sets the order

Before feature work, the project gets a public repository (without the private design notes), an issue tracker linked from the docs and the FAQ, and an up-to-date docs site. Reports from the 0.8 announcement go into the tracker, and each confirmed difference either becomes a v0.9 item or a row on the differences page. Where this ADR's order and the reports disagree, the reports win; the ADR is amended to say so.

### 2.2 Insertion-ordered dicts on `full`

The headline item. Dicts, and the `**kwargs` and class namespaces built from them, iterate in insertion order on the `full` build, as in CPython 3.7+. `nano` keeps MicroPython's hash order, so the nano corpus stays byte-exact; the wasm build follows nano.

The shape (a compact index table plus an entries array, or ordered insertion into vendor's open-addressing map) is chosen by measurement: memory per dict, lookup speed on `benchmarks/programs/dictops.py`, and the full corpus. No frozen golden prints a multi-key dict, so few `.out` files should change; any that do are re-frozen in the same commit, per the corpus rules.

### 2.3 The gaps real programs hit, on `full`

In rough order of how often a script meets them:

1. Keyword arguments on built-in methods: `"a,b".split(sep=",")` raises `TypeError: argument num/types mismatch` (built-in functions such as `sorted(key=...)` already take them).
2. `os.environ`, which does not exist today: a mapping that reads and writes the process environment.
3. `.value` on `str` and `int` enum members, and `print(Enum.member)` printing `Class.member`.
4. Annotations evaluated at runtime when asked (`typing.get_type_hints`, `list[str]`, `int | None`), with the PEP 563 text kept as the default.
5. `json`: `ensure_ascii`, non-string keys converted as CPython does, `str` subclasses, and CPython's error messages for invalid documents.
6. The cheap differences-page rows: `sys.platform` as `linux`/`darwin`, `ModuleNotFoundError` for `import os.nope`, `slice()`, `__mro__`.

Each item lands with an integration case compared against CPython and removes or narrows its row on the differences page.

### 2.4 Browser: publish, then decide bignums

- Publish the npm package (`make npm-package`, `npm publish ./npm/dist`) once the PyPI feedback has settled, and deploy the playground and demos with the docs.
- Measure MPZ on wasm32: the size cost on the browser build and how many of the bignum known-fails it closes. Then decide: ship it, ship it as a separate larger build, or keep 64-bit integers and say so on the differences page. The decision is recorded as an amendment to this ADR.

### 2.5 One name: petitpy

The packages are called petitpy, while the repository, the build and the docs still say nanopython: the binaries `zig-out/bin/nanopython` and `nanopython-vm`, `web/nanopython.wasm`, `nanopython-lib/`, `NANOPYTHON_TARGET`, the docs' remarks about a "development name". v0.9 renames all the names a user or contributor sees to petitpy, in one cycle, so the split does not last. The public repository is created as `petitpy` from the start.

Internal identifiers that nobody outside the source sees (the `npy_` C symbols, `NPY_GC_STRESS`) are renamed only where the rename is mechanical and the gates stay green; they are not worth a risky sweep.

### 2.6 Homebrew

A tap (`brew install abilian/tap/petitpy`) that installs the same binary and stdlib as the wheels, for macOS users who do not use pip. ADR 016 §6 deferred it; v0.9 does it after the npm release, from the same release artifacts, and ADR 016 is amended.

### 2.7 Embedding, after the CPython-facing work

Running Python from a host program (a C or Zig API over a library build) is back in scope, but behind §2.2 to §2.4. v0.9 writes its ADR first: the API surface, how the GC finds the host's roots (ADR 019 assumes it owns the stack), and which build profile it uses. Code follows if the cycle has room.

### 2.8 What stays fixed

- nano byte-exact against MicroPython at `MICROPY_REV`, on the whole corpus.
- The strict bidirectional gates, and CI passing on a fresh checkout.
- The full arm's corpus baseline only shrinks.
- Size is still watched on wasm: any v0.9 change that grows the browser build by more than 2% states the cost in its commit.

## 3. Alternatives considered

**A browser-first cycle** (MPZ on wasm, `asyncio` over the JS event loop, a richer `js` bridge). It serves the primary audience of ADR 010, but 0.8's users arrive through PyPI first, and the npm package is not yet published. It stays the likely theme of the cycle after, informed by the MPZ measurement in §2.4.

**CPython-shaped exception text and tracebacks with line numbers.** High on the differences page, but exception text touches the many full-arm goldens that print an exception, all frozen against vendor MicroPython's wording, and line numbers need source-line emission, which the build turns off (`MICROPY_ENABLE_SOURCE_LINE=0`) and which costs bytecode size. Worth its own ADR; not in v0.9 unless the reports put it first.

**Insertion-ordered dicts on every build.** Breaks nano's byte-exact invariant against MicroPython, the project's oldest correctness gate. Rejected.

**A performance cycle.** ADR 020 closed with no optimisation front open, and petitpy already runs the benchmark suite faster than MicroPython. Nothing user-facing asks for more speed yet.

## 4. Sequencing

1. **Public release hygiene**: public repository, tracker, docs deploy, `CHANGES.md` dated, the 0.8.0 tag. Small, and it unblocks the feedback loop.
2. **Dict order** (§2.2), measured and landed.
3. **The §2.3 list**, reordered by reports as they arrive.
4. **The rename** (§2.5), early, before more code and docs accumulate the old name; in parallel with 2.
5. **npm publish and the MPZ measurement** (§2.4), then the **Homebrew tap** (§2.6), in parallel with 3.
6. **The embedding ADR** (§2.7), once 2 and most of 3 have landed.
7. **Release 0.9.0** when §2.2 and §2.5 have landed and the §2.3 items either landed or moved to the differences page with a reason.

## 5. Out of scope for v0.9

- `asyncio`, real threads (`_thread` stays a stub).
- STR_UNICODE case mapping (`str.upper()` beyond ASCII) and `unicodedata`.
- Complex numbers.
- Implicit exception chaining (`__context__`).
- ADR 013's exception unwinding on wasm.
- CPython C-API extension loading.

## 6. Consequences

**Wins:** the commonest CPython surprise goes away on the build `pip` installs; scripts that use enums, environment variables and type hints at runtime run unchanged; the project has one name; the browser gets its package published and a measured answer on bignums; macOS users get `brew install`; early users see their reports shape the release.

**Costs:** `full` and `nano` diverge further in behaviour (dict order first), so the differences page has to say which build each row describes, and bugs reported on one build need checking on the other. The rename touches most files once and breaks old local paths and environment variables. The browser's own reach work waits a cycle, and embedding may reach only its ADR.

**Preserved:** the strangler invariant, the gate discipline, and the size watch on wasm.

## 7. Amendment (2026-10-23): MPZ ships in the browser build

Measured per §2.4. The bignum group turned out to be nearly all of the wasm known-fails, not only the `*_intbig` tests: it includes `int_big_*` and other integer tests. Their nano goldens record native nano's OverflowError, so the wasm gate now judges these tests against the full arm's goldens (`corpus/wasm-mpz-goldens.txt`), since wasm has full's integers. With MPZ, all but three of them pass, and `web/petitpy.wasm` grows by 2.6% (2.2% gzipped).

**Decision: ship MPZ in the browser build**, rather than a separate larger build or keeping 64-bit integers. The cost is above §2.8's 2% line and is stated here and in the commit. The three tests left store values beyond 2**31 in an `array`, `memoryview` or `struct` (wasm32's 32-bit machine word).

MPZ made a known wasm limitation much more visible: errors raised in vendor C, such as `big // 0`, `int(None)` or `int([])`, ended the program instead of reaching `except`. The same change gives the wasm build ADR 013's trampoline through wasm exception handling ([ADR 013 §7](013-exception-unwind-vendor-c.md)), so these raise as on native.

## 8. Outcome (2026-10-23)

v0.9.0 shipped every item of §2:

- §2.1: the public repository is `github.com/abilian/petitpy`, and the FAQ points reports to its issue tracker.
- §2.2: dicts keep insertion order on `full`, in a compact layout, at unchanged speed on the benchmarks.
- §2.3: all six items landed, each with its integration cases, and the differences page lost or narrowed their rows. Running real code found more on the way: `int`, `float` and `str` subclasses as operands, `dict()` of any mapping, C3 method order, and a `subprocess.run` that hung on large output.
- §2.4: MPZ ships in the browser build (§7). The npm package is built and checked; publishing it and deploying the playground are the maintainer's steps of the release.
- §2.5: the repository, the build and the docs say petitpy.
- §2.6: a Homebrew formula built from the PyPI wheels, in the `abilian/homebrew-tap` repository. [ADR 016](016-distribution.md) §7 records it.
- §2.7: embedding went further than the ADR. [ADR 022](022-embedding.md) was written and accepted, and its API shipped as an experimental static library and wasm module, with several interpreters per process.

## 9. See also

- [ADR 010](010-roadmap-v06.md): the v0.6 roadmap this replaces.
- [ADR 016](016-distribution.md): distribution, wheels and npm.
- [ADR 019](019-garbage-collector.md): the collector an embedding API has to work with.
- [ADR 020](020-quickening.md): the closed speed work.
- [Differences from CPython](../differences.md): the list v0.9 works down.
- [Benchmarks](../benchmarks.md) and the [daemon case study](../case-study-daemon.md).
