# Internals

_For contributors. This section examines the patterns and mechanisms that make the strangler work. If you use petitpy without modifying it, the [Architecture](../architecture.md) page is the right level of detail; this section is one layer deeper._

## In this section

- [Type Mirrors](mirrors.md): `mp_mirrors.zig`, the ~40 `extern struct` declarations that make Zig speak MicroPython's struct layouts
- [PyError Convention](pyerror.md): the `error{PyRaise}!T` propagation that replaced MicroPython's setjmp/longjmp NLR
- [Persistentcode Loader](persistentcode.md): the `.mpy` loader, fully Zig
- [qstr Generation](qstr-gen.md): how `tools/zig_qstr_shadow.py` lets Zig modules participate in MicroPython's qstr/module tables
- [Wasm Composition](wasm-composition.md): the wasm binary's section-by-section breakdown + the size-cut opportunity catalog ([ADR 007](../adrs/007-wasm-fat-loss.md))

## Why an "internals" section

The architecture pages cover *what* petitpy is. The internals pages cover *how* specific subsystems work. They're aimed at:

- People who want to port a new MicroPython subsystem to Zig (the patterns matter).
- People debugging unexpected behavior (knowing the polled-sentinel mechanism helps when a `MP_OBJ_NULL` propagates farther than expected).
- People extending petitpy (e.g., adding a new builtin module: the qstr-gen page covers that).

For the casual reader, the architecture + strangler-journey pages are enough.

## Cross-cutting conventions

A few rules thread through all the internals:

### `Obj = usize`

The Zig type for "any Python object" is always `usize`. No matter what the value points to (a small-int via low-bit-tagged encoding, a qstr via byte-tagged encoding, or a heap object via aligned pointer), it's stored as a `usize` in Zig.

Helper conversions live in `mp_mirrors.zig`:

```zig
const obj = mirrors.objFromQstr(MP_QSTR_print);   // qstr to Obj
const obj = mirrors.objFromPtr(&some_heap_type);  // pointer to Obj
const obj = mirrors.newSmallInt(42);              // smallint to Obj
```

This is REPR_A, MicroPython's default object representation. Both nano and full configs use REPR_A.

### `PyError!T` for raisable Zig fns

If a fn can raise a Python exception, its Zig signature returns `pyerr.PyError!T`, where a non-raising one returns `T`. The error is `error.PyRaise`; the exception object is stored in `pyerr.pending_exc` (a threadlocal `usize`).

```zig
fn computeImpl(arg: Obj) PyError!Obj {
    if (bad(arg)) try raiseTypeErrorBadArg();
    return result;
}
```

At C-ABI boundaries, `pyerr.bridge` catches `PyError` and returns the appropriate zero-sentinel:

```zig
pub export fn npy_compute(arg: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, computeImpl(arg));
}
```

See [PyError Convention](pyerror.md).

### `callconv(.c)` for ABI exports

Every Zig function the runtime expects to call (whether from C, when C still existed, or from a function-pointer table) is marked `callconv(.c)`:

```zig
pub export fn mp_load_global(qst: Qstr) callconv(.c) Obj { ... }
```

Forgetting `callconv(.c)` is a common source of subtle bugs: Zig's default calling convention may pack arguments differently than C.

### `extern struct` for vendor C struct mirrors

When Zig needs to read/write a struct that MicroPython C also reads/writes, the Zig declaration uses `extern struct`:

```zig
pub const MpRawCode = extern struct {
    proto_fun_indicator: [2]u8,
    kind: u8,
    is_generator: bool,
    fun_data: ?*const anyopaque,
    children: [*c]?*MpRawCode,
};
```

`extern struct` guarantees C-compatible field ordering and padding. Combined with `@sizeOf` / `@offsetOf` checks in `assertLayout()`, it catches any drift from vendor's struct.

See [Type Mirrors](mirrors.md).

### Vendor C inclusion

The build uses explicit per-arm `addCSourceFiles` lists. Under `-Dconfig=nano` with default flags the core interpreter compiles no vendor C. Three project-local `.c` files (616 LOC) and the default-on `float` and `re` carveouts (~1,900 LOC of vendor C) still compile. See [Architecture](../architecture.md#the-residual-c).

Per-feature carveouts pull individual vendor `.c` files back in:

| Carveout | Files |
|---|---|
| `feature-longint=true` (auto for wasm32-nano) | `py/objint.c`, `py/objint_longlong.c` |
| `feature-float=true` (auto for nano) | `py/objfloat.c`, `py/formatfloat.c` |
| `-Dconfig=full` | `py/objint.c`, `py/objint_mpz.c`, `py/mpz.c`, `py/modio.c`, `py/objstringio.c`, `py/builtinhelp.c`, `py/warning.c` |

The choice of "port vs re-use vendor" is per-file: small focused subsystems are ported (parser, VM, type system); large well-tuned arithmetic engines (MPZ) are re-used as vendor carveouts.

### The decision record

Every architectural decision is documented in the [ADR series](../adrs/index.md) (Architecture Decision Record):

- ADR 001: v0.4 roadmap (closed)
- ADR 002: feature selection (per-feature `-D` flags + frozen nano profile)
- ADR 003: library + module loading (frozen-tiny + lazy-fetch)
- ADR 004: benchmarking methodology
- ADR 005: future optimization landscape (PROTO)
- ADR 006: JS interop bridge
- ADR 007: wasm fat loss
- ADR 008: golden program tracking
- ADR 009: v0.5 roadmap (now closed with §11 retrospective)
- ADR 010: v0.6 roadmap (current)
