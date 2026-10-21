//! nanopython — Zig port of py/objcell.c (the entire file).
//! mp_type_cell is `static` — only referenced internally by
//! mp_obj_new_cell. Pair the two in Zig and the symbol stays
//! file-local.

const mp = @cImport({
    @cInclude("py/qstr.h");
});
const mirrors = @import("../../mp_mirrors.zig");
const types = @import("../../mp_type_roms.zig");

const Obj = mirrors.Obj;

extern const mp_type_type: anyopaque;
extern fn m_malloc(num_bytes: usize) callconv(.c) ?*anyopaque;

// File-local (not exported): mp_type_cell was `static` in vendor objcell.c.
const mp_type_cell: types.MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = 0, // FLAG_NONE
        .name = mp.MP_QSTR_,
        .slot_index_make_new = 0,
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
        .slot_index_locals_dict = 0,
    },
    .slots = .{ null, null, null, null, null, null, null, null, null, null, null },
};

pub export fn mp_obj_new_cell(obj: Obj) callconv(.c) Obj {
    const cell: *mirrors.MpObjCell = @ptrCast(@alignCast(m_malloc(@sizeOf(mirrors.MpObjCell)).?));
    cell.base.type = &mp_type_cell;
    cell.obj = obj;
    return @intFromPtr(cell);
}

comptime {
    _ = &mp_obj_new_cell;
}
