# Contributing

_For developers modifying the runtime or adding features. If you just want to use petitpy, [Getting Started](getting-started.md) is shorter. If you want to understand the architecture before reading this, start with [Architecture](architecture.md)._

## The one rule

**`make` must end with exit 0.** This is the strangler invariant + the four-gate test harness combined. Any commit that breaks it is broken; either fix it or revert.

If your change passes `make`, it's compatible with the project.

## Workflow

1. Make your change.
2. Run `make`.
3. If green, commit. If red, debug or revert.

For larger changes:

```sh
make rebuild         # clean rebuild (in case caches misled you)
make                 # the full aggregate gate, ~37s
```

If a gate regresses but you're not sure which test:

```sh
make verify          # per-test PASS/FAIL list — names each native miss
make wasm-check      # same idea for the wasm arm
```

Diff the output against a known-good run to localize the regression.

## Project conventions

### Surgical changes

Touch only what your change requires.

- No "improving" adjacent code, comments, or formatting.
- No refactoring of things that aren't broken.
- Match existing style even if you'd do it differently.
- If you notice unrelated dead code, mention it; don't delete it as part of an unrelated change.

The test: every changed line should trace directly to the request.

### Surgical commits

Make one conceptual change per commit. The commit history is the project's actual journal; commits like `fix(strings): str.splitlines(False) now strips line endings — flag value bug` are easy to bisect against. Don't bundle unrelated changes.

Commit-with-hooks-disabled is the project convention (hooks have corrupted byte-exact `corpus/nano/basics/*.out` fixtures in the past):

```sh
git -c core.hooksPath=/dev/null commit --no-verify -m "msg"
```

Do not add `Co-Authored-By` trailers unless explicitly asked.

### The `_ = &func;` rule

When you write a comptime force-analyze block, use the address-of variant:

```zig
// CORRECT — forces full Zig body analysis
comptime { _ = &myFn; }

// WRONG — silently fake-green
comptime { _ = myFn; }
```

The wrong form silently passes the compile without checking the body. This has caused undetected regressions.

### Corpus golden files are sacred

`corpus/nano/basics/*.out` and `corpus/full/basics/*.out` are **byte-exact binary fixtures**. Never run formatters, trailing-whitespace tools, or line-ending normalizers over them. `make lint` and `make fmt` exclude them by design.

Regenerating goldens is the `make freeze` target, **only** after an intended config change. Re-freezing from a broken binary destroys the oracle.

### Don't touch `sandbox/` or `vendor/`

- `sandbox/micropython` is a **symlink** to a 2.6 GB external clone. Gitignored.
- `vendor/` is **generated** by `make port`. Gitignored. Regenerable from `sandbox/micropython` + `port/mpconfigport.h`.

If you need to change MicroPython config behavior, edit `port/mpconfigport.h` and regenerate via `make port`.

### Don't push problems under the rug

The project surfaces work-in-progress explicitly. If you discover a real failure that's deferred work:

- List it in the matching `corpus/*-known-fails.txt` with a reason AND in the relevant ADR.
- Reference where the work is tracked.
- Don't add a SKIP-style guard or an unexplained `// TODO` to keep the suite green.

The rule of thumb: would a future maintainer be surprised by this? If yes, surface it.

### Markdown soft-wrap

All markdown in this project uses soft-wrap, so one paragraph is one long line. Your editor's word-wrap handles the display.

## Common patterns

### Adding a new builtin or builtin method

The shortest path:

1. Add the implementation in the appropriate `src/objects/*.zig` or `src/modules/*.zig`.
2. Wire any new qstrs through the `__qstr_shadow_begin__` / `__qstr_shadow_end__` block convention so `tools/zig_qstr_shadow.py` registers them.
3. Add at least one regression pin in `tests/integration.py`.
4. Run `make`.

Working examples to copy from: `str.ljust`/`str.rjust`/`str.isalnum` (added in v0.5), `chr()` Unicode range (also v0.5), `collections.deque`'s CPython-friendly `(iterable)` signature.

### The PyError convention

If your fn can raise a Python exception, return `PyError!T`, and avoid `T` with a polled side-channel:

```zig
const pyerr = @import("../pyerr.zig");
const PyError = pyerr.PyError;

// Per distinct exception+message, a small raise helper at file top:
fn raiseValueErrorBadX() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_ValueError, "bad x");
    return error.PyRaise;
}

// Internal fn returns PyError!T:
fn xImpl(arg: Obj) PyError!Obj {
    if (bad(arg)) try raiseValueErrorBadX();
    return compute(arg);
}

// C-ABI export wraps with pyerr.bridge:
pub export fn npy_x(arg: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, xImpl(arg));
}
```

For void exports: `pyerr.bridge(void, xImpl(...))`.

For exports referenced via `@ptrCast` in ROM tables: split into `Impl` + thin C-ABI shim.

### Adding a new module-registered Zig module

Use the `__qstr_shadow_*` block convention so `tools/zig_qstr_shadow.py` registers the qstrs + module:

```zig
//! my module ...
//!
//! __qstr_shadow_begin__
//! #if MICROPY_PY_MYMODULE
//! MP_QSTR_mymodule
//! MP_QSTR_myfunc
//! MP_REGISTER_MODULE(MP_QSTR_mymodule, mp_module_mymodule);
//! #endif
//! __qstr_shadow_end__
```

The shadow generator picks this up at `make port` time. See `src/modules/modgc.zig` and `src/modules/modmath.zig` for working examples.

### Adding a unit test

Append a `test "..." { ... }` block in-line in any module under `src/`:

```zig
test "vstr_init produces a usable buffer" {
    const std = @import("std");
    const testing = std.testing;
    var v: VstrLocal = undefined;
    vstr_init_len(&v, 10);
    try testing.expect(v.alloc >= 10);
}
```

Test discovery is automatic via `build.zig`'s `addTest` step. Run with `make test-unit-vm` or `make test-unit-compiler`.

### Adding an integration smoke test

Edit `tests/integration.py`:

```python
("my_test_case",
 "x = 5\nprint(x * 2)",
 "10\n"),
```

If the exit code matters, use the 4-tuple form:

```python
("my_test_exits_7",
 "import sys; sys.exit(7)",
 "",
 7),
```

Run with `make test-integration` (native) or `make test-integration-wasm` (wasm). Every bug fix should ship with a regression pin here.

## What if I want to land a big change?

Bigger changes often need to land in multiple commits, each individually green. The pattern:

1. **Split** the change into commits that each pass `make` independently.
2. **Order** them so the green sequence makes sense (e.g., add the new helper first, then the migration that uses it).
3. **Verify** at each commit.

If you can't split a change into green intermediates, it's probably too coupled and needs a design rethink.

## Where to ask

The project is built mostly via solo + AI-assisted development. There's no formal community forum yet. Issues and discussion are welcome at the upstream repo.

## License

Contributions are accepted under the MIT license, inherited from MicroPython.
