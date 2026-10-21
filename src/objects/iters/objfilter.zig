//! nanopython — Zig port of py/objfilter.c.

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
extern fn mp_getiter(o: Obj, iter_buf: ?*anyopaque) callconv(.c) Obj;
extern fn mp_iternext(o: Obj) callconv(.c) Obj;
extern fn mp_call_function_n_kw(fun: Obj, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj;
extern fn mp_obj_is_true(arg: Obj) callconv(.c) bool;

const MpObjFilter = extern struct {
    base: mirrors.MpObjBase,
    fun: Obj,
    iter: Obj,

    inline fn fromObj(o: Obj) *MpObjFilter {
        return @ptrFromInt(o);
    }
};

// MP_OBJ_FUN_MAKE_SIG(2, 2, false) = (2<<17) | (2<<1) | 0
const ARG_SIG_FILTER: u32 = (2 << 17) | (2 << 1) | 0;

export fn filter_make_new(type_in: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    mp_arg_check_num_sig(n_args, n_kw, ARG_SIG_FILTER);
    const o: *MpObjFilter = @ptrCast(@alignCast(mp_obj_malloc_helper(@sizeOf(MpObjFilter), type_in.?).?));
    o.base.type = type_in;
    o.fun = args[0];
    o.iter = mp_getiter(args[1], null);
    return @intFromPtr(o);
}

export fn filter_iternext(self_in: Obj) callconv(.c) Obj {
    const self = MpObjFilter.fromObj(self_in);
    while (true) {
        const next = mp_iternext(self.iter);
        if (next == mirrors.OBJ_STOP_ITERATION) return mirrors.OBJ_STOP_ITERATION;
        const val: Obj = if (self.fun != mirrors.OBJ_NONE)
            mp_call_function_n_kw(self.fun, 1, 0, @ptrCast(&next))
        else
            next;
        if (mp_obj_is_true(val)) return next;
    }
}

// MP_TYPE_FLAG_ITER_IS_ITERNEXT = 0x0080; slots: make_new=1, iter=2.
pub export const mp_type_filter: types.MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = 0x0080,
        .name = mp.MP_QSTR_filter,
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
        @ptrCast(&filter_make_new),
        @ptrCast(&filter_iternext),
        null, null, null, null, null, null, null, null, null,
    },
};

comptime {
    _ = &mp_type_filter;
    _ = &filter_make_new;
    _ = &filter_iternext;
}
