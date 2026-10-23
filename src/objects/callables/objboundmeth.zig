//! petitpy — full Zig port of py/objboundmeth.c (incl. mp_type_bound_meth ROM).
//!
//! Under nano: MICROPY_PY_BOUND_METHOD_FULL_EQUALITY_CHECK=0 →
//! binary_op uses pointer comparison (no mp_obj_equal). The print
//! branch (ERROR_REPORTING_DETAILED) is dead and dropped.
//! FUNCTION_ATTRS=1 → attr slot live.

const build_options = @import("build_options");
const mp = @cImport({
    @cInclude("py/runtime.h");
    @cInclude("py/qstr.h");
});
const mirrors = @import("../../mp_mirrors.zig");
const types = @import("../../mp_type_roms.zig");

const Obj = mirrors.Obj;

extern const mp_type_type: anyopaque;
extern fn mp_call_method_self_n_kw(meth: Obj, self_obj: Obj, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj;
extern fn mp_obj_malloc_helper(num_bytes: usize, type_in: ?*const anyopaque) callconv(.c) ?*anyopaque;
extern fn mp_load_method_maybe(base: Obj, attr: usize, dest: [*]Obj) callconv(.c) void;
extern fn mp_obj_equal(o1: Obj, o2: Obj) callconv(.c) bool;

export fn bound_meth_call(self_in: Obj, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    const o = mirrors.MpObjBoundMeth.fromObj(self_in);
    return mp_call_method_self_n_kw(o.meth, o.self_obj, n_args, n_kw, args);
}

export fn bound_meth_unary_op(op: c_int, self_in: Obj) callconv(.c) Obj {
    if (op != mp.MP_UNARY_OP_HASH) return mirrors.OBJ_NULL;
    const o = mirrors.MpObjBoundMeth.fromObj(self_in);
    const xored: isize = @bitCast(o.self_obj ^ o.meth);
    return mirrors.newSmallInt(xored);
}

export fn bound_meth_binary_op(op: c_int, lhs_in: Obj, rhs_in: Obj) callconv(.c) Obj {
    // FLAG_EQ_CHECKS_OTHER_TYPE clear → both sides same type guaranteed.
    if (op != mp.MP_BINARY_OP_EQUAL) return mirrors.OBJ_NULL;
    const l = mirrors.MpObjBoundMeth.fromObj(lhs_in);
    const r = mirrors.MpObjBoundMeth.fromObj(rhs_in);
    const same = if (comptime build_options.is_full)
        mp_obj_equal(l.self_obj, r.self_obj) and mp_obj_equal(l.meth, r.meth)
    else
        (l.self_obj == r.self_obj and l.meth == r.meth);
    return mirrors.newBool(same);
}

export fn mp_obj_new_bound_meth(meth: Obj, self_obj: Obj) callconv(.c) Obj {
    const raw = mp_obj_malloc_helper(@sizeOf(mirrors.MpObjBoundMeth), &mp_type_bound_meth);
    const o: *mirrors.MpObjBoundMeth = @ptrCast(@alignCast(raw));
    o.meth = meth;
    o.self_obj = self_obj;
    return @intFromPtr(o);
}

// FUNCTION_ATTRS=1 — attr slot live.
export fn bound_meth_attr(self_in: Obj, attr: u16, dest: [*]Obj) callconv(.c) void {
    if (dest[0] != 0) return; // not a load
    const o = mirrors.MpObjBoundMeth.fromObj(self_in);
    mp_load_method_maybe(o.meth, attr, dest);
}

// MP_TYPE_FLAG_NONE = 0. ERROR_REPORTING=TERSE → no print slot.
pub export const mp_type_bound_meth: types.MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = 0,
        .name = mp.MP_QSTR_bound_method,
        .slot_index_make_new = 0,
        .slot_index_print = 0,
        .slot_index_call = 2,
        .slot_index_unary_op = 3,
        .slot_index_binary_op = 4,
        .slot_index_attr = 1,
        .slot_index_subscr = 0,
        .slot_index_iter = 0,
        .slot_index_buffer = 0,
        .slot_index_protocol = 0,
        .slot_index_parent = 0,
        .slot_index_locals_dict = 0,
    },
    .slots = .{
        @ptrCast(&bound_meth_attr),
        @ptrCast(&bound_meth_call),
        @ptrCast(&bound_meth_unary_op),
        @ptrCast(&bound_meth_binary_op),
        null, null, null, null, null, null, null,
    },
};

comptime {
    _ = &bound_meth_call;
    _ = &bound_meth_unary_op;
    _ = &bound_meth_binary_op;
    _ = &mp_obj_new_bound_meth;
    _ = &bound_meth_attr;
    _ = &mp_type_bound_meth;
}
