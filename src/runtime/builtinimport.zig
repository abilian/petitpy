//! nanopython — Zig port of py/builtin_import.c's mp_builtin___import___default
//! (W6 #5). Under nano MICROPY_ENABLE_EXTERNAL_IMPORT=0, this is the live
//! __import__ implementation.
//!
//! Body:
//!   - Reject relative import (n_args=5 with non-zero level) → NotImplementedError
//!   - Iterate dotted components of args[0] ("foo.bar.baz")
//!   - For each component:
//!       * Look up the full dotted-prefix in mp_loaded_modules_dict → reuse if hit
//!       * For the top-level component: try mp_module_get_builtin (non-ext + ext)
//!       * Try `import_search.tryLoadComponent` against the parent module
//!         (sys.path for the top-level; parent's __path__ for submodules)
//!       * Else → raise ImportError "module not found"
//!   - Store submodule references on their parents (so `pkg.sub` works)
//!   - Return the leaf module if `fromtuple` is set, else the top-level

const mp = @cImport({
    @cInclude("py/obj.h");
    @cInclude("py/runtime.h");
    @cInclude("py/objmodule.h");
});
const mirrors = @import("../mp_mirrors.zig");
const pyerr = @import("../pyerr.zig");
const import_search = @import("import_search.zig");
const PyError = pyerr.PyError;

const Obj = mirrors.Obj;
const TypePtr = ?*const anyopaque;

extern fn mp_obj_str_get_data(o: Obj, len_out: *usize) callconv(.c) [*c]const u8;
extern fn mp_module_get_builtin(module_name: usize, extensible: bool) callconv(.c) Obj;
extern fn mp_obj_new_exception_msg(t: TypePtr, msg: [*:0]const u8) callconv(.c) Obj;
extern fn qstr_from_strn(str: [*]const u8, len: usize) callconv(.c) usize;
extern fn mp_store_attr(base: Obj, attr: usize, value: Obj) callconv(.c) void;
extern const mp_type_module: anyopaque;

extern const mp_type_NotImplementedError: anyopaque;
extern const mp_type_ImportError: anyopaque;
extern const mp_type_fun_builtin_var: anyopaque;

// Under nano REPR_A + MICROPY_OBJ_IMMEDIATE_OBJS=1, mp_const_none is the
// immediate value `(0<<3)|6` = 6 (mp_type_roms.zig:28).
const MP_OBJ_CONST_NONE: Obj = 6;

inline fn isNone(o: Obj) bool {
    return o == MP_OBJ_CONST_NONE;
}

fn raiseExcMsg(t: TypePtr, msg: [*:0]const u8) PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(t, msg);
    return error.PyRaise;
}

// Look up `qstr` in sys.modules. Returns the cached module obj or 0.
inline fn loadedLookup(qstr_id: usize) Obj {
    if (mirrors.mp_map_lookup(
        &mirrors.mp_state_ctx.vm.mp_loaded_modules_dict.map,
        mirrors.objFromQstr(qstr_id),
        mirrors.MP_MAP_LOOKUP,
    )) |elem| {
        return elem.value;
    }
    return 0;
}

// Process one dotted component (mirrors process_import_at_level).
//   full_slice  : "foo.bar"  (absolute path up to here)
//   level_slice : "bar"      (the current component)
//   parent_obj  : parent module (already loaded), or OBJ_NULL for top-level
fn processComponent(
    full_slice: []const u8,
    level_slice: []const u8,
    parent_obj: Obj,
) PyError!Obj {
    const full_qstr = qstr_from_strn(full_slice.ptr, full_slice.len);
    const level_qstr = qstr_from_strn(level_slice.ptr, level_slice.len);

    // Already loaded? Reuse.
    const cached = loadedLookup(full_qstr);
    if (cached != 0) return cached;

    // Top-level: try built-ins first. (Sub-components don't get the
    // builtin lookup — upstream gates this on outer_module == NULL.)
    if (parent_obj == mirrors.OBJ_NULL) {
        const nb = mp_module_get_builtin(level_qstr, false);
        if (nb != mirrors.OBJ_NULL) return nb;

        // Filesystem / frozen search.
        const found = try import_search.tryLoadComponent(full_qstr, level_slice, mirrors.OBJ_NULL);
        if (found != mirrors.OBJ_NULL) return found;

        const ext = mp_module_get_builtin(level_qstr, true);
        if (ext != mirrors.OBJ_NULL) return ext;
    } else {
        const found = try import_search.tryLoadComponent(full_qstr, level_slice, parent_obj);
        if (found != mirrors.OBJ_NULL) {
            // Hook the submodule onto its parent so attribute access
            // works (vendor builtinimport.c:524).
            mp_store_attr(parent_obj, level_qstr, found);
            if (pyerr.pending_exc != 0) return error.PyRaise;
            return found;
        }
        // Neither on disk nor frozen: a built-in parent may serve the
        // submodule as an attribute (`import os.path`, os.__getattr__).
        var dest: [2]Obj = .{ 0, 0 };
        import_search.loadAttrMaybe(parent_obj, level_qstr, &dest);
        if (pyerr.pending_exc != 0) return error.PyRaise;
        if (dest[0] != 0 and dest[1] == 0 and mirrors.isExactType(dest[0], &mp_type_module)) return dest[0];
    }

    try raiseExcMsg(&mp_type_ImportError, "module not found");
    unreachable;
}

fn importImpl(n_args: usize, args: [*c]const Obj) PyError!Obj {
    // Reject relative imports. args[4] is the level (small-int).
    if (n_args >= 5 and (@as(isize, @bitCast(args[4])) >> 1) != 0) {
        try raiseExcMsg(&mp_type_NotImplementedError, "relative import");
        unreachable;
    }

    // Pull out the module-name bytes.
    var name_len: usize = 0;
    const name_data = mp_obj_str_get_data(args[0], &name_len);
    if (name_len == 0) {
        try raiseExcMsg(&mp_type_ImportError, "module not found");
        unreachable;
    }
    const name_slice = name_data[0..name_len];

    // fromtuple decides whether to return the top-level or the leaf.
    const fromtuple: Obj = if (n_args >= 4) args[3] else MP_OBJ_CONST_NONE;

    // Iterate the dotted path. Each component spans
    // name[current_start..i] and the full prefix is name[0..i].
    var top_module: Obj = mirrors.OBJ_NULL;
    var outer_module: Obj = mirrors.OBJ_NULL;
    var current_start: usize = 0;
    var i: usize = 1;
    while (i <= name_len) : (i += 1) {
        if (i == name_len or name_slice[i] == '.') {
            const full_slice = name_slice[0..i];
            const level_slice = name_slice[current_start..i];
            const mod = try processComponent(full_slice, level_slice, outer_module);
            outer_module = mod;
            if (top_module == mirrors.OBJ_NULL) top_module = mod;
            current_start = i + 1;
        }
    }

    return if (isNone(fromtuple)) top_module else outer_module;
}

export fn mp_builtin___import___default(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, importImpl(n_args, args));
}

// ROM const fun-obj for the __import__ builtin. Vendor obj.h:69
// `#define mp_builtin___import__ mp_builtin___import___default` aliases
// the symbol; the const literal points at our Zig export. Replaces the
// `MP_DEFINE_CONST_FUN_OBJ_VAR_BETWEEN(mp_builtin___import___obj, 1, 5,
// mp_builtin___import__)` macro that the shim used to emit.
pub export const mp_builtin___import___obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(1, 5, false),
    .fun = @ptrCast(&mp_builtin___import___default),
};

comptime {
    _ = &mp_builtin___import___default;
    _ = &mp_builtin___import___obj;
}
