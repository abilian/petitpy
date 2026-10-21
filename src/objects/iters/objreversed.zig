//! nanopython — Zig port of py/objreversed.c.

const mp = @cImport({
    @cInclude("py/runtime.h");
    @cInclude("py/qstr.h");
});
const mirrors = @import("../../mp_mirrors.zig");
const types = @import("../../mp_type_roms.zig");

const Obj = mirrors.Obj;

extern const mp_type_type: anyopaque;
extern fn mp_arg_check_num_sig(n_args: usize, n_kw: usize, sig: u32) callconv(.c) void;
extern fn mp_obj_malloc_helper(num_bytes: usize, type_in: *const anyopaque) callconv(.c) ?*anyopaque;
extern fn mp_load_method_maybe(base: Obj, attr: usize, dest: [*]Obj) callconv(.c) void;
extern fn mp_call_method_n_kw(n_args: usize, n_kw: usize, args: [*]const Obj) callconv(.c) Obj;
extern fn mp_obj_get_int(arg: Obj) callconv(.c) isize;
extern fn mp_obj_len(o: Obj) callconv(.c) Obj;
extern fn mp_obj_subscr(base: Obj, index: Obj, value: Obj) callconv(.c) Obj;

const MpObjReversed = extern struct {
    base: mirrors.MpObjBase,
    seq: Obj,
    cur_index: usize,

    inline fn fromObj(o: Obj) *MpObjReversed {
        return @ptrFromInt(o);
    }
};

// MP_OBJ_FUN_MAKE_SIG(1, 1, false)
const ARG_SIG_REVERSED: u32 = (1 << 17) | (1 << 1) | 0;

export fn reversed_make_new(type_in: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    mp_arg_check_num_sig(n_args, n_kw, ARG_SIG_REVERSED);

    // Check if __reversed__ exists and delegate.
    var dest: [2]Obj = .{ 0, 0 };
    mp_load_method_maybe(args[0], mp.MP_QSTR___reversed__, &dest);
    if (dest[0] != mirrors.OBJ_NULL) {
        return mp_call_method_n_kw(0, 0, &dest);
    }

    const o: *MpObjReversed = @ptrCast(@alignCast(mp_obj_malloc_helper(@sizeOf(MpObjReversed), type_in.?).?));
    o.base.type = type_in;
    o.seq = args[0];
    o.cur_index = @intCast(mp_obj_get_int(mp_obj_len(args[0])));
    return @intFromPtr(o);
}

export fn reversed_iternext(self_in: Obj) callconv(.c) Obj {
    const self = MpObjReversed.fromObj(self_in);
    if (self.cur_index == 0) return mirrors.OBJ_STOP_ITERATION;
    self.cur_index -= 1;
    return mp_obj_subscr(self.seq, mirrors.newSmallInt(@bitCast(self.cur_index)), mirrors.OBJ_SENTINEL);
}

pub export const mp_type_reversed: types.MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = 0x0080, // MP_TYPE_FLAG_ITER_IS_ITERNEXT
        .name = mp.MP_QSTR_reversed,
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
        @ptrCast(&reversed_make_new),
        @ptrCast(&reversed_iternext),
        null, null, null, null, null, null, null, null, null,
    },
};

comptime {
    _ = &mp_type_reversed;
    _ = &reversed_make_new;
    _ = &reversed_iternext;
}
