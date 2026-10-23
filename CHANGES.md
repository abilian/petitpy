# Changelog

All notable changes to petitpy (development name nanopython) are documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/); the entries use [Conventional Commits](https://www.conventionalcommits.org/) types (feat, fix, perf, docs, build, test).

## [Unreleased]

### Changed

- **Dicts keep insertion order on `full`**, as in CPython 3.7+: printing, `json.dumps`, `**kwargs`, and class and instance namespaces follow the order keys were added, a key deleted and re-added moves to the end, and `popitem()` takes the last item. Maps use a compact layout: entries in insertion order followed by a hash index of 1, 2 or 4-byte slots. Speed is unchanged on the benchmarks; small dicts and 3-attribute instances use the same memory as before, while a large dict takes 40 to 75% more, depending on where its size falls between growth steps. `nano` and the browser build keep MicroPython's hash order, so nano stays byte-exact.
- **Built-in methods and constructors take keyword arguments on `full`** where CPython does: `str.split(sep=, maxsplit=)`, `rsplit`, `encode`/`decode(encoding=, errors=)`, `replace(count=)`, `str()`, `bytes()` and `bytearray()` with `encoding=`, `sum(start=)`, `round(ndigits=)`, `pow(mod=)`, `os.getenv(default=)`, and `print(flush=)`, which calls the file's `flush()`. `round(x, None)` now works. The `int` methods are vendor MicroPython's and still take positional arguments only.
- **`os.environ` is the real environment** on `full`: every variable at startup, and assigning or deleting a key changes the process environment, so child processes see it. `os` also gains `makedirs`, `walk`, `replace`, `fspath`, `devnull` and `pathsep`, and `os.fdopen` is reached as `os.fdopen`. File objects have `fileno()`.
- **Enums are real on `full`**: in `class Color(Enum):`, `IntEnum`, `StrEnum` and `(str, Enum)` classes, members are instances of the class with `.name` and `.value`, print as `Color.RED`, compare and hash as CPython's do, and `Color(1)` looks one up by value. `auto()`, `@unique`, `_missing_` and `__members__` work; iterating the class itself does not, since there are no metaclasses. This rests on `__init_subclass__` (PEP 487), which `full` now calls.
- **`int`, `float` and `str` subclasses work where their base does** on `full`: on the right of an operator (`1 + R(2)`, `1 < R(2)`, `'a' + S('b')`, with a subclass's own `__radd__` or `__gt__` going first), in `str.join`, and in `str.format` and `%` formatting. `format()`, f-strings and `str.format` call a class's `__format__`.
- **Type hints evaluate at run time on `full`**: `list[str]`, `dict[str, int]`, `int | None`, `Optional[...]` and `Union[...]` build objects that print as in CPython, `isinstance(x, int | None)` works, a class's `__class_getitem__` is called, and `typing.get_type_hints()` evaluates a class's annotations, its bases' included. Annotations stay stored as text; functions keep none.
- **`json` follows CPython**: `dumps` escapes non-ASCII unless `ensure_ascii=False`, converts `int`, `float`, `bool` and `None` keys, writes `NaN` and `Infinity` (or raises with `allow_nan=False`), and takes `skipkeys`, `default=`, `check_circular` and `cls=` with a `JSONEncoder` subclass. `loads` takes `object_hook`, `object_pairs_hook`, `parse_float`, `parse_int`, `parse_constant` and `strict`, rejects what CPython rejects (`01`, `1.`, control characters in strings), joins surrogate pairs, and raises `JSONDecodeError` with CPython's messages, positions, `lineno` and `colno`. `json.dump` and `json.load` are new.
- **Multiple inheritance follows CPython's C3 order on `full`**: in a diamond, method lookup and `super()` chains visit each class in the order CPython does, where MicroPython searched bases depth-first, and classes have `__mro__`. Bases that admit no consistent order raise `TypeError`.
- **`sys.platform` is `linux`, `darwin` or `wasi`**, as in CPython, instead of `petitpy`.
- **`ModuleNotFoundError`** on `full`, for a module that cannot be found, with CPython's message (`No module named 'os.nope'; 'os' is not a package`).
- **`slice()` constructs slices** on `full`.
- **`dict()`, `dict.update()` and `{**x}` take any mapping** on `full`: an object with a `keys()` method, a `dict` subclass among them, is read as CPython reads it instead of as a sequence of pairs.

### Fixed

- **`subprocess.run` no longer hangs on a child that writes more than a pipe holds** (64 KB on Linux): output is read while the child runs. `env=` is honoured, where it was ignored; output that is not captured goes to the parent's stdout and stderr, where it was dropped; and `run()` gains `cwd=`, `text=` (with `encoding`, `errors`, `universal_newlines`), `stdout`/`stderr`/`stdin` as `PIPE`, `STDOUT`, `DEVNULL`, a descriptor or a file, and the child no longer gets an empty stdin when no `input` is given. `check_output()` captures stdout only, as in CPython.
- **`dict.__setitem__(self, k, v)` and `dict.__delitem__` called from a `dict` subclass's own override** recursed until the stack overflowed. They now act on the dict itself, as `super()` already did.
- **`float()` of a `float` subclass** raised `TypeError` on `full`.
- **`'%d' % 3.7`** raised `TypeError` instead of formatting `3`, on both builds; vendor MicroPython formats it.

## [0.8.0] - 2026-10-21

This was a reach cycle. `match` statements land: with them, nanopython runs Python that vendor MicroPython cannot parse at all, for the first time. The **full-unix profile** grows POSIX modules and enough of `json`, `pathlib`, `dataclasses`, `re`, `logging`, `unittest.mock` and `pytest` to run a real third-party test suite. The compiler/VM split becomes a supported, gated configuration; a second front-end (`pyfront`, pure Python) exists to exercise the bytecode boundary from the outside; and a capability matrix measures both front-ends against both back-ends, construct by construct. The browser playground now shows the bytecode it compiled.

### Highlights

- **`match` statements.** Literals, singletons (compared by identity, per PEP 634), captures, wildcards, or-patterns, sequences including `*rest`, mapping patterns, class patterns with keyword sub-patterns, `as` bindings and guards. `match` and `case` stay soft keywords (`match = 1` is still an ordinary assignment) through a token replay buffer in the lexer, so the token stream stays byte-identical to vendor `py/lexer.c` for every input. The grammar lives in `src/compiler/grammar_ext.zig` at rule ids above the vendor table, leaving the generated `grammar_data.zig` untouched, and the lowering emits no opcode that was not already there.
- **The full-unix profile.** POSIX modules, PEP 448, PEP 570 and the stdlib surface needed to run `hop3-rootd`'s unit suite unmodified.
- **A supported compiler/VM split.** Compiling to `.mpy` and running `.mpy` are separately buildable and separately gated, which is what makes a second front-end possible.
- **A second front-end.** `projects/pyfront/` compiles Python to `.mpy` v6 in pure Python, sharing no code with the Zig front-end. It exists to test the bytecode boundary from outside. It found real bugs on both sides.
- **A capability matrix.** `make check-capability` compiles 67 constructs with both front-ends, runs each result on both back-ends, and compares against CPython. It tells a front-end gap from a back-end gap and from a disagreement. It is a strict bidirectional gate.
- **The playground shows bytecode.** `nanopython --emit-mpy` compiles without running; the browser page decodes the container and disassembles it beside your program, with a gallery of the 580 corpus programs measured to run on wasm.
- **Install from PyPI and npm, as petitpy.** `uvx petitpy script.py`, `pip install petitpy` or `uv tool install petitpy` install prebuilt wheels on macOS and Linux and build the sdist with Zig elsewhere; the commands are `petitpy` and `ppy`. `npm install petitpy` brings the browser build (ADR 016).
- **A garbage collector.** Until now nothing was ever freed: a program that created a million small objects kept all of them, 67 MB where MicroPython needs 3.7 MB. Memory is now collected (ADR 019), on native whenever the heap fills and on wasm between entries into Python, so a browser game that makes garbage on every frame stays flat (2000 callbacks: 1.36 GB before, 19 MB now). Files and sockets dropped without `close()` are closed by the collector. `gc.collect()`, `gc.mem_alloc()` and `gc.mem_free()` are real.
- **Faster.** Native `nano` runs fibo about 2x faster and bubble sort about 3x faster than at the start of October 2026, about 1.4x faster than MicroPython on both. In the browser, loop-heavy code runs up to 2.2x faster: V8 had kept the interpreter loop on its baseline compiler.

### Added

- **Published as petitpy.** PyPI refused `nanopython` as too close to an existing project, so the PyPI and npm packages are `petitpy`, and the wheel installs the command twice, as `petitpy` and as the short `ppy`. `--version`, the REPL banner, error messages and `sys.platform` say `petitpy`; the stdlib search path is `PETITPY_LIB` (or `~/.petitpy/lib`), where it was `NANOPYTHON_LIB` (or `~/.nanopython/lib`). The repository keeps its development name for now.
- **A "Differences from CPython" page** in the docs, by build, and the playground, demos and games on the docs site under `/play/` (`make doc-build` copies them; deploying is the maintainer's `make -C docs deploy`). The PyPI classifier is `3 - Alpha`.
- **An npm package**, `petitpy` (in `npm/`, assembled by `make npm-package`): the browser wasm, the JS bridge, and `loadPetitpy()`, whose `run(source, {stdin, files, argv, onStdout, onStderr})` runs a program on a fresh instance. `make npm-check` runs it under Node and in headless Chromium. Publishing is the maintainer's `npm publish ./npm/dist`.
- **Prebuilt wheels** for macOS (arm64, x86_64) and Linux (x86_64, aarch64), cross-built by Zig on one machine, with the sdist as the fallback (ADR 016, revision 3). The binary in them is built with ReleaseFast and stripped: about 850 KB, 1.3 to 2 times faster than the 540 KB ReleaseSmall build. The installed `petitpy` and `ppy` commands are the binary itself, with no Python launcher in between, and the runtime finds its stdlib at `<exe dir>/../share/petitpy/lib`. `make release-dist` builds them all on one machine; `make release-publish` uploads them to PyPI and npm from a tagged HEAD.
- **Class annotations and `@dataclass` fields without defaults.** Vendor compiles `x: int` in a class body to nothing, so `@dataclass` could not see a field without a default, and took field order from `dir()`, which is hash order here: `P(3)` could bind 3 to the wrong field. A class that annotates names now gets `__annotations__`, an `OrderedDict` in source order holding each annotation's text, as under `from __future__ import annotations` (PEP 563; evaluating them would raise `NameError` on forward references). `@dataclass` takes its fields from it and skips `ClassVar`. Annotations the compiler does not unparse (calls, constant tuples such as `Literal[1, 2]`) are recorded as `None`.
- **Exception chaining** (`raise X from Y`, PEP 3134). `__cause__` and `__suppress_context__` are set and readable; `__cause__` is assignable. A traceback prints the cause first with CPython's "The above exception was the direct cause of the following exception" line. Vendor MicroPython warns "exception chaining not supported" and drops the cause, so the full corpus golden for `exception_chain` was re-frozen without that warning. Implicit chaining (`__context__`) is not recorded.
- `petitpy -c CODE`.
- **Native `json.dumps` and `json.loads`.** Values made of `dict`, `list`, `tuple`, `str`, `int`, `float`, `bool` and `None` are encoded and decoded in Zig (`src/modules/modjson.zig`), 20 to 25 times faster than the Python code and close to CPython. `indent`, `sort_keys`, other types and invalid JSON still take the Python path, which reports the error.
- `os.path` after `import os` (and `import os.path`), served by a module `__getattr__`; module `__getattr__` (PEP 562) works on the full build.
- `math.gcd(*integers)`, the `format()` builtin, and in `itertools`: `permutations`, `combinations`, `combinations_with_replacement`, `product`, `groupby`, `zip_longest`, `takewhile`, `dropwhile`, `filterfalse`, `compress`, `pairwise` and `chain.from_iterable`. `itertools.tee()` returns independent iterators; it returned one iterator n times.

### Compatibility

- **`str` is Unicode on every build**, nano and the browser included: `len("é")` is 1, indexing, slicing and iteration count code points, and `"\u20ac"` compiles. They were byte strings before. Build with `-Dstr-unicode=false` to get byte strings back; the cost of Unicode is about 2 KB of wasm, and the nano build still matches vendor MicroPython's reference corpus byte for byte.
- **`from __future__ import ...` is a compiler directive**, consumed by the compiler and emitting nothing, as in CPython. The frozen `__future__` module 0.7.1 shipped is gone; `import __future__` now raises `ImportError`. Vendor MicroPython raises `ImportError` for the whole statement, so here nanopython follows CPython by choice.
- **`match` is not portable back to vendor MicroPython.** `golden-programs/works/match_statements.py` is the first entry whose `works-on=` header omits `micropython`.
- **String literals on the full build are UTF-8.** `"\xff"` is the code point U+00FF, so `print("\xff")` writes `ÿ` as UTF-8 where it wrote the raw byte 0xff; `len()` and `ord()` are unchanged. This is CPython's behaviour; nano and wasm keep byte strings.
- **No breaking changes** to source that ran under 0.7.1, apart from `import __future__` and the full build's string literals above.

### Fixed

- **Installing a package in the playground** mounted it as flat `lib/<file>` names, which the WASI shim never resolves, and its IndexedDB cache could wait forever for a transaction that had already committed; after a run the status was stuck at "Fetching…".
- **Float errors ended the program.** `try: x / 0.0 except ZeroDivisionError:` did not catch: vendor `objfloat.c` raises with a longjmp the VM cannot catch (ADR 013), so any float division by zero, `0.0 ** -1` or a negative base to a fractional power exited the program. They are now raised before vendor code runs, on every build. On full, `(-8.0) ** 0.5` panicked the process (the complex code it reached is an unported stub); it raises `ValueError` like nano until complex numbers are ported.
- **`10 ** -3` raised `ValueError: negative power with no float support`.** An int to a negative power is a float, as in CPython and vendor MicroPython.
- **`repr(float)` is the shortest string that round-trips, as in CPython,** and on native builds float literals are parsed with correct rounding (libc `strtod`). `math.sqrt(2)` printed `1.4142135623730952`, `5e-324` printed `1.84467440737095505e-323`, and `2.2250738585072014e-308` parsed one ulp off. 20,000 random floats now round-trip on native. The browser build keeps vendor's parser, which can be an ulp off on 17-digit literals: a correctly rounded one costs 16 to 25 KB of wasm. Neither corpus changed.
- **`pip install` shipped half the stdlib.** The wheel's module list in `scripts/hatch_build.py` was kept by hand and had fallen behind `nanopython-lib/`: `datetime`, `pathlib`, `typing`, `collections`, `os.path`, `subprocess`, `unittest` and `uuid` were missing. The list is now the directory itself, and `make test` imports every module from the installed layout.
- **`collections.abc` and `importlib.metadata` did not import from disk.** Both packages set `__path__ = []` so that their frozen copies counted as packages, which hid their submodules on disk. The frozen loader now marks frozen packages itself.
- **Unicode strings on the full build.** Indexing, slicing, iteration, `find`/`index` offsets and `center`/`ljust`/`rjust` widths counted bytes, so `"héllo"[1:2]` returned half a character; the compiler also rejected escapes above `\xff` (`"\u20ac"`) and stored `"\u00e9"` as a lone byte. All now count code points, as vendor MicroPython and CPython do; step slices work too. `string_escape` compiled by vendor `mpy-cross` now passes on our VM.
- **Uncaught tracebacks went to stdout,** and when stdout was a pipe they came out before the program's earlier output. They go to stderr after stdout is flushed, as in CPython.
- **A missing script printed a Zig stack trace.** `nanopython nope.py` now reports `can't open file` and exits 2, as CPython does.
- **The `.mpy` object table lost its NUL terminators** in pyfront. `str` and `bytes` payloads end with a terminator the loader skips; omitting it left the reader one byte behind for every entry that followed, so a program compiled, ran, and printed nothing.
- **`case 1 | 2:` compiled to `case 3:`.** The parser folds constant binary ops as it builds nodes, so an or-pattern routed through the `expr` rule arrived as a single integer. The alternatives now bind `|` below the level where folding happens.
- **A mapping pattern is not a dict comparison.** `case {"a": 1}` matches a dict that has other keys too; `case {}` matches any mapping. Both were wrong or refused.
- **`--emit-mpy` failed silently**, exiting non-zero with no message, because the bridge collapses the compiler's error payload into a code.
- **The capability gate passed while pyfront was completely broken**, reading 65 total failures as 65 front-end gaps, a category it does not gate, by design. Any exit code other than "compiled" or "refused by name" now stops the run.
- **Native `aarch64-linux` was blocked** by the `va_list` surface; portable `errno` and `MP_SSIZE_MAX` handling followed.
- **`enumerate()`, `property()`, `list.sort()` and `print()` with a bad keyword argument** read uninitialised memory after raising `TypeError`. ReleaseFast builds segfaulted on `enumerate()`; `print(1, z=1)` printed `1` before raising.
- **An out-of-range store overwrote element 0.** `l[5] = x` on a short list raised `IndexError` and also replaced `l[0]`; the same for `array`, `memoryview` and `deque`.
- **The browser build did not get the V8 speed-up.** `wasm-opt -Oz` in `make web` inlined the interpreter loop back into its caller, undoing the re-entry that lets V8 optimise it; the shipped wasm ran bubble with 1.8x the instructions of the build it was measured on. `make web` now limits that inlining (ADR 020).
- **Browser demos**: dead bridge handlers in snake and todo, `beep()`/`tone()` killing the wasm instance without `nanopy-host.js`, and a malformed JSON import that killed the ci-build-monitor page.

### Corpus (regression-gate metrics)

- Full-arm corpus: **545 / 552 (98.7%)**, unchanged; `corpus/full-known-fails.txt` stays at 7 documented decisions.
- Nano invariant: **541 / 541 byte-exact** against the frozen reference, held after every commit.
- Wasm gate: **490 / 541**, 51-entry known-fails baseline, unchanged.
- Integration suite: **148 → 175** hand-written cases, green on both arms.
- Curated golden programs: **579 → 580** in `works/`; `needs-grammar/` drops from 2 to 1.
- Capability matrix: **67 constructs**, 0 front-end gaps, 0 back-end gaps, 0 splits.

---

## [0.7.1] - 2026-07-03

This is a correctness and feature-reach patch. Nine standard-Python behaviors that used to crash, silently produce the wrong result, or raise the wrong exception now work. The full-arm build passes 545/552 of the MicroPython corpus (up from 538/552 in 0.7.0); the nano build stays at 541/541 byte-exact against the frozen reference, unchanged.

### Highlights

- **`bytearray` and `memoryview` slice assignment works**. `b[1:3] = b"xy"` and `m[i:j] = other` work, including growing, shrinking and self-referential assignments (`b[4:] = b`).
- **`compile()` + `exec()` / `eval()` on the resulting code object works**. Round-tripping user code through the compiler now works: `exec(compile(src, "file", "exec"), globals_dict)` runs.
- **You can override builtins**. `import builtins; builtins.abs = my_abs` now takes effect for the whole program, including `__build_class__` and `__import__`.
- **Scripts see their own `__file__`**. `sys.path[0]` is set to the script's directory, so `import`s relative to the running script work.
- **Small correctness fixes** in `ord("\xff")` (returns 255, was 0), `"%(missing)s" % {}` (`KeyError`, was `TypeError`), and `list.append(1, 2)` (`TypeError`, was a runtime crash).
- **Batteries included by default**. The stock `make check` / `make build-release-frozen` binary now bundles `random`, `heapq`, `bisect`, `itertools`, `functools`, `collections`, `__future__`, `_thread`, and `json` via `@embedFile`. `import random` etc. work out of the box; no separate stdlib install step for the standard set.

### Compatibility

- **`collections.deque` follows CPython semantics on the full build**, where it had the strict MicroPython form. `deque(iterable)` works without a `maxlen`; `d[i:j]` slice access is unsupported (as in CPython). The strict-MP behavior stays available via `from ucollections import deque`. The same choice already applies on the wasm build; both `deque_micropython` and `deque_slice` are now explicit documented divergences.
- **`--version` reports `nanopython 0.7.1`**.
- **No breaking changes**: every source that ran under 0.7.0 continues to run under 0.7.1.

### Fixed

- **`bytearray` / `memoryview` slice assignment** (`MICROPY_PY_ARRAY_SLICE_ASSIGN`). `bytearray(range(10))[1:3] = bytearray([10, 20])` now works, as do growing (`b[2:] = bytearray(10)`), shrinking, extending-from-bytes (`b[1:1] = b"12345"`), and self-append (`b[4:] = b`). Applies to `bytearray`, `memoryview` (write-through), and `array.array`. Full build only.
- **`exec()` / `eval()` on a `compile()` result**. Previously `compile()` produced a code object but `exec(c)` / `eval(c)` panicked. The full lifecycle now works: `c = compile("print(x)", "f", "exec"); exec(c, {"x": 1})` executes correctly and picks up the user-supplied globals dict.
- **Overridable `builtins`**. `builtins.abs = ...`, `builtins.__build_class__ = ...`, `builtins.__import__ = ...` all take effect. Full build only; nano keeps the read-only builtins module its frozen reference has.
- **`__file__` and `sys.path[0]` for script execution**. `nanopython script.py` now sets `__main__.__file__ = "script.py"` and puts the script's directory at the head of `sys.path`, matching CPython's script-mode behavior. Imports next to the script resolve without `PYTHONPATH` fiddling.
- **`ord()` on high-byte characters**. `ord("\xff")` returns `255` (was `0`). Any 1-character string of a non-ASCII byte now returns the byte value, matching CPython.
- **`"%(key)s" % {}` on a missing key**. Raises `KeyError('key')` (was `TypeError("format string needs more arguments")`), matching CPython and MicroPython.
- **`list.append(1, 2)` no longer crashes the runtime**. Raises `TypeError("argument should be a list")` as expected.

### Improved

- **The `make check` binary matches the shipping binary**. Full-arm gates route through `build-frozen`, so the corpus tests run against a binary that has the stdlib set baked in. Previously the gate ran a bare binary where `import random` silently failed, and the "sequence-hazard" stochastic test skipped through the broken import and never exercised the hazard check.

### Corpus (regression-gate metrics)

- Full-arm corpus: **538 / 552 (97.5%) → 545 / 552 (98.7%)**. Nine closures (`sys_path`, `self_type_check`, `bytearray_slice_assign`, `memoryview_slice_assign`, `string_escape`, `builtin_override`, `class_setname_hazard_rand`, `builtin_compile`, `string_format_modulo`).
- `corpus/full-known-fails.txt`: **14 → 7** entries. The remaining 7 are all documented decisions: unix-port modules we don't ship (`memoryview_slice_size`, `subclass_native_call`, `builtin_help`), chosen CPython-compat divergences (`deque_micropython`, `deque_slice`), and architectural or more-conformant-than-vendor entries (`nanbox_smallint`, `class_inplace_op2`). See the file's header comments for the per-entry rationale.
- Nano invariant: **541 / 541 byte-exact** against the frozen reference throughout the release, held after every commit.
- Wasm gate: unchanged (490 / 541 raw pass; the wasm known-fails list did not move).

---

## [0.7.0] - 2026-06-13

This was a profile cycle, in which three landmark ADRs land together. **011 (everyday stdlib)** ships 8 modules with 160 tests. **012 (profiles + feature matrix)** is implemented through Phase 4b: `full` is now the default profile and `make check` routes to a strict bidirectional gate against `corpus/full-known-fails.txt`; `nano` stays reachable via `CONFIG=nano`. **013 (NLR carveout)** lands the runtime trampoline that lets `try/except` catch exceptions raised inside vendor C (MPZ, io, pow3). The full arm went from "doesn't link" at the start of the cycle to **538/552 = 97.5%** under the strict gate; nano stays byte-exact at 541/541 throughout. Five nano-side runtime bug fixes lift the long-standing `is_full` over-trimming. The descriptor protocol + `__set_name__` + walrus PEP-572 + bytearray.append round out a busy correctness pass.

### Highlights

- **Default profile flips to `full`** ([ADR 012](docs/src/adrs/012-profiles-and-feature-matrix.md) Phase 4b). `make build` produces a full binary; `make check` / `verify` route to `tools/full_gate.py` against `corpus/full-known-fails.txt` (538/552 = 97.5%, 14 documented misses); `make check CONFIG=nano` keeps the byte-exact 541/541 strangler invariant reachable. Wasm targets pinned to nano (wasm has no MPZ).
- **Everyday stdlib: 8 modules, 160 tests** ([ADR 011](docs/src/adrs/011-everyday-stdlib.md)). `pytest_lite`, `enum`, `dataclasses`, `contextlib`, `functools`, `logging`, `argparse`, `abc`. A daily-CPython script (`@dataclass class Config: ...`; `import logging; logging.info(...)`; `pytest tests/`) now works unchanged.
- **`try/except` over vendor-C raises** ([ADR 013](docs/src/adrs/013-exception-unwind-vendor-c.md)). New scoped setjmp/longjmp trampoline (`src/runtime/nlr_trampoline.{c,zig}`) wraps the type's `.call` slot dispatch + `mp_obj_int_pow3` + the binary-op slot. Vendor MPZ / io / pow3 raises (ZeroDivisionError, OverflowError, OSError, ValueError) now unwind back into the polled-sentinel pattern; they used to `exit(1)` past the user's `try/except`. Native-only; wasi-libc `setjmp.h` `#error`s out (spike documented in §6).
- **Full arm becomes a real release target.** Was: doesn't link (13 undefined symbols + the `nanopython-vm` variant still has 10 deferred). Is: 538/552 corpus, strict bidirectional regression gate, `make check-full` + `make check-nano` + `make check-all` aggregate.
- **Nano runtime bug closures**: five `is_full` over-trims fixed: `__radd__` / `__rmul__` (reverse special methods), `b'-'.join([bytearray(...), b'..'])`, `bytes([256])` validation, `bytearray.append`'s polled-sentinel rollback, PEP-572 walrus rebind-of-for-target rejection. All five close CPython-conformance gaps that nano shipped silently broken.
- **Descriptor protocol fixes**: `__getattr__` no longer fires when probing `__get__` / `__set__` / `__delete__` / `__set_name__` / `__setattr__` / `__delattr__` (mirrors vendor `py/objtype.c:664-678`); `__set_name__` is dispatched after class-body finalization with a capture-then-call snapshot that tolerates in-collector mutations (mirrors vendor `py/objtype.c:1256-1287`).
- **`make check-full` strict gate**: bidirectional regression checker mirrors `make wasm-check` discipline exactly. `corpus/full-known-fails.txt` only ever shrinks; closing a test means removing it from the list in the same commit. Categorized rationale per entry.
- **Browser-game tutorial**: [docs/writing-games.md](docs/src/writing-games.md) walks newcomers through building Catch on the `nanopy` library, kid (procedural) and pro (classes + decorators) variants.

### feat (runtime)

- **NLR carveout trampoline** ([ADR 013](docs/src/adrs/013-exception-unwind-vendor-c.md)). `src/runtime/nlr_trampoline.c` + `.zig`. New `build_options.exception_unwind` flag (default true on native + full only; false on nano + wasm32). Wraps `mp_obj_int_binary_op` (covers MPZ divide/shift/mod/pow), `mp_obj_int_pow3`, and the type-slot `.call` dispatch in `mpCallFunctionNKwImpl` (the funnel wrap, which catches StringIO closed-file, BytesIO EINVAL, `int()` TypeError, `int.to_bytes` OverflowError). Closes 11 corpus tests that used `try/except` across the vendor-C boundary.
- **Parser MPZ overflow handoff under full**: new `build_options.longint_impl` tri-valued enum (`.none` / `.longlong` / `.mpz`) mirroring `MICROPY_LONGINT_IMPL`. `parsenum.zig` overflow gate widened from `if (longint_none)` to `if (longint_impl != .longlong)` so NONE and MPZ both delegate to vendor `mp_obj_new_int_from_str_len`. Closes 33 `*intbig*` tests in one commit; aligning the MPZ accumulator with the NONE shape closes 5 more.
- **`sys.implementation` attrtuple layout fix**: `impl_fields` declared as `[u16]` (2-byte stride) but read as `[Qstr]` (8-byte stride on 64-bit) → panic on `sys.implementation` under full. One-line type fix. Closes 4 tests (3 async_*2 + attrtuple1), all gated on `sys.implementation.name`.
- **`__build_class__` propagates class-body exceptions**: `class S: m.x = 1` used to panic with `cast causes pointer to be null` from `MpObjCell.fromObj(0)`. Vendor unwinds via NLR; nano's `mp_call_function_0` returns the bridge sentinel and we forgot to poll. Two-line fix.
- **All raise helpers unified across arms**: `mp_raise_msg`, `mp_raise_msg_varg`, `mp_raise_ValueError`, `mp_raise_TypeError_int_conversion`, `mp_raise_TypeError`, `mp_raise_OSError`, `mp_raise_NotImplementedError`, `mp_raise_type_arg` moved from `@panic` stubs under full to real implementations on both arms. Pairs with the NLR trampoline so try/except catches when a pad is registered.
- **Full main binary now links**: three small fixes (`build.zig` float files unconditional, `mp_raise_NotImplementedError`/`type_arg` exports unconditional, `mp_obj_new_str_from_utf8_vstr` alias under full). `nanopython-vm` (the experimental variant) still has 10 link errors (deferred).
- **User-class `__setattr__` / `__delattr__` work on nano**: `MICROPY_PY_DELATTR_SETATTR` flipped from `0` to `1` for both arms via new `build_options.delattr_setattr` flag. `JsProxy` bridge uses natural attribute writes (`js.window.title = "foo"`); `object.__setattr__` / `object.__delattr__` reachable as methods.

### feat (stdlib, ADR 011)

Each module pure Python under `nanopython-lib/`. 160 self-tests under `tests/stdlib/`; new `make test-stdlib` target wired into `make test`.

- **`pytest_lite`** (~230 lines): minimal pytest-shaped runner. `pytest.raises(ExcType)` context manager; `pytest.skip(reason)` inline + `@pytest.skip` decorator. `pytest.py` shim re-exports under the `pytest` name.
- **`enum`** (~60 lines): `@enum` class decorator (nano lacks `__init_subclass__` + metaclasses, so the subclass-of-Enum form isn't an option).
- **`dataclasses`** (~110 lines): `@dataclass` synthesizing `__init__` / `__repr__` / `__eq__`. Fields use plain `x = 0` (no `__annotations__` on nano). `field(default_factory=)`, `asdict()`, `fields()`.
- **`contextlib`** (~90 lines): `@contextmanager`, `closing`, `suppress`, `nullcontext`.
- **`functools`** (~100 lines): `partial`, `wraps` (no-op on nano), `reduce`, `lru_cache(maxsize=128)` FIFO eviction.
- **`logging`** (~150 lines): `getLogger`, `basicConfig`, level constants, printf-style substitution, `%(name)s` / `%(levelname)s` / `%(message)s` format tokens. Nano extension: `basicConfig(sink=callable)`.
- **`argparse`** (~190 lines): `ArgumentParser`, `add_argument` with `action="store"`/`"store_true"`/`"store_false"`/`"count"`, `type=`, `default=`, `choices=`, `required=`. `--flag=value`, `-h`/`--help`, exit status 2 on error.
- **`abc`** (~80 lines): `ABC` + `@abstractmethod` via marker-object pattern (function-attribute writes used to panic the runtime; that was the bug we fixed in `__build_class__` propagation above, but `abc`'s pattern is also CPython-conformant without `ABCMeta`).

### feat (gates + build)

- **`tools/full_gate.py`** + **`corpus/full-known-fails.txt`** + **`make check-full`**: strict bidirectional gate for the full arm. Mirrors `make wasm-check`'s discipline. 14 known-fails categorized: 4 vendor-config-divergence, 4 port-specific, 1 architectural (nanbox_smallint), 3 deferred-large-surface (builtin_compile/help, string_escape), 1 architectural-fix-known (self_type_check), 3 descriptor-protocol-deep-work.
- **`make check-nano`** + **`make check-all`**: explicit nano gate; aggregate dual-arm gate. `make check-all` is the new pre-commit standard.
- **Wasm-arm pinned to nano**: `make wasm` / `wasm-small` / `web` hardcode `-Dconfig=nano` regardless of `CONFIG`. Wasm32 has no MPZ; full on wasm would tank `wasm-check`.
- **`make test-stdlib`** runs every `tests/stdlib/test_*.py` through the binary; wired into `make test`.
- **`make lint`** adds `prettier --check` for JS sources.

### fix (correctness, nano)

- **Reverse special methods** (`__radd__` / `__rsub__` / `__rmul__` / `__rtruediv__`, etc.): `is_full` gate removed; vendor MP runs these unconditionally per Python data-model semantics. New `build_options.reverse_special_methods` flag (default true). `class_reverse_op` golden re-frozen against vendor MP byte-exact.
- **`b'-'.join([bytearray(b'a'), b'b'])`**: `bytes↔bytearray` normalization in `str.join` was `is_full`-gated though `bytearray` is built on both arms. Gate removed; corpus golden refrozen.
- **`bytes([256])`** validates 0..255 on both arms; it was `is_full`-gated, so nano silently truncated. Correctness wins over a meaningless size cut.
- **`bytearray.append` polled-sentinel rollback**: vendor C `nlr_jump` from `mp_binary_set_val_array` left `self.len` bumped after a TypeError, printing trailing garbage byte. Two-line poll-and-rollback fix.
- **PEP-572 walrus rebind of for-target**: `[i := i+1 for i in range(4)]` silently produced `[1,2,3,4]`; now raises `SyntaxError: identifier redefined as nonlocal` per vendor `py/compile.c:1252-1274`.
- **Walrus golden** for nano refreshed against vendor MP byte-exact.

### fix (correctness, runtime)

- **Descriptor-protocol probe fallthrough**: `mp_obj_instance_load_attr` now mirrors vendor `py/objtype.c:664-678`: short-circuits `__getattr__` delegation for `__get__` / `__set__` / `__delete__` / `__set_name__` (always) and `__setattr__` / `__delattr__` (when `build_options.delattr_setattr`). Without this, accessing `TestClass().non_descriptor` where `NonDescriptor` defines `__getattr__` but no `__get__` triggered phantom `getattr __get__` synthesis.
- **`__set_name__` dispatch** in `newTypeImpl` (gated on `is_full` to preserve nano-C corpus discipline). Capture-then-call snapshot pattern (mirrors vendor `py/objtype.c:1256-1287`): walks `locals_map`, captures bound `__set_name__` methods, then invokes them. Earlier single-pass loop missed siblings overwritten by an earlier `__set_name__` body via `setattr` (the SetReplaceTest / DelReplaceTest hazard).
- **`mp_builtin___build_class__` propagates exceptions**: class-body raises now unwind to the caller's `try/except`; they panicked on `MpObjCell.fromObj(0)`.

### fix (correctness, parser + frontend)

- **MPZ overflow handoff** (parsenum.zig): under full, parser now delegates overflow to vendor `mp_obj_new_int_from_str_len`, getting heap MPZ ints. 33 `*intbig*` tests close.
- **MPZ accumulator alignment** (parsenum.zig): under MPZ, signed `mp_int_t` accumulator + smallint-fits check (mirrors vendor's NONE arm); previously used the LONGLONG-shaped u64 + LLONG_MAX+1 cap, which let `0x8000000000000000` exactly equal 1<<63 and panic on `@intCast` to i64. 5 more tests close; `struct_micropython` hang resolves as a side effect.
- **`reverse_special_methods` gate**: see fix (correctness, nano) above.

### refactor

- **Dead `Compiler.is_full` field removed** (compile.zig). Assigned in 5 places, never read. ADR 012 D4 cleanup.
- **`.set("attr", X)` → `.attr = X` across 13 demos**: `JsProxy` bridge accepts both syntaxes now that `__setattr__` works on nano. 164 substitutions.
- **Prettier 1TBS over all JS**: `.prettierrc.json` pins 1TBS / 100-col / double quotes / trailing commas.
- **`web/` reorganized** into `demos/` / `games/` / `extensions/` subdirectories with three-section landing page.

### docs

- **[docs/writing-games.md](docs/src/writing-games.md)**: newcomer tutorial; builds Catch end-to-end, kid + pro variants, `nanopy` quick-reference.
- **[ADR 011](docs/src/adrs/011-everyday-stdlib.md)**: Everyday stdlib. **Implemented**.
- **[ADR 012](docs/src/adrs/012-profiles-and-feature-matrix.md)**: Profiles + feature matrix. **Implemented** (Phase 4b lands the default flip). Partially supersedes ADR 002.
- **[ADR 013](docs/src/adrs/013-exception-unwind-vendor-c.md)**: Exception unwinding across vendor C. **Proposed**; trampoline foundation + 3 wrap sites implemented in this cycle; alternative B' (native-only) per the setjmp spike.
- **CLAUDE.md "What 'green' means" section** rewritten for the default-full era. 7-row gate table.
- ADR 002 status → "Partially superseded by ADR 012."

### Known issues (deferred)

- **`nanopython-vm` variant under full**: 10 undefined symbols at link time. The main `nanopython` binary builds fine. Affected Makefile targets tolerate the partial-build exit code.
- **Wasm-arm uses `exit(1)` for vendor-C raises**: wasi-libc `setjmp.h` `#error`s out, so the NLR trampoline (ADR 013 B') doesn't compile under wasm32. Wasm full would need WasmEH (ADR 013 Alternative D) once toolchain support firms up.
- **14 full-corpus known-fails** in `corpus/full-known-fails.txt`, each with a categorized one-line rationale. Closing one is a net-improvement to the project; the strict gate enforces atomic removal.

### chore

- **golden re-freezes** (against vendor MP byte-exact): `class_reverse_op`, `bytearray_byte_operations`, `bytes_construct`, `class_delattr_setattr`, `bytearray_append`, `assign_expr_syntaxerror`.
- **Integration suite grew 70 → 77** (regression pins for class-body-raise-propagation, reverse special methods, bytearray + bytes range, more).
- **Native byte-exact corpus** holds at 541/541 throughout the cycle.

---

## [0.6.0] - 2026-06-12

This was the first post-strangler cycle. The runtime works end-to-end on both arms; v0.6 broadens the surface (stdlib `re`/`itertools`/`string`, multiple inheritance, several Python-3.x features), closes the eval/exec wasm wall, lands measurable size + cold-load metrics infrastructure, and addresses two classes of wasm32 layout bug that had been latent since v0.3. The plan is in [ADR 010](docs/src/adrs/010-roadmap-v06.md).

### Highlights

- **eval/exec works on wasm32**: the longjmp wall identified in v0.5 closes via a u16/usize ABI fix at the bytecode entry boundary. It belongs to a class of bugs latent on amd64's tolerant register layout but trapping on wasm32's typed function-call discipline.
- **Multiple inheritance under nano**: `class C(A, B):` works correctly; nine corpus tests previously fail-fasting on `NotImplementedError` now match vendor MP byte-for-byte.
- **`re` works on both arms**: vendor `extmod/modre.c` + `lib/re1.5/` ship as a feature carveout. Closing this required fixing `MpObjFunBuiltinVar`'s wasm32 layout: an explicit `_pad: u32 = 0` in the mirror was correct on amd64 but inserted phantom padding on wasm32, manifesting as `wasm trap: undefined element` deep in any var-arity builtin caller. `MpCodeState` + `MpArg` got the same treatment in cleanup.
- **Wasm shipping artifact: 305 KB → 278 KB raw** (-9%) via export-section strip ([ADR 010 §D1 P2](docs/src/adrs/010-roadmap-v06.md)). Post-`wasm-opt -Oz`: 283 KB.
- **Cold-load wasm timing measured for the first time**: ~10 ms median (Apple Silicon, wasmtime CLI). Trend tracked per row in `metrics/history.ndjson`; `make cold-load` runs the harness standalone.
- **Property setters work correctly on nano**: independent code review surfaced that `mp_obj_instance_store_attr` was incorrectly gated on `is_full`, silently bypassing setters under nano since v0.3. The corpus golden for `builtin_property` had been frozen against the broken behavior; re-froze against vendor MP.

### feat

- **`re` module**: full regex API (`compile`, `match`, `search`, `sub`, `split`) on both arms via vendor `extmod/modre.c` + `lib/re1.5/`. Gated by `-Dfeature-re=true` (default on).
- **`itertools`**: `chain`, `cycle`, `count`, `repeat`, `starmap`, `tee`, and the rest. Both arms.
- **`string`**: `ascii_letters`, `digits`, `whitespace`, `Formatter`, etc. Frozen-tiny stdlib.
- **Multiple inheritance** under nano: `class E(C, D)` and the diamond pattern work. Nine corpus tests refrozen to vendor-matching output: `builtin_dir`, `class_inherit_mul`, `class_store_class`, `class_super_multinherit`, `subclass_native1/2/5`, `subclass_native_init`, `subclass_native2_list`, `subclass_native2_tuple`.
- **`str[::step]`** with step ≠ 1, including negative step (`"abc"[::-1]` → `"cba"`).
- **`__missing__`** on dict subclasses, which closes the `collections.Counter`-style pattern.
- **`bytes.fromhex(data, sep)`**: CPython 3.5+ separator argument.
- **Richer arithmetic TypeError**: `1 + 'a'` → *"unsupported types for `__add__`: 'int', 'str'"* (was the TERSE *"unsupported type for operator"* regardless of operands).
- **`tools/timing.py`**: cold-load wasm timing harness. Median ms over 5 wasmtime runs; recorded per row in `metrics/history.ndjson` and surfaced via `make cold-load` + new `cold-ms` column in `make metrics-report`.

### fix

- **eval/exec works on wasm32**: closed the longjmp wall by fixing a u16/usize ABI mismatch at the bytecode entry boundary. Reached 30 corpus tests previously known-failing.
- **`MpObjFunBuiltinVar` wasm32 layout**: explicit `_pad: u32 = 0` mirror field caused every var-arity builtin to dispatch through a wrong-by-4-bytes function pointer on wasm32. Manifested as `wasm trap: undefined element` deep in any caller (most visibly: `re.compile`). Removed; replaced with comptime layout checks so the bug can't return silently.
- **`MpCodeState` + `MpArg` wasm32 layout**: same class of bug as the `MpObjFunBuiltinVar` fix. It had no live symptom: the cross-arm consumers are all Zig, so the mirror was internally consistent. The mirror disagreed with vendor C's layout on wasm32, which would silently break a future C-side reader. Comptime layout checks now cover both arms.
- **Property setters/deleters fire on nano**: `mp_obj_instance_store_attr` was incorrectly gated on `is_full`; vendor MP gates the property+descriptor block on `PROPERTY || DESCRIPTORS` (both = 1 on nano). Setter `c.x = v` silently stored `v` into instance members and never called the setter. Golden `corpus/nano/basics/builtin_property.out` re-frozen against vendor MP byte-exact output.
- **Inherited property descriptors fire**: same class as the setter bug, surfaced first by MI enablement. `ENABLE_SPECIAL_ACCESSORS` flag propagation in `newTypeImpl` and the dynamic-property-attach path in `type_attr` were both gated on `is_full`; both flipped to flags that match vendor MP's `PROPERTY || DESCRIPTORS || DELATTR_SETATTR` discipline.
- **Held exception text stable under nested binops**: `binopUnsupported` originally formatted into a module-static buffer that was overwritten on every raise, mutating any already-captured `except ... as e:` message. Routed through `mp_obj_new_exception_msg_varg` for per-raise `m_malloc`'d message lifetime.

### perf

- **Wasm shipping artifact: 305 KB → 278 KB raw, 283 KB post-`wasm-opt -Oz`** via export-section strip ([ADR 010 §D1 P2](docs/src/adrs/010-roadmap-v06.md)). Replaced `exe.rdynamic = true` (which exported every `pub fn`) with an explicit `export_symbol_names` list, so DCE strips the unreachable internals.

### docs

- [ADR 010](docs/src/adrs/010-roadmap-v06.md) updated with DONE/DEFERRED markers per item, including the A3c (MPZ on wasm32) deferral rationale and the D2 timing-harness resolution.
- ADRs moved into `docs/adrs/` and cross-references made clickable across the docs.
- README + `docs/` restructured around three personas (web devs, embedded devs, contributors); contrastive *"X, not Y"* constructions removed across the docs and ADRs.
- CLAUDE.md updated with the v0.6 retrospective (MI surfacing the property-descriptor bug class; the `re`-on-wasm root cause; the MpStateVmPartial known issue).

### build

- **`tools/timing.py` + `make cold-load`**: cold-load timing infrastructure ([ADR 010 §D2](docs/src/adrs/010-roadmap-v06.md)).
- `make doc-setup / doc-build / doc-serve` targets for the Zensical doc site.
- New build flag `-Dmultiple-inheritance=true` (default on, controls the MI enable in `objtype.zig`).
- New build flag `-Dfeature-re=true` (default on, gates the re module carveout).

### test

- Integration cases grew from 37 to **70**: covering eval/exec, MI, itertools, string, `re`, `str[::step]`, `__missing__`, `bytes.fromhex(sep)`, the richer TypeError messages, the held-exception stability edge, and the property setter on nano.
- New regression pins discriminate against each fixed bug: `property_setter_fires_on_nano`, `typeerror_held_stable_under_nested`, `property_via_subclass`, `property_dynamic_attach`.

### chore

- `corpus/wasm-known-fails.txt` baseline: 68 → **51** entries. The difference is the corpus tests that crossed the wasm threshold via the eval/exec ABI fix, the `re` module landing, and the MpObjFunBuiltinVar layout fix.
- `golden-programs/works/` filesystem count: 546 (unchanged from v0.5; the surface broadened via stdlib but new programs map to existing buckets).
- Frozen-tiny stdlib total: 8.3 KB → **9.5 KB** (+ itertools + string + re hooks).
- Native binary: 1.0 MB → 3.6 MB (Debug; Release+frozen unchanged at ~1 MB).

### removed

- Dead build wiring + the retired `wasm_setjmp.c` stub (commit `762178c`).
- Two now-orphan extern declarations in `src/runtime/runtime.zig` (`mp_obj_get_type_str`, `qstr_str`) after the binopUnsupported rewrite.

---

## [0.5.0] - 2026-06-11

The strangler-to-Zig phase is done. v0.5 closes the long-standing 541/541 native byte-exact baseline, ships the shipping artifact's first major size cut, and brings the test harness to both arms. The full retrospective is in [ADR 009](docs/src/adrs/009-roadmap-v05.md); the v0.6 plan that follows is in [ADR 010](docs/src/adrs/010-roadmap-v06.md).

### Highlights

- **541/541 native byte-exact corpus**: the long-standing strangler invariant from v0.4 is reached.
- **Wasm shipping artifact: 354 KB → 305 KB** (-14%) via `wasm-opt -Oz` in the production pipeline.
- **Test harness is both-arms by default**: every integration smoke runs on native AND wasm; wasm-only regressions surface in 1 second.
- **`docs/COMPATIBILITY.md`**: auto-generated user view: 546 of 756 in-scope programs work, bucketed by what's missing for the rest.
- **Class of wasm32 ABI bugs closed**: u16/usize FFI mismatches at the boundary tolerated on amd64 but trapping on wasm32; surfaced and fixed systematically.

### Breaking changes

- **Exit code on uncaught exceptions changed from 0 to 1.** Matches CPython and MicroPython. Scripts that depended on the previous (incorrect) exit 0 on raise will need adjustment. `sys.exit(N)` still propagates N; `sys.exit()` / `SystemExit(None)` / `SystemExit(0)` still exit 0.

### feat

- Native byte-exact corpus closed to 541/541 (`builtin_help`, `gc1`, `string_strip` all addressed).
- `wasm-opt -Oz` integrated into `make web`: the artifact users download is now post-optimization by default.
- `docs/COMPATIBILITY.md` auto-generated from `golden-programs/` via `make compatibility`.
- `tools/metrics.py`: longitudinal recording of size, coverage, and (opt-in) benchmark perf to `metrics/history.ndjson`. Subcommands `record`, `report`, `latest`.
- `NotImplemented` builtin now available on nano (was `is_full`-only).
- `str.isalnum()`, `str.ljust(width, fillchar)`, `str.rjust(width, fillchar)`: new string methods.
- `chr()` accepts the full Unicode range to U+10FFFF and returns the UTF-8 encoding (was capped at byte range).
- `from collections import deque` ships a CPython-compatible `deque(iterable)` (unbounded by default). Vendor MP's strict `(iterable, maxlen)` shape is still reachable via `from ucollections import deque`.
- Improved error messages: `NameError` / `AttributeError` now include the offending identifier; `int / int` correctly produces a float; `%`-format handles floats.

### fix

- **Uncaught exception now exits 1** (was silently exit 0). The metrics tool's "blazing fast 5 ms benchmark" sightings of crashed programs led to this finding.
- **`__init__` raising propagates correctly.** Previously, any user exception raised inside `__init__` was overwritten by a misleading "TypeError: `__init__` should return None". The root cause was in `instanceMakeNewImpl`: the `pending_exc` check was missing before the return-value validation.
- **`fprintf(NULL)` wasm trap removed** from the LONGLONG raise bridge. macOS libc tolerated the NULL stream; wasi-libc traps when dereferencing the FILE* vtable.
- **u16/usize ABI mismatches at FFI boundaries.** `mp_errno_to_str` and `mp_obj_fun_get_name` declared `u16` returns where the actual ABI was `usize`. Tolerated on amd64 (low 16 bits of RAX align by accident); wasm32's typed-call discipline produces an unreachable-trap diagnostic. Fixed at both definition and declaration sites; class audit completed.
- **`str.splitlines(False)`** correctly strips line endings. The `keepends` arg was being ignored on any explicit value (root cause: `MpArgT.flags = 0x008` should have been `0x001 = MP_ARG_BOOL`; the union storage was being read with the wrong type).
- **`gc.isenabled()` returns True on startup.** `gc_init` now initializes the auto-collect flag, matching vendor `py/gc.c`.
- **`gc_info` stub** sized to the correct struct extent (was zeroing 64 bytes into a 56-byte struct, scribbling past the caller's stack frame, which caused a delayed SIGTRAP after `gc.mem_free()`).
- Build: `make wasm` now produces a runnable binary (the JS-feature toggle had silently defaulted to a configuration the wasm runtime couldn't load).

### perf

- Wasm shipping artifact: **354 KB → 305 KB** (-14% raw, -5% gzipped) via `wasm-opt -Oz` integration ([ADR 007 §4 P6](docs/src/adrs/007-wasm-fat-loss.md)).

### docs

- `README.md` revised end-to-end. The gate state (four independent test gates) is surfaced where new readers land, with each gate's purpose and current count.
- `CLAUDE.md` restructured around the "What 'green' means" test-harness table. Known failures surfaced explicitly with a "don't push problems under the rug" policy.
- [ADR 009](docs/src/adrs/009-roadmap-v05.md): v0.5 roadmap (now closed; §11 retrospective added).
- [ADR 010](docs/src/adrs/010-roadmap-v06.md): v0.6 roadmap. Headline: closing the eval/exec longjmp wall, broadening the stdlib surface (`re`, `itertools`, `string`), and a softening of the size target from 228 KB to 285 KB with explicit reasoning.

### build

- `make` (the aggregate target) now exercises both arms by default: native (`test-unit` + `test-integration` + `test-e2e`) plus wasm (`wasm-check` + `test-integration-wasm`). Adds ~8s to the pipeline; catches the kind of wasm-only regression that hid the float-print bug in v0.4.
- `make test-integration` switched to `build-frozen` so the native smoke uses the same module surface as the shipping wasm.
- New targets: `make compatibility`, `make metrics-record`, `make metrics-record-perf`, `make metrics-report`, `make metrics-latest`, `make test-integration-wasm`, `make build-release-frozen`.
- `make web` runs `wasm-opt -Oz` automatically with feature flags scoped to what Zig emits (`--enable-bulk-memory --enable-nontrapping-float-to-int`). Gracefully degrades to the un-optimized binary when binaryen isn't installed.

### test

- `tests/integration.py` is runner-pluggable via `--runner`: the same hand-written smoke suite drives native, wasm, or any future runtime.
- Integration cases grew from 22 to 37, all running on both arms.
- Every fix in this release ships with a regression pin in `tests/integration.py` so the bug can't silently return.

### chore

- `golden-programs/` rebootstrapped after each major fix. `works/` filesystem count: 543 → **546** (+3 after collisions; bucket distribution moved more programs to `works/` than the filesystem reflects due to filename collisions across source corpora).
- `corpus/wasm-known-fails.txt` baseline: 73 → **68** entries (the difference is the corpus tests that crossed the wasm threshold via the runtime / ABI fixes above).
- Frozen-tiny stdlib total: 7.9 KB → **8.3 KB** (CPython-friendly `deque` class + helpers).

---

## [0.4.0] - Earlier

This release converged the strangler-to-Zig core, positioned WASM as primary and added per-feature size flags. The v0.4 roadmap is in [ADR 001](docs/src/adrs/001-roadmap-v04.md); details predate this changelog.

