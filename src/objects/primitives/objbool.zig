//! nanopython — full Zig port of py/objbool.c (incl. mp_type_bool ROM).
//! Nano: IMMEDIATE_OBJS=1 (mp_obj_bool_t / const false/true obj #if-dead),
//! PY_JSON=0 (bool_print → True/False always).
const mp = @cImport({
    @cInclude("py/qstr.h");
});
const mirrors = @import("../../mp_mirrors.zig");
const types = @import("../../mp_type_roms.zig");

const Obj = mirrors.Obj;

extern const mp_type_type: anyopaque;
extern fn mp_unary_op(op: c_int, o: Obj) callconv(.c) Obj;
extern fn mp_binary_op(op: c_int, lhs: Obj, rhs: Obj) callconv(.c) Obj;
extern fn mp_obj_is_true(arg: Obj) callconv(.c) bool;
extern fn mp_arg_check_num_sig(n_args: usize, n_kw: usize, sig: u32) callconv(.c) void;
extern fn mp_print_str(print: ?*const anyopaque, s: [*:0]const u8) callconv(.c) c_int;

// MP_OBJ_FUN_MAKE_SIG(0, 1, false) = (0<<17) | (1<<1) | 0
const ARG_SIG_BOOL: u32 = (0 << 17) | (1 << 1) | 0;

inline fn boolValue(o: Obj) bool {
    return o == mirrors.OBJ_TRUE;
}

export fn npy_bool_fn_print(print: ?*const anyopaque, self_in: Obj, kind: c_int) callconv(.c) void {
    _ = kind; // PY_JSON=0 — print "True"/"False" unconditionally
    _ = mp_print_str(print, if (boolValue(self_in)) "True" else "False");
}

export fn npy_bool_fn_make_new(type_in: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    _ = type_in;
    mp_arg_check_num_sig(n_args, n_kw, ARG_SIG_BOOL);
    if (n_args == 0) return mirrors.OBJ_FALSE;
    return mirrors.newBool(mp_obj_is_true(args[0]));
}

export fn npy_bool_fn_unary_op(op: c_int, o_in: Obj) callconv(.c) Obj {
    // MP_UNARY_OP_LEN = 5 (vendor mp_unary_op_t).
    if (op == 5) return mirrors.OBJ_NULL;
    const v: isize = if (boolValue(o_in)) 1 else 0;
    return mp_unary_op(op, mirrors.newSmallInt(v));
}

export fn npy_bool_fn_binary_op(op: c_int, lhs_in: Obj, rhs_in: Obj) callconv(.c) Obj {
    const v: isize = if (boolValue(lhs_in)) 1 else 0;
    return mp_binary_op(op, mirrors.newSmallInt(v), rhs_in);
}

pub export const mp_type_bool: types.MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = 0x0008, // MP_TYPE_FLAG_EQ_CHECKS_OTHER_TYPE
        .name = mp.MP_QSTR_bool,
        .slot_index_make_new = 1,
        .slot_index_print = 2,
        .slot_index_call = 0,
        .slot_index_unary_op = 3,
        .slot_index_binary_op = 4,
        .slot_index_attr = 0,
        .slot_index_subscr = 0,
        .slot_index_iter = 0,
        .slot_index_buffer = 0,
        .slot_index_protocol = 0,
        .slot_index_parent = 0,
        .slot_index_locals_dict = 0,
    },
    .slots = .{
        @ptrCast(&npy_bool_fn_make_new),
        @ptrCast(&npy_bool_fn_print),
        @ptrCast(&npy_bool_fn_unary_op),
        @ptrCast(&npy_bool_fn_binary_op),
        null, null, null, null, null, null, null,
    },
};

comptime {
    _ = &npy_bool_fn_print;
    _ = &npy_bool_fn_make_new;
    _ = &npy_bool_fn_unary_op;
    _ = &npy_bool_fn_binary_op;
    _ = &mp_type_bool;
}
