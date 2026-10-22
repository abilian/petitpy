# Contributing

_For developers changing the runtime. To use petitpy, [Getting Started](getting-started.md) is shorter. For the structure of the code, read [Architecture](architecture.md) first._

## The one rule

**`make` must exit 0.** It builds, runs the tests, both corpus gates, the wasm gates and lint. A commit that breaks it is broken: fix it or revert it.

## Workflow

1. Make your change.
2. Run `make`.
3. If it is green, commit. If not, debug or revert.

`make rebuild` cleans the caches and rebuilds, when you suspect a stale build. When a gate fails and you need to know which test, `make verify` lists PASS/FAIL per test on native, and `make wasm-check` does the same on wasm.

## Rules

### Change only what you need

Touch only what your change requires. Don't reformat or refactor adjacent code, and match the existing style. If you notice unrelated dead code, mention it rather than deleting it.

### One change per commit

Each commit holds one change and passes `make` on its own, so the history can be bisected. Split a large change into a sequence of green commits, for example the new helper first and then the code that uses it. If it cannot be split that way, it is probably too coupled.

Commit with hooks disabled, since hooks have corrupted the byte-exact fixtures in the past:

```sh
git -c core.hooksPath=/dev/null commit --no-verify -m "msg"
```

Don't add `Co-Authored-By` trailers unless asked.

### Use `_ = &func;` to force analysis

In a comptime force-analyze block, take the address:

```zig
comptime { _ = &myFn; }  // analyzes the body
comptime { _ = myFn; }   // compiles without checking the body
```

The second form passes silently and has hidden regressions.

### Corpus fixtures are byte-exact

`corpus/basics/*.py` are verbatim copies of upstream MicroPython tests, and `corpus/nano/basics/*.out` and `corpus/full/basics/*.out` are the expected outputs, byte for byte. Never run formatters, whitespace or line-ending tools over them; `make lint` leaves them alone. Regenerate the outputs with `make freeze` only after a deliberate change in behaviour, in the same commit. Freezing from a broken binary destroys the oracle.

### Leave `vendor/` and `sandbox/` alone

- `vendor/micropython` is the upstream clone pinned by `MICROPY_REV`, created by `make bootstrap` or a symlink to an external checkout.
- `vendor/micropython_embed` is generated from it by `make port`.
- `sandbox/` is local scratch. Nothing a build or a gate needs may live there.

All three are gitignored. To change MicroPython's configuration, edit `port/mpconfigport.h` and run `make port`.

### Make deferred work visible

When a failure is intentional (an unimplemented feature, a design choice), list it in the matching `corpus/*-known-fails.txt` with a reason, and record it in the relevant ADR. Never hide it behind a skip or an unexplained `// TODO`. The full and wasm gates are strict both ways: a new failure fails the gate, and so does a test that now passes but is still listed. Remove it from the list in the same commit.

### Markdown is soft-wrapped

One paragraph is one line.

## Common tasks

### Add a builtin or a method

1. Implement it in the matching `src/objects/` or `src/modules/` file.
2. Declare any new qstr in a shadow block (below).
3. Add a regression case to the integration tests.
4. Run `make`.

### Raise a Python exception

A function that can raise returns `PyError!T`. Set the pending exception, then return `error.PyRaise`; the C-ABI export converts the result with `pyerr.bridge`:

```zig
const pyerr = @import("../pyerr.zig");
const PyError = pyerr.PyError;

fn raiseValueErrorBadX() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_ValueError, "bad x");
    return error.PyRaise;
}

fn xImpl(arg: Obj) PyError!Obj {
    if (bad(arg)) try raiseValueErrorBadX();
    return compute(arg);
}

pub export fn npy_x(arg: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, xImpl(arg));
}
```

A void export uses `pyerr.bridge(void, ...)`. A function referenced through `@ptrCast` in a ROM table is split into the `Impl` and a thin C-ABI shim. See [Internals: PyError](internals/pyerror.md).

### Register qstrs and a module from Zig

MicroPython's qstr scanner reads only C, so a Zig file declares its qstrs, and a module its registration, in a comment block that `tools/zig_qstr_shadow.py` turns into C at `make port` time:

```zig
// __qstr_shadow_begin__
// #if MICROPY_PY_MYMODULE
// MP_QSTR_mymodule
// MP_QSTR_myfunc
// MP_REGISTER_MODULE(MP_QSTR_mymodule, mp_module_mymodule);
// #endif
// __qstr_shadow_end__
```

`src/modules/modmath.zig` has an example. See [qstr Generation](internals/qstr-gen.md).

### Add a unit test

Put a `test "..." { ... }` block next to the code in any file under `src/`. `build.zig` discovers it. Run `make test-unit`, or `make test-unit-vm` / `make test-unit-compiler` for one side.

### Add an integration test

Add a case to `CASES` in `tests/test_integration_core.py`, or `tests/test_integration_os.py` for OS features:

```python
("my_test_case", "x = 5\nprint(x * 2)", "10\n"),
("my_test_exits_7", "import sys; sys.exit(7)", "", 7),  # checks the exit code
```

Run `make test-integration` (native) or `make test-integration-wasm`. Every bug fix comes with a case here.

## Where to ask

There is no forum yet. Issues and discussion are welcome on the repository.

## License

Contributions are accepted under the MIT license, inherited from MicroPython.
