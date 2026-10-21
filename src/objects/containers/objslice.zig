//! nanopython — Zig port of py/objslice.c.
//!
//! Config (under both nano and full): SLICE=1, SLICE_INDICES=1.
//! SLICE_ATTRS: 0 under nano (locals_dict with indices method only),
//!              1 under full (attr fn).
//!
//! Both configs have slot order: unary_op=1, (locals_dict|attr)=2, print=3.

const build_options = @import("build_options");
const mp = @cImport({
    @cInclude("py/runtime.h");
    @cInclude("py/qstr.h");
});
const mirrors = @import("../../mp_mirrors.zig");
const types = @import("../../mp_type_roms.zig");
const pyerr = @import("../../pyerr.zig");
const PyError = pyerr.PyError;

const Obj = mirrors.Obj;
const Qstr = usize;

extern const mp_type_type: anyopaque;
extern const mp_type_dict: anyopaque;
extern const mp_type_ValueError: anyopaque;
extern const mp_type_fun_builtin_2: anyopaque;
extern fn mp_obj_malloc_helper(num_bytes: usize, type_in: *const anyopaque) callconv(.c) ?*anyopaque;
extern fn mp_obj_get_int(arg: Obj) callconv(.c) isize;
extern fn mp_obj_new_tuple(n: usize, items: [*c]const Obj) callconv(.c) Obj;
extern fn mp_obj_print_helper(print: ?*const anyopaque, o: Obj, kind: c_int) callconv(.c) void;
extern fn mp_print_str(print: ?*const anyopaque, s: [*:0]const u8) callconv(.c) c_int;
extern fn mp_obj_new_exception_msg(t: *const anyopaque, msg: [*:0]const u8) callconv(.c) Obj;

// Raise helper (PyError convention).
// Sets pyerr.pending_exc + returns error.PyRaise — the C-ABI export
// wraps the impl with pyerr.bridge which catches and returns the
// zero sentinel (callers poll pending_exc).
fn raiseStepZero() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_ValueError, "slice step can't be zero");
    return error.PyRaise;
}

const MpObjSlice = extern struct {
    base: mirrors.MpObjBase,
    start: Obj,
    stop: Obj,
    step: Obj,

    inline fn fromObj(o: Obj) *MpObjSlice {
        return @ptrFromInt(o);
    }
};

const MpBoundSlice = extern struct { start: isize, stop: isize, step: isize };

fn slice_print(print: ?*const anyopaque, o_in: Obj, kind: c_int) callconv(.c) void {
    _ = kind;
    const o = MpObjSlice.fromObj(o_in);
    _ = mp_print_str(print, "slice(");
    mp_obj_print_helper(print, o.start, mp.PRINT_REPR);
    _ = mp_print_str(print, ", ");
    mp_obj_print_helper(print, o.stop, mp.PRINT_REPR);
    _ = mp_print_str(print, ", ");
    mp_obj_print_helper(print, o.step, mp.PRINT_REPR);
    _ = mp_print_str(print, ")");
}

fn slice_unary_op(op: c_int, o_in: Obj) callconv(.c) Obj {
    _ = op;
    _ = o_in;
    // Explicitly opt out of default __hash__.
    return mirrors.OBJ_NULL;
}

fn sliceIndicesMethodImpl(self_in: Obj, length_obj: Obj) PyError!Obj {
    const length = mp_obj_get_int(length_obj);
    var b = MpBoundSlice{ .start = 0, .stop = 0, .step = 0 };
    try mpObjSliceIndicesImpl(self_in, length, &b);
    const results = [_]Obj{
        mirrors.newSmallInt(b.start),
        mirrors.newSmallInt(b.stop),
        mirrors.newSmallInt(b.step),
    };
    return mp_obj_new_tuple(3, &results);
}

fn slice_indices_impl(self_in: Obj, length_obj: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, sliceIndicesMethodImpl(self_in, length_obj));
}

pub export const slice_indices_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&slice_indices_impl),
};

// Under nano (ATTRS=0): slot table has only `.indices` method.
const RomEntry = extern struct {
    key: Obj,
    value: *const anyopaque,
};
const slice_locals_dict_table = [_]RomEntry{
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_indices)), .value = &slice_indices_obj },
};
pub export const slice_locals_dict: mirrors.MpObjDict = .{
    .base = .{ .type = &mp_type_dict },
    .map = .{
        .bits = .{ .all_keys_are_qstrs = 1, .is_fixed = 1, .is_ordered = 1, .used = slice_locals_dict_table.len },
        .alloc = slice_locals_dict_table.len,
        .table = @ptrCast(@constCast(&slice_locals_dict_table)),
    },
};

// Under full (ATTRS=1): slice_attr provides start/stop/step + indices.
fn slice_attr(self_in: Obj, attr: u16, dest: [*]Obj) callconv(.c) void {
    if (dest[0] != mirrors.OBJ_NULL) return;
    const self = MpObjSlice.fromObj(self_in);
    if (attr == mp.MP_QSTR_start) dest[0] = self.start
    else if (attr == mp.MP_QSTR_stop) dest[0] = self.stop
    else if (attr == mp.MP_QSTR_step) dest[0] = self.step
    else if (attr == mp.MP_QSTR_indices) {
        dest[0] = @intFromPtr(&slice_indices_obj);
        dest[1] = self_in;
    }
}

pub export fn mp_obj_new_slice(ostart: Obj, ostop: Obj, ostep: Obj) callconv(.c) Obj {
    const o: *MpObjSlice = @ptrCast(@alignCast(mp_obj_malloc_helper(@sizeOf(MpObjSlice), &mp_type_slice).?));
    o.start = ostart;
    o.stop = ostop;
    o.step = ostep;
    return @intFromPtr(o);
}

fn mpObjSliceIndicesImpl(self_in: Obj, length: isize, result: *MpBoundSlice) PyError!void {
    const self = MpObjSlice.fromObj(self_in);
    var step: isize = undefined;
    if (self.step == mirrors.OBJ_NONE) {
        step = 1;
    } else {
        step = mp_obj_get_int(self.step);
        if (step == 0) try raiseStepZero();
    }

    var start: isize = undefined;
    var stop: isize = undefined;
    if (step > 0) {
        if (self.start == mirrors.OBJ_NONE) {
            start = 0;
        } else {
            start = mp_obj_get_int(self.start);
            if (start < 0) start += length;
            start = @min(length, @max(start, 0));
        }
        if (self.stop == mirrors.OBJ_NONE) {
            stop = length;
        } else {
            stop = mp_obj_get_int(self.stop);
            if (stop < 0) stop += length;
            stop = @min(length, @max(stop, 0));
        }
    } else {
        if (self.start == mirrors.OBJ_NONE) {
            start = length - 1;
        } else {
            start = mp_obj_get_int(self.start);
            if (start < 0) start += length;
            start = @min(length - 1, @max(start, -1));
        }
        if (self.stop == mirrors.OBJ_NONE) {
            stop = -1;
        } else {
            stop = mp_obj_get_int(self.stop);
            if (stop < 0) stop += length;
            stop = @min(length - 1, @max(stop, -1));
        }
    }
    result.start = start;
    result.stop = stop;
    result.step = step;
}

pub export fn mp_obj_slice_indices(self_in: Obj, length: isize, result: *MpBoundSlice) callconv(.c) void {
    pyerr.bridge(void, mpObjSliceIndicesImpl(self_in, length, result));
}

// mp_type_slice: slot order unary_op=1, locals_dict|attr=2, print=3.
pub export const mp_type_slice: types.MpObjTypeFull = if (build_options.is_full) .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = 0,
        .name = mp.MP_QSTR_slice,
        .slot_index_make_new = 0,
        .slot_index_print = 3,
        .slot_index_call = 0,
        .slot_index_unary_op = 1,
        .slot_index_binary_op = 0,
        .slot_index_attr = 2,
        .slot_index_subscr = 0,
        .slot_index_iter = 0,
        .slot_index_buffer = 0,
        .slot_index_protocol = 0,
        .slot_index_parent = 0,
        .slot_index_locals_dict = 0,
    },
    .slots = .{
        @ptrCast(&slice_unary_op),
        @ptrCast(&slice_attr),
        @ptrCast(&slice_print),
        null, null, null, null, null, null, null, null,
    },
} else .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = 0,
        .name = mp.MP_QSTR_slice,
        .slot_index_make_new = 0,
        .slot_index_print = 3,
        .slot_index_call = 0,
        .slot_index_unary_op = 1,
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
        @ptrCast(&slice_unary_op),
        @ptrCast(&slice_locals_dict),
        @ptrCast(&slice_print),
        null, null, null, null, null, null, null, null,
    },
};

comptime {
    _ = &mp_type_slice;
    _ = &mp_obj_new_slice;
    _ = &mp_obj_slice_indices;
    _ = &slice_indices_obj;
    _ = &slice_locals_dict;
}
