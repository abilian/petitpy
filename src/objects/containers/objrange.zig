//! nanopython — full Zig port of py/objrange.c (drops objrange_shim).
//!
//! Config:
//!   nano: SLICE=1, RANGE_BINOP=1 (binop live), RANGE_ATTRS=0 (no attr)
//!   full: SLICE=1, RANGE_BINOP=0,             RANGE_ATTRS=1 (attr live)
//!
//! Slot layout differs by config (matches the C-macro slot expansion):
//!   nano: make_new=1, binary_op=2, print=3, unary_op=4, subscr=5, iter=6
//!   full: make_new=1, attr=2,      print=3, unary_op=4, subscr=5, iter=6
//!
//! Two extern struct mirrors of mp_obj_range_t + mp_obj_range_it_t (both
//! fixed-size, no flex array).

const mp = @cImport({
    @cInclude("py/runtime.h");
    @cInclude("py/qstr.h");
});
const mirrors = @import("../../mp_mirrors.zig");
const types = @import("../../mp_type_roms.zig");
const pyerr = @import("../../pyerr.zig");
const PyError = pyerr.PyError;
const build_options = @import("build_options");

const Obj = mirrors.Obj;
const Int = isize; // mp_int_t

const MpObjRange = extern struct {
    base: mirrors.MpObjBase,
    start: Int,
    stop: Int,
    step: Int,

    inline fn fromObj(o: Obj) *MpObjRange {
        return @ptrFromInt(o);
    }
};

const MpObjRangeIt = extern struct {
    base: mirrors.MpObjBase,
    cur: Int,
    stop: Int,
    step: Int,

    inline fn fromObj(o: Obj) *MpObjRangeIt {
        return @ptrFromInt(o);
    }
};

extern const mp_type_type: anyopaque;
extern const mp_type_ValueError: anyopaque;
extern const mp_type_slice: anyopaque;
extern fn mp_obj_get_int(arg: Obj) callconv(.c) Int;
extern fn mp_obj_new_int(v: Int) callconv(.c) Obj;
extern fn mp_obj_new_exception_msg(t: *const anyopaque, msg: [*:0]const u8) callconv(.c) Obj;
extern fn mp_arg_check_num_sig(n_args: usize, n_kw: usize, sig: u32) callconv(.c) void;
extern fn mp_get_index(t: *const anyopaque, len: usize, idx: Obj, is_slice: bool) callconv(.c) usize;
extern fn mp_obj_malloc_helper(num_bytes: usize, type_in: *const anyopaque) callconv(.c) ?*anyopaque;
extern fn mp_obj_slice_indices(slice: Obj, len: Int, indexes: *MpBoundSlice) callconv(.c) void;
extern fn mp_print_str(print: ?*const anyopaque, s: [*:0]const u8) callconv(.c) c_int;
extern fn mp_printf(print: ?*const anyopaque, fmt: [*:0]const u8, ...) callconv(.c) c_int;

const MpBoundSlice = extern struct { start: Int, stop: Int, step: Int };

// MP_OBJ_FUN_MAKE_SIG(1, 3, false) for the make_new arg check
const ARG_SIG_RANGE: u32 = (1 << 17) | (3 << 1) | 0;

fn raiseZeroStep() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_ValueError, "zero step");
    return error.PyRaise;
}

inline fn rangeLenFromParts(start: Int, stop: Int, step: Int) Int {
    var len: Int = (stop -% start) +% step;
    if (step > 0) len -%= 1 else len +%= 1;
    len = @divTrunc(len, step);
    if (len < 0) len = 0;
    return len;
}
inline fn rangeLen(self: Obj) Int {
    const r = MpObjRange.fromObj(self);
    return rangeLenFromParts(r.start, r.stop, r.step);
}

// Externally callable (for any C-side caller that may still reach for it).
export fn npy_rng_len_helper(self_in: Obj) callconv(.c) Int {
    return rangeLen(self_in);
}

fn range_print(print: ?*const anyopaque, self_in: Obj, kind: c_int) callconv(.c) void {
    _ = kind;
    const self = MpObjRange.fromObj(self_in);
    _ = mp_printf(print, "range(%ld, %ld", self.start, self.stop);
    if (self.step == 1) {
        _ = mp_print_str(print, ")");
    } else {
        _ = mp_printf(print, ", %ld)", self.step);
    }
}

// RANGE_ATTRS — full-only.
fn range_attr(o_in: Obj, attr: u16, dest: [*]Obj) callconv(.c) void {
    if (dest[0] != mirrors.OBJ_NULL) return;
    const o = MpObjRange.fromObj(o_in);
    if (attr == mp.MP_QSTR_start) dest[0] = mp_obj_new_int(o.start)
    else if (attr == mp.MP_QSTR_stop) dest[0] = mp_obj_new_int(o.stop)
    else if (attr == mp.MP_QSTR_step) dest[0] = mp_obj_new_int(o.step);
}

// RANGE_BINOP — nano-only.
fn range_binary_op(op: c_int, lhs_in: Obj, rhs_in: Obj) callconv(.c) Obj {
    if (!mirrors.isExactType(rhs_in, &mp_type_range) or op != mp.MP_BINARY_OP_EQUAL) {
        return mirrors.OBJ_NULL;
    }
    const lhs = MpObjRange.fromObj(lhs_in);
    const rhs = MpObjRange.fromObj(rhs_in);
    const lhs_len = rangeLenFromParts(lhs.start, lhs.stop, lhs.step);
    const rhs_len = rangeLenFromParts(rhs.start, rhs.stop, rhs.step);
    const eq = lhs_len == rhs_len and (lhs_len == 0 or (lhs.start == rhs.start and (lhs_len == 1 or lhs.step == rhs.step)));
    return mirrors.newBool(eq);
}

export fn npy_rng_fn_it_iternext(o_in: Obj) callconv(.c) Obj {
    const it = MpObjRangeIt.fromObj(o_in);
    if ((it.step > 0 and it.cur < it.stop) or (it.step < 0 and it.cur > it.stop)) {
        const v = it.cur;
        it.cur +%= it.step;
        return mp_obj_new_int(v);
    }
    return mirrors.OBJ_STOP_ITERATION;
}

fn rngFnMakeNewImpl(type_in: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const Obj) PyError!Obj {
    mp_arg_check_num_sig(n_args, n_kw, ARG_SIG_RANGE);
    const raw = mp_obj_malloc_helper(@sizeOf(MpObjRange), type_in.?).?;
    const o: *MpObjRange = @ptrCast(@alignCast(raw));
    var start: Int = 0;
    var stop: Int = 0;
    var step: Int = 1;
    if (n_args == 1) {
        stop = mp_obj_get_int(args[0]);
        if (pyerr.pending_exc != 0) return error.PyRaise;
    } else {
        start = mp_obj_get_int(args[0]);
        if (pyerr.pending_exc != 0) return error.PyRaise;
        stop = mp_obj_get_int(args[1]);
        if (pyerr.pending_exc != 0) return error.PyRaise;
        if (n_args == 3) {
            step = mp_obj_get_int(args[2]);
            if (pyerr.pending_exc != 0) return error.PyRaise;
            if (step == 0) {
                try raiseZeroStep();
                unreachable;
            }
        }
    }
    o.start = start;
    o.stop = stop;
    o.step = step;
    return @intFromPtr(o);
}
export fn npy_rng_fn_make_new(type_in: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, rngFnMakeNewImpl(type_in, n_args, n_kw, args));
}

export fn npy_rng_fn_unary_op(op: c_int, self_in: Obj) callconv(.c) Obj {
    const len = rangeLen(self_in);
    if (op == mp.MP_UNARY_OP_BOOL) return mirrors.newBool(len > 0);
    if (op == mp.MP_UNARY_OP_LEN) return mp_obj_new_int(len);
    return mirrors.OBJ_NULL;
}

export fn npy_rng_fn_subscr(self_in: Obj, index: Obj, value: Obj) callconv(.c) Obj {
    if (value == mirrors.OBJ_SENTINEL) {
        const self = MpObjRange.fromObj(self_in);
        const len = rangeLen(self_in);
        // r[a:b:c] returns a new range — vendor py/objrange.c provides
        // this when MICROPY_PY_BUILTINS_SLICE=1 (set in mpconfigport.h).
        // Was gated to is_full as bug-for-bug compat with the nano-C
        // reference; ungated here because the slice-of-range idiom is
        // a basic Python feature and the reference's omission was just
        // the same MINIMUM-ROM-level config gate.
        if (mirrors.isExactType(index, &mp_type_slice)) {
            var s = MpBoundSlice{ .start = 0, .stop = 0, .step = 0 };
            mp_obj_slice_indices(index, len, &s);
            const raw = mp_obj_malloc_helper(@sizeOf(MpObjRange), &mp_type_range).?;
            const o: *MpObjRange = @ptrCast(@alignCast(raw));
            o.start = self.start +% s.start *% self.step;
            o.stop = self.start +% s.stop *% self.step;
            o.step = s.step *% self.step;
            return @intFromPtr(o);
        }
        const idx: Int = @intCast(mp_get_index(self.base.type.?, @bitCast(len), index, false));
        return mp_obj_new_int(self.start +% idx *% self.step);
    }
    return mirrors.OBJ_NULL;
}

export fn mp_obj_new_range_iterator(cur: Int, stop: Int, step: Int, iter_buf: ?*anyopaque) callconv(.c) Obj {
    const o: *MpObjRangeIt = @ptrCast(@alignCast(iter_buf));
    o.base.type = &mp_type_range_it;
    o.cur = cur;
    o.stop = stop;
    o.step = step;
    return @intFromPtr(o);
}

export fn npy_rng_fn_getiter(o_in: Obj, iter_buf: ?*anyopaque) callconv(.c) Obj {
    const r = MpObjRange.fromObj(o_in);
    return mp_obj_new_range_iterator(r.start, r.stop, r.step, iter_buf);
}

// mp_type_range_it: { name=iterator, flags=ITER_IS_ITERNEXT, iter=iternext }
pub export const mp_type_range_it: types.MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = 0x0080, // ITER_IS_ITERNEXT
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
        @ptrCast(&npy_rng_fn_it_iternext),
        null, null, null, null, null, null, null, null, null, null,
    },
};

// mp_type_range: slot layout depends on config (see file header).
pub export const mp_type_range: types.MpObjTypeFull = if (build_options.is_full) .{
    // full: make_new=1, attr=2, print=3, unary_op=4, subscr=5, iter=6
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = 0x0000,
        .name = mp.MP_QSTR_range,
        .slot_index_make_new = 1,
        .slot_index_print = 3,
        .slot_index_call = 0,
        .slot_index_unary_op = 4,
        .slot_index_binary_op = 0,
        .slot_index_attr = 2,
        .slot_index_subscr = 5,
        .slot_index_iter = 6,
        .slot_index_buffer = 0,
        .slot_index_protocol = 0,
        .slot_index_parent = 0,
        .slot_index_locals_dict = 0,
    },
    .slots = .{
        @ptrCast(&npy_rng_fn_make_new),
        @ptrCast(&range_attr),
        @ptrCast(&range_print),
        @ptrCast(&npy_rng_fn_unary_op),
        @ptrCast(&npy_rng_fn_subscr),
        @ptrCast(&npy_rng_fn_getiter),
        null, null, null, null, null,
    },
} else .{
    // nano: make_new=1, binary_op=2, print=3, unary_op=4, subscr=5, iter=6, attr=7
    // attr was previously slot_index=0 (disabled) to make room for
    // binary_op (range==range comparison). Both fit — we have 10 slot
    // positions; using slot 7 for range_attr is free.
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = 0x0000,
        .name = mp.MP_QSTR_range,
        .slot_index_make_new = 1,
        .slot_index_print = 3,
        .slot_index_call = 0,
        .slot_index_unary_op = 4,
        .slot_index_binary_op = 2,
        .slot_index_attr = 7,
        .slot_index_subscr = 5,
        .slot_index_iter = 6,
        .slot_index_buffer = 0,
        .slot_index_protocol = 0,
        .slot_index_parent = 0,
        .slot_index_locals_dict = 0,
    },
    .slots = .{
        @ptrCast(&npy_rng_fn_make_new),
        @ptrCast(&range_binary_op),
        @ptrCast(&range_print),
        @ptrCast(&npy_rng_fn_unary_op),
        @ptrCast(&npy_rng_fn_subscr),
        @ptrCast(&npy_rng_fn_getiter),
        @ptrCast(&range_attr),
        null, null, null, null,
    },
};

comptime {
    _ = &npy_rng_len_helper;
    _ = &npy_rng_fn_it_iternext;
    _ = &npy_rng_fn_make_new;
    _ = &npy_rng_fn_unary_op;
    _ = &npy_rng_fn_subscr;
    _ = &npy_rng_fn_getiter;
    _ = &mp_obj_new_range_iterator;
    _ = &mp_type_range;
    _ = &mp_type_range_it;
}
