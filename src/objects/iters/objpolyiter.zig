//! petitpy — full Zig port of py/objpolyiter.c (excluding the
//! ENABLE_FINALISER variant which is dead under both nano and full).
//! Universal iterator type: stores an `iternext` fn-ptr at offset 8;
//! dispatches via indirect call.

const mp = @cImport({
    @cInclude("py/qstr.h");
});
const mirrors = @import("../../mp_mirrors.zig");
const types = @import("../../mp_type_roms.zig");

const Obj = mirrors.Obj;

extern const mp_type_type: anyopaque;

const IterNextFn = *const fn (Obj) callconv(.c) Obj;

const MpObjPolymorphIter = extern struct {
    base: mirrors.MpObjBase,
    iternext: IterNextFn,
};

fn polymorph_it_iternext(self_in: Obj) callconv(.c) Obj {
    const self: *const MpObjPolymorphIter = @ptrFromInt(self_in);
    return self.iternext(self_in);
}

pub export const mp_type_polymorph_iter: types.MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = 0x0080, // MP_TYPE_FLAG_ITER_IS_ITERNEXT
        .name = mp.MP_QSTR_iterator,
        .slot_index_make_new = 0,
        .slot_index_print = 0,
        .slot_index_call = 0,
        .slot_index_unary_op = 0,
        .slot_index_binary_op = 0,
        .slot_index_attr = 0,
        .slot_index_subscr = 0,
        .slot_index_iter = 1,
        .slot_index_buffer = 0,
        .slot_index_protocol = 0,
        .slot_index_parent = 0,
        .slot_index_locals_dict = 0,
    },
    .slots = .{
        @ptrCast(&polymorph_it_iternext),
        null, null, null, null, null, null, null, null, null, null,
    },
};

comptime {
    _ = &mp_type_polymorph_iter;
}
