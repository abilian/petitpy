# ADR 011. Everyday stdlib: dataclasses, pytest, and the eight modules a CPython script reaches for daily

- **Status**: Accepted. Implemented in v0.7 (8 modules shipped with a pytest_lite test surface reachable via `make test-stdlib` on both arms).
- **Decider**: project maintainers
- **Supersedes**: nothing
- **Branches from**: ADR 003 (frozen-tiny stdlib + lazy-fetch model; this ADR fills in *which* modules ship in the frozen tier); ADR 010 §A3a (stdlib expansion slices; this ADR is the v0.7+ continuation of that lane); **[ADR 012](012-profiles-and-feature-matrix.md)** (profiles + feature matrix; once landed, each stdlib module here declares its `# nanopy:profile-requires` header per ADR 012 D5, and the "which profile bundles which module" question becomes mechanical)
- **Consequences**: commits the project to shipping a Python-stdlib subset shaped by *typical CPython script use*, with upstream micropython-lib not ported verbatim; commits to writing the modules in pure Python (no C/Zig), each as its own file under `nanopython-lib/`; commits to a "bootstrap-then-test" methodology where pytest-lite is the second module written and is used to test the rest; commits to ~15-25 KB total frozen-tiny growth over the v0.6 baseline.

## 1. Context

### 1.1 What we have today

The modules below ship in `nanopython-lib/`, frozen-tiny under wasm and on the filesystem under native (per ADR 003 D4):

- `collections.py`: CPython-shaped `deque(iterable)` plus the standard `namedtuple` / `OrderedDict` / `defaultdict` / `Counter` from micropython-lib.
- `itertools.py`: ADR 010 §A3a slice 2. `chain`, `cycle`, `count`, `repeat`, `starmap`, `tee`, etc.
- `string.py`: ADR 010 §A3a slice 2. `ascii_letters`, `digits`, `whitespace`, `Formatter`.
- `re`: built-in C carveout (vendor `extmod/modre.c` + `lib/re1.5/`). Both arms.
- `json`, `__future__`, `_thread`, `types`, `heapq`, `bisect`: frozen-tiny via micropython-lib.

The following are missing for a *daily CPython* feel:

- **No dataclasses.** Every script that uses `@dataclass class Point: x: int; y: int` falls back to a hand-written `__init__` + `__repr__` + `__eq__`.
- **No test runner.** Programs ship tests as `if __name__ == "__main__":` blocks with assertions. There is no `pytest tests/` equivalent and no way to discover `test_*` functions across a tree.
- **No `logging`**. `print(level, msg)` everywhere; no level filtering, no format strings, no namespacing.
- **No `argparse`**. CLI scripts hand-roll `sys.argv` parsing.
- **No `enum`**. `class Color: RED = 1; GREEN = 2` is the workaround.
- **`functools` is missing key everyday helpers**: `partial`, `wraps`, `lru_cache`.
- **No `contextlib`**. `@contextmanager` over a generator is unavailable; `with` blocks need full class implementations.

The v0.6.1 `DELATTR_SETATTR` flip enables the descriptor + `__setattr__` machinery several of these modules need (`dataclasses` synthesizes `__init__` which assigns to instance attributes; `enum` uses a metaclass-ish pattern; `pytest` decorators want `__setattr__` to attach metadata to functions). The runtime work is done; the library work isn't.

### 1.2 What "everyday" means

This ADR is anchored on the workflow of a Python developer who reaches for the language daily: for scripts, CLIs, small services, data munging, test suites. The shape of their stdlib usage is well-studied (see CPython's import telemetry, PyPI's `import` graph). The eight modules below cover most of what such a developer types into a fresh `main.py`.

In contrast, ADR 003 framed the stdlib question around "the modules micropython-lib already implements." That's a perfectly valid framing for embedded compatibility. But for the petitpy demos site, for kids working through tutorials, for a "write a Python script that solves my problem" use case, the modules a CPython developer reaches for daily are the right surface to optimize.

### 1.3 Why this isn't subsumed by micropython-lib

Most of the modules below exist in micropython-lib in some form. We write petitpy-shaped versions anyway, for these reasons:

- **Size**. Upstream `argparse` (in micropython-lib) is ~1700 lines and pulls a chain of dependencies; a petitpy-shaped version covering 80% of script-CLI use can be ~120 lines. The frozen-tiny tier is opinionated; everything in it pays a cold-load cost. Subset before vendor.
- **Test discoverability**. There is no upstream `pytest`-shaped runner under micropython-lib. The closest is `unittest`, which is heavier and lacks the function-discovery + bare-`assert` workflow we want.
- **`@dataclass`**. CPython's `dataclasses.py` is ~1500 lines and depends on `inspect`, `copy`, `types`. A petitpy-shaped version covering field synthesis (with defaults; without slots, frozen or kw_only) is ~150 lines.
- **Bootstrap test path**. The runner that tests the stdlib modules needs to itself be one of the modules. Writing pytest-lite second (after `enum`) and testing the rest with it is cleaner than depending on `unittest`.

### 1.4 What this ADR does not commit to

This ADR addresses the *stdlib library tier*. The *language* stays out of scope. These are out of scope for v0.7:

- Type hints at runtime beyond what already works (annotation reading via `__annotations__`).
- `typing` module: `NamedTuple`, `Protocol`, `Any`, `Generic` runtime semantics.
- `pathlib`: until the WASI filesystem story is more developed.
- `subprocess`: no OS process model in wasm.
- `datetime`: needs calendar + locale APIs whose surface is larger than this ADR can scope.
- `asyncio`: Path B deferral from ADR 010 §A4 still stands.
- `pickle`, `shelve`, `xml`, `http`, `socket`, `ssl`: large surface, low signal for the use cases above.

## 2. Decision space

### 2.1 What should ship in the frozen-tiny tier vs lazy-fetch

ADR 003 D4 introduces both. Frozen-tiny is bundled into the wasm shipping artifact (pays the cold-load tax); lazy-fetch is fetched on first `import` (it pays a runtime tax in place of the cold-load tax).

The criterion is that a module belongs in frozen-tiny if (a) it's small, (b) it's reached for often enough that the lazy-fetch latency would surprise users, and (c) other frozen modules depend on it.

For the candidates here:

- **dataclasses**: small (~150 lines after subsetting), reached for often (decorator on every script), and used by other modules below (logging's Record could be a dataclass). **Frozen-tiny.**
- **pytest-lite**: ~250 lines, but only reached for during testing; never at runtime by a shipping script. **Lazy-fetch.** Lives at `nanopython-lib/pytest.py`; `import pytest` triggers fetch the first time.
- **logging**: small (~80 lines), reached for in every script that wants to emit anything beyond `print`. **Frozen-tiny.**
- **argparse-lite**: ~120 lines, reached for in every CLI script. CLI scripts care about cold-load less because they're one-shot. **Frozen-tiny** *but* slow to second-fetch: argparse is fundamental enough to warrant being in the always-available tier.
- **enum**: tiny (~50 lines), reached for everywhere as a base concept. **Frozen-tiny.**
- **functools**: subset (partial, wraps, lru_cache; ~80 lines), reached for in everyday composition. **Frozen-tiny.**
- **contextlib**: tiny (~40 lines), reached for in `with` blocks. **Frozen-tiny.**
- **abc**: tiny (~30 lines), reached for in any class hierarchy with abstract methods. **Frozen-tiny.**

### 2.2 Implementation tier: pure Python vs C/Zig

All modules here are *pure Python*, without Zig or vendor C extensions. The reasoning:

1. Each is small. The frozen-tiny size budget for the eight is ~15-25 KB *unoptimized*. A `mpy-cross` pass shrinks each by ~40% (ADR 003 references this). Pure Python ships well.
2. Pure Python is easier to audit and update than a Zig port. None of these modules sit on the hot path of an interpreter loop; performance isn't a concern.
3. The C extensions micropython-lib provides for some of these (`micropython-uctypes` etc.) bring transitive dependencies we don't want in the frozen tier.

### 2.3 Bootstrap-then-test methodology

The natural order for *writing* these modules has a dependency graph:

```
enum  ──┐
        ├──→  pytest-lite ──→  test everything else
contextlib  ─┘
                 ↑
functools ───────┘
dataclasses ─────┘
logging          (independent)
argparse         (independent)
abc              (independent)
```

We write `enum` + `contextlib` + `functools` first (no runtime features beyond what v0.6.1 already shipped). Then `pytest-lite` using those. Then we write `dataclasses` and the rest, each with a pytest-lite test suite that ships in `tests/stdlib/`.

This avoids the "test the test runner with the test runner" bootstrap problem: pytest-lite has a tiny self-test that runs first (`tests/stdlib/test_pytest_lite.py`) and checks its own discovery before the rest of the suite trusts it.

## 3. Decision

### D1. Ship eight modules in two phases

**Phase 1 (the headline pair the user asked for):**
- `dataclasses` (frozen-tiny)
- `pytest` aliased to `pytest_lite` (lazy-fetch)

**Phase 2 (the everyday set):**
- `logging` (frozen-tiny)
- `argparse` (frozen-tiny)
- `enum` (frozen-tiny)
- `functools` (frozen-tiny; subset: partial, wraps, lru_cache, reduce)
- `contextlib` (frozen-tiny; subset: contextmanager, closing, suppress)
- `abc` (frozen-tiny; ABCMeta, abstractmethod)

Phase 1 lands first because the user asked. Phase 2 lands as a unit once Phase 1 has been used in at least one demo (target: a CLI script in `web/demos/cli-example/` that uses dataclasses + argparse + logging + pytest).

### D2. Pure Python, one file per module

Every module is a single `.py` file under `nanopython-lib/`. No subpackages. No C extensions. The modules can `import` each other; the import graph stays acyclic.

This matches the pattern `nanopython-lib/collections.py` and `nanopython-lib/itertools.py` already follow.

### D3. Tests live at `tests/stdlib/`

Each module gets a `tests/stdlib/test_<name>.py` file. The runner is the module under test only for pytest itself; for the rest, pytest-lite runs the test file.

`make test-stdlib` runs the whole directory.

### D4. Subset over completeness

Every module is explicitly a *subset* of its CPython counterpart. The subsetting rules:

- Cover the **80% case**: what a "fresh `main.py`" needs.
- **No** rarely-used edge features (`@dataclass(frozen=True)`, `pytest.mark.parametrize`, argparse subparsers, lru_cache with `typed=True`).
- **No** features that depend on missing nano runtime support (metaclass-based ABC if metaclasses aren't fully supported; `dataclass(slots=True)` since `__slots__` is silently ignored on micropython).
- Each module's docstring explicitly lists what's NOT supported so callers know what to expect.

### D5. `import pytest` works whether installed or not

For the lazy-fetch case: the frozen-tiny tier ships a tiny stub `pytest.py` that re-exports from `pytest_lite` once the latter is fetched. The stub is ~10 lines and means `import pytest` works the moment the package fetches.

This is asymmetric with what CPython users expect (pytest is a third-party package), but matches what they *want*: the import name is reliable.

## 4. Sequencing

### Phase 1. dataclasses + pytest-lite (the headlines)

Order within phase:
1. `enum` (smallest, prerequisite for nothing here but useful immediately)
2. `pytest_lite` (tested initially via tiny self-test, then becomes the runner for everything else)
3. `dataclasses` (the user's headline, depends on v0.6.1 `__setattr__`)
4. `pytest` stub (10-line re-export, makes `import pytest` work)

Estimated total: ~3-4 days.

### Phase 2. the everyday rest

Once Phase 1 demonstrates the methodology and a tiny CLI demo (`web/demos/cli-example/`) uses dataclasses + pytest + at least one Phase 2 module:

5. `contextlib` (small, unblocks pytest-lite's yield-style fixtures)
6. `functools` (frequently reached for; depends on `contextlib` for `lru_cache`'s docstring example only)
7. `logging` (independent)
8. `argparse` (independent)
9. `abc` (independent)

Estimated total: ~3-4 days.

### Phase 3. sizing pass

After both phases land, run `make wasm-small` and `tools/metrics.py record` to measure the cold-load impact. The acceptable growth is ≤25 KB total in the frozen-tiny tier. If we land at ≤15 KB, the budget is comfortable and we can revisit `datetime` / `pathlib-lite`. If we're closer to 25 KB, defer those.

## 5. Consequences

**Positive:**

- A typical CPython script (`dataclasses` for data, `argparse` for CLI, `logging` for output, `pytest` for tests) runs unchanged on petitpy for the first time.
- Demos in `web/demos/` can use these idioms without falling back to hand-written `__init__` / `print` / etc.
- The tutorials we'd write to teach Python on petitpy can mirror the CPython curriculum more closely. "Here's how you write a class" doesn't have to dodge `@dataclass`.
- The library tier in `nanopython-lib/` grows in a coherent direction: each module added is one a daily-CPython user already knows.

**Negative:**

- Frozen-tiny grows by ~15-25 KB. The shipping wasm artifact grows proportionally; this is partly offset by the `wasm-opt` pass but is real cold-load tax.
- Maintenance surface: 8 new pure-Python modules to keep in sync with CPython behavior changes. Each ships subset semantics; deltas need to be documented or callers will hit "but CPython does X" issues.
- The pytest aliasing is mildly confusing: `import pytest` works without `pip install pytest`, which CPython users might find surprising. The first surprise is good; the second time someone tries to install `pytest` and discover the version landscape diverges is worse. We document this in `docs/COMPATIBILITY.md`.

**Open risks:**

- `__init_subclass__` support on nano needs verification. ADR drafted assuming it works (vendor MP supports it). If it doesn't, `enum.py` and `abc.py` need redesigns to use class decorators instead.
- The "lazy-fetch via micropython-lib path" for `pytest_lite` depends on ADR 003 D6 (IndexedDB cache) being wired for non-micropython-lib origin packages. Verify before committing the lazy-fetch tier.

## 6. Out of scope (deferred to later v0.x)

- `datetime`: needs Python-level calendar + epoch APIs we don't have. Defer to v0.8 or whenever a `time` module surfaces.
- `pathlib`: depends on a richer WASI filesystem story.
- `typing` runtime: `NamedTuple`, `Protocol`, `Any`. Defer.
- `subprocess`, `socket`, `ssl`, `http`: wasm + browser environment doesn't have these.
- `pickle`, `xml`, `csv`: defer until a concrete use case asks.
- `asyncio`: Path B deferral from ADR 010 §A4 still stands.

## 7. See also

- [ADR 003](003-library-and-module-loading.md): frozen-tiny + lazy-fetch delivery model; this ADR is the "which modules" instantiation of D4.
- [ADR 010 §A3a](010-roadmap-v06.md): earlier stdlib slices (re, itertools, string). This ADR is the v0.7+ continuation.
