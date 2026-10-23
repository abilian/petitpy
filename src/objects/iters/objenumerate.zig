//! petitpy — Zig port of py/objenumerate.c.
//! Under nano CPYTHON_COMPAT=1 → make_new takes kw args (iterable=, start=).

const build_options = @import("build_options");
const mp = @cImport({
    @cInclude("py/runtime.h");
    @cInclude("py/qstr.h");
});
const mirrors = @import("../../mp_mirrors.zig");
const pyerr = @import("../../pyerr.zig");
const types = @import("../../mp_type_roms.zig");

const Obj = mirrors.Obj;

extern const mp_type_type: anyopaque;
extern fn mp_arg_check_num_sig(n_args: usize, n_kw: usize, sig: u32) callconv(.c) void;
extern fn mp_obj_malloc_helper(num_bytes: usize, type_in: *const anyopaque) callconv(.c) ?*anyopaque;
extern fn mp_arg_parse_all_kw_array(n_pos: usize, n_kw: usize, args: [*c]const Obj, n_allowed: usize, allowed: ?*const anyopaque, out: ?*anyopaque) callconv(.c) void;
extern fn mp_getiter(o: Obj, iter_buf: ?*anyopaque) callconv(.c) Obj;
extern fn mp_iternext(o: Obj) callconv(.c) Obj;
extern fn mp_obj_get_int(arg: Obj) callconv(.c) isize;
extern fn mp_obj_new_tuple(n: usize, items: [*c]const Obj) callconv(.c) Obj;

const MpObjEnumerate = extern struct {
    base: mirrors.MpObjBase,
    iter: Obj,
    cur: isize,

    inline fn fromObj(o: Obj) *MpObjEnumerate {
        return @ptrFromInt(o);
    }
};

// MICROPY_CPYTHON_COMPAT=1 under both nano and full → kw-args path.
// MP_ARG_REQUIRED|MP_ARG_OBJ = 0x103; MP_ARG_INT = 0x002.
const allowed_args = [_]mirrors.MpArg{
    .{ .qst = mp.MP_QSTR_iterable, .flags = 0x103, .defval = .{ .u_obj = mirrors.OBJ_NULL } },
    .{ .qst = mp.MP_QSTR_start, .flags = 0x002, .defval = .{ .u_int = 0 } },
};

export fn enumerate_make_new(type_in: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    var arg_vals: [2]mirrors.MpArgVal = undefined;
    mp_arg_parse_all_kw_array(n_args, n_kw, args, allowed_args.len, &allowed_args, &arg_vals);
    if (pyerr.pending_exc != 0) return mirrors.OBJ_NULL;
    const o: *MpObjEnumerate = @ptrCast(@alignCast(mp_obj_malloc_helper(@sizeOf(MpObjEnumerate), type_in.?).?));
    o.base.type = type_in;
    o.iter = mp_getiter(arg_vals[0].u_obj, null);
    o.cur = arg_vals[1].u_int;
    return @intFromPtr(o);
}

export fn enumerate_iternext(self_in: Obj) callconv(.c) Obj {
    const self = MpObjEnumerate.fromObj(self_in);
    const next = mp_iternext(self.iter);
    if (next == mirrors.OBJ_STOP_ITERATION) return mirrors.OBJ_STOP_ITERATION;
    const items = [_]Obj{ mirrors.newSmallInt(self.cur), next };
    self.cur += 1;
    return mp_obj_new_tuple(2, &items);
}

pub export const mp_type_enumerate: types.MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = 0x0080, // MP_TYPE_FLAG_ITER_IS_ITERNEXT
        .name = mp.MP_QSTR_enumerate,
        .slot_index_make_new = 1,
        .slot_index_print = 0,
        .slot_index_call = 0,
        .slot_index_unary_op = 0,
        .slot_index_binary_op = 0,
        .slot_index_attr = 0,
        .slot_index_subscr = 0,
        .slot_index_iter = 2,
        .slot_index_buffer = 0,
        .slot_index_protocol = 0,
        .slot_index_parent = 0,
        .slot_index_locals_dict = 0,
    },
    .slots = .{
        @ptrCast(&enumerate_make_new),
        @ptrCast(&enumerate_iternext),
        null, null, null, null, null, null, null, null, null,
    },
};

comptime {
    _ = &mp_type_enumerate;
    _ = &enumerate_make_new;
    _ = &enumerate_iternext;
}
