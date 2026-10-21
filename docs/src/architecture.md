# Architecture

_For contributors and anyone who wants to understand how the runtime is structured. If you just want to run Python in a browser tab, the [Getting Started](getting-started.md#for-web-developers) page is shorter. If you want to embed the native binary in a Linux/macOS scripting context, [vs MicroPython](comparison-micropython.md) covers the compatibility surface._

## Overview

petitpy is a Python interpreter assembled from two cooperating Zig executables sharing one source tree:

- **The compiler** (`src/compiler/`): pure Zig. Lexes Python source, parses to a grammar tree, runs scope analysis, emits MicroPython `.mpy` bytecode. The parser is a Zig port of MicroPython's `parse.c`; the grammar it consumes is upstream's `grammar.h` patched at `make port` time (see `port/grammar-patched/`) to accept PEP 448 dict/list unpack in more positions and PEP 570 positional-only `/` markers. Ships as the standalone `zigpy-compile` binary AND links into the main interpreter.
- **The VM** (`src/runtime/`, `src/objects/`, `src/modules/`, `src/memory/`): Zig with 616 LOC of residual C in three files (§ The residual C). Loads bytecode, dispatches the bytecode interpreter, manages the object model, handles allocator + GC.

The main `petitpy` binary contains both the compiler and the runtime; the runtime calls into the compiler at exec time to compile and run a string. The split matters because the compiler is fully testable in isolation (~93 unit tests across `lexer.zig`, `parser.zig`, `scope.zig`, `emit.zig`, `compile.zig`, `qstr.zig`, `bigint.zig`).

This page covers the central patterns; the [ADR series](adrs/index.md) records the decisions.

## The methodology in one paragraph

The codebase is the result of an incremental C→Zig strangler of MicroPython under a byte-exact differential test corpus. For each MicroPython subsystem, a Zig module was written matching the vendor C file's link surface (function signatures and struct layouts), so the C file could be dropped from the compile graph and the Zig module linked in its place. This is an internal link contract, used during the port and still relied on for the `full` config's residual vendor-C carveouts; it is not a public ABI that downstream code should link against. After every change, all 541 corpus tests ran against a frozen oracle (`corpus/nano/basics/*.out`); any byte drift failed the build. The strangler converged at the long-standing 541/541 invariant. Active work is now on user experience, feature reach, and size; see [ADR 010](adrs/010-roadmap-v06.md).

## The two configurations

`port/mpconfigport.h` has two arms selected via `-Dconfig=...`:

| `nano` (default) | `full` |
|---|---|
| `MICROPY_CONFIG_ROM_LEVEL_MINIMUM` baseline | Everything-on superset |
| Subset of features | Matches CPython more closely |
| The frozen invariant (541/541 byte-identical) | Soft target against upstream MicroPython unix-standard |
| `make check` | `CONFIG=full make check` |

### Why two configs

**`nano`** is the forcing function. It's minimal so the surface that has to stay byte-identical is small. The strangler froze nano-as-baseline early and uses byte-equality against those goldens as the unbreakable invariant.

**`full`** is the parity ceiling. Features like float (under nano too via the FLOAT carveout), complex, io, longint (MPZ), threading all live under `full` via vendor C carveouts that `build.zig` pulls in conditionally. The nano arm uses Zig replacements for almost everything; under full, the appropriate vendor C gets re-added so we match upstream MicroPython where the Zig port hasn't shipped yet.

### Status

| Config | Native | Wasm |
|---|---|---|
| `nano` (default) | **541/541** byte-identical (the strangler invariant) | **490/541** raw, 51-entry baseline green |
| `full` | builds + runs | builds + runs |

## Per-feature build flags

Beyond `-Dconfig`, the build accepts orthogonal `-Dfeature-*` flags ([ADR 002](adrs/002-feature-selection.md)) so a downstream user can pick exactly the surface they need.

| Flag | Module(s) | Default (nano) |
|---|---|---|
| `-Dfeature-math` | `math` | on |
| `-Dfeature-warning` | the warning subsystem | off |
| `-Dfeature-collections` | `collections` (namedtuple, OrderedDict, deque) | on |
| `-Dfeature-struct` | `struct` (binary pack/unpack) | on |
| `-Dfeature-array` | `array.array` | on |
| `-Dfeature-errno` | `errno` constants | on |
| `-Dfeature-micropython` | `micropython` (heap_lock, opt_level) | on |
| `-Dfeature-gc-module` | `gc` module surface | on |
| `-Dfeature-js` | JS interop bridge | wasm only |

Flipping a flag away from its preset default emits a warning that the corpus invariant is not enforced for the resulting build. `nano` (all defaults) is the only frozen-output configuration.

## Target architectures

| Target | Status |
|---|---|
| **arm64-macos** | Tier 1: primary dev platform; 541/541 byte-identical |
| **x86_64-macos** | Tier 1: builds + smoke tested |
| **x86_64-linux** | Tier 1: builds + smoke tested |
| **wasm32-wasi** | Tier 1: the **shipping target**; 346 KB post-`wasm-opt -Oz` |
| **aarch64-linux** | Tier 2: builds via cross-compile; runtime smoke pending a Zig 0.16 toolchain fix |

## The PyError convention

Every error in the runtime propagates via Zig's error union (replacing MicroPython's `setjmp`/`longjmp`-based NLR machinery):

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

`pyerr.bridge(T, r)` catches `error.PyRaise` and returns `std.mem.zeroes(T)` (which is `MP_OBJ_NULL` for `Obj`); the raised exception is stashed in `pyerr.pending_exc`, a polled sentinel that vendor C callers (where any remain, primarily in the float and longint carveouts) check after the call.

Dropping the NLR machinery made wasm targeting straightforward. Wasm lacks a native setjmp, and the previous code path traded setjmp tricks for a runtime trap. See [Internals: PyError Convention](internals/pyerror.md) for the detailed walkthrough.

## Type mirrors

`src/mp_mirrors.zig` holds ~1,200 lines and ~40 `extern struct` definitions that mirror vendor MicroPython C structs field-for-field. Each mirror has `@sizeOf` / `@offsetOf` checks in a comptime block, so a vendor `git pull` that shifts a struct layout fails the build at the right place, where it would otherwise corrupt memory silently.

```zig
pub const MpRawCode = extern struct {
    proto_fun_indicator: [2]u8,
    kind: u8,
    is_generator: bool,
    fun_data: ?*const anyopaque,
    children: [*c]?*MpRawCode,
};
```

This lets Zig read/write the same memory the vendor C code did, by name (the type-mirror pattern).

See [Internals → Type Mirrors](internals/mirrors.md).

## The residual C

The strangler removed vendor C from the core interpreter: lexer, parser, compiler, emitter, `.mpy` loader, VM dispatch, object model, allocator and GC are all Zig. Vendor C did not reach zero, though, because per-feature carveouts are default-on under nano: `float` and `re` on both arms, longint additionally on wasm. Counting what a default `-Dconfig=nano` build actually compiles:

| Layer | Native nano | Wasm nano |
|---|---|---|
| Project-local C (qstr tombstone, `va_list` surface, NLR trampoline) | 616 | 616 |
| Vendor C, `float` carveout (`py/objfloat.c`, `py/formatfloat.c`) | 908 | 908 |
| Vendor C, `re` carveout (`extmod/modre.c` + the re1.5 sources it `#include`s) | 1,009 | 1,009 |
| Vendor C, longint (`py/objint.c`, `py/objint_longlong.c`) | 0 | 861 |
| **Total compiled C** | **2,533** | **3,394** |

The three project-local files are:

| File | LOC | Why it is C |
|---|---|---|
| `src/objects/objtype/objmodule_shim.c` | 86 | The qstr-gen tombstone. Holds `MICROPY_REGISTERED_MODULES`, the macro table listing every available module. `tools/makeqstrdefs.py` (vendor tooling) scans `.c` at build time, never `.zig`. Eliminating it needs a qstr-gen port. |
| `src/objects/strings/va_ops.c` | 406 | The `va_list` surface (`mp_vprintf`, `mp_printf`, `vstr_printf`/`_vprintf`, `mp_obj_new_exception_msg_varg`/`_vlist`). Zig 0.16's `std.builtin.VaList` emits `error: disabled due to miscompilations` on `aarch64-linux` under the LLVM backend. Reverts to Zig when that guard lifts. |
| `src/runtime/nlr_trampoline.c` | 124 | [ADR 013](adrs/013-exception-unwind-vendor-c.md)'s `setjmp`/`longjmp` trampoline, restoring exception unwinding across the `full` profile's vendor-C carveouts. Compiled unconditionally because the Zig side declares its symbols `extern`; never called under nano, where the linker strips it. |

Under `-Dconfig=full` the build pulls in additional vendor C carveouts (MPZ, IO, builtin_help, warning, complex) that we have intentionally not ported. They're well-tuned vendor code, and the parity target benefits more from re-using them than from re-implementing them. The carveout list lives in `build.zig`; toggling between nano and full is a single `-Dconfig=` flip.

## Test infrastructure

The harness has four independent gates plus an aggregate. Each answers a different question. [Build & Test](build-and-test.md) has the full breakdown.

| Gate | Target | Question | Result |
|---|---|---|---|
| Native byte-exact corpus | `make check` | Does the strangled binary match the frozen reference? | **541/541** |
| Same, strict | `make verify` | List each failing test | exits 0 |
| Wasm corpus | `make wasm-check` | Does the wasm binary still match its documented baseline? | **green** at 490/541 raw |
| Integration smoke (native) | `make test-integration` | Does the binary actually run real Python? | 189/189 |
| Integration smoke (wasm) | `make test-integration-wasm` | Same, via wasmtime | 189/189 |
| All of the above + lint | `make` | The "I'm about to commit" gate | exit 0 |

The project also has these checks:

- **Unit tests**: `make test-unit` runs ~100 Zig unit tests across the compiler + VM tracks.
- **`tools/compile-exec-test.py`**: secondary differential gate. Compiles each `.py` with `zigpy-compile`, runs the `.mpy` through vendor MicroPython, diffs the output. Catches "the Zig compiler produced subtly wrong bytecode" cases the byte-exact gate misses.
- **`golden-programs/`**: 823 real Python programs sourced from MicroPython tests, CPython tests, PEP examples, and curated demos, bucketed by what they need ([ADR 008](adrs/008-golden-programs.md)). Drives the per-program coverage view in [`COMPATIBILITY.md`](COMPATIBILITY.md).
- **`tools/metrics.py`**: longitudinal recording of binary size + coverage + (opt-in) perf to `metrics/history.ndjson`. Each session records baseline at start and post-change at end.

See [Build & Test](build-and-test.md) for the full Makefile reference.

## Layout reference

```
src/
├── main.zig                 — entry point + comptime force-analyze block
├── main_vm.zig              — VM-only entry point (for the slim build)
├── mp_mirrors.zig           — Zig mirrors of vendor MicroPython C structs (~40 extern structs)
├── mp_type_roms.zig         — ROM-resident type singletons
├── pyerr.zig                — PyError error union + polled-sentinel bridge
├── vendor_stubs.zig         — small C-ABI stubs for vendor symbols whose full implementation is deferred
├── compiler/                — pure-Zig compiler track
│   ├── lexer.zig            (with unit tests)
│   ├── parser.zig
│   ├── grammar_data.zig     (generated from the patched upstream grammar; see port/grammar-patched/)
│   ├── bigint.zig
│   ├── scope.zig
│   ├── emit.zig
│   ├── compile.zig
│   ├── qstr.zig
│   ├── mpy.zig              — .mpy v6 format
│   └── mpy_roundtrip.zig    — standalone roundtrip tool
├── runtime/                 — VM track
│   ├── runtime.zig          — binary_op, unary_op, call dispatch
│   ├── vm.zig               — bytecode interpreter
│   ├── mpstate.zig          — mp_state_ctx mirror
│   ├── persistentcode.zig   — .mpy loader
│   ├── zig_compile_bridge.zig — compile + load entry point
│   ├── raise.zig            — exception raise helpers
│   ├── argcheck.zig         — arg-checking helpers
│   ├── full_stubs.zig       — is_full-gated stubs for unported full features
│   └── ...
├── objects/                 — type implementations
│   ├── obj.zig              — base type dispatch
│   ├── objtype/             — type system (objtype, objmodule, objobject) + the qstr-gen tombstone
│   ├── primitives/          — int, cell
│   ├── strings/             — str, bytes, objstr, vstr, mpprint
│   ├── containers/          — list, dict, tuple, set, range, slice, array
│   ├── iters/               — filter, map, zip, deque, namedtuple, reversed, enumerate
│   └── callables/           — fun, generator, boundmeth, closure
├── modules/                 — builtin modules
│   ├── modbuiltins.zig      — print, len, range, etc.
│   ├── modsys.zig           — sys.path, sys.argv, etc.
│   ├── modmath.zig          — math.sqrt, math.pi, etc.
│   ├── modgc.zig            — gc.collect, gc.mem_free
│   ├── modstruct.zig        — struct.pack/unpack
│   ├── modarray.zig         — array.array
│   ├── modcollections.zig   — collections (namedtuple, OrderedDict, deque)
│   ├── moderrno.zig         — errno constants
│   ├── modmain.zig          — __main__ module ROM
│   ├── modmicropython.zig   — micropython builtin
│   └── file_io.zig          — file IO (is_full-gated)
├── memory/                  — allocator + GC
│   ├── alloc.zig            — m_malloc / m_realloc / m_new
│   ├── gc.zig               — minimal bump GC
│   └── ...
├── frontend/                — compiler-to-runtime bridge
│   ├── emitglue.zig
│   ├── parsenum.zig
│   ├── parsenumbase.zig
│   └── reader.zig
├── entry/
│   └── embed_exec.zig       — top-level script execution + REPL entry
├── support/
│   ├── smallint.zig         — Python-semantic divmod / floordiv
│   ├── unicode.zig          — unichar classification
│   ├── readline.zig         — REPL line editing (is_full-gated)
│   ├── mpprint.zig          — formatted printing
│   └── stream.zig           — stream protocol (is_full-gated)
└── tests.zig                — unit tests for shimless utility modules
```

## See also

- [ADR series](adrs/index.md): architecture decisions
- [Internals: PyError Convention](internals/pyerror.md)
- [Internals: Type Mirrors](internals/mirrors.md)
- [Internals: qstr Generation](internals/qstr-gen.md)
- [Internals: Persistentcode Loader](internals/persistentcode.md)
- [Internals: Wasm Composition](internals/wasm-composition.md)
- [Strangler Journey](strangler-journey.md): the narrative (historical)
