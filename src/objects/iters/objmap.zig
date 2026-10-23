//! petitpy — full Zig port of py/objmap.c.

const mp = @cImport({
    @cInclude("py/obj.h");
    @cInclude("py/qstr.h");
});
const mirrors = @import("../../mp_mirrors.zig");
const types = @import("../../mp_type_roms.zig");

const Obj = mirrors.Obj;

extern fn mp_call_function_n_kw(fun: Obj, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj;
extern fn mp_getiter(o: Obj, iter_buf: ?*anyopaque) callconv(.c) Obj;
extern fn mp_iternext(o: Obj) callconv(.c) Obj;
extern fn mp_arg_check_num_sig(n_args: usize, n_kw: usize, sig: u32) callconv(.c) void;
extern fn mp_obj_malloc_helper(n: usize, t: *const anyopaque) callconv(.c) ?*anyopaque;
extern fn m_malloc(num_bytes: usize) callconv(.c) ?*anyopaque;
extern fn m_free(ptr: ?*anyopaque) callconv(.c) void;
extern const mp_type_type: anyopaque;

// `mp_obj_map_t` mirror: { base, n_iters, fun, iters[] flex }.
const MpObjMap = extern struct {
    base: mirrors.MpObjBase,
    n_iters: usize,
    fun: Obj,
    // iters[] flex array follows.

    inline fn fromObj(o: Obj) *MpObjMap {
        return @ptrFromInt(o);
    }
    inline fn itersPtr(self: *MpObjMap) [*]Obj {
        return @ptrFromInt(@intFromPtr(self) + @sizeOf(MpObjMap));
    }
};

// mp_arg_check_num(2, MP_OBJ_FUN_ARGS_MAX, false): sig = (2<<17) | (0xffff<<1) | 0.
const ARG_SIG_MAP: u32 = (2 << 17) | (0xffff << 1) | 0;

pub export const mp_type_map: types.MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = 0x0080, // MP_TYPE_FLAG_ITER_IS_ITERNEXT
        .name = mp.MP_QSTR_map,
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
        @ptrCast(&npy_map_fn_make_new),
        @ptrCast(&npy_map_fn_iternext),
        null, null, null, null, null, null, null, null, null,
    },
};

export fn npy_map_fn_make_new(type_in: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const Obj) Obj {
    mp_arg_check_num_sig(n_args, n_kw, ARG_SIG_MAP);
    const n_iters = n_args - 1;
    const total = @sizeOf(MpObjMap) + n_iters * @sizeOf(Obj);
    const o: *MpObjMap = @ptrCast(@alignCast(mp_obj_malloc_helper(total, type_in.?).?));
    o.n_iters = n_iters;
    o.fun = args[0];
    var i: usize = 0;
    while (i < n_iters) : (i += 1) {
        o.itersPtr()[i] = mp_getiter(args[i + 1], null);
    }
    return @intFromPtr(o);
}

export fn npy_map_fn_iternext(self_in: Obj) Obj {
    const self = MpObjMap.fromObj(self_in);
    const n = self.n_iters;
    const nextses: [*]Obj = @ptrCast(@alignCast(m_malloc(n * @sizeOf(Obj)).?));
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const next = mp_iternext(self.itersPtr()[i]);
        if (next == mirrors.OBJ_STOP_ITERATION) {
            m_free(nextses);
            return mirrors.OBJ_STOP_ITERATION;
        }
        nextses[i] = next;
    }
    const ret = mp_call_function_n_kw(self.fun, n, 0, nextses);
    m_free(nextses);
    return ret;
}

comptime {
    _ = &npy_map_fn_make_new;
    _ = &npy_map_fn_iternext;
    _ = &mp_type_map;
}
