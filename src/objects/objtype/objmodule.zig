//! nanopython — Zig port of py/objmodule.c bodies (Phase 2 lift,
//! enabled by mp_mirrors.zig). Cleanup pass: replaced ~20 shim
//! constants and qstr/MP_MAP/config helpers with direct @cImport of
//! the MicroPython headers. Only the helpers that need MP_STATE access,
//! `m_new_obj` / `&symbol_address`, or static-fn forwarding stay shim-side.

const c = @cImport({
    @cInclude("objmodule_api.h");
});
/// MicroPython config + qstr enums via @cImport — covers MP_QSTR_*,
/// MP_MAP_LOOKUP*, MICROPY_* flags, MP_QSTRnull. Each saved a shim helper.
const mp = @cImport({
    @cInclude("py/obj.h");
    @cInclude("py/runtime.h");
    @cInclude("py/qstr.h");
    @cInclude("py/objmodule.h");
    @cInclude("genhdr/moduledefs.h");
});
const mirrors = @import("../../mp_mirrors.zig");
// PEP 562 module __getattr__: a bool from the ROM-level default (nano),
// a c_int where mpconfigport.h defines it (full).
const MODULE_GETATTR = if (@TypeOf(mp.MICROPY_MODULE_GETATTR) == bool) mp.MICROPY_MODULE_GETATTR else mp.MICROPY_MODULE_GETATTR != 0;
const build_options = @import("build_options");

const Obj = c.npy_obj;
const MP_OBJ_NULL: Obj = 0;
// C `qstr` typedef is size_t (qstr.h:60). On arm64 a u16 alias works
// because registers zero-extend; on wasm32 the Zig compiler tracks the
// type mismatch and emits a "bitcast_invalid" trap stub.
const Qstr = usize;

// Already-Zig public exports
extern fn mp_obj_new_dict(n_args: usize) callconv(.c) Obj;
extern fn mp_obj_dict_store(self_in: Obj, key: Obj, value: Obj) callconv(.c) Obj;
extern fn mp_obj_dict_delete(self_in: Obj, key: Obj) callconv(.c) Obj;
// Runtime helpers (still C, just declared extern)
extern fn mp_call_function_0(fun: Obj) callconv(.c) Obj;
extern fn mp_call_function_1(fun: Obj, arg: Obj) callconv(.c) Obj;
extern fn mp_map_lookup(map: ?*anyopaque, key: Obj, kind: c_int) ?*mirrors.MpMap.Elem;
// NX-3 N4a: mp_obj_str_get_str returns null + sets pending_exc on bad input
// (non-str-or-bytes). Callers MUST check the returned ptr for null.
extern fn mp_obj_str_get_str(o: Obj) callconv(.c) ?[*:0]const u8;
extern fn qstr_data(q: Qstr, len_out: *usize) callconv(.c) [*]const u8;
extern fn qstr_find_strn(s: [*]const u8, len: usize) callconv(.c) Qstr;
extern fn mp_printf(print: ?*const anyopaque, fmt: [*:0]const u8, ...) callconv(.c) c_int;

// Vendor ROM symbols — used to be wrapped by npy_mod_* accessors;
// safe to declare extern in Zig (just symbol addresses, no qstr-gen).
extern const mp_module_sys: mirrors.MpObjModule;
extern const mp_module_builtins_globals: mirrors.MpObjDict;

/// Zig-side override-dict for `builtins.X = Y` (see the module_attr
/// store path below). Never referenced under nano — the golden was
/// frozen against `MICROPY_CAN_OVERRIDE_BUILTINS=0` behavior.
pub export var mp_module_builtins_override_dict: ?*mirrors.MpObjDict = null;

inline fn mapLookup(map: anytype, key: Obj, kind: c_int) ?*mirrors.MpMap.Elem {
    return mp_map_lookup(@ptrCast(@constCast(map)), key, kind);
}

/// Linear search over a parallel (keys, values) array, used by
/// MODULE-attribute-delegation tables. dest[0] == NULL → load,
/// otherwise → store (dest[1] == NULL means delete via store of NULL).
export fn mp_module_generic_attr(attr: Qstr, dest: [*c]Obj, keys: [*c]const u16, values: [*c]Obj) callconv(.c) void {
    var i: usize = 0;
    while (@as(c_int, keys[i]) != mp.MP_QSTRnull) : (i += 1) {
        if (attr == keys[i]) {
            if (dest[0] == MP_OBJ_NULL) {
                dest[0] = values[i];
            } else {
                values[i] = dest[1];
                dest[0] = MP_OBJ_NULL;
            }
            return;
        }
    }
}

/// Allocate a fresh module object named `module_name`, register it in the
/// global loaded-modules table, and initialise it with `__name__`.
export fn mp_obj_new_module(module_name: Qstr) callconv(.c) Obj {
    const elem = mapLookup(
        &mirrors.mp_state_ctx.vm.mp_loaded_modules_dict.map,
        mirrors.objFromQstr(module_name),
        mp.MP_MAP_LOOKUP_ADD_IF_NOT_FOUND,
    ).?;
    if (elem.value != MP_OBJ_NULL) {
        return elem.value;
    }

    const mod = c.npy_mod_alloc_module_context();
    const globals = mp_obj_new_dict(mp.MICROPY_MODULE_DICT_SIZE);
    mirrors.MpObjModule.fromObj(mod).globals = @ptrFromInt(globals);

    _ = mp_obj_dict_store(globals, mirrors.objFromQstr(mp.MP_QSTR___name__), mirrors.objFromQstr(module_name));

    elem.value = mod;
    return mod;
}

/// Look up a built-in module by name; run __init__ if BUILTIN_INIT is on.
export fn mp_module_get_builtin(module_name: Qstr, extensible: bool) callconv(.c) Obj {
    const map_void = if (mp.MICROPY_HAVE_REGISTERED_EXTENSIBLE_MODULES != 0 and extensible)
        c.npy_mod_builtin_extensible_module_map()
    else
        c.npy_mod_builtin_module_map();
    var elem = mapLookup(map_void, mirrors.objFromQstr(module_name), mp.MP_MAP_LOOKUP);

    if (elem == null) {
        if (mp.MICROPY_PY_SYS != 0 and module_name == mp.MP_QSTR_usys) {
            return @intFromPtr(&mp_module_sys);
        }
        if (mp.MICROPY_HAVE_REGISTERED_EXTENSIBLE_MODULES != 0) {
            if (extensible) return MP_OBJ_NULL;
            // u-prefix-strip: `import ufoo` maps to extensible `foo`.
            var name_len: usize = undefined;
            const name_str = qstr_data(module_name, &name_len);
            if (name_str[0] != 'u') return MP_OBJ_NULL;
            const stripped = qstr_find_strn(name_str + 1, name_len - 1);
            elem = mapLookup(c.npy_mod_builtin_extensible_module_map(), mirrors.objFromQstr(stripped), mp.MP_MAP_LOOKUP);
        }
        if (elem == null) return MP_OBJ_NULL;
    }

    if (comptime build_options.is_full) {
        // F-rehab Fix 4 (notes/40): stub modules (mp_module_io) live as
        // zero-init storage in full_stubs.zig — base.type is NULL, so
        // mp_load_method_maybe would crash. Skip __init__ when the module
        // object isn't fully formed.
        const mod_obj = elem.?.value;
        const mod_base: *const mirrors.MpObjBase = @ptrFromInt(mod_obj);
        if (mod_base.type != null) {
            // Look in the module's own globals, not through an attribute
            // load, which would reach a module __getattr__ (os has one).
            const gdict = mirrors.MpObjModule.fromObj(mod_obj).globals;
            const gmap: ?*anyopaque = @ptrCast(&gdict.map);
            if (mapLookup(gmap, mirrors.objFromQstr(mp.MP_QSTR___init__), mp.MP_MAP_LOOKUP)) |init| {
                _ = mp_call_function_0(init.value);
            }
        }
    }
    return elem.?.value;
}

/// module_attr — load/store/delete attribute. Previously demoted-to-extern
/// by translate-c due to dict.is_fixed bitfield access — now portable via
/// MpObjDict mirror.
export fn module_attr(self_in: Obj, attr: Qstr, dest: [*c]Obj) callconv(.c) void {
    const gdict = mirrors.MpObjModule.fromObj(self_in).globals;
    const map_void: ?*anyopaque = @ptrCast(&gdict.map);

    if (dest[0] == MP_OBJ_NULL) {
        // load
        var elem = mapLookup(map_void, mirrors.objFromQstr(attr), mp.MP_MAP_LOOKUP);
        if (elem != null) {
            dest[0] = elem.?.value;
            return;
        }
        if (mp.MICROPY_CPYTHON_COMPAT != 0 and attr == mp.MP_QSTR___dict__) {
            dest[0] = @intFromPtr(gdict);
            return;
        }
        if (MODULE_GETATTR and attr != mp.MP_QSTR___getattr__) {
            elem = mapLookup(map_void, mirrors.objFromQstr(mp.MP_QSTR___getattr__), mp.MP_MAP_LOOKUP);
            if (elem != null) {
                dest[0] = mp_call_function_1(elem.?.value, mirrors.objFromQstr(attr));
                return;
            }
        }
        c.npy_mod_attr_try_delegation(self_in, @intCast(attr), dest);
        return;
    }

    // store/delete
    var dict: *mirrors.MpObjDict = gdict;
    if (dict.map.bits.is_fixed != 0) {
        // MICROPY_CAN_OVERRIDE_BUILTINS is 0 in port/mpconfigport.h (so the
        // vendor mp_state_vm_t doesn't carry the override_dict slot). We
        // keep our own Zig-side global so we don't have to shift the whole
        // mpstate layout mirror. Gated on is_full — nano preserves the
        // "map is fixed → AttributeError" behavior the byte-exact golden
        // was frozen against.
        if (build_options.is_full and
            @as(*const mirrors.MpObjDict, dict) == &mp_module_builtins_globals)
        {
            if (mp_module_builtins_override_dict == null) {
                mp_module_builtins_override_dict = @ptrFromInt(mp_obj_new_dict(1));
            }
            dict = mp_module_builtins_override_dict.?;
        } else {
            c.npy_mod_attr_try_delegation(self_in, @intCast(attr), dest);
            return;
        }
    }
    const dict_obj: Obj = @intFromPtr(dict);
    const key = mirrors.objFromQstr(attr);
    if (dest[1] == MP_OBJ_NULL) {
        _ = mp_obj_dict_delete(dict_obj, key);
    } else {
        _ = mp_obj_dict_store(dict_obj, key, dest[1]);
    }
    dest[0] = MP_OBJ_NULL;
}

/// module_print — "<module 'name'>" or "<module 'name' from 'file'>".
export fn module_print(print: ?*const anyopaque, self_in: Obj, _: c_int) callconv(.c) void {
    const gdict = mirrors.MpObjModule.fromObj(self_in).globals;
    const map_void: ?*anyopaque = @ptrCast(&gdict.map);
    var module_name: [*:0]const u8 = "";
    var elem = mapLookup(map_void, mirrors.objFromQstr(mp.MP_QSTR___name__), mp.MP_MAP_LOOKUP);
    if (elem != null) {
        // NX-3 N4a: mp_obj_str_get_str polled-sentinel — fall back to empty on bad input.
        if (mp_obj_str_get_str(elem.?.value)) |s| module_name = s;
    }
    if (mp.MICROPY_MODULE___FILE__) {
        elem = mapLookup(map_void, mirrors.objFromQstr(c.npy_mod_QSTR_FILE), mp.MP_MAP_LOOKUP);
        if (elem != null) {
            const file_name: [*:0]const u8 = mp_obj_str_get_str(elem.?.value) orelse "";
            _ = mp_printf(print, "<module '%s' from '%s'>", module_name, file_name);
            return;
        }
    }
    _ = mp_printf(print, "<module '%s'>", module_name);
}

comptime {
    _ = &mp_module_generic_attr;
    _ = &mp_obj_new_module;
    _ = &mp_module_get_builtin;
    _ = &module_attr;
    _ = &module_print;
}
