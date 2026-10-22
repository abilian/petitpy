# Architecture

_For contributors and anyone who wants to understand how the runtime is structured. To run Python in a browser tab, [Getting Started](getting-started.md#python-in-the-browser) is shorter. For compatibility with MicroPython, see [vs MicroPython](comparison-micropython.md)._

## Overview

petitpy has two halves that share one source tree:

- **The compiler** (`src/compiler/`) is pure Zig. It lexes and parses Python source, runs scope analysis and emits MicroPython `.mpy` bytecode. The parser is a Zig port of MicroPython's `parse.c`. Its grammar is upstream's `grammar.h`, patched at `make port` time (`port/grammar-patched/`) to accept `{**d}` dict unpacking and PEP 570 positional-only `/` markers. It ships as the standalone `zigpy-compile` binary and is linked into the interpreter.
- **The VM** (`src/runtime/`, `src/objects/`, `src/modules/`, `src/memory/`) loads bytecode, runs the bytecode interpreter, and implements the object model, the allocator and the garbage collector. It is Zig apart from the residual C described below.

The main binary (`zig-out/bin/nanopython`) contains both and calls the compiler at run time to compile source. A VM-only binary, `nanopython-vm`, loads `.mpy` files. Keeping the compiler separate means it can be tested on its own, and the VM can be checked against bytecode from MicroPython's own `mpy-cross`.

The [ADR series](adrs/index.md) records the decisions behind this page.

## How it was built

The codebase is the result of an incremental C-to-Zig strangler of MicroPython, checked against a byte-exact differential test corpus. For each MicroPython subsystem, a Zig module was written with the same link surface as the vendor C file (function signatures and struct layouts), so the C file could be dropped from the build and the Zig module linked in its place. After every change the corpus ran against frozen reference output, and any byte of drift failed the build. This link contract is internal: downstream code should not link against it. [How it was built](strangler-journey.md) tells the story.

## The two configurations

`port/mpconfigport.h` has two arms, selected with `-Dconfig=...`:

- **`full`** (the default) turns on everything available and tracks upstream MicroPython's unix port. Features that have not been ported to Zig, such as bignums (MPZ), `io` and warnings, come from vendor C files that `build.zig` adds only under this config.
- **`nano`** is the minimal arm. Its output must stay byte-identical to the frozen MicroPython reference, which keeps the surface that has to match small. The wasm targets are always built as nano.

### Per-feature build flags

`-Dfeature-*` flags ([ADR 002](adrs/002-feature-selection.md)) turn individual modules on or off on top of the preset: `math`, `collections`, `struct`, `array`, `errno`, `micropython`, `gc-module`, `re`, `warning`, the JS bridge (`js`, wasm only) and the POSIX modules of the full native build (`os`, `time`, `socket`, `select`, `signal`, `pwd-grp`, `subprocess`). `zig build --help` lists them with their defaults. Moving a flag away from its preset default prints a warning that the corpus gate does not cover the resulting build.

## Targets

Native builds run on macOS and Linux, on arm64 and x86_64; CI also cross-compiles for aarch64-linux. The wasm target is wasm32-wasi, run under wasmtime or in the browser through the JS bridge.

## The PyError convention

Errors propagate through Zig error unions, replacing MicroPython's `setjmp`/`longjmp` non-local return (NLR):

```zig
pub const PyError = error{PyRaise};

// Internal fns return PyError!T
fn computeImpl(...) PyError!Obj {
    if (bad) try raiseTypeError(...);
    return result;
}

// C-ABI exports bridge via pyerr.bridge
pub export fn npy_compute(...) callconv(.c) Obj {
    return pyerr.bridge(Obj, computeImpl(...));
}
```

The raised exception is stored in `pyerr.pending_exc`. At a C boundary, `pyerr.bridge(T, r)` turns `error.PyRaise` into a zero value (`MP_OBJ_NULL` for `Obj`), and the C caller checks `pending_exc`. Dropping `setjmp` is what made the wasm target practical, since wasm has no native `setjmp`. See [Internals: PyError Convention](internals/pyerror.md).

## Type mirrors

`src/mp_mirrors.zig` declares Zig `extern struct` types that mirror vendor MicroPython C structs field for field, so Zig reads and writes the same memory as the C code, by name:

```zig
pub const MpRawCode = extern struct {
    proto_fun_indicator: [2]u8,
    kind: u8,
    is_generator: bool,
    fun_data: ?*const anyopaque,
    children: [*c]?*MpRawCode,
};
```

Comptime `@sizeOf` and `@offsetOf` checks make a layout mismatch fail the build instead of corrupting memory at run time. See [Internals: Type Mirrors](internals/mirrors.md).

## The residual C

The core interpreter is Zig: lexer, parser, compiler, emitter, `.mpy` loader, VM, object model, allocator and GC. Some C remains.

Vendor C still compiles for features that were never ported. On both configs this is `float` (`py/objfloat.c`, `py/formatfloat.c`) and the `re` module (`extmod/modre.c`). Nano on wasm adds the long-long integer files. Full adds MPZ bignums, `io`, `help()` and warnings. These are well-tuned upstream code, and reusing them costs less than rewriting them. The lists live in `build.zig`.

Three project-local C files also compile into every build:

- `src/objects/objtype/objmodule_shim.c` holds the built-in module table. It expands `MICROPY_REGISTERED_MODULES`, a macro that MicroPython's build tooling generates and that only resolves inside a C file (see [qstr Generation](internals/qstr-gen.md)).
- `src/objects/strings/va_ops.c` holds the functions that take a `va_list` (`mp_printf`, `mp_vprintf`, `vstr_printf` and the formatted exception constructors), because Zig 0.16 refuses `va_list` on aarch64-linux.
- `src/runtime/nlr_trampoline.c` is the `setjmp` pad from [ADR 013](adrs/013-exception-unwind-vendor-c.md). It lets exceptions raised inside the full config's vendor C reach Python `try`/`except`. The pad is active only on full native builds; elsewhere the wrappers forward the call.

## Testing

Each gate answers a different question: does nano still match the frozen reference byte for byte, does full match its documented baseline, does wasm, does the binary actually start and run real programs, and do the compiler and VM agree with MicroPython's own when mixed. [Build & Test](build-and-test.md) lists the commands. The [golden programs](adrs/008-golden-programs.md) are a separate collection of real Python programs; [`COMPATIBILITY.md`](COMPATIBILITY.md) is generated from them.

## See also

- [Internals: PyError Convention](internals/pyerror.md)
- [Internals: Type Mirrors](internals/mirrors.md)
- [Internals: qstr Generation](internals/qstr-gen.md)
- [Internals: Persistentcode Loader](internals/persistentcode.md)
- [Internals: Wasm Composition](internals/wasm-composition.md)
- [How it was built](strangler-journey.md)
