# Feature profiles

Each bucket under `golden-programs/` corresponds to a profile — a feature bundle. A program lives in the minimal profile it needs to run.

## `works/`

**Current nanopython, no additional features required.** This is what ships today.

Includes: f-strings, list/dict/set comprehensions, classes (single inheritance + multiple via `-Dconfig=full`), decorators (`@staticmethod`, `@classmethod`, `@property`), exception handling (`try/except/finally`), context managers (`with`), generators (`yield`), `__future__` imports (no-op stub), most builtin types, basic `sys`, basic `math`.

## `works-native-only/`

**Current nanopython, but only the native build.** The wasm build hits a documented architectural blocker.

Mostly programs that raise exceptions caught by a `try/except` going through C-NORETURN raise paths (vendor C still uses `nlr_jump` → `longjmp` for some paths). Native unwinds; wasm cannot.

Closing this profile requires the emscripten-sjlj runtime arc.

## `needs-stdlib/`

**Adds pure-Python stdlib stubs for algorithm primitives.**

Required modules (each ~50-200 LOC of pure Python):
- `heapq` — binary heap operations
- `bisect` — binary insertion into sorted lists
- `collections.Counter` (we have `deque` already)
- `itertools.starmap`, `itertools.chain`, etc. (we have some)

Implementation: frozen Python modules bundled into the binary. The mechanism isn't wired in the embed port today; adding it is a one-time infrastructure cost, after which adding more modules is trivial.

## `needs-grammar/`

**Adds grammar features that today's parser rejects.**

- Walrus operator (`:=`): MicroPython doesn't ship it.
- Match statement (`match/case`): MicroPython doesn't ship it.
- PEP 604 union types (`int | str` in non-`__future__` files).

Each requires parser grammar changes coordinated with vendor grammar tables.

## `needs-async/`

**Adds `async def` / `await` / `async for` / `async with`.**

Vendor has `MICROPY_PY_ASYNC_AWAIT` but enabling it under nano shifts the grammar enum layout, which our strangled parser has cached the values of. Requires coordinated grammar regen + per-PN-kind audit.

Once enabled, the actual coroutine runtime is provided by vendor; we just need to un-gate `if (build_options.is_full and pnsKind(...) == PN_async_funcdef)` in `compile.zig`.

## `needs-fs/`

**Adds file-system I/O.** `open()`, `file.read()`, `file.write()`.

Requires:
- `mp_sys_stdin_obj` / `_stdout_obj` / `_stderr_obj` symbol definitions (wasi-fd wrappers).
- Builtin `open()` wired to the WASI file APIs.
- `MICROPY_PY_IO_FILEIO=1`.

On native this is straightforward; on wasm it depends on what filesystem access the host (browser, wasmtime) provides.

## `needs-mpz/`

**Adds arbitrary-precision integers (beyond 2^63).**

Today nanopython has LONGLONG on wasm (2^63 ceiling) and NONE on native (62-bit smallint). Both cover all realistic web-developer values. `needs-mpz/` would only include programs that genuinely use larger numbers (crypto, factorials of large N, etc.).

Requires `MICROPY_LONGINT_IMPL=MPZ` + a corpus refresh.

## `disagreement/`

**Not a feature gap — a question.**

When MicroPython and CPython produce different output for the same program, we have a decision to make: follow MicroPython (matches the strangler reference) or CPython (matches user expectation). The program lands here while we decide.

Common cases:
- Error messages: CPython is more informative.
- `dict` ordering in some edge cases.
- Specific corner cases of integer formatting.

Each program in this bucket has a `# golden: disagreement=...` comment summarizing the divergence.
