//! nanopython — Zig port of py/sequence.c.
//! 5 class-A exports, 0 nlr-hosts (raises only via the verbatim
//! ValueError path — freely strangleable). Shim-tier (the argcheck
//! recipe): MP_BINARY_OP_* + obj helpers via npy_sq_*.
//! MICROPY_PY_BUILTINS_SLICE=0 (probed) ⇒ the two slice fns are
//! #if-dead; nano exports exactly these 5.
//!
//! Faithful (lesson #6): the C SWAP macro = whole-value swap (mirror
//! every field — here scalar ptr/len pairs); memcmp's <0/0/>0 via
//! std.mem.order; `mp_get_index` true→`is_slice` folded into the
//! shim. mp_raise_ValueError is MP_NORETURN (longjmps; Zig calls +
//! unreachable).

const std = @import("std");
const mp = @cImport({
    @cInclude("py/runtime.h");
});
const mirrors = @import("../../mp_mirrors.zig");
const pyerr = @import("../../pyerr.zig");
const PyError = pyerr.PyError;
const Obj = mirrors.Obj;

// Direct externs replacing the npy_sq_* C-shim helpers.
extern fn mp_obj_equal(o1: Obj, o2: Obj) callconv(.c) bool;
extern fn mp_binary_op(op: c_int, lhs: Obj, rhs: Obj) callconv(.c) Obj;
extern fn mp_get_index(t: *const anyopaque, len: usize, idx: Obj, is_slice: bool) callconv(.c) usize;
extern fn mp_obj_get_type(o: Obj) callconv(.c) *const anyopaque;
extern fn mp_obj_new_exception_msg(t: *const anyopaque, msg: [*:0]const u8) callconv(.c) Obj;
extern fn mp_obj_slice_indices(slice: Obj, len: isize, indexes: *anyopaque) callconv(.c) void;
extern fn mp_obj_new_list(n: usize, items: [*c]const Obj) callconv(.c) Obj;
extern fn mp_obj_list_append(list: Obj, val: Obj) callconv(.c) Obj;
extern const mp_type_ValueError: anyopaque;

inline fn binopIsTrue(op: c_int, a: Obj, b: Obj) bool {
    return mp_binary_op(op, a, b) == mirrors.OBJ_TRUE;
}
inline fn getIndex(arg0: Obj, len: usize, idx: Obj) usize {
    return mp_get_index(mp_obj_get_type(arg0), len, idx, true);
}

fn raiseNotInSeq() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_ValueError, "object not in sequence");
    return error.PyRaise;
}

export fn mp_seq_multiply(items: ?*const anyopaque, item_sz: usize, len: usize, times: usize, dest: ?*anyopaque) void {
    const src: [*]const u8 = @ptrCast(items.?);
    var d: [*]u8 = @ptrCast(dest.?);
    var i: usize = 0;
    while (i < times) : (i += 1) {
        const copy_sz = item_sz * len;
        @memcpy(d[0..copy_sz], src[0..copy_sz]);
        d += copy_sz; // dest = (char*)dest + copy_sz
    }
}

export fn mp_seq_cmp_bytes(op_in: usize, d1_in: [*c]const u8, l1_in: usize, d2_in: [*c]const u8, l2_in: usize) bool {
    var op: c_int = @intCast(op_in);
    var data1 = d1_in;
    var data2 = d2_in;
    var len1 = l1_in;
    var len2 = l2_in;
    if (op == mp.MP_BINARY_OP_EQUAL and len1 != len2) return false;
    if (op == mp.MP_BINARY_OP_LESS or op == mp.MP_BINARY_OP_LESS_EQUAL) {
        std.mem.swap(@TypeOf(data1), &data1, &data2); // SWAP(const byte*)
        std.mem.swap(usize, &len1, &len2); // SWAP(size_t)
        op = if (op == mp.MP_BINARY_OP_LESS) mp.MP_BINARY_OP_MORE else mp.MP_BINARY_OP_MORE_EQUAL;
    }
    const min_len = if (len1 < len2) len1 else len2;
    // Empty-prefix short-circuit: vendor C accepts NULL buf when len=0
    // (e.g. b"" or zero-length array slice); Zig's [*c]→[]u8 cast panics
    // on the deref even with min_len=0.
    const ord = if (min_len == 0)
        std.math.Order.eq
    else
        std.mem.order(u8, data1[0..min_len], data2[0..min_len]);
    if (op == mp.MP_BINARY_OP_EQUAL) return ord == .eq;
    if (ord == .lt) return false; // res < 0
    if (ord == .gt) return true; // res > 0
    // tie in the compared prefix
    if (len1 != len2) {
        if (len1 < len2) return false;
    } else if (op == mp.MP_BINARY_OP_MORE) {
        return false;
    }
    return true;
}

export fn mp_seq_cmp_objs(op_in: usize, i1_in: [*c]const Obj, l1_in: usize, i2_in: [*c]const Obj, l2_in: usize) bool {
    var op: c_int = @intCast(op_in);
    var items1 = i1_in;
    var items2 = i2_in;
    var len1 = l1_in;
    var len2 = l2_in;
    if (op == mp.MP_BINARY_OP_EQUAL and len1 != len2) return false;
    if (op == mp.MP_BINARY_OP_LESS or op == mp.MP_BINARY_OP_LESS_EQUAL) {
        std.mem.swap(@TypeOf(items1), &items1, &items2);
        std.mem.swap(usize, &len1, &len2);
        op = if (op == mp.MP_BINARY_OP_LESS) mp.MP_BINARY_OP_MORE else mp.MP_BINARY_OP_MORE_EQUAL;
    }
    const len = if (len1 < len2) len1 else len2;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (mp_obj_equal(items1[i], items2[i])) continue;
        if (op == mp.MP_BINARY_OP_EQUAL) return false;
        return binopIsTrue(op, items1[i], items2[i]);
    }
    if (len1 != len2) {
        if (len1 < len2) return false;
    } else if (op == mp.MP_BINARY_OP_MORE) {
        return false;
    }
    return true;
}

fn mpSeqIndexObjImpl(items: [*c]const Obj, len: usize, n_args: usize, args: [*c]const Obj) PyError!Obj {
    const value = args[1];
    var start: usize = 0;
    var stop: usize = len;
    if (n_args >= 3) {
        start = getIndex(args[0], len, args[2]);
        if (n_args >= 4) {
            stop = getIndex(args[0], len, args[3]);
        }
    }
    var i: usize = start;
    while (i < stop) : (i += 1) {
        if (mp_obj_equal(items[i], value)) {
            return mirrors.newSmallInt(@bitCast(i));
        }
    }
    try raiseNotInSeq();
    unreachable;
}
export fn mp_seq_index_obj(items: [*c]const Obj, len: usize, n_args: usize, args: [*c]const Obj) Obj {
    return pyerr.bridge(Obj, mpSeqIndexObjImpl(items, len, n_args, args));
}

export fn mp_seq_count_obj(items: [*c]const Obj, len: usize, value: Obj) Obj {
    var count: usize = 0;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (mp_obj_equal(items[i], value)) count += 1;
    }
    return mirrors.newSmallInt(@bitCast(count));
}

// mp_bound_slice_t (obj.h:1215): { start, stop, step } isize trio.
const MpBoundSlice = extern struct {
    start: isize,
    stop: isize,
    step: isize,
};

// Ported from sequence_shim.c (added in 0.2; vendor sequence.c excluded).
export fn mp_seq_get_fast_slice_indexes(len: usize, slice: Obj, indexes: *MpBoundSlice) callconv(.c) bool {
    mp_obj_slice_indices(slice, @bitCast(len), @ptrCast(indexes));
    if (indexes.step < 0) indexes.stop += 1;
    if (indexes.step > 0 and indexes.start > indexes.stop) {
        indexes.stop = indexes.start;
    } else if (indexes.step < 0 and indexes.start < indexes.stop) {
        indexes.stop = indexes.start + 1;
    }
    return indexes.step == 1;
}

export fn mp_seq_extract_slice(seq: [*c]const Obj, indexes: *MpBoundSlice) callconv(.c) Obj {
    var start = indexes.start;
    const stop = indexes.stop;
    const step = indexes.step;
    const res = mp_obj_new_list(0, null);
    if (step < 0) {
        while (start >= stop) : (start += step) {
            _ = mp_obj_list_append(res, seq[@bitCast(start)]);
        }
    } else {
        while (start < stop) : (start += step) {
            _ = mp_obj_list_append(res, seq[@bitCast(start)]);
        }
    }
    return res;
}

comptime {
    _ = &mp_seq_multiply;
    _ = &mp_seq_cmp_bytes;
    _ = &mp_seq_cmp_objs;
    _ = &mp_seq_index_obj;
    _ = &mp_seq_count_obj;
    _ = &mp_seq_get_fast_slice_indexes;
    _ = &mp_seq_extract_slice;
}
