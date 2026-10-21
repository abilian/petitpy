//! nanopython — Zig port of py/objproperty.c.
//! property(fget, fset, fdel, doc) — 4 kw-args, doc ignored.

const mp = @cImport({
    @cInclude("py/runtime.h");
    @cInclude("py/qstr.h");
});
const mirrors = @import("../../mp_mirrors.zig");
const pyerr = @import("../../pyerr.zig");
const types = @import("../../mp_type_roms.zig");

const Obj = mirrors.Obj;
const Qstr = usize;

extern const mp_type_type: anyopaque;
extern const mp_type_dict: anyopaque;
extern const mp_type_fun_builtin_2: anyopaque;
extern fn mp_arg_parse_all_kw_array(n_pos: usize, n_kw: usize, args: [*c]const Obj, n_allowed: usize, allowed: ?*const anyopaque, out: ?*anyopaque) callconv(.c) void;
extern fn mp_obj_malloc_helper(num_bytes: usize, type_in: *const anyopaque) callconv(.c) ?*anyopaque;
extern fn m_malloc(num_bytes: usize) callconv(.c) ?*anyopaque;

const MpObjProperty = extern struct {
    base: mirrors.MpObjBase,
    proxy: [3]Obj, // getter, setter, deleter

    inline fn fromObj(o: Obj) *MpObjProperty {
        return @ptrFromInt(o);
    }
};

// MP_ARG_OBJ = 0x003. Names: empty qstr (positional-only) for 3 entries, then `doc`.
// MP_QSTR_ = 1 (empty qstr — first slot in qstrdefs).
const allowed_args = [_]mirrors.MpArg{
    .{ .qst = mp.MP_QSTR_, .flags = 0x003, .defval = .{ .u_rom_obj = mirrors.OBJ_NONE } },
    .{ .qst = mp.MP_QSTR_, .flags = 0x003, .defval = .{ .u_rom_obj = mirrors.OBJ_NONE } },
    .{ .qst = mp.MP_QSTR_, .flags = 0x003, .defval = .{ .u_rom_obj = mirrors.OBJ_NONE } },
    .{ .qst = mp.MP_QSTR_doc, .flags = 0x003, .defval = .{ .u_rom_obj = mirrors.OBJ_NONE } },
};

export fn property_make_new(type_in: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    var vals: [4]mirrors.MpArgVal = undefined;
    mp_arg_parse_all_kw_array(n_args, n_kw, args, allowed_args.len, &allowed_args, &vals);
    if (pyerr.pending_exc != 0) return mirrors.OBJ_NULL;
    const o: *MpObjProperty = @ptrCast(@alignCast(mp_obj_malloc_helper(@sizeOf(MpObjProperty), type_in.?).?));
    o.base.type = type_in;
    o.proxy[0] = vals[0].u_obj;
    o.proxy[1] = vals[1].u_obj;
    o.proxy[2] = vals[2].u_obj;
    // vals[3] (doc) silently discarded
    return @intFromPtr(o);
}

inline fn cloneWith(self_in: Obj, slot: usize, value: Obj) Obj {
    const p2: *MpObjProperty = @ptrCast(@alignCast(m_malloc(@sizeOf(MpObjProperty)).?));
    p2.* = MpObjProperty.fromObj(self_in).*;
    p2.proxy[slot] = value;
    return @intFromPtr(p2);
}

fn property_getter(self_in: Obj, getter: Obj) callconv(.c) Obj {
    return cloneWith(self_in, 0, getter);
}
fn property_setter(self_in: Obj, setter: Obj) callconv(.c) Obj {
    return cloneWith(self_in, 1, setter);
}
fn property_deleter(self_in: Obj, deleter: Obj) callconv(.c) Obj {
    return cloneWith(self_in, 2, deleter);
}

pub export const property_getter_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&property_getter),
};
pub export const property_setter_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&property_setter),
};
pub export const property_deleter_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&property_deleter),
};

const RomEntry = extern struct {
    key: Obj,
    value: *const anyopaque,
};
const property_locals_dict_table = [_]RomEntry{
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_getter)), .value = &property_getter_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_setter)), .value = &property_setter_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_deleter)), .value = &property_deleter_obj },
};
pub export const property_locals_dict: mirrors.MpObjDict = .{
    .base = .{ .type = &mp_type_dict },
    .map = .{
        .bits = .{ .all_keys_are_qstrs = 1, .is_fixed = 1, .is_ordered = 1, .used = property_locals_dict_table.len },
        .alloc = property_locals_dict_table.len,
        .table = @ptrCast(@constCast(&property_locals_dict_table)),
    },
};

pub export const mp_type_property: types.MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = 0,
        .name = mp.MP_QSTR_property,
        .slot_index_make_new = 1,
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
        .slot_index_locals_dict = 2,
    },
    .slots = .{
        @ptrCast(&property_make_new),
        @ptrCast(&property_locals_dict),
        null, null, null, null, null, null, null, null, null,
    },
};

pub export fn mp_obj_property_get(self_in: Obj) callconv(.c) [*]const Obj {
    return &MpObjProperty.fromObj(self_in).proxy;
}

comptime {
    _ = &mp_type_property;
    _ = &property_make_new;
    _ = &property_locals_dict;
    _ = &mp_obj_property_get;
}
