# Internals

_For contributors. If you use petitpy without modifying it, the [Architecture](../architecture.md) page is the right level of detail. This section goes one layer deeper, into the mechanisms a contributor meets when porting or extending a subsystem._

## In this section

- [Type Mirrors](mirrors.md): the `extern struct` declarations that give Zig MicroPython's struct layouts
- [PyError Convention](pyerror.md): how Zig code raises and propagates Python exceptions without setjmp/longjmp
- [Persistentcode Loader](persistentcode.md): the `.mpy` loader
- [qstr Generation](qstr-gen.md): how Zig modules get their interned names and module registrations
- [Wasm Composition](wasm-composition.md): what makes up the wasm binary and how to measure it

## Cross-cutting conventions

### `Obj = usize`

A Python object is a `usize` in Zig, whatever it encodes: a tagged small int, a tagged qstr, or a pointer to a heap object. This is MicroPython's default representation (REPR_A), used by both configs. Use the helpers in `mp_mirrors.zig` instead of doing the bit-twiddling by hand:

```zig
const a = mirrors.objFromQstr(MP_QSTR_print);
const b = mirrors.objFromPtr(&some_heap_obj);
const c = mirrors.newSmallInt(42);
```

### `PyError!T` for functions that can raise

A Zig function that can raise returns `pyerr.PyError!T` and propagates with `try`. The exception object sits in `pyerr.pending_exc`. At a C-ABI export, `pyerr.bridge` turns the error into a zero return value:

```zig
pub export fn npy_compute(arg: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, computeImpl(arg));
}
```

See [PyError Convention](pyerror.md).

### `callconv(.c)` and `extern struct`

Functions the runtime reaches through a C-shaped table (type slots, function objects) or through a C declaration use `callconv(.c)`. Structs that C code also reads or writes are declared `extern struct`, which gives them C field order and padding. See [Type Mirrors](mirrors.md).

### Remaining vendor C

The build lists its C sources explicitly in `build.zig`. Three project-local `.c` files compile in every build, and some vendor files come back in per arm:

| When | Vendor files |
|---|---|
| always | `py/objfloat.c`, `py/formatfloat.c` |
| `feature-re=true` (the default) | `extmod/modre.c` |
| nano on wasm32 (MPZ ints) | `py/objint.c`, `py/objint_mpz.c`, `py/mpz.c` |
| `-Dconfig=full` | `py/objint.c`, `py/objint_mpz.c`, `py/mpz.c`, `py/modio.c`, `py/objstringio.c`, `py/builtinhelp.c`, `py/warning.c` |

The choice is made per file: compact subsystems were ported to Zig, and large, well-tuned engines such as the MPZ bignum code are reused. See [Architecture](../architecture.md#the-residual-c).

Design decisions are recorded in the [ADR series](../adrs/index.md).
