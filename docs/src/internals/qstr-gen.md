# qstr Generation

MicroPython interns every name the runtime looks up (methods, attributes, modules, error messages) as a qstr: an immutable string with a small integer ID. Comparing two qstrs is an integer compare, which keeps attribute lookup cheap. C code names them with macros such as `MP_QSTR_print` or `MP_QSTR___init__`.

## How MicroPython collects them

The IDs come from `qstrdefs.generated.h`, which `make port` builds with vendor's `py/makeqstrdefs.py`. The scanner preprocesses every C source, collects each `MP_QSTR_<name>` it finds, and assigns IDs to the deduplicated set. A name that no C file mentions gets no ID, and code that uses it fails to compile with `'MP_QSTR_<name>' undeclared`.

The scanner reads only C, so a Zig module that uses `mp.MP_QSTR_threshold` is invisible to it. Early Zig ports kept a small "tombstone" `.c` file next to each module just to mention its qstrs and its `MP_REGISTER_MODULE` line.

## Shadow blocks

`tools/zig_qstr_shadow.py` removes the need for those files. A Zig source declares the qstrs it needs in a comment block:

```zig
// __qstr_shadow_begin__
// #if MICROPY_GC_ALLOC_THRESHOLD
// MP_QSTR_threshold
// #endif
// __qstr_shadow_end__
```

The script reads every `src/**/*.zig`, and writes one generated C file (`port/build-embed/zig_qstr_shadow.c`) that `port/Makefile` adds to the scanner's input. Inside a block, after the `//` or `//!` prefix is stripped:

- a bare `MP_QSTR_<name>` becomes a `__attribute__((used))` constant that references it;
- preprocessor lines (`#if`, `#endif`) are copied as they are, so a qstr can follow the same config gate as vendor C;
- any other line is copied verbatim, which is how a Zig module registers itself (`MP_REGISTER_MODULE(MP_QSTR___main__, mp_module___main__);`).

## Limits

- **The gate has to match vendor's.** Blocks are emitted unconditionally and the preprocessor does the gating. A wrong macro name in `#if` drops the qstr without any warning.
- **New `.zig` files need `make port`.** The list of Zig sources is computed when the Makefile is parsed, so an incremental build does not see a new file.
- **The module table stays in C.** `makemoduledefs.py` emits the registered-modules table as a C initializer, consumed by `src/objects/objtype/objmodule_shim.c`. Moving that file to Zig would need a generator that emits Zig, which the project has not written.
- **Blocks are explicit on purpose.** Scanning Zig for every `mp.MP_QSTR_X` would also anchor names that a module only probes with `@hasDecl`, and pull in qstrs that the current config does not have.

## See also

- [`tools/zig_qstr_shadow.py`](https://github.com/abilian/petitpy/blob/main/tools/zig_qstr_shadow.py) and [`port/Makefile`](https://github.com/abilian/petitpy/blob/main/port/Makefile)
- Upstream [`py/makeqstrdefs.py`](https://github.com/micropython/micropython/blob/master/py/makeqstrdefs.py)
- [The strangler journey](../strangler-journey.md)
