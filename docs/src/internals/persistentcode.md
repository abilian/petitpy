# Persistentcode Loader (`.mpy` Loader)

`src/runtime/persistentcode.zig` is the Zig port of the load half of MicroPython's `py/persistentcode.c`. It turns `.mpy` bytes into the runtime's raw-code structures, ready for the VM.

## Where it sits

The compiler never hands the VM a data structure directly. It emits a `.mpy` byte stream, and the loader reads it back with `mp_raw_code_load_mem`. Every code path goes through it: running a script, `exec`/`eval`, `import` of a `.py` file (compiled in memory first), and `import` of a precompiled `.mpy`. Because the in-memory format is the on-disk format, the same loader serves both.

## The format

A `.mpy` file (version 6) starts with a four-byte header: `'M'`, the version, a byte that encodes the native architecture, and the small-int width in bits. Then come a qstr table, a table of constant objects (strings, bytes, ints, floats, tuples), and a tree of raw codes, one per function or class body, each with its bytecode and its children. Lengths are 7-bit continuation varints, and each function's bytecode starts with a bit-packed prelude (state size, exception-stack depth, argument counts, scope flags).

## What the port covers

Only what petitpy needs:

- **Load only.** There is no save path; the Zig compiler writes `.mpy` itself (`src/compiler/mpy.zig`).
- **Bytecode only.** The header must declare no native architecture, and every raw code must be bytecode. Anything else raises `ValueError("incompatible .mpy file")`.
- **No ROM mapping.** Bytecode is always copied into the heap.

The file keeps vendor's structure and function names (`read_uint`, `load_qstr`, `load_obj`, `load_raw_code`, `mp_raw_code_load`), and comments cite the vendor line ranges, so it can be read side by side with the C original.

## Differences from vendor C

- **No leak on error.** `load_raw_code` allocates the bytecode buffer and the children array, then recurses. In C, a raise inside the recursion longjmps past both allocations. The Zig version frees them with `errdefer`.
- **Checked size arithmetic.** The children-array size is computed with `std.math.mul`, so a huge child count in a corrupt file raises instead of overflowing.
- **Wide prelude counters.** The prelude decoder keeps its continuation counter in a `u32` and casts at each shift, so a malformed prelude with many continuation bytes panics in safe builds instead of wrapping.

## Limits

- **Treat `.mpy` input as trusted.** The loader checks the header and the children-array size, but it does not validate the rest of the stream against its length.
- **The small-int width check is fixed at 63 bits**, the 64-bit value. A file that claims a wider width is rejected; on wasm32, where small ints are narrower, the check is looser than it should be.

## Tests

`src/tests.zig` has unit tests for `read_uint` around the varint byte boundaries and for both prelude decoders, including continuation bytes. The rest of the loader runs on every corpus test, since every program passes through it before it executes.

## See also

- [`src/runtime/persistentcode.zig`](https://github.com/abilian/petitpy/blob/main/src/runtime/persistentcode.zig)
- Upstream [`py/persistentcode.c`](https://github.com/micropython/micropython/blob/master/py/persistentcode.c)
- [The strangler journey](../strangler-journey.md)
