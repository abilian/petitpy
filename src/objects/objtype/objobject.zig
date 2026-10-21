//! nanopython — full Zig port of py/objobject.c.
//!
//! Config:
//!   nano: CPYTHON_COMPAT=1, DELATTR_SETATTR=0
//!   full: CPYTHON_COMPAT=1, DELATTR_SETATTR=1
//!
//! Under nano the locals_dict has { __init__, __new__ } (DELATTR_SETATTR
//! off means no setattr/delattr methods). Under full all 4 are present.

const build_options = @import("build_options");
const mp = @cImport({
    @cInclude("py/qstr.h");
});
const mirrors = @import("../../mp_mirrors.zig");
const types = @import("../../mp_type_roms.zig");
const pyerr = @import("../../pyerr.zig");
const PyError = pyerr.PyError;

const Obj = mirrors.Obj;
const Qstr = usize;

extern const mp_type_type: anyopaque;
extern const mp_type_fun_builtin_1: anyopaque;
extern const mp_type_fun_builtin_2: anyopaque;
extern const mp_type_fun_builtin_3: anyopaque;
extern const mp_type_staticmethod: anyopaque;
extern const mp_type_dict: anyopaque;
extern const mp_type_TypeError: anyopaque;
extern const mp_type_AttributeError: anyopaque;
extern fn mp_obj_malloc_helper(num_bytes: usize, type_in: *const anyopaque) callconv(.c) ?*anyopaque;
extern fn mp_arg_check_num_sig(n_args: usize, n_kw: usize, sig: u32) callconv(.c) void;
extern fn mp_obj_new_instance(cls: *const anyopaque, native_base: *?*const anyopaque) callconv(.c) ?*anyopaque;
extern fn mp_obj_get_type(o: Obj) callconv(.c) *const anyopaque;
extern const mp_type_str: anyopaque;

// mp_obj_is_str (macro): qstr-immediate OR exact-type-str.
inline fn objIsStr(o: Obj) bool {
    return (o & 7) == 2 or mirrors.isExactType(o, &mp_type_str);
}
extern fn mp_obj_new_exception(t: *const anyopaque) callconv(.c) Obj;
extern fn mp_obj_new_exception_msg(t: *const anyopaque, msg: [*:0]const u8) callconv(.c) Obj;
extern fn mp_map_lookup(map: *mirrors.MpMap, index: Obj, kind: c_int) callconv(.c) ?*mirrors.MpMap.Elem;

// NX-3 N1 raise helpers (PyError convention; notes/41, /42). Each
// sets pyerr.pending_exc + returns error.PyRaise; C-ABI exports wrap
// the impl with pyerr.bridge which catches and returns the zero
// sentinel (callers poll pending_exc).
fn raiseTypeErrorUserType() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_TypeError, "arg must be user-type");
    return error.PyRaise;
}
fn raiseTypeErrorBare() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception(&mp_type_TypeError);
    return error.PyRaise;
}
fn raiseAttributeErrorNoSuch() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_AttributeError, "no such attribute");
    return error.PyRaise;
}

// Vendor mp_obj_is_instance_type macro: (type->flags & MP_TYPE_FLAG_INSTANCE_TYPE)
inline fn objIsInstanceType(t: *const anyopaque) bool {
    const flags: *const u16 = @ptrFromInt(@intFromPtr(t) + @offsetOf(mirrors.MpObjType, "flags"));
    return (flags.* & 0x0200) != 0; // MP_TYPE_FLAG_INSTANCE_TYPE
}

// MP_OBJ_FUN_MAKE_SIG(0, 0, false) for object()
const ARG_SIG_OBJECT: u32 = (0 << 17) | (0 << 1) | 0;

// mp_obj_object_t is just { base }.
fn object_make_new(type_in: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    _ = args;
    mp_arg_check_num_sig(n_args, n_kw, ARG_SIG_OBJECT);
    const raw = mp_obj_malloc_helper(@sizeOf(mirrors.MpObjBase), type_in.?).?;
    return @intFromPtr(raw);
}

// __init__(self) → None — CPYTHON_COMPAT.
fn object___init__(self: Obj) callconv(.c) Obj {
    _ = self;
    return mirrors.OBJ_NONE;
}
pub export const object___init___obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_1 },
    .fun = @ptrCast(&object___init__),
};

// __new__(cls) → instance — CPYTHON_COMPAT.
fn objectNewImpl(cls: Obj) PyError!Obj {
    // !(is_type(cls, &mp_type_type) && is_instance_type(cls)) → TypeError
    if (!mirrors.isExactType(cls, &mp_type_type)) try raiseTypeErrorUserType();
    const cls_ptr: *const anyopaque = @ptrFromInt(cls);
    if (!objIsInstanceType(cls_ptr)) try raiseTypeErrorUserType();
    var native_base: ?*const anyopaque = null;
    const inst = mp_obj_new_instance(cls_ptr, &native_base);
    return @intFromPtr(inst);
}
fn object___new__(cls: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, objectNewImpl(cls));
}
pub export const object___new___fun_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_1 },
    .fun = @ptrCast(&object___new__),
};
pub export const object___new___obj: mirrors.MpObjStaticClassMethod = .{
    .base = .{ .type = &mp_type_staticmethod },
    .fun = @ptrCast(&object___new___fun_obj),
};

// __setattr__(self, attr, value) — DELATTR_SETATTR full-only.
fn objectSetattrImpl(self_in: Obj, attr: Obj, value: Obj) PyError!Obj {
    if (!objIsInstanceType(mp_obj_get_type(self_in))) try raiseTypeErrorUserType();
    if (!objIsStr(attr)) try raiseTypeErrorBare();
    const self = mirrors.MpObjInstance.fromObj(self_in);
    const elem = mp_map_lookup(&self.members, attr, 1); // ADD_IF_NOT_FOUND
    elem.?.value = value;
    return mirrors.OBJ_NONE;
}
fn object___setattr__(self_in: Obj, attr: Obj, value: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, objectSetattrImpl(self_in, attr, value));
}
pub export const object___setattr___obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_3 },
    .fun = @ptrCast(&object___setattr__),
};

// __delattr__(self, attr) — DELATTR_SETATTR full-only.
fn objectDelattrImpl(self_in: Obj, attr: Obj) PyError!Obj {
    if (!objIsInstanceType(mp_obj_get_type(self_in))) try raiseTypeErrorUserType();
    if (!objIsStr(attr)) try raiseTypeErrorBare();
    const self = mirrors.MpObjInstance.fromObj(self_in);
    if (mp_map_lookup(&self.members, attr, 2) == null) { // REMOVE_IF_FOUND
        try raiseAttributeErrorNoSuch();
    }
    return mirrors.OBJ_NONE;
}
fn object___delattr__(self_in: Obj, attr: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, objectDelattrImpl(self_in, attr));
}
pub export const object___delattr___obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&object___delattr__),
};

// locals_dict — entries config-gated; nano has 2 (init, new), full has 4.
// RomEntry shares MpMap.Elem byte layout (key:Obj/usize, value:ptr-stored-as-uintptr)
// but types value as `*const anyopaque` so `&fun_obj` initialisers work at link
// time. Zig forbids `@intFromPtr(&pub-export-const)` at comptime.
const RomEntry = extern struct {
    key: Obj,
    value: *const anyopaque,
};
const N_ENTRIES: usize = if (build_options.delattr_setattr) 4 else 2;

const object_locals_dict_table: [N_ENTRIES]RomEntry = if (build_options.delattr_setattr) .{
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR___init__)), .value = &object___init___obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR___new__)), .value = &object___new___obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR___setattr__)), .value = &object___setattr___obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR___delattr__)), .value = &object___delattr___obj },
} else .{
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR___init__)), .value = &object___init___obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR___new__)), .value = &object___new___obj },
};

pub export const object_locals_dict: mirrors.MpObjDict = .{
    .base = .{ .type = &mp_type_dict },
    .map = .{
        .bits = .{ .all_keys_are_qstrs = 1, .is_fixed = 1, .is_ordered = 1, .used = N_ENTRIES },
        .alloc = N_ENTRIES,
        .table = @ptrCast(@constCast(&object_locals_dict_table)),
    },
};

// mp_type_object: { name=object, flags=NONE, make_new=1, locals_dict=2 }
pub export const mp_type_object: types.MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = 0x0000,
        .name = mp.MP_QSTR_object,
        .slot_index_make_new = 1,
        .slot_index_print = 0,
        .slot_index_call = 0,
        .slot_index_unary_op = 0,
        .slot_index_binary_op = 0,
        .slot_index_attr = 0,
        .slot_index_subscr = 0,
        .slot_index_iter = 0,
        .slot_index_buffer = 0,
        .slot_index_protocol = 0,
        .slot_index_parent = 0,
        .slot_index_locals_dict = 2,
    },
    .slots = .{
        @ptrCast(&object_make_new),
        @ptrCast(&object_locals_dict),
        null, null, null, null, null, null, null, null, null,
    },
};

comptime {
    _ = &mp_type_object;
    _ = &object___init___obj;
    _ = &object___new___obj;
    _ = &object___setattr___obj;
    _ = &object___delattr___obj;
    _ = &object_locals_dict;
}
