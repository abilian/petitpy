# Type Mirrors

`src/mp_mirrors.zig` declares, as Zig `extern struct`s, the MicroPython C structs that Zig code needs to read or write: the object base and type, lists, dicts, tuples, strings, modules, functions and closures, exceptions, the interpreter state, and the raw-code and reader structs used by the `.mpy` loader. An `extern struct` has C field order and padding, so Zig and the remaining C code (vendor carveouts and the project-local `.c` files) agree on where each field lives.

## Why not `@cImport`

`translate-c` cannot express some of MicroPython's declarations. Structs with computed-width bitfields, such as `qstr_pool_t` and `mp_obj_exception_t`, become `opaque{}`, and opacity spreads to every struct that embeds them, up to `mp_state_ctx_t`. Writing the mirrors by hand gives usable types, and a comment on each one names the vendor declaration it follows.

```zig
/// Mirror of C `mp_obj_list_t` (objlist.h). No bitfields.
pub const MpObjList = extern struct {
    base: MpObjBase,
    alloc: usize,
    len: usize,
    items: [*]Obj,
};
```

## Helpers

Beyond the types, the file holds the helpers that encode and decode `Obj` values under REPR_A (`objFromQstr`, `objFromPtr`, `newSmallInt`, `newBool`, `isSmallInt`, `smallIntValue`, `objBaseType`, `isExactType`), so the rest of the code has no tag arithmetic of its own.

`MpObjType` mirrors vendor's compressed slot layout: each slot has a one-byte `slot_index_*` field, zero means unset, and a non-zero index points into the `slots` array that follows the struct. `getSlot` decodes it:

```zig
const ty = mirrors.MpObjType.fromPtr(mirrors.objBaseType(obj));
if (ty.getSlot(.binary_op)) |raw| { ... }
```

## The interpreter state

The `mp_state_ctx` singleton is defined in Zig, in `src/runtime/mpstate.zig`, with its full `thread`, `vm` and `mem` layout and comptime assertions on its field offsets and sizes. The field order matters beyond C compatibility: the GC scans a contiguous span of this struct as roots. `mp_mirrors.zig` declares the same symbol with a shorter type that covers only the `thread` and `vm` fields Zig code reads, such as `mirrors.mp_state_ctx.thread.dict_globals`.

## Limits

- **The layout checks are weak.** `assertLayout()` compares each mirror's `@sizeOf` and `@offsetOf` against `npy_mirror_*` constants, but `src/mp_layout_check.zig` computes those constants from the same Zig types, so the comparison cannot fail, and the call in `main.zig` is commented out. The comptime assertions in `mpstate.zig` use hard-coded numbers for 64-bit targets and do catch drift there.
- **Mirrors follow one config.** Some vendor structs grow fields under config macros (`MICROPY_PERSISTENT_CODE_SAVE` for `MpRawCode`, for example). The mirror matches the current `port/mpconfigport.h`; flipping such a macro means updating the mirror by hand. Comments marked `CONFIG-COUPLED` flag these cases.
- **Vendor upgrades need a manual check.** Nothing compares the mirrors against vendor headers, so a new `MICROPY_REV` that moves a field requires rechecking the affected mirrors against upstream.

A mirror at the wrong offset usually shows up as a nonsense length or a bad pointer in the struct's first user. Compare the mirror field by field with the vendor declaration its comment names.

## See also

- [`src/mp_mirrors.zig`](https://github.com/abilian/petitpy/blob/main/src/mp_mirrors.zig)
- [`src/runtime/mpstate.zig`](https://github.com/abilian/petitpy/blob/main/src/runtime/mpstate.zig)
