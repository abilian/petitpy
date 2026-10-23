//! petitpy — full Zig port of py/objlist.c (drops objlist_shim).
//!
//! Nano config: JSON=0 (print branch dead), SLICE=1 (live), SYS_GETSIZEOF=0
//! (sizeof branch dead). The flexible-array hazard is milder than tuple
//! (items is a separate ptr); we keep the mutation methods reallocating
//! items[] via m_realloc.
//!
//! Faithful: quicksort partition do/while preserved via labeled
//! while-true; recursive mp_quicksort calls mp_cstack_check.
//! `mp_seq_replace_slice_no_grow` / `_grow_inplace` were vendor macros
//! — inlined as two `@memmove` calls each (note: the destination region
//! and the slice source region may overlap).

const std = @import("std");
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

const LIST_MIN_ALLOC: usize = 4;

extern const mp_type_type: anyopaque;
extern const mp_type_dict: anyopaque;
extern const mp_type_slice: anyopaque;
extern const mp_type_polymorph_iter: anyopaque;
extern const mp_type_fun_builtin_1: anyopaque;
extern const mp_type_fun_builtin_2: anyopaque;
extern const mp_type_fun_builtin_3: anyopaque;
extern const mp_type_fun_builtin_var: anyopaque;
extern const mp_type_IndexError: anyopaque;
extern const mp_type_NotImplementedError: anyopaque;
extern const mp_type_TypeError: anyopaque;
extern fn mp_obj_is_subclass_fast(object_in: Obj, classinfo: Obj) callconv(.c) bool;

extern const mp_const_empty_tuple_obj: mirrors.MpObjTuple;

// Externs in already-Zig modules:
extern fn mp_unary_op(op: c_int, arg: Obj) callconv(.c) Obj;
extern fn mp_binary_op(op: c_int, lhs: Obj, rhs: Obj) callconv(.c) Obj;
extern fn mp_getiter(o: Obj, iter_buf: ?*anyopaque) callconv(.c) Obj;
extern fn mp_iternext(o: Obj) callconv(.c) Obj;
extern fn mp_call_function_1(fun: Obj, arg: Obj) callconv(.c) Obj;
extern fn mp_seq_multiply(items: ?*const anyopaque, item_sz: usize, len: usize, times: usize, dest: ?*anyopaque) callconv(.c) void;
extern fn mp_seq_cmp_objs(op: usize, i1: [*c]const Obj, l1: usize, i2: [*c]const Obj, l2: usize) callconv(.c) bool;
extern fn mp_seq_count_obj(items: [*c]const Obj, len: usize, value: Obj) callconv(.c) Obj;
extern fn mp_seq_index_obj(items: [*c]const Obj, len: usize, n_args: usize, args: [*c]const Obj) callconv(.c) Obj;
extern fn mp_seq_get_fast_slice_indexes(len: usize, slice: Obj, indexes: *MpBoundSlice) callconv(.c) bool;
extern fn mp_seq_extract_slice(seq: [*c]const Obj, indexes: *MpBoundSlice) callconv(.c) Obj;
extern fn mp_arg_parse_all(n_pos: usize, pos: [*c]const Obj, kws: ?*anyopaque, n_allowed: usize, allowed: ?*const anyopaque, out_vals: ?*anyopaque) callconv(.c) void;
extern fn mp_arg_check_num_sig(n_args: usize, n_kw: usize, sig: u32) callconv(.c) void;
extern fn mp_obj_get_type(o: Obj) callconv(.c) *const anyopaque;
extern fn mp_obj_get_int_maybe(arg: Obj, value: *isize) callconv(.c) bool;
extern fn mp_obj_print_helper(print: ?*const anyopaque, o: Obj, kind: c_int) callconv(.c) void;
extern fn mp_print_str(print: ?*const anyopaque, s: [*:0]const u8) callconv(.c) c_int;
extern fn mp_get_index(t: *const anyopaque, len: usize, idx: Obj, is_slice: bool) callconv(.c) usize;
extern fn mp_obj_new_exception_msg(t: *const anyopaque, msg: [*:0]const u8) callconv(.c) Obj;
extern fn mp_obj_new_exception(t: *const anyopaque) callconv(.c) Obj;
extern fn mp_obj_get_array(o: Obj, len: *usize, items: *[*c]Obj) callconv(.c) void;
// mp_cstack_check is static-inline; under nano STACK_CHECK=0 it's a no-op.
inline fn mp_cstack_check() void {}
extern fn m_malloc(num_bytes: usize) callconv(.c) ?*anyopaque;
extern fn m_realloc(ptr: ?*anyopaque, new_num_bytes: usize) callconv(.c) ?*anyopaque;
extern fn m_free(ptr: ?*anyopaque) callconv(.c) void;

const MpBoundSlice = extern struct { start: isize, stop: isize, step: isize };

// Iterator overlay layout (mp_obj_list_it_t).
const MpObjListIt = extern struct {
    base: mirrors.MpObjBase,
    iternext: *const fn (Obj) callconv(.c) Obj,
    list: Obj,
    cur: usize,

    inline fn fromObj(o: Obj) *MpObjListIt {
        return @ptrFromInt(o);
    }
};

// ── helpers ─────────────────────────────────────────────────────────

inline fn itemsClear(items: [*]Obj, start: usize, stop: usize) void {
    // mp_seq_clear: memset items[start..stop] to 0 (a tagged NULL Obj).
    var i = start;
    while (i < stop) : (i += 1) items[i] = 0;
}

inline fn allocList(n: usize) Obj {
    // NX-3 N4: returns OBJ_NULL on alloc failure; m_malloc_fail has
    // already set pyerr.pending_exc to MemoryError. Caller (a slot fn)
    // propagates OBJ_NULL + pending_exc; mp_binary_op's polled-sentinel
    // check (runtime.zig:576) lifts it into PyError.
    const o: *mirrors.MpObjList = @ptrCast(@alignCast(m_malloc(@sizeOf(mirrors.MpObjList)) orelse return mirrors.OBJ_NULL));
    o.base.type = &mp_type_list;
    o.alloc = if (n < LIST_MIN_ALLOC) LIST_MIN_ALLOC else n;
    o.len = n;
    o.items = @ptrCast(@alignCast(m_malloc(o.alloc * @sizeOf(Obj)) orelse return mirrors.OBJ_NULL));
    itemsClear(o.items, n, o.alloc);
    return @intFromPtr(o);
}

inline fn listInit(o: *mirrors.MpObjList, n: usize) void {
    o.base.type = &mp_type_list;
    o.alloc = if (n < LIST_MIN_ALLOC) LIST_MIN_ALLOC else n;
    o.len = n;
    o.items = @ptrCast(@alignCast(m_malloc(o.alloc * @sizeOf(Obj)).?));
    itemsClear(o.items, n, o.alloc);
}

inline fn itemsGet(o: Obj, i: usize) Obj {
    return mirrors.MpObjList.fromObj(o).items[i];
}
inline fn itemsSet(o: Obj, i: usize, v: Obj) void {
    mirrors.MpObjList.fromObj(o).items[i] = v;
}

fn raisePopEmpty() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_IndexError, "pop from empty list");
    return error.PyRaise;
}

fn raiseNotImplemented() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception(&mp_type_NotImplementedError);
    return error.PyRaise;
}

// ── list_print ──────────────────────────────────────────────────────
export fn npy_lst_print(print: ?*const anyopaque, o_in: Obj, kind_in: c_int) callconv(.c) void {
    _ = kind_in; // nano JSON=0 → always PRINT_REPR
    _ = mp_print_str(print, "[");
    const self = mirrors.MpObjList.fromObj(o_in);
    var i: usize = 0;
    while (i < self.len) : (i += 1) {
        if (i > 0) _ = mp_print_str(print, ", ");
        mp_obj_print_helper(print, self.items[i], mp.PRINT_REPR);
    }
    _ = mp_print_str(print, "]");
}

fn listAppendInline(self_in: Obj, arg: Obj) Obj {
    const self = mirrors.MpObjList.fromObj(self_in);
    if (self.len >= self.alloc) {
        const new_alloc = self.alloc * 2;
        // NX-3 N4: m_realloc returns null on alloc failure (pending_exc set).
        // Return OBJ_NULL; caller (list.append slot fn / list-extend loop)
        // must check via pending_exc.
        const new_items = m_realloc(self.items, new_alloc * @sizeOf(Obj)) orelse return mirrors.OBJ_NULL;
        self.items = @ptrCast(@alignCast(new_items));
        itemsClear(self.items, self.len + 1, new_alloc);
        self.alloc = new_alloc;
    }
    self.items[self.len] = arg;
    self.len += 1;
    return mirrors.OBJ_NONE;
}

export fn mp_obj_list_append(self_in: Obj, arg: Obj) callconv(.c) Obj {
    // Self-type guard: vendor MICROPY_BUILTIN_METHOD_CHECK_SELF_ARG wraps
    // builtin methods in a checked_fun that validates self before delegating.
    // Without it, `list.append(1, 2)` (self=smallint) reaches listAppendInline
    // which @ptrFromInts the tagged smallint → alignment panic. Surgical
    // version of the wrap: just check self at the entry of each builtin
    // bound to a method-table slot. Subclass-fast covers `class MyList(list)`.
    // ADR 012 Phase 3.5 follow-up; closes corpus/full-known-fails.txt entry
    // `self_type_check`.
    const self_type_obj: Obj = @intFromPtr(mp_obj_get_type(self_in));
    const list_type_obj: Obj = @intFromPtr(&mp_type_list);
    if (!mp_obj_is_subclass_fast(self_type_obj, list_type_obj)) {
        pyerr.pending_exc = mp_obj_new_exception_msg(
            &mp_type_TypeError,
            "argument should be a list",
        );
        return mirrors.OBJ_NULL;
    }
    return listAppendInline(self_in, arg);
}

fn listExtendFromIter(list_o: Obj, iterable: Obj) Obj {
    const it = mp_getiter(iterable, null);
    if (pyerr.pending_exc != 0) return mirrors.OBJ_NULL;
    while (true) {
        const item = mp_iternext(it);
        if (pyerr.pending_exc != 0) return mirrors.OBJ_NULL;
        if (item == mirrors.OBJ_STOP_ITERATION) break;
        _ = listAppendInline(list_o, item);
        // NX-3 N4: append may fail via polled-sentinel (alloc OOM).
        if (pyerr.pending_exc != 0) return mirrors.OBJ_NULL;
    }
    return list_o;
}

export fn npy_lst_extend(self_in: Obj, arg_in: Obj) callconv(.c) Obj {
    if (mirrors.isExactType(arg_in, &mp_type_list)) {
        const self = mirrors.MpObjList.fromObj(self_in);
        const arg = mirrors.MpObjList.fromObj(arg_in);
        if (self.len + arg.len > self.alloc) {
            const new_alloc = self.len + arg.len + 4;
            // NX-3 N4: propagate alloc failure via polled-sentinel.
            const new_items = m_realloc(self.items, new_alloc * @sizeOf(Obj)) orelse return mirrors.OBJ_NULL;
            self.items = @ptrCast(@alignCast(new_items));
            itemsClear(self.items, self.len + arg.len, new_alloc);
            self.alloc = new_alloc;
        }
        const dst = self.items + self.len;
        const src = arg.items;
        var i: usize = 0;
        while (i < arg.len) : (i += 1) dst[i] = src[i];
        self.len += arg.len;
    } else {
        const r = listExtendFromIter(self_in, arg_in);
        if (r == mirrors.OBJ_NULL) return mirrors.OBJ_NULL;
    }
    return mirrors.OBJ_NONE;
}

fn listPopImpl(n_args: usize, args: [*c]const Obj) PyError!Obj {
    const self_in = args[0];
    const self = mirrors.MpObjList.fromObj(self_in);
    if (self.len == 0) try raisePopEmpty();
    const idx_arg = if (n_args == 1) mirrors.newSmallInt(-1) else args[1];
    const index = mp_get_index(self.base.type.?, self.len, idx_arg, false);
    if (pyerr.pending_exc != 0) return error.PyRaise;
    const ret = self.items[index];
    self.len -= 1;
    // memmove items[index..self.len] from items[index+1..self.len+1]
    if (self.len > index) {
        @memmove(
            (self.items + index)[0 .. self.len - index],
            (self.items + index + 1)[0 .. self.len - index],
        );
    }
    self.items[self.len] = 0;
    if (self.alloc > LIST_MIN_ALLOC and self.alloc > 2 * self.len) {
        const new_alloc = self.alloc / 2;
        self.items = @ptrCast(@alignCast(m_realloc(self.items, new_alloc * @sizeOf(Obj)).?));
        self.alloc = new_alloc;
    }
    return ret;
}
export fn npy_lst_pop(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, listPopImpl(n_args, args));
}

export fn npy_lst_unary_op(op: c_int, self_in: Obj) callconv(.c) Obj {
    const len = mirrors.MpObjList.fromObj(self_in).len;
    if (op == mp.MP_UNARY_OP_BOOL) return mirrors.newBool(len != 0);
    if (op == mp.MP_UNARY_OP_LEN) return mirrors.newSmallInt(@bitCast(len));
    return mirrors.OBJ_NULL;
}

export fn npy_lst_binary_op(op: c_int, lhs: Obj, rhs: Obj) callconv(.c) Obj {
    const o_len = mirrors.MpObjList.fromObj(lhs).len;
    if (op == mp.MP_BINARY_OP_ADD) {
        if (!mirrors.isExactType(rhs, &mp_type_list)) return mirrors.OBJ_NULL;
        const p_len = mirrors.MpObjList.fromObj(rhs).len;
        const s = allocList(o_len + p_len);
        if (s == mirrors.OBJ_NULL) return mirrors.OBJ_NULL; // NX-3 N4: OOM propagation
        const dst = mirrors.MpObjList.fromObj(s).items;
        const lhs_items = mirrors.MpObjList.fromObj(lhs).items;
        const rhs_items = mirrors.MpObjList.fromObj(rhs).items;
        var i: usize = 0;
        while (i < o_len) : (i += 1) dst[i] = lhs_items[i];
        i = 0;
        while (i < p_len) : (i += 1) dst[o_len + i] = rhs_items[i];
        return s;
    } else if (op == mp.MP_BINARY_OP_INPLACE_ADD) {
        const r = npy_lst_extend(lhs, rhs);
        if (r == mirrors.OBJ_NULL) return mirrors.OBJ_NULL; // NX-3 N4
        return lhs;
    } else if (op == mp.MP_BINARY_OP_MULTIPLY) {
        var n: isize = 0;
        if (!mp_obj_get_int_maybe(rhs, &n)) return mirrors.OBJ_NULL;
        if (n < 0) n = 0;
        const s = allocList(o_len * @as(usize, @intCast(n)));
        if (s == mirrors.OBJ_NULL) return mirrors.OBJ_NULL; // NX-3 N4: OOM propagation
        mp_seq_multiply(mirrors.MpObjList.fromObj(lhs).items, @sizeOf(Obj), o_len, @intCast(n), @ptrCast(mirrors.MpObjList.fromObj(s).items));
        return s;
    } else if (op == mp.MP_BINARY_OP_EQUAL or op == mp.MP_BINARY_OP_LESS or
        op == mp.MP_BINARY_OP_LESS_EQUAL or op == mp.MP_BINARY_OP_MORE or
        op == mp.MP_BINARY_OP_MORE_EQUAL)
    {
        if (!mirrors.isExactType(rhs, &mp_type_list)) {
            if (op == mp.MP_BINARY_OP_EQUAL) return mirrors.OBJ_FALSE;
            return mirrors.OBJ_NULL;
        }
        const a_len = mirrors.MpObjList.fromObj(rhs).len;
        return mirrors.newBool(mp_seq_cmp_objs(@intCast(op), mirrors.MpObjList.fromObj(lhs).items, o_len, mirrors.MpObjList.fromObj(rhs).items, a_len));
    }
    return mirrors.OBJ_NULL;
}

// ── slice helpers ───────────────────────────────────────────────────

fn listSliceLoad(self_in: Obj, index: Obj) Obj {
    const self = mirrors.MpObjList.fromObj(self_in);
    var slice = MpBoundSlice{ .start = 0, .stop = 0, .step = 0 };
    if (!mp_seq_get_fast_slice_indexes(self.len, index, &slice)) {
        return mp_seq_extract_slice(self.items, &slice);
    }
    const span: usize = @intCast(slice.stop - slice.start);
    return mp_obj_new_list(span, self.items + @as(usize, @intCast(slice.start)));
}

fn listSliceStore(self_in: Obj, index: Obj, value_in: Obj) PyError!Obj {
    const self = mirrors.MpObjList.fromObj(self_in);
    var slice = MpBoundSlice{ .start = 0, .stop = 0, .step = 0 };
    if (!mp_seq_get_fast_slice_indexes(self.len, index, &slice)) {
        try raiseNotImplemented();
    }
    var value = value_in;
    if (value == mirrors.OBJ_NULL) value = mirrors.objFromPtr(&mp_const_empty_tuple_obj);
    var value_len: usize = 0;
    var value_items: [*c]Obj = undefined;
    mp_obj_get_array(value, &value_len, &value_items);
    const span = @as(usize, @intCast(slice.stop - slice.start));
    const len_adj: isize = @as(isize, @intCast(value_len)) - @as(isize, @intCast(span));
    if (len_adj > 0) {
        const adj_u: usize = @intCast(len_adj);
        if (self.len + adj_u > self.alloc) {
            const new_alloc = self.len + adj_u;
            self.items = @ptrCast(@alignCast(m_realloc(self.items, new_alloc * @sizeOf(Obj)).?));
            self.alloc = new_alloc;
        }
        // mp_seq_replace_slice_grow_inplace(items, len, beg, end, slice, slice_len, len_adj, item_sz)
        //   memmove(items + beg + slice_len, items + end, (len + len_adj - (beg + slice_len)) * item_sz)
        //   memmove(items + beg, slice, slice_len * item_sz)
        const beg: usize = @intCast(slice.start);
        const end: usize = @intCast(slice.stop);
        const tail_len = self.len + adj_u - (beg + value_len);
        @memmove(
            (self.items + beg + value_len)[0..tail_len],
            (self.items + end)[0..tail_len],
        );
        @memmove(
            (self.items + beg)[0..value_len],
            value_items[0..value_len],
        );
    } else {
        // mp_seq_replace_slice_no_grow:
        //   memmove(items + beg, slice, slice_len)
        //   memmove(items + beg + slice_len, items + end, (len - end))
        const beg: usize = @intCast(slice.start);
        const end: usize = @intCast(slice.stop);
        @memmove(
            (self.items + beg)[0..value_len],
            value_items[0..value_len],
        );
        @memmove(
            (self.items + beg + value_len)[0 .. self.len - end],
            (self.items + end)[0 .. self.len - end],
        );
    }
    self.len = @intCast(@as(isize, @intCast(self.len)) + len_adj);
    return mirrors.OBJ_NONE;
}

fn npyLstSubscrImpl(self_in: Obj, index: Obj, value: Obj) PyError!Obj {
    if (mirrors.isExactType(index, &mp_type_slice)) {
        if (value == mirrors.OBJ_SENTINEL) return listSliceLoad(self_in, index);
        return try listSliceStore(self_in, index, value);
    }
    if (value == mirrors.OBJ_NULL) {
        var args2: [2]Obj = .{ self_in, index };
        _ = try listPopImpl(2, &args2);
        return mirrors.OBJ_NONE;
    } else if (value == mirrors.OBJ_SENTINEL) {
        const self = mirrors.MpObjList.fromObj(self_in);
        const t = mirrors.objBaseType(self_in).?;
        const i = mp_get_index(t, self.len, index, false);
        if (pyerr.pending_exc != 0) return error.PyRaise;
        return self.items[i];
    } else {
        const self = mirrors.MpObjList.fromObj(self_in);
        const t = mirrors.objBaseType(self_in).?;
        const i = mp_get_index(t, self.len, index, false);
        if (pyerr.pending_exc != 0) return error.PyRaise;
        self.items[i] = value;
        return mirrors.OBJ_NONE;
    }
}

export fn npy_lst_subscr(self_in: Obj, index: Obj, value: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, npyLstSubscrImpl(self_in, index, value));
}

export fn npy_lst_getiter(o_in: Obj, iter_buf: ?*anyopaque) callconv(.c) Obj {
    return npy_lst_new_list_iterator(o_in, 0, iter_buf);
}

export fn npy_lst_it_iternext(self_in: Obj) callconv(.c) Obj {
    const it = MpObjListIt.fromObj(self_in);
    const len = mirrors.MpObjList.fromObj(it.list).len;
    if (it.cur < len) {
        const out = mirrors.MpObjList.fromObj(it.list).items[it.cur];
        it.cur += 1;
        return out;
    }
    return mirrors.OBJ_STOP_ITERATION;
}

export fn mp_obj_list_make_new(type_in: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    _ = type_in;
    // sig = (max<<1)|(min<<17)|takes_kw → min=0,max=1,kw=false = (1<<1)
    mp_arg_check_num_sig(n_args, n_kw, (@as(u32, 1) << 1));
    const list = mp_obj_new_list(0, null);
    if (n_args == 0) return list;
    return listExtendFromIter(list, args[0]);
}

export fn npy_lst_clear(self_in: Obj) callconv(.c) Obj {
    const self = mirrors.MpObjList.fromObj(self_in);
    self.len = 0;
    self.items = @ptrCast(@alignCast(m_realloc(self.items, LIST_MIN_ALLOC * @sizeOf(Obj)).?));
    self.alloc = LIST_MIN_ALLOC;
    itemsClear(self.items, 0, LIST_MIN_ALLOC);
    return mirrors.OBJ_NONE;
}

export fn npy_lst_copy(self_in: Obj) callconv(.c) Obj {
    const self = mirrors.MpObjList.fromObj(self_in);
    return mp_obj_new_list(self.len, self.items);
}

export fn npy_lst_count(self_in: Obj, value: Obj) callconv(.c) Obj {
    const self = mirrors.MpObjList.fromObj(self_in);
    return mp_seq_count_obj(self.items, self.len, value);
}

export fn npy_lst_index(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    const self = mirrors.MpObjList.fromObj(args[0]);
    return mp_seq_index_obj(self.items, self.len, n_args, args);
}

export fn npy_lst_insert(self_in: Obj, idx: Obj, obj: Obj) callconv(.c) Obj {
    var index: isize = mirrors.smallIntValue(idx);
    var self_len = mirrors.MpObjList.fromObj(self_in).len;
    if (index < 0) index += @intCast(self_len);
    if (index < 0) index = 0;
    if (@as(usize, @intCast(index)) > self_len) index = @intCast(self_len);
    _ = listAppendInline(self_in, mirrors.OBJ_NONE);
    self_len = mirrors.MpObjList.fromObj(self_in).len;
    var i: isize = @as(isize, @intCast(self_len)) - 1;
    while (i > index) : (i -= 1) {
        itemsSet(self_in, @intCast(i), itemsGet(self_in, @intCast(i - 1)));
    }
    itemsSet(self_in, @intCast(index), obj);
    return mirrors.OBJ_NONE;
}

export fn mp_obj_list_remove(self_in: Obj, value: Obj) callconv(.c) Obj {
    var args2: [2]Obj = .{ self_in, value };
    const self = mirrors.MpObjList.fromObj(self_in);
    args2[1] = mp_seq_index_obj(self.items, self.len, 2, &args2);
    _ = pyerr.bridge(Obj, listPopImpl(2, &args2));
    return mirrors.OBJ_NONE;
}

export fn npy_lst_reverse(self_in: Obj) callconv(.c) Obj {
    const self = mirrors.MpObjList.fromObj(self_in);
    var i: usize = 0;
    while (i < self.len / 2) : (i += 1) {
        const tmp = self.items[i];
        self.items[i] = self.items[self.len - i - 1];
        self.items[self.len - i - 1] = tmp;
    }
    return mirrors.OBJ_NONE;
}

// Quicksort — faithful to the C pointer-arithmetic-based partition.
fn mpQuicksort(head_in: [*c]Obj, tail_in: [*c]Obj, key_fn: Obj, binop_less_result: Obj) void {
    mp_cstack_check();
    var head = head_in;
    var tail = tail_in;
    while (@intFromPtr(tail) - @intFromPtr(head) > @sizeOf(Obj)) {
        var h = head;
        var t = tail;
        const v: Obj = if (key_fn == mirrors.OBJ_NULL) tail[0] else mp_call_function_1(key_fn, tail[0]);
        while (true) {
            while (true) {
                h += 1;
                if (!(@intFromPtr(h) < @intFromPtr(t) and
                    mp_binary_op(mp.MP_BINARY_OP_LESS, if (key_fn == mirrors.OBJ_NULL) h[0] else mp_call_function_1(key_fn, h[0]), v) == binop_less_result)) break;
            }
            while (true) {
                t -= 1;
                if (!(@intFromPtr(h) < @intFromPtr(t) and
                    mp_binary_op(mp.MP_BINARY_OP_LESS, v, if (key_fn == mirrors.OBJ_NULL) t[0] else mp_call_function_1(key_fn, t[0])) == binop_less_result)) break;
            }
            if (@intFromPtr(h) >= @intFromPtr(t)) break;
            const x = h[0];
            h[0] = t[0];
            t[0] = x;
        }
        const x = h[0];
        h[0] = tail[0];
        tail[0] = x;
        if (@intFromPtr(t) - @intFromPtr(head) < @intFromPtr(tail) - @intFromPtr(h)) {
            mpQuicksort(head, t, key_fn, binop_less_result);
            head = h;
        } else {
            mpQuicksort(h, tail, key_fn, binop_less_result);
            tail = t;
        }
    }
}

// ── sort allowed_args table ─────────────────────────────────────────
// MP_ARG_KW_ONLY (0x200) | MP_ARG_OBJ (0x003) = 0x203
// MP_ARG_KW_ONLY | MP_ARG_BOOL (0x001) = 0x201
const sort_allowed_args = [_]mirrors.MpArg{
    .{ .qst = mp.MP_QSTR_key, .flags = 0x203, .defval = .{ .u_rom_obj = mirrors.OBJ_NONE } },
    .{ .qst = mp.MP_QSTR_reverse, .flags = 0x201, .defval = .{ .u_bool = false } },
};

export fn mp_obj_list_sort(n_args: usize, pos_args: [*c]const Obj, kw_args: ?*anyopaque) callconv(.c) Obj {
    var buf: [@sizeOf(mirrors.MpArgVal) * sort_allowed_args.len]u8 align(16) = undefined;
    mp_arg_parse_all(n_args - 1, pos_args + 1, kw_args, sort_allowed_args.len, &sort_allowed_args, &buf);
    if (pyerr.pending_exc != 0) return mirrors.OBJ_NULL;
    const vals: [*]const mirrors.MpArgVal = @ptrCast(@alignCast(&buf));
    const key = vals[0].u_obj;
    const reverse = vals[1].u_bool;

    const self = mirrors.MpObjList.fromObj(pos_args[0]);
    if (self.len > 1) {
        const key_fn: Obj = if (key == mirrors.OBJ_NONE) mirrors.OBJ_NULL else key;
        const binop_less_result: Obj = if (reverse) mirrors.OBJ_FALSE else mirrors.OBJ_TRUE;
        mpQuicksort(self.items - 1, self.items + self.len - 1, key_fn, binop_less_result);
    }
    return mirrors.OBJ_NONE;
}

// ── public ABI ──────────────────────────────────────────────────────
export fn mp_obj_list_init(o_ptr: ?*anyopaque, n: usize) callconv(.c) void {
    listInit(@ptrCast(@alignCast(o_ptr)), n);
}

export fn mp_obj_new_list(n: usize, items: [*c]const Obj) callconv(.c) Obj {
    const o = allocList(n);
    if (items != null) {
        const dst = mirrors.MpObjList.fromObj(o).items;
        var i: usize = 0;
        while (i < n) : (i += 1) dst[i] = items[i];
    }
    return o;
}

export fn mp_obj_list_get(self_in: Obj, len_out: *usize, items_out: *[*c]Obj) callconv(.c) void {
    len_out.* = mirrors.MpObjList.fromObj(self_in).len;
    items_out.* = mirrors.MpObjList.fromObj(self_in).items;
}

export fn mp_obj_list_set_len(self_in: Obj, len: usize) callconv(.c) void {
    mirrors.MpObjList.fromObj(self_in).len = len;
}

export fn mp_obj_list_store(self_in: Obj, index: Obj, value: Obj) callconv(.c) void {
    const self = mirrors.MpObjList.fromObj(self_in);
    const i = mp_get_index(self.base.type.?, self.len, index, false);
    if (pyerr.pending_exc != 0) return;
    self.items[i] = value;
}

export fn npy_lst_new_list_iterator(list: Obj, cur: usize, iter_buf: ?*anyopaque) callconv(.c) Obj {
    const o: *MpObjListIt = @ptrCast(@alignCast(iter_buf));
    o.base.type = &mp_type_polymorph_iter;
    o.iternext = &npy_lst_it_iternext;
    o.list = list;
    o.cur = cur;
    return @intFromPtr(o);
}

// ── ROM: methods + locals_dict + mp_type_list ───────────────────────
pub export const list_append_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&mp_obj_list_append),
};
pub export const list_extend_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&npy_lst_extend),
};
pub export const list_clear_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_1 },
    .fun = @ptrCast(&npy_lst_clear),
};
pub export const list_copy_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_1 },
    .fun = @ptrCast(&npy_lst_copy),
};
pub export const list_count_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&npy_lst_count),
};
pub export const list_index_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(2, 4, false),
    .fun = @ptrCast(&npy_lst_index),
};
pub export const list_insert_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_3 },
    .fun = @ptrCast(&npy_lst_insert),
};
pub export const list_pop_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(1, 2, false),
    .fun = @ptrCast(&npy_lst_pop),
};
pub export const list_remove_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&mp_obj_list_remove),
};
pub export const list_reverse_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_1 },
    .fun = @ptrCast(&npy_lst_reverse),
};
// MP_DEFINE_CONST_FUN_OBJ_KW: takes_kw=true, max=ARGS_MAX; same type as VAR.
pub export const list_sort_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(1, 0xffff, true),
    .fun = @ptrCast(&mp_obj_list_sort),
};

const RomEntry = extern struct {
    key: Obj,
    value: *const anyopaque,
};
const list_locals_dict_table = [_]RomEntry{
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_append)), .value = &list_append_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_clear)), .value = &list_clear_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_copy)), .value = &list_copy_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_count)), .value = &list_count_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_extend)), .value = &list_extend_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_index)), .value = &list_index_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_insert)), .value = &list_insert_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_pop)), .value = &list_pop_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_remove)), .value = &list_remove_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_reverse)), .value = &list_reverse_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_sort)), .value = &list_sort_obj },
};
pub export const list_locals_dict: mirrors.MpObjDict = .{
    .base = .{ .type = &mp_type_dict },
    .map = .{
        .bits = .{ .all_keys_are_qstrs = 1, .is_fixed = 1, .is_ordered = 1, .used = list_locals_dict_table.len },
        .alloc = list_locals_dict_table.len,
        .table = @ptrCast(@constCast(&list_locals_dict_table)),
    },
};

// mp_type_list slot order: make_new=1, print=2, unary_op=3, binary_op=4,
//                          subscr=5, iter=6, locals_dict=7
pub export const mp_type_list: types.MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = 0x0000, // MP_TYPE_FLAG_ITER_IS_GETITER = 0
        .name = mp.MP_QSTR_list,
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
        @ptrCast(&mp_obj_list_make_new),
        @ptrCast(&npy_lst_print),
        @ptrCast(&npy_lst_unary_op),
        @ptrCast(&npy_lst_binary_op),
        @ptrCast(&npy_lst_subscr),
        @ptrCast(&npy_lst_getiter),
        @ptrCast(&list_locals_dict),
        null,
        null,
        null,
        null,
    },
};

comptime {
    _ = &npy_lst_print;
    _ = &mp_obj_list_make_new;
    _ = &npy_lst_unary_op;
    _ = &npy_lst_binary_op;
    _ = &npy_lst_subscr;
    _ = &npy_lst_getiter;
    _ = &mp_obj_list_append;
    _ = &npy_lst_extend;
    _ = &npy_lst_pop;
    _ = &npy_lst_clear;
    _ = &npy_lst_copy;
    _ = &npy_lst_count;
    _ = &npy_lst_index;
    _ = &npy_lst_insert;
    _ = &mp_obj_list_remove;
    _ = &npy_lst_reverse;
    _ = &mp_obj_list_sort;
    _ = &mp_obj_list_init;
    _ = &mp_obj_new_list;
    _ = &mp_obj_list_get;
    _ = &mp_obj_list_set_len;
    _ = &mp_obj_list_store;
    _ = &npy_lst_it_iternext;
    _ = &npy_lst_new_list_iterator;
    _ = &mp_type_list;
    _ = &list_locals_dict;
}
