# Type Mirrors

`src/mp_mirrors.zig` (~1,200 lines) collects the ~40 `extern struct` definitions that mirror MicroPython's C structs **field-for-field**, with `@sizeOf` and `@offsetOf` checks.

This lets Zig read and write the same memory that vendor MicroPython C did, by name.

## The problem mirrors solve

MicroPython's runtime is full of structs like this (vendor C):

```c
typedef struct _mp_obj_list_t {
    mp_obj_base_t base;
    size_t alloc;
    size_t len;
    mp_obj_t *items;
} mp_obj_list_t;
```

When the strangler ports a function that operates on a `mp_obj_list_t`, the Zig version needs to access the same fields, at the same offsets, with the same types. If Zig writes to offset 16 thinking it's `len` but C reads from offset 24 thinking it's `len`, you get data corruption.

The conventional solution is `@cImport`, which runs the C header through `translate-c` and exposes the struct as a Zig type. That works for simple cases but breaks down for:

- Macros (`MP_OBJ_NEW_SMALL_INT`, `MP_OBJ_FROM_PTR`): translate-c can't always reproduce these
- Anonymous types: `translate-c` generates `struct_unnamed_N` names that don't `@ptrCast` cleanly between modules
- Build-time configuration variation: `translate-c` runs in a separate pass; macros set after the `@cInclude` aren't visible

The mirror approach sidesteps all of these by **declaring the type manually in Zig** with `extern struct` (which guarantees C layout) and verifying the layout matches with `@sizeOf` / `@offsetOf` checks.

## Anatomy of a mirror

```zig
/// Mirror of `mp_obj_list_t` from vendor `objlist.h:13-19`.
///
/// Fields must match exactly. Verified by `assertLayout()`.
pub const MpObjList = extern struct {
    base: MpObjBase,           // 16 bytes on 64-bit (type ptr + padding)
    alloc: usize,              // 8
    len: usize,                // 8
    items: ?[*]Obj,            // 8
};

// In assertLayout():
std.debug.assert(@sizeOf(MpObjList) == npy_mirror_sizeof_mp_obj_list_t);
std.debug.assert(@offsetOf(MpObjList, "items") == npy_mirror_offsetof_mp_obj_list_t_items);
```

The `npy_mirror_*` consts come from a tiny C file (`src/mp_layout_check.zig` defines them as exports computed from the actual C structs). If Zig's `MpObjList` drifts from vendor's `mp_obj_list_t`, the assert fires at runtime startup and the binary panics with a layout error.

Today the checks are **tautological** (Zig `MpObjList` checked against Zig `npy_mirror_sizeof_*`, both Zig). The original intent was to use `@cImport` to compare against the actual C type; documented as a follow-up. The mirror still catches "I broke `MpObjList` in Zig" but not "vendor changed `mp_obj_list_t` upstream." Acceptable because vendor is pinned via the symlink.

## What's in mp_mirrors.zig

Roughly 50 mirror types covering:

| Category | Examples |
|---|---|
| Object base / type system | `MpObjBase`, `MpObjType`, `MpObjFullType`, `MpObjTypeWithSlots` |
| Built-in object types | `MpObjList`, `MpObjDict`, `MpObjTuple`, `MpObjStr`, `MpObjModule` |
| Function types | `MpObjFunBc`, `MpObjFunBuiltinFixed`, `MpObjFunBuiltinVar`, `MpObjBoundMeth`, `MpObjClosure` |
| Exception types | `MpObjException`, `MpExcStack` |
| State singletons | `MpStateCtx`, `MpStateThread`, `MpStateVm`, `MpStateMem` |
| Compilation types | `MpRawCode`, `MpCompiledModule`, `MpModuleContext`, `MpReader`, `MpPrint` |
| Map / qstr internals | `MpMap`, `MpMapElem`, `MpModuleContextConstants` |
| Iterator types | `MpObjGenInstance`, `MpObjCell`, `MpObjGetitemIter` |

Each mirror has a comment pointing at the vendor C declaration (e.g., `// Mirror of mp_obj_list_t (objlist.h:13-19)`). When the mirror is wrong, that comment is the first thing to recheck against upstream.

## Helper functions in mirrors

Beyond types, `mp_mirrors.zig` exports inline helpers for the common operations:

```zig
// Object construction
pub inline fn objFromQstr(q: Qstr) Obj { ... }
pub inline fn objFromPtr(p: *const anyopaque) Obj { ... }
pub inline fn newSmallInt(v: isize) Obj { ... }
pub inline fn newBool(b: bool) Obj { ... }

// Object inspection
pub inline fn objBaseType(obj: Obj) *const anyopaque { ... }
pub inline fn isExactType(obj: Obj, ty: *const anyopaque) bool { ... }
pub inline fn smallIntValue(obj: Obj) isize { ... }
pub inline fn isSmallInt(obj: Obj) bool { ... }

// Type slot access
pub const MpObjType = struct {
    pub fn fromPtr(p: *const anyopaque) MpObjType { ... }
    pub fn hasSlot(self: MpObjType, slot: TypeSlot) bool { ... }
    pub fn getSlot(self: MpObjType, slot: TypeSlot) ?*const anyopaque { ... }
    pub fn flagX(self: MpObjType) bool { ... }
};
```

These wrap the bit-manipulation needed to encode/decode `mp_obj_t` values per REPR_A's tagged-pointer scheme. Using them keeps the rest of the code free of magic-number bit twiddles.

## Notable mirrors

### `MpStateCtx`: the global state singleton

MicroPython's `mp_state_ctx` is the top-level state struct: a `volatile struct` containing:

- `MpStateThread thread`: the current thread's NLR stack, current locals/globals, recursion depth
- `MpStateVm vm`: the qstr pool, the dict_main, mp_loaded_modules_dict, sys.path, etc.
- `MpStateMem mem`: GC state, allocator pointers

Mirrored exactly in Zig as `MpStateCtx` with offset checks that pin every byte. Accessing the singleton:

```zig
mirrors.mp_state_ctx.vm.dict_main  // direct field access through the mirror
```

The mirror replaced what was originally a C shim file (`zigonly_state.zig`) that exposed accessors. Once the mirror matched byte-for-byte, the accessors became unnecessary.

### `MpObjType`: the type system

`mp_obj_type_t` is the heart of MicroPython's dispatch. It contains:

- Type metadata (`name`, `flags`, `protocol`)
- Slot dispatch pointers (`make_new`, `print`, `call`, `unary_op`, `binary_op`, `attr`, `subscr`, `iter`, `buffer`, `protocol`, `parent`, `locals_dict`)

The slot array is **compressed** in vendor C: the type stores indices into a global slot table. Compared with direct pointers, that saves 4-8 bytes per slot. The `MpObjType` mirror replicates this via `slot_index_*: u8` fields and a `slots: [N]?*const anyopaque` array.

Helpers like `tm.getSlot(.binary_op)` decode the compression and return the actual function pointer (or null if the slot isn't set).

### `MpRawCode`: the bytecode container

A `mp_raw_code_t` represents a compiled function. Its fields:

- `proto_fun_indicator: [2]u8`: disambiguates raw_code (bytecode) from native code via two leading bytes
- `kind: u8`: one of BYTECODE, NATIVE_PY, NATIVE_VIPER, NATIVE_ASM
- `is_generator: bool`: does this function yield?
- `fun_data: ?*const anyopaque`: pointer to the bytecode or native code
- `children: [*c]?*MpRawCode`: array of nested raw_codes (one per nested function/class)

This mirror was added in NX-1 (commit `2f7c1c3`) along with `MpCompiledModule`, `MpReader`, `MpPrint`, `MpBytecodePrelude`, and the constants `BYTES_FOR_INT`, `QSTR_LAST_STATIC`, `MP_SCOPE_FLAG_*`. Together they enabled the persistentcode loader port.

## Layout assertion mechanics

The checks run at startup via a `comptime` block in `assertLayout()`:

```zig
pub fn assertLayout() void {
    std.debug.assert(@sizeOf(MpObjList) == npy_mirror_sizeof_mp_obj_list_t);
    std.debug.assert(@offsetOf(MpObjList, "alloc") == npy_mirror_offsetof_mp_obj_list_t_alloc);
    // ... ~50 more
}
```

`npy_mirror_sizeof_mp_obj_list_t` is an extern const declared in `src/mp_layout_check.zig`. Today its value comes from another Zig file (tautological); historically it came from a C TU compiled against vendor headers.

In Debug builds, a mismatch makes `assertLayout` panic with a useful message (`expected 32, got 24`). In Release builds, the `std.debug.assert` is compiled out, so the checks fire only during development.

This is a **defense against drift**; it guards against no actual attack. Vendor's struct layout changes only when the upstream tree is updated (via `make port`), and `make port` regenerates the C structs we're mirroring. If the regenerated structs differ from the Zig mirror, the checks catch it before the binary runs corpus tests.

## When mirrors fail

Most often, a mirror failure looks like:

```
panic: index out of bounds: index 12345, len 100
src/objects/containers/objlist.zig:142
```

That's a clue that some struct's `len` field is at the wrong offset. The fix is:

1. Find the corresponding vendor C struct declaration.
2. Compare field-for-field with the Zig mirror.
3. Adjust the mirror to match.

Common drift causes:
- A vendor `#if MICROPY_PY_X` block adds a field under some configs and the mirror was written for one config only.
- A vendor refactor moved fields around; the Zig mirror is stale.
- A new mirror was added by hand without `@offsetOf` checks.

The `assertLayout()` call is invoked from `main.zig` startup. Adding new mirrors should always include their checks; missing checks let mismatches sneak through to runtime crashes.

## See also

- [`src/mp_mirrors.zig`](https://git.sr.ht/~sfermigier/petitpy/tree/main/item/src/mp_mirrors.zig) (in tree): the canonical source
- [`src/mp_layout_check.zig`](https://git.sr.ht/~sfermigier/petitpy/tree/main/item/src/mp_layout_check.zig): the extern const declarations
