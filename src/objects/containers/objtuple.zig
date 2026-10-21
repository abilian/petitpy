//! nanopython — full Zig port of py/objtuple.c (drops objtuple_shim).
//!
//! Nano config (probed): SLICE=1 (slice subscr live), JSON=0 (print
//! JSON branch dead).
//!
//! The flexible-array `mp_obj_tuple_t.items[]` is accessed via
//! mirrors.MpObjTuple. The 2 ROM types (mp_type_tuple + the iterator
//! is overlaid on mp_type_polymorph_iter), the locals_dict (count,
//! index), and `mp_const_empty_tuple_obj` live in this file.
//!
//! Faithful: print's "single-element trailing comma" branch preserved;
//! hash accumulates with wrapping +%; iterator overlay is a sizeof-fits
//! assert (NOP at nano DEBUG=0).

const mp = @cImport({
    @cInclude("py/obj.h");
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
extern const mp_type_slice: anyopaque;
extern const mp_type_polymorph_iter: anyopaque;
extern const mp_type_fun_builtin_2: anyopaque;
extern const mp_type_fun_builtin_var: anyopaque;
extern const mp_type_list: anyopaque;

// Externs in already-Zig modules:
extern fn mp_unary_op(op: c_int, arg: Obj) callconv(.c) Obj;
extern fn mp_binary_op(op: c_int, lhs: Obj, rhs: Obj) callconv(.c) Obj;
extern fn mp_getiter(o: Obj, iter_buf: ?*anyopaque) callconv(.c) Obj;
extern fn mp_iternext(o: Obj) callconv(.c) Obj;
extern fn mp_seq_multiply(items: ?*const anyopaque, item_sz: usize, len: usize, times: usize, dest: ?*anyopaque) callconv(.c) void;
extern fn mp_seq_cmp_objs(op: usize, i1: [*c]const Obj, l1: usize, i2: [*c]const Obj, l2: usize) callconv(.c) bool;
extern fn mp_seq_count_obj(items: [*c]const Obj, len: usize, value: Obj) callconv(.c) Obj;
extern fn mp_seq_index_obj(items: [*c]const Obj, len: usize, n_args: usize, args: [*c]const Obj) callconv(.c) Obj;
extern fn mp_seq_get_fast_slice_indexes(len: usize, slice: Obj, indexes: *MpBoundSlice) callconv(.c) bool;

extern fn mp_obj_get_type(o: Obj) callconv(.c) *const mirrors.MpObjType;
extern fn mp_obj_is_subclass_fast(o: Obj, classinfo: Obj) callconv(.c) bool;
extern fn mp_obj_cast_to_native_base(self_in: Obj, native_type: Obj) callconv(.c) Obj;
extern fn mp_obj_get_int_maybe(arg: Obj, value: *isize) callconv(.c) bool;
extern fn mp_obj_print_helper(print: ?*const anyopaque, o: Obj, kind: c_int) callconv(.c) void;
extern fn mp_print_str(print: ?*const anyopaque, s: [*:0]const u8) callconv(.c) c_int;
extern fn mp_get_index(t: *const anyopaque, len: usize, idx: Obj, is_slice: bool) callconv(.c) usize;
extern fn mp_arg_check_num_sig(n_args: usize, n_kw: usize, sig: u32) callconv(.c) void;
extern fn mp_obj_malloc_helper(num_bytes: usize, type_in: *const anyopaque) callconv(.c) ?*anyopaque;
extern const mp_type_NotImplementedError: anyopaque;
extern fn mp_obj_new_exception_msg(t: *const anyopaque, msg: [*:0]const u8) callconv(.c) Obj;
extern fn m_malloc(num_bytes: usize) callconv(.c) ?*anyopaque;
extern fn m_realloc(ptr: ?*anyopaque, new_num_bytes: usize) callconv(.c) ?*anyopaque;
extern fn m_free(ptr: ?*anyopaque) callconv(.c) void;

const MpBoundSlice = extern struct { start: isize, stop: isize, step: isize };

// NX-3 N1 raise helper (PyError convention; notes/41, /42).
// Sets pyerr.pending_exc + returns error.PyRaise — the C-ABI export
// wraps the impl with pyerr.bridge which catches and returns the
// zero sentinel (callers poll pending_exc).
fn raiseSliceStepUnsupported() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_NotImplementedError, "only slices with step=1 (aka None) are supported");
    return error.PyRaise;
}

// Iterator overlay layout (mp_obj_tuple_it_t).
const MpObjTupleIt = extern struct {
    base: mirrors.MpObjBase,
    iternext: *const fn (Obj) callconv(.c) Obj,
    tuple: *mirrors.MpObjTuple,
    cur: usize,

    inline fn fromObj(o: Obj) *MpObjTupleIt {
        return @ptrFromInt(o);
    }
};

// MP_OBJ_FUN_MAKE_SIG(0, 1, false) = (0<<17) | (1<<1) = 2
const ARG_SIG_TUPLE: u32 = (0 << 17) | (1 << 1) | 0;

inline fn allocTuple(n: usize) Obj {
    const bytes = @sizeOf(mirrors.MpObjTuple) + n * @sizeOf(Obj);
    const raw = mp_obj_malloc_helper(bytes, &mp_type_tuple).?;
    const o: *mirrors.MpObjTuple = @ptrCast(@alignCast(raw));
    o.len = n;
    return @intFromPtr(o);
}

inline fn delTuple(o: Obj) void {
    m_free(@ptrFromInt(o));
}

export fn mp_obj_tuple_print(print: ?*const anyopaque, o_in: Obj, kind_in: c_int) callconv(.c) void {
    _ = kind_in; // JSON=0 → JSON branch dead.
    _ = mp_print_str(print, "(");
    const self = mirrors.MpObjTuple.fromObj(o_in);
    var i: usize = 0;
    while (i < self.len) : (i += 1) {
        if (i > 0) _ = mp_print_str(print, ", ");
        mp_obj_print_helper(print, self.itemsPtr()[i], mp.PRINT_REPR);
    }
    if (self.len == 1) _ = mp_print_str(print, ",");
    _ = mp_print_str(print, ")");
}

export fn mp_obj_tuple_make_new(type_in: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    _ = type_in;
    mp_arg_check_num_sig(n_args, n_kw, ARG_SIG_TUPLE);
    if (n_args == 0) return mirrors.objFromPtr(&mp_const_empty_tuple_obj);
    if (mirrors.isExactType(args[0], &mp_type_tuple)) return args[0];
    var alloc: usize = 4;
    var len: usize = 0;
    var items: [*]Obj = @ptrCast(@alignCast(m_malloc(alloc * @sizeOf(Obj)).?));
    const iterable = mp_getiter(args[0], null);
    while (true) {
        const item = mp_iternext(iterable);
        if (item == mirrors.OBJ_STOP_ITERATION) break;
        if (len >= alloc) {
            items = @ptrCast(@alignCast(m_realloc(items, alloc * 2 * @sizeOf(Obj)).?));
            alloc *= 2;
        }
        items[len] = item;
        len += 1;
    }
    const tuple = mp_obj_new_tuple(len, items);
    m_free(items);
    return tuple;
}

// MP_TYPE_GET_SLOT_OR_NULL: read slot_index_iter; if 0, return null; else return slots[idx-1].
inline fn typeIterSlot(t: *const mirrors.MpObjType) ?*const anyopaque {
    const idx = t.slot_index_iter;
    if (idx == 0) return null;
    // slots[] follows the header in MpObjTypeFull; we know slot_index_iter is the
    // 1-based index. Pointer arithmetic past the header gives slots[idx-1].
    const slots_base: [*]const ?*const anyopaque = @ptrFromInt(@intFromPtr(t) + @sizeOf(mirrors.MpObjType));
    return slots_base[idx - 1];
}

// Forward-declared so tupleCmpHelper can compare against it.
const getiter_zig_ptr: ?*const anyopaque = @ptrCast(&mp_obj_tuple_getiter);

fn tupleCmpHelper(op: usize, self_in_in: Obj, another_in_in: Obj) Obj {
    var another_in = another_in_in;
    const another_type = mp_obj_get_type(another_in);
    if (typeIterSlot(another_type) != getiter_zig_ptr) {
        // Slow path for user subclasses.
        another_in = mp_obj_cast_to_native_base(another_in, mirrors.objFromPtr(&mp_type_tuple));
        if (another_in == mirrors.OBJ_NULL) return mirrors.OBJ_NULL;
    }
    const self_len = mirrors.MpObjTuple.fromObj(self_in_in).len;
    const another_len = mirrors.MpObjTuple.fromObj(another_in).len;
    const items_self = mirrors.MpObjTuple.fromObj(self_in_in).itemsPtr();
    const items_other = mirrors.MpObjTuple.fromObj(another_in).itemsPtr();
    return mirrors.newBool(mp_seq_cmp_objs(op, items_self, self_len, items_other, another_len));
}

export fn mp_obj_tuple_unary_op(op: c_int, self_in: Obj) callconv(.c) Obj {
    const self = mirrors.MpObjTuple.fromObj(self_in);
    if (op == mp.MP_UNARY_OP_BOOL) {
        return mirrors.newBool(self.len != 0);
    } else if (op == mp.MP_UNARY_OP_HASH) {
        // Start hash with pointer to empty tuple, to make it fairly unique.
        var hash: isize = @as(isize, @bitCast(mirrors.objFromPtr(&mp_const_empty_tuple_obj)));
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            hash +%= mirrors.smallIntValue(mp_unary_op(mp.MP_UNARY_OP_HASH, self.itemsPtr()[i]));
        }
        return mirrors.newSmallInt(hash);
    } else if (op == mp.MP_UNARY_OP_LEN) {
        return mirrors.newSmallInt(@bitCast(self.len));
    }
    return mirrors.OBJ_NULL;
}

export fn mp_obj_tuple_binary_op(op: c_int, lhs: Obj, rhs: Obj) callconv(.c) Obj {
    const o_len = mirrors.MpObjTuple.fromObj(lhs).len;
    if (op == mp.MP_BINARY_OP_ADD or op == mp.MP_BINARY_OP_INPLACE_ADD) {
        // Operands must be tuple-subclass-compatible.
        const rhs_type_obj: Obj = @intFromPtr(mp_obj_get_type(rhs));
        if (!mp_obj_is_subclass_fast(rhs_type_obj, mirrors.objFromPtr(&mp_type_tuple))) {
            return mirrors.OBJ_NULL;
        }
        const p_len = mirrors.MpObjTuple.fromObj(rhs).len;
        const s = allocTuple(o_len + p_len);
        const dst = mirrors.MpObjTuple.fromObj(s).itemsPtr();
        const lhs_items = mirrors.MpObjTuple.fromObj(lhs).itemsPtr();
        const rhs_items = mirrors.MpObjTuple.fromObj(rhs).itemsPtr();
        var i: usize = 0;
        while (i < o_len) : (i += 1) dst[i] = lhs_items[i];
        i = 0;
        while (i < p_len) : (i += 1) dst[o_len + i] = rhs_items[i];
        return s;
    } else if (op == mp.MP_BINARY_OP_MULTIPLY or op == mp.MP_BINARY_OP_INPLACE_MULTIPLY) {
        var n: isize = 0;
        if (!mp_obj_get_int_maybe(rhs, &n)) return mirrors.OBJ_NULL;
        if (n <= 0) return mirrors.objFromPtr(&mp_const_empty_tuple_obj);
        const s = allocTuple(o_len * @as(usize, @intCast(n)));
        mp_seq_multiply(
            mirrors.MpObjTuple.fromObj(lhs).itemsPtr(),
            @sizeOf(Obj),
            o_len,
            @intCast(n),
            @ptrCast(mirrors.MpObjTuple.fromObj(s).itemsPtr()),
        );
        return s;
    } else if (op == mp.MP_BINARY_OP_EQUAL or
        op == mp.MP_BINARY_OP_LESS or
        op == mp.MP_BINARY_OP_LESS_EQUAL or
        op == mp.MP_BINARY_OP_MORE or
        op == mp.MP_BINARY_OP_MORE_EQUAL)
    {
        return tupleCmpHelper(@intCast(op), lhs, rhs);
    }
    return mirrors.OBJ_NULL;
}

fn tupleSliceLoad(self_in: Obj, index: Obj) PyError!Obj {
    const self = mirrors.MpObjTuple.fromObj(self_in);
    var slice = MpBoundSlice{ .start = 0, .stop = 0, .step = 0 };
    if (!mp_seq_get_fast_slice_indexes(self.len, index, &slice)) {
        try raiseSliceStepUnsupported();
    }
    const span: usize = @intCast(slice.stop - slice.start);
    return mp_obj_new_tuple(span, self.itemsPtr() + @as(usize, @intCast(slice.start)));
}

fn mpObjTupleSubscrImpl(self_in: Obj, index: Obj, value: Obj) PyError!Obj {
    if (value != mirrors.OBJ_SENTINEL) return mirrors.OBJ_NULL;
    if (mirrors.isExactType(index, &mp_type_slice)) return tupleSliceLoad(self_in, index);
    const self = mirrors.MpObjTuple.fromObj(self_in);
    const t = mirrors.objBaseType(self_in).?;
    const idx = mp_get_index(t, self.len, index, false);
    if (pyerr.pending_exc != 0) return error.PyRaise;
    return self.itemsPtr()[idx];
}

export fn mp_obj_tuple_subscr(self_in: Obj, index: Obj, value: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, mpObjTupleSubscrImpl(self_in, index, value));
}

// tuple.count(value)
export fn npy_tup_method_count(self_in: Obj, value: Obj) callconv(.c) Obj {
    const self = mirrors.MpObjTuple.fromObj(self_in);
    return mp_seq_count_obj(self.itemsPtr(), self.len, value);
}

// tuple.index(value[, start[, end]])
export fn npy_tup_method_index(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    const self = mirrors.MpObjTuple.fromObj(args[0]);
    return mp_seq_index_obj(self.itemsPtr(), self.len, n_args, args);
}

export fn mp_obj_new_tuple(n: usize, items: [*c]const Obj) callconv(.c) Obj {
    if (n == 0) return mirrors.objFromPtr(&mp_const_empty_tuple_obj);
    const o = allocTuple(n);
    if (items != null) {
        const dst = mirrors.MpObjTuple.fromObj(o).itemsPtr();
        var i: usize = 0;
        while (i < n) : (i += 1) dst[i] = items[i];
    }
    return o;
}

export fn mp_obj_tuple_get(self_in: Obj, len_out: *usize, items_out: *[*c]Obj) callconv(.c) void {
    len_out.* = mirrors.MpObjTuple.fromObj(self_in).len;
    items_out.* = @ptrCast(mirrors.MpObjTuple.fromObj(self_in).itemsPtr());
}

export fn mp_obj_tuple_del(self_in: Obj) callconv(.c) void {
    delTuple(self_in);
}

// ── iterator ────────────────────────────────────────────────────────
// mp_obj_tuple_it_t is overlaid into the caller's mp_obj_iter_buf_t.

export fn npy_tup_it_iternext(self_in: Obj) callconv(.c) Obj {
    const it = MpObjTupleIt.fromObj(self_in);
    if (it.cur < it.tuple.len) {
        const out = it.tuple.itemsPtr()[it.cur];
        it.cur += 1;
        return out;
    }
    return mirrors.OBJ_STOP_ITERATION;
}

export fn mp_obj_tuple_getiter(o_in: Obj, iter_buf: ?*anyopaque) callconv(.c) Obj {
    const o: *MpObjTupleIt = @ptrCast(@alignCast(iter_buf));
    o.base.type = &mp_type_polymorph_iter;
    o.iternext = &npy_tup_it_iternext;
    o.tuple = mirrors.MpObjTuple.fromObj(o_in);
    o.cur = 0;
    return @intFromPtr(o);
}

// ── ROM: const empty tuple ──────────────────────────────────────────
// `mp_obj_tuple_t` with len=0; items[] is empty (flex-array, zero-sized).
pub export const mp_const_empty_tuple_obj: mirrors.MpObjTuple = .{
    .base = .{ .type = &mp_type_tuple },
    .len = 0,
};

// ── ROM: methods + locals_dict ──────────────────────────────────────
pub export const tuple_count_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&npy_tup_method_count),
};
pub export const tuple_index_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(2, 4, false),
    .fun = @ptrCast(&npy_tup_method_index),
};

const RomEntry = extern struct {
    key: Obj,
    value: *const anyopaque,
};
const tuple_locals_dict_table = [_]RomEntry{
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_count)), .value = &tuple_count_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_index)), .value = &tuple_index_obj },
};
pub export const tuple_locals_dict: mirrors.MpObjDict = .{
    .base = .{ .type = &mp_type_dict },
    .map = .{
        .bits = .{ .all_keys_are_qstrs = 1, .is_fixed = 1, .is_ordered = 1, .used = tuple_locals_dict_table.len },
        .alloc = tuple_locals_dict_table.len,
        .table = @ptrCast(@constCast(&tuple_locals_dict_table)),
    },
};

// ── ROM: mp_type_tuple ──────────────────────────────────────────────
// MP_TYPE_FLAG_ITER_IS_GETITER = 0x0000.
// Slot order from the C macro: make_new=1, print=2, unary_op=3,
// binary_op=4, subscr=5, iter=6, locals_dict=7.
pub export const mp_type_tuple: types.MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = 0x0000,
        .name = mp.MP_QSTR_tuple,
        .slot_index_make_new = 1,
        .slot_index_print = 2,
        .slot_index_call = 0,
        .slot_index_unary_op = 3,
        .slot_index_binary_op = 4,
        .slot_index_attr = 0,
        .slot_index_subscr = 5,
        .slot_index_iter = 6,
        .slot_index_buffer = 0,
        .slot_index_protocol = 0,
        .slot_index_parent = 0,
        .slot_index_locals_dict = 7,
    },
    .slots = .{
        @ptrCast(&mp_obj_tuple_make_new),
        @ptrCast(&mp_obj_tuple_print),
        @ptrCast(&mp_obj_tuple_unary_op),
        @ptrCast(&mp_obj_tuple_binary_op),
        @ptrCast(&mp_obj_tuple_subscr),
        @ptrCast(&mp_obj_tuple_getiter),
        @ptrCast(&tuple_locals_dict),
        null, null, null, null,
    },
};

comptime {
    _ = &mp_obj_tuple_print;
    _ = &mp_obj_tuple_make_new;
    _ = &mp_obj_tuple_unary_op;
    _ = &mp_obj_tuple_binary_op;
    _ = &mp_obj_tuple_subscr;
    _ = &mp_obj_new_tuple;
    _ = &mp_obj_tuple_get;
    _ = &mp_obj_tuple_del;
    _ = &mp_obj_tuple_getiter;
    _ = &npy_tup_method_count;
    _ = &npy_tup_method_index;
    _ = &npy_tup_it_iternext;
    _ = &mp_type_tuple;
    _ = &mp_const_empty_tuple_obj;
    _ = &tuple_locals_dict;
}
