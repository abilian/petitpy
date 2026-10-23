//! petitpy — full Zig port of py/objattrtuple.c.
//!
//! Layout: an attrtuple is a regular `mp_obj_tuple_t` whose flex
//! `items[]` is sized `len + 1`; the trailing slot stores the qstr-
//! field-name array as a fake-Obj pointer.

const mp = @cImport({
    @cInclude("py/qstr.h");
});
const mirrors = @import("../../mp_mirrors.zig");
const types = @import("../../mp_type_roms.zig");

const Obj = mirrors.Obj;
// qstr typedef = size_t (vendor py/qstr.h:60).
const Qstr = usize;

extern const mp_type_type: anyopaque;
extern const mp_type_tuple: anyopaque;
extern fn mp_obj_tuple_unary_op(op: c_int, self_in: Obj) callconv(.c) Obj;
extern fn mp_obj_tuple_binary_op(op: c_int, lhs: Obj, rhs: Obj) callconv(.c) Obj;
extern fn mp_obj_tuple_subscr(self_in: Obj, index: Obj, value: Obj) callconv(.c) Obj;
extern fn mp_obj_tuple_getiter(o_in: Obj, iter_buf: ?*anyopaque) callconv(.c) Obj;
extern fn mp_print_str(print: ?*const anyopaque, s: [*:0]const u8) callconv(.c) c_int;
extern fn mp_obj_print_helper(print: ?*const anyopaque, o: Obj, kind: c_int) callconv(.c) void;
extern fn mp_obj_malloc_helper(n: usize, t: *const anyopaque) callconv(.c) ?*anyopaque;
extern fn qstr_str(q: Qstr) callconv(.c) [*:0]const u8;

// Externally-callable: used by py/modcollections.c for namedtuple repr.
export fn mp_obj_attrtuple_print_helper(
    print: ?*const anyopaque,
    fields: [*]const Qstr,
    o: *mirrors.MpObjTuple,
) callconv(.c) void {
    _ = mp_print_str(print, "(");
    var i: usize = 0;
    while (i < o.len) : (i += 1) {
        if (i > 0) _ = mp_print_str(print, ", ");
        _ = mp_print_str(print, qstr_str(fields[i]));
        _ = mp_print_str(print, "=");
        mp_obj_print_helper(print, o.itemsPtr()[i], 1); // PRINT_REPR = 1
    }
    _ = mp_print_str(print, ")");
}

fn mp_obj_attrtuple_print(print: ?*const anyopaque, o_in: Obj, kind: c_int) callconv(.c) void {
    _ = kind;
    const o = mirrors.MpObjTuple.fromObj(o_in);
    // fields ptr stored in items[len] as a raw pointer disguised as Obj.
    const fields_obj = o.itemsPtr()[o.len];
    const fields: [*]const Qstr = @ptrFromInt(fields_obj);
    mp_obj_attrtuple_print_helper(print, fields, o);
}

fn mp_obj_attrtuple_attr(self_in: Obj, attr: Qstr, dest: [*]Obj) callconv(.c) void {
    if (dest[0] != mirrors.OBJ_NULL) return; // store path — no-op
    const self = mirrors.MpObjTuple.fromObj(self_in);
    const len = self.len;
    const fields: [*]const Qstr = @ptrFromInt(self.itemsPtr()[len]);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (fields[i] == attr) {
            dest[0] = self.itemsPtr()[i];
            return;
        }
    }
}

export fn mp_obj_new_attrtuple(
    fields: [*]const Qstr,
    n: usize,
    items: [*c]const Obj,
) callconv(.c) Obj {
    const total = @sizeOf(mirrors.MpObjTuple) + (n + 1) * @sizeOf(Obj);
    const o: *mirrors.MpObjTuple = @ptrCast(@alignCast(mp_obj_malloc_helper(total, &mp_type_attrtuple).?));
    o.len = n;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        o.itemsPtr()[i] = items[i];
    }
    o.itemsPtr()[n] = @intFromPtr(fields);
    return @intFromPtr(o);
}

// MP_TYPE_FLAG_ITER_IS_GETITER = 0x0000 (no flag bit set).
pub export const mp_type_attrtuple: types.MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = 0x0000,
        .name = mp.MP_QSTR_tuple,
        .slot_index_make_new = 0,
        .slot_index_print = 1,
        .slot_index_call = 0,
        .slot_index_unary_op = 2,
        .slot_index_binary_op = 3,
        .slot_index_attr = 4,
        .slot_index_subscr = 5,
        .slot_index_iter = 6,
        .slot_index_buffer = 0,
        .slot_index_protocol = 0,
        .slot_index_parent = 0,
        .slot_index_locals_dict = 0,
    },
    .slots = .{
        @ptrCast(&mp_obj_attrtuple_print),
        @ptrCast(&mp_obj_tuple_unary_op),
        @ptrCast(&mp_obj_tuple_binary_op),
        @ptrCast(&mp_obj_attrtuple_attr),
        @ptrCast(&mp_obj_tuple_subscr),
        @ptrCast(&mp_obj_tuple_getiter),
        null, null, null, null, null,
    },
};

comptime {
    _ = &mp_obj_attrtuple_print_helper;
    _ = &mp_obj_new_attrtuple;
    _ = &mp_type_attrtuple;
}
