//! petitpy — full Zig port of py/objzip.c. Previously a hybrid
//! port (Zig slot fns + C-shim glue); now self-contained.

const mp = @cImport({
    @cInclude("py/obj.h");
    @cInclude("py/qstr.h");
});
const mirrors = @import("../../mp_mirrors.zig");
const types = @import("../../mp_type_roms.zig");

const Obj = mirrors.Obj;

// Direct externs (replacing the npy_zip_* C-shim helpers).
extern fn mp_getiter(o: Obj, iter_buf: ?*anyopaque) callconv(.c) Obj;
extern fn mp_iternext(o: Obj) callconv(.c) Obj;
extern fn mp_obj_new_tuple(n: usize, items: [*c]const Obj) callconv(.c) Obj;
extern fn mp_obj_tuple_del(o: Obj) callconv(.c) Obj;
extern fn mp_arg_check_num_sig(n_args: usize, n_kw: usize, sig: u32) callconv(.c) void;
extern fn mp_obj_malloc_helper(n: usize, t: *const anyopaque) callconv(.c) ?*anyopaque;
extern const mp_type_type: anyopaque;

// `mp_obj_zip_t` mirror: { base, n_iters, iters[] flex }. iters[] is
// accessed past the struct via itersPtr.
const MpObjZip = extern struct {
    base: mirrors.MpObjBase,
    n_iters: usize,
    // iters[] flex array follows.

    inline fn fromObj(o: Obj) *MpObjZip {
        return @ptrFromInt(o);
    }
    inline fn itersPtr(self: *MpObjZip) [*]Obj {
        return @ptrFromInt(@intFromPtr(self) + @sizeOf(MpObjZip));
    }
};

// mp_arg_check_num sig: (0 << 17) | (MP_OBJ_FUN_ARGS_MAX << 1) | takes_kw.
const ARG_SIG_ZIP: u32 = (0 << 17) | (0xffff << 1) | 0;

// ROM type singleton — file-local (vendor's MP_DEFINE_CONST_OBJ_TYPE
// emitted external linkage; we keep it pub-export so vendor C code that
// references &mp_type_zip via extern decl still finds it).
pub export const mp_type_zip: types.MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = 0x0080, // MP_TYPE_FLAG_ITER_IS_ITERNEXT
        .name = mp.MP_QSTR_zip,
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
        @ptrCast(&npy_zip_fn_make_new),
        @ptrCast(&npy_zip_fn_iternext),
        null, null, null, null, null, null, null, null, null,
    },
};

export fn npy_zip_fn_make_new(type_in: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const Obj) Obj {
    mp_arg_check_num_sig(n_args, n_kw, ARG_SIG_ZIP);
    const total = @sizeOf(MpObjZip) + n_args * @sizeOf(Obj);
    const o: *MpObjZip = @ptrCast(@alignCast(mp_obj_malloc_helper(total, type_in.?).?));
    o.n_iters = n_args;
    var i: usize = 0;
    while (i < n_args) : (i += 1) {
        o.itersPtr()[i] = mp_getiter(args[i], null);
    }
    return @intFromPtr(o);
}

export fn npy_zip_fn_iternext(self_in: Obj) Obj {
    const self = MpObjZip.fromObj(self_in);
    if (self.n_iters == 0) return mirrors.OBJ_STOP_ITERATION;
    const tuple = mp_obj_new_tuple(self.n_iters, null);
    const tup_items = mirrors.MpObjTuple.fromObj(tuple).itemsPtr();
    var i: usize = 0;
    while (i < self.n_iters) : (i += 1) {
        const next = mp_iternext(self.itersPtr()[i]);
        if (next == mirrors.OBJ_STOP_ITERATION) {
            _ = mp_obj_tuple_del(tuple);
            return mirrors.OBJ_STOP_ITERATION;
        }
        tup_items[i] = next;
    }
    return tuple;
}

comptime {
    _ = &npy_zip_fn_make_new;
    _ = &npy_zip_fn_iternext;
    _ = &mp_type_zip;
}
