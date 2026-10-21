# pyfront

An alternative front-end for nanopython: Python source in, MicroPython `.mpy` v6 out, in pure Python.

The runtime already splits at the bytecode boundary (see `notes/plans/adr-017-bytecode-boundary.md`), which makes `.mpy` an interface rather than an internal detail. `zigpy-compile` is the Zig front-end; this is a second one, written to a different design, so the boundary gets exercised by something that shares no code with it.

It compiles a subset, not the language. What it does not handle it refuses by name, so an unsupported construct is a `pyfront: unsupported: ...` on stderr and exit 2, never bytecode that runs and computes the wrong answer.

## Use

```bash
uv run pyfront hello.py -o hello.mpy
../../zig-out/bin/nanopython-vm hello.mpy
```

Exit codes: `0` compiled, `2` refused by name (an unsupported construct, or a `SyntaxError` from CPython's parser). Anything else is a bug in pyfront.

## What it covers

Of the 67 constructs in `tools/capability_matrix.py`, pyfront compiles 65, and both back-ends run the result with output matching CPython. The two it declines are below; `notes/14-capability-matrix.md` carries the full table.

The compiled subset spans assignment and arithmetic, control flow, functions and closures, classes and inheritance, dunder methods, comprehensions of all four kinds, generators, `try`/`except`/`finally`, `with`, f-strings including format specs, decorators, default arguments, `*args`/`**kwargs` in both signatures and calls, the walrus, chained comparisons, unpacking, `global`/`nonlocal`, lambdas, and `match`.

## What is missing

Two constructs the Zig front-end compiles and pyfront does not:

| construct | why |
| --- | --- |
| `async def`, `await`, `async for`, `async with` | needs coroutine emission pyfront has no path for. MicroPython itself compiles `async def` to a generator |
| zero-argument `super()` | the vendor compiler rewrites it to `super(__class__, self)`, which needs the class body to bind `__class__` as a cell. pyfront's class body compiles as a plain function, so the rewrite would raise `NameError` at run time. Write `super(Class, self)` |

Refused within otherwise-supported constructs — each a decision, not a backlog:

- **Patterns**: more than one star in a sequence, `**` captures in a mapping (`case {"k": v, **rest}`), positional class sub-patterns (`case P(1)`). The Zig front-end refuses the same set, deliberately, so the capability matrix reads one gap rather than two.
- **Assignment**: starred targets (`a, *b = ...`); `del` of anything but a name, attribute or subscript.
- **Functions**: positional-only and keyword-only parameters; lambda signatures beyond plain positional arguments.
- **Classes**: class decorators; class keyword arguments (`metaclass=`).
- **Comprehensions**: async comprehensions; generator expressions with more than one `for`.
- **Other**: `**` unpacking in a dict display, `with` statements with more than one item, `try` without `except`, a bare `except` that is not the last handler, f-string conversions (`!r`/`!s`/`!a`), and format specs containing a nested expression.

Jump offsets beyond the two-byte range are also refused. That is a real ceiling on function size, not a language limit.

`TypeAlias`, `TryStar`, t-strings and type comments are out of scope, recorded as such in `tests/test_coverage.py`.

## Why astero

Two passes need facts about Python's grammar that are tedious and error-prone to hand-maintain:

- **Scope analysis.** Which names a function binds decides `LOAD_FAST` versus `LOAD_GLOBAL`, and getting it wrong produces a program that runs and computes the wrong answer. `astero.scopes.scope_tree` answers it from the grammar.
- **Dispatch coverage.** `astero.coverage` fails the test suite when the AST grows a production this compiler does not handle, so an unsupported construct is a named refusal instead of silently wrong bytecode.

astero is a path dependency under active development, and its module layout moves. Two breakages so far — `astero.lang_py` to `astero.python.lang`, then `astero.hygiene` to `astero.python.hygiene` — each breaking every import at once. `make check-capability` now stops on a pyfront exit code other than 0 or 2, because a broken pyfront otherwise reads as 65 front-end gaps and the gate passes.

## Layout

Two halves, and the dependency runs one way. `emit/` knows what MicroPython consumes and nothing about the language that produced it; `compile/` works through it and never writes bytes itself. `tests/test_layering.py` enforces that — a stray `import ast` under `emit/` fails the suite.

| file | what it does |
| --- | --- |
| `errors.py` | `Unsupported`, the one exception raised on purpose |
| `cli.py` | the `pyfront` command |
| **`emit/`** | **the `.mpy` side — never imports `ast`** |
| `emit/bytecode.py` | opcodes, var-int encodings, the prelude signature and size encoders |
| `emit/mpy.py` | the `.mpy` v6 container: header, qstr table, constant table, raw-code tree |
| `emit/code.py` | the per-scope buffer: emission, stack accounting, jump patching |
| `emit/scopes.py` | qstr interning and the per-scope name tables |
| **`compile/`** | **the `ast` side — one method per production** |
| `compile/driver.py` | `Compiler`: one per module, a child scope per function |
| `compile/analysis.py` | is this scope a generator, what does it capture, what does it bind |
| `compile/statements.py` | one method per statement production |
| `compile/expressions.py` | one method per expression production |
| `compile/patterns.py` | `match`, desugared to if/elif |

That split is worth keeping honest: pyfront exists to be a *second*, independent front-end for the same bytecode boundary. If the format half stops being separable from the compiler half, it can no longer be tested alone, reused by a disassembler, or pointed at another source language.

## Tests

```bash
uv run pytest              # 408 cases
uv run pytest -m unit      # 275: no subprocess, no VM — about 1s
uv run pytest -m e2e       # 114: the real binary, and CPython
uv run tepyd report        # pyramid shape
```

The tree mirrors the source tree, so a package with no tests shows as an empty directory rather than an absence.

| where | what it proves |
| --- | --- |
| `a_unit/emit/test_mpy.py` | the constant table byte for byte — tags, the NUL terminator, big-int text, interning by (type, value) |
| `a_unit/emit/test_code.py` | stack accounting, and the two-byte jump range that is the real ceiling on scope size |
| `a_unit/emit/test_bytecode_vendor.py` | every opcode and encoding constant re-derived from the vendor headers, so a drifting `bc0.h` fails the suite instead of producing subtly wrong bytecode |
| `a_unit/compile/test_compiles.py` | every corpus program compiles to a container that decodes *exactly* — no VM needed to catch a truncated payload or a missing terminator |
| `a_unit/compile/test_refusals.py` | every refusal promised above, plus a supported neighbour for each so the suite cannot pass by refusing everything |
| `a_unit/compile/test_dispatch_coverage.py` | the astero ledger: a production nobody thought about is distinguishable from one deliberately left out |
| `a_unit/test_layering.py` | `emit/` never imports `ast` |
| `c_e2e/compile/test_differential.py` | compile, run on `nanopython-vm`, compare against CPython — the only tier that can say the bytecode is *right* |
| `c_e2e/test_cli.py` | the exit-code contract above |

`tests/programs.py` holds the construct corpus and `tests/mpy_reader.py` a validating `.mpy` reader; both tiers use them. Line coverage is 93% from the unit tier alone, 94% overall.

A caveat on `tepyd report`: it measures test *mass* per tier by directory, and a fixture shared between tiers belongs to neither. The corpus is ~200 lines, so compile's reported test/src ratio understates by roughly that much.
