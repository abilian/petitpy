//! nanopython — full Zig port of py/opmethods.c. The 4 slot-dispatch
//! fns are now expressed via `mirrors.MpObjType` (callSubscr +
//! callBinaryOp); the 4 ROM const fun-objects (mp_op_getitem_obj /
//! setitem / delitem / contains) live here as `pub export const`
//! values of `MpObjFunBuiltinFixed` mirror type, replacing the
//! vendor `MP_DEFINE_CONST_FUN_OBJ_2` macros that the shim previously
//! emitted. C callers see byte-identical ROM objects (same layout,
//! same symbols).
const mirrors = @import("../mp_mirrors.zig");
const Obj = mirrors.Obj;

// MP_BINARY_OP_CONTAINS value (from py/runtime.h enum). Direct via @cImport.
const mp = @cImport({
    @cInclude("py/runtime.h");
});

extern fn mp_obj_get_type(o: Obj) callconv(.c) ?*const mirrors.MpObjType;
// mp_type_fun_builtin_2 is the vendor fun-builtin type singleton.
extern const mp_type_fun_builtin_2: anyopaque;
extern const mp_type_fun_builtin_3: anyopaque;

extern fn instance_count_native_bases(type_in: ?*const anyopaque, last_native_base: *?*const anyopaque) callconv(.c) c_int;

/// The native base object of an instance of a Python subclass of a native
/// type (the `dict` inside an instance of `class E(dict)`); any other
/// object is returned as it is.
pub fn nativeBase(self_in: Obj) Obj {
    const t = mp_obj_get_type(self_in).?;
    if (!t.flagInstanceType()) return self_in;
    var native: ?*const anyopaque = null;
    if (instance_count_native_bases(t, &native) == 0) return self_in;
    return mirrors.MpObjInstance.fromObj(self_in).subobjPtr()[0];
}

// These functions are the `__getitem__`/`__setitem__`/`__delitem__` of
// native types such as dict. Called on an instance of a Python subclass,
// as in `dict.__setitem__(self, k, v)`, they act on its native base
// object: the instance's own subscr would call the subclass's override,
// which calls them again, until the stack runs out.

export fn npy_op_fn_getitem(self_in: Obj, key_in: Obj) Obj {
    const self = nativeBase(self_in);
    return mp_obj_get_type(self).?.callSubscr(self, key_in, mirrors.OBJ_SENTINEL);
}
export fn npy_op_fn_setitem(self_in: Obj, key_in: Obj, value_in: Obj) Obj {
    const self = nativeBase(self_in);
    return mp_obj_get_type(self).?.callSubscr(self, key_in, value_in);
}
export fn npy_op_fn_delitem(self_in: Obj, key_in: Obj) Obj {
    const self = nativeBase(self_in);
    return mp_obj_get_type(self).?.callSubscr(self, key_in, mirrors.OBJ_NULL);
}
export fn npy_op_fn_contains(lhs_in: Obj, rhs_in: Obj) Obj {
    const t = mp_obj_get_type(lhs_in).?;
    return t.callBinaryOp(mp.MP_BINARY_OP_CONTAINS, lhs_in, rhs_in);
}

// ── ROM const fun-objects (vendor py/opmethods.c emits these via
// MP_DEFINE_CONST_FUN_OBJ_{2,3}). Layout via MpObjFunBuiltinFixed
// mirror — byte-identical to the C-emitted versions. ──
pub export const mp_op_getitem_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&npy_op_fn_getitem),
};
// setitem is a 3-arg fn — uses fun_builtin_3 (others use fun_builtin_2).
pub export const mp_op_setitem_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_3 },
    .fun = @ptrCast(&npy_op_fn_setitem),
};
pub export const mp_op_delitem_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&npy_op_fn_delitem),
};
pub export const mp_op_contains_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&npy_op_fn_contains),
};

comptime {
    _ = &npy_op_fn_getitem;
    _ = &npy_op_fn_setitem;
    _ = &npy_op_fn_delitem;
    _ = &npy_op_fn_contains;
    _ = &mp_op_getitem_obj;
    _ = &mp_op_setitem_obj;
    _ = &mp_op_delitem_obj;
    _ = &mp_op_contains_obj;
}
