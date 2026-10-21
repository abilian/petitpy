//! nanopython — full Zig port of py/objdict.c (drops objdict_shim).
//!
//! Nano config (probed):
//!   - ORDEREDDICT=1 (mp_type_ordereddict live, used by collections)
//!   - DICT_FROMKEYS=0 (classmethod gated under is_full)
//!   - JSON=0, SYS_GETSIZEOF=0, CPYTHON_COMPAT (binary-op OR) gated by is_full
//!
//! mp_map_t has BITFIELDS — accessed via mirrors.MpObjDict (packed
//! struct-aligned with C layout). The dict_view{,_it} structs are
//! private to this file (mirrors of the C internal types).
//!
//! 6 live raises (each PyError-bridged):
//!   1. mp_obj_dict_get        : KeyError(key)
//!   2. dict_subscr load       : KeyError(key)
//!   3. mp_ensure_not_fixed    : TypeError(NULL)  — gates 5 mutation methods
//!   4. dict_get_helper        : KeyError(key) — on .pop(k) missing
//!   5. dict_popitem           : KeyError "popitem(): dictionary is empty"
//!   6. dict_update            : ValueError "dict update sequence has wrong length"

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
const build_options = @import("build_options");

const Obj = mirrors.Obj;
const Qstr = usize;
const MP_OBJ_NULL: Obj = 0;

// dict-view kinds — internal enum.
const DICT_VIEW_ITEMS: c_int = 0;
const DICT_VIEW_KEYS: c_int = 1;
const DICT_VIEW_VALUES: c_int = 2;

// ── extern types ────────────────────────────────────────────────────
extern const mp_type_type: anyopaque;
extern const mp_type_fun_builtin_1: anyopaque;
extern const mp_type_fun_builtin_var: anyopaque;
extern const mp_type_classmethod: anyopaque;
extern const mp_type_polymorph_iter: anyopaque;
extern const mp_type_KeyError: anyopaque;
extern const mp_type_TypeError: anyopaque;
extern const mp_type_ValueError: anyopaque;

// Op-method fun-objs (defined in src/runtime/opmethods.zig).
extern const mp_op_getitem_obj: mirrors.MpObjFunBuiltinFixed;
extern const mp_op_setitem_obj: mirrors.MpObjFunBuiltinFixed;
extern const mp_op_delitem_obj: mirrors.MpObjFunBuiltinFixed;

// ── extern C runtime fns ────────────────────────────────────────────
extern fn mp_getiter(o: Obj, iter_buf: ?*anyopaque) callconv(.c) Obj;
extern fn mp_iternext(o: Obj) callconv(.c) Obj;
extern fn mp_obj_new_tuple(n: usize, items: [*c]const Obj) callconv(.c) Obj;
extern fn mp_obj_equal(o1: Obj, o2: Obj) callconv(.c) bool;
extern fn mp_obj_is_true(arg: Obj) callconv(.c) bool;
extern fn mp_obj_len_maybe(o_in: Obj) callconv(.c) Obj;
extern fn mp_map_init(map: *mirrors.MpMap, n: usize) callconv(.c) void;
extern fn mp_map_clear(map: *mirrors.MpMap) callconv(.c) void;
extern fn mp_map_init_fixed_table(map: *mirrors.MpMap, n: usize, table: [*c]const Obj) callconv(.c) void;
extern fn mp_map_lookup(map: *mirrors.MpMap, key: Obj, mode: c_int) callconv(.c) ?*mirrors.MpMap.Elem;
extern fn mp_obj_malloc_helper(num_bytes: usize, type_in: *const anyopaque) callconv(.c) ?*anyopaque;
extern fn mp_arg_check_num_sig(n_args: usize, n_kw: usize, sig: u32) callconv(.c) void;
extern fn mp_obj_exception_make_new(type_in: *const anyopaque, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj;
extern fn mp_obj_new_exception(type_in: *const anyopaque) callconv(.c) Obj;
extern fn mp_obj_new_exception_msg(type_in: *const anyopaque, msg: [*:0]const u8) callconv(.c) Obj;
extern fn m_new_objects_dict_obj_t() callconv(.c) *mirrors.MpObjDict; // not used; see m_malloc path

// Allocator hooks (vendor m_new_obj expands to m_malloc + cast).
extern fn m_malloc(num_bytes: usize) callconv(.c) ?*anyopaque;

// Print primitives.
extern fn mp_print_str(print: ?*const anyopaque, s: [*:0]const u8) callconv(.c) c_int;
extern fn mp_obj_print_helper(print: ?*const anyopaque, o: Obj, kind: c_int) callconv(.c) void;

// ── raise helpers ──────────────────────────────────────────────────
fn raiseKeyErrorArg(key: Obj) PyError!void {
    pyerr.pending_exc = mp_obj_exception_make_new(&mp_type_KeyError, 1, 0, @ptrCast(&key));
    return error.PyRaise;
}
fn raiseTypeErrorNull() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception(&mp_type_TypeError);
    return error.PyRaise;
}
fn raiseKeyErrorPopitemEmpty() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_KeyError, "popitem(): dictionary is empty");
    return error.PyRaise;
}
fn raiseValueErrorUpdateSeq() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_ValueError, "dict update sequence has wrong length");
    return error.PyRaise;
}

// ── dict_view struct mirrors ────────────────────────────────────────
// Note: field ORDER matches the C shim's internal layout (which the
// shim asserted via sizeof() at runtime; preserved here for ABI
// compat with iter_buf overlays).
const NpObjDictView = extern struct {
    base: mirrors.MpObjBase,
    dict: Obj,
    kind: c_int, // np_dict_view_kind_t

    inline fn fromObj(o: Obj) *NpObjDictView {
        return @ptrFromInt(o);
    }
};

const NpObjDictViewIt = extern struct {
    base: mirrors.MpObjBase,
    kind: c_int, // np_dict_view_kind_t — note: BEFORE dict in C
    dict: Obj,
    cur: usize,

    inline fn fromObj(o: Obj) *NpObjDictViewIt {
        return @ptrFromInt(o);
    }
};

// ── dict_iter_next helper ──────────────────────────────────────────
// Returns the next filled slot index (and updates *cur to one past it).
// Returns null on exhaustion.
fn dictIterNext(dict_o: Obj, cur: *usize) ?usize {
    const map = &mirrors.MpObjDict.fromObj(dict_o).map;
    if (map.alloc == 0) return null;
    const table = map.tablePtr();
    var i = cur.*;
    while (i < map.alloc) : (i += 1) {
        const k = table[i].key;
        if (k != MP_OBJ_NULL and k != mirrors.OBJ_SENTINEL) {
            cur.* = i + 1;
            return i;
        }
    }
    return null;
}

// ── dict_print ──────────────────────────────────────────────────────
// Under full: OrderedDict prints as "OrderedDict({k: v, …})".
export fn npy_dt_print(print: ?*const anyopaque, self_in: Obj, _: c_int) callconv(.c) void {
    const is_ordered = mirrors.objBaseType(self_in) == @as(?*const anyopaque, &mp_type_ordereddict);
    if (build_options.is_full and is_ordered) {
        _ = mp_print_str(print, "OrderedDict(");
    }
    _ = mp_print_str(print, "{");
    var first = true;
    var cur: usize = 0;
    while (dictIterNext(self_in, &cur)) |i| {
        if (!first) _ = mp_print_str(print, ", ");
        first = false;
        const table = mirrors.MpObjDict.fromObj(self_in).map.tablePtr();
        mp_obj_print_helper(print, table[i].key, mp.PRINT_REPR);
        _ = mp_print_str(print, ": ");
        mp_obj_print_helper(print, table[i].value, mp.PRINT_REPR);
    }
    _ = mp_print_str(print, "}");
    if (build_options.is_full and is_ordered) {
        _ = mp_print_str(print, ")");
    }
}

// ── make_new ────────────────────────────────────────────────────────
fn mpObjDictMakeNewImpl(type_in: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const Obj) PyError!Obj {
    const dict_out = mp_obj_new_dict(0);
    mirrors.MpObjDict.fromObj(dict_out).base.type = type_in;
    // OrderedDict: flag the map as ordered.
    if (type_in == @as(?*const anyopaque, &mp_type_ordereddict)) {
        mirrors.MpObjDict.fromObj(dict_out).map.bits.is_ordered = 1;
    }
    if (n_args > 0 or n_kw > 0) {
        var args2: [2]Obj = .{ dict_out, args[0] };
        var kwargs: mirrors.MpMap = undefined;
        mp_map_init_fixed_table(&kwargs, n_kw, args + n_args);
        _ = try dictUpdateImpl(n_args + 1, &args2, &kwargs);
    }
    return dict_out;
}
export fn mp_obj_dict_make_new(type_in: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, mpObjDictMakeNewImpl(type_in, n_args, n_kw, args));
}

// ── unary_op (BOOL/LEN; SIZEOF dead under nano) ─────────────────────
export fn npy_dt_unary_op(op: c_int, self_in: Obj) callconv(.c) Obj {
    const self_used = mirrors.MpObjDict.fromObj(self_in).map.bits.used;
    if (op == mp.MP_UNARY_OP_BOOL) {
        return mirrors.newBool(self_used != 0);
    } else if (op == mp.MP_UNARY_OP_LEN) {
        return mirrors.newSmallInt(@intCast(self_used));
    }
    return MP_OBJ_NULL;
}

// ── binary_op (CONTAINS + EQUAL; +OR/INPLACE_OR under full) ───────
export fn npy_dt_binary_op(op: c_int, lhs_in: Obj, rhs_in: Obj) callconv(.c) Obj {
    // CPYTHON_COMPAT: dict | dict and |= (Python 3.9+).
    if (build_options.is_full and (op == mp.MP_BINARY_OP_OR or op == mp.MP_BINARY_OP_INPLACE_OR)) {
        var target = lhs_in;
        if (op == mp.MP_BINARY_OP_OR) target = mp_obj_dict_copy(lhs_in);
        var dicts: [2]Obj = .{ target, rhs_in };
        const empty_map: *mirrors.MpMap = &@constCast(&mp_const_empty_dict_obj).map;
        _ = npy_dt_method_update(2, &dicts, empty_map);
        return target;
    }
    if (op == mp.MP_BINARY_OP_CONTAINS) {
        const elem = mp_map_lookup(&mirrors.MpObjDict.fromObj(lhs_in).map, rhs_in, mp.MP_MAP_LOOKUP);
        return mirrors.newBool(elem != null);
    } else if (op == mp.MP_BINARY_OP_EQUAL) {
        // ORDEREDDICT: both-ordered → compare in order.
        if (build_options.is_full and mirrors.objBaseType(lhs_in) == @as(?*const anyopaque, &mp_type_ordereddict) and mirrors.objBaseType(rhs_in) == @as(?*const anyopaque, &mp_type_ordereddict)) {
            const used_lhs = mirrors.MpObjDict.fromObj(lhs_in).map.bits.used;
            const used_rhs = mirrors.MpObjDict.fromObj(rhs_in).map.bits.used;
            if (used_lhs != used_rhs) return mirrors.OBJ_FALSE;
            var cl: usize = 0;
            var cr: usize = 0;
            while (true) {
                const il = dictIterNext(lhs_in, &cl);
                const ir = dictIterNext(rhs_in, &cr);
                if (il == null and ir == null) return mirrors.OBJ_TRUE;
                if (il == null or ir == null) return mirrors.OBJ_FALSE;
                const lt = mirrors.MpObjDict.fromObj(lhs_in).map.tablePtr();
                const rt = mirrors.MpObjDict.fromObj(rhs_in).map.tablePtr();
                if (!mp_obj_equal(lt[il.?].key, rt[ir.?].key)) return mirrors.OBJ_FALSE;
                if (!mp_obj_equal(lt[il.?].value, rt[ir.?].value)) return mirrors.OBJ_FALSE;
            }
        }
        if (!mirrors.isExactType(rhs_in, &mp_type_dict)) return mirrors.OBJ_FALSE;
        if (mirrors.MpObjDict.fromObj(lhs_in).map.bits.used != mirrors.MpObjDict.fromObj(rhs_in).map.bits.used) return mirrors.OBJ_FALSE;
        var cur: usize = 0;
        while (dictIterNext(lhs_in, &cur)) |i| {
            const lt = mirrors.MpObjDict.fromObj(lhs_in).map.tablePtr();
            const elem = mp_map_lookup(&mirrors.MpObjDict.fromObj(rhs_in).map, lt[i].key, mp.MP_MAP_LOOKUP);
            if (elem == null) return mirrors.OBJ_FALSE;
            if (!mp_obj_equal(lt[i].value, elem.?.value)) return mirrors.OBJ_FALSE;
        }
        return mirrors.OBJ_TRUE;
    }
    return MP_OBJ_NULL;
}

// ── mp_obj_dict_get / dict_subscr ───────────────────────────────────
fn mpObjDictGetImpl(self_in: Obj, index: Obj) PyError!Obj {
    const elem = mp_map_lookup(&mirrors.MpObjDict.fromObj(self_in).map, index, mp.MP_MAP_LOOKUP);
    if (elem == null) {
        try raiseKeyErrorArg(index);
        unreachable;
    }
    return elem.?.value;
}
export fn mp_obj_dict_get(self_in: Obj, index: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, mpObjDictGetImpl(self_in, index));
}

fn dictSubscrImpl(self_in: Obj, index: Obj, value: Obj) PyError!Obj {
    if (value == MP_OBJ_NULL) {
        // delete
        _ = mp_obj_dict_delete(self_in, index);
        return mirrors.OBJ_NONE;
    } else if (value == mirrors.OBJ_SENTINEL) {
        // load
        const elem = mp_map_lookup(&mirrors.MpObjDict.fromObj(self_in).map, index, mp.MP_MAP_LOOKUP);
        if (elem == null) {
            // CPython __missing__ protocol: on a dict subclass (not
            // exact mp_type_dict), look up __missing__ on the type
            // and call it with the failing key. If found, return its
            // result; otherwise raise KeyError as before. Unlocks
            // Counter[absent_key] → 0 and defaultdict default-factory.
            // Vendor MicroPython's objdict.c skips this; nanopython
            // intentionally matches CPython here per the cheatsheet's
            // user-experience principle.
            // CPython would dispatch through `__missing__` on dict
            // subclasses here. Investigated but not done in this commit:
            // the subscr slot receives the INNER dict storage (the
            // mp_obj_dict_t subobj), not the OUTER subclass instance,
            // so there's no path from here to look up __missing__ on
            // the user's subclass (`mp_load_method_maybe` on self_in
            // finds methods only on mp_type_dict, not on the subclass).
            // A proper fix needs runtime support to make the outer
            // instance reachable from the subscr slot. Until then,
            // `Counter[absent] → 0` and `defaultdict` semantics don't
            // work — programs need `c.get(k, 0)` and manual dispatch.
            try raiseKeyErrorArg(index);
            unreachable;
        }
        return elem.?.value;
    } else {
        // store
        _ = mp_obj_dict_store(self_in, index, value);
        return mirrors.OBJ_NONE;
    }
}
export fn npy_dt_subscr(self_in: Obj, index: Obj, value: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, dictSubscrImpl(self_in, index, value));
}

// ── ensure_not_fixed (gates mutation methods) ──────────────────────
fn ensureNotFixed(dict_o: Obj) PyError!void {
    if (mirrors.MpObjDict.fromObj(dict_o).map.bits.is_fixed != 0) try raiseTypeErrorNull();
}

// ── dict_clear ──────────────────────────────────────────────────────
fn dictClearImpl(self_in: Obj) PyError!Obj {
    try ensureNotFixed(self_in);
    mp_map_clear(&mirrors.MpObjDict.fromObj(self_in).map);
    return mirrors.OBJ_NONE;
}
export fn npy_dt_method_clear(self_in: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, dictClearImpl(self_in));
}

// ── mp_obj_dict_copy ────────────────────────────────────────────────
export fn mp_obj_dict_copy(self_in: Obj) callconv(.c) Obj {
    const self = mirrors.MpObjDict.fromObj(self_in);
    const other_obj = mp_obj_new_dict(self.map.alloc);
    const other = mirrors.MpObjDict.fromObj(other_obj);
    other.base.type = mirrors.objBaseType(self_in);
    other.map.bits = .{
        .all_keys_are_qstrs = self.map.bits.all_keys_are_qstrs,
        .is_fixed = 0,
        .is_ordered = self.map.bits.is_ordered,
        .used = self.map.bits.used,
    };
    // Guard: alloc=0 ⇒ both tables are NULL (C memcpy(NULL,NULL,0) is fine,
    // but Zig @ptrCast(null) panics). Skip the copy loop entirely.
    if (self.map.alloc != 0) {
        const dst_table = other.map.tablePtr();
        const src_table = self.map.tablePtr();
        var i: usize = 0;
        while (i < self.map.alloc) : (i += 1) {
            dst_table[i] = src_table[i];
        }
    }
    return other_obj;
}

// ── dict_get_helper (used by .get/.pop/.setdefault) ────────────────
fn dictGetHelperImpl(n_args: usize, args: [*c]const Obj, lookup_kind: c_int) PyError!Obj {
    if (lookup_kind != mp.MP_MAP_LOOKUP) try ensureNotFixed(args[0]);
    const elem = mp_map_lookup(&mirrors.MpObjDict.fromObj(args[0]).map, args[1], lookup_kind);
    var value: Obj = undefined;
    if (elem == null or elem.?.value == MP_OBJ_NULL) {
        if (n_args == 2) {
            if (lookup_kind == mp.MP_MAP_LOOKUP_REMOVE_IF_FOUND) {
                try raiseKeyErrorArg(args[1]);
                unreachable;
            } else {
                value = mirrors.OBJ_NONE;
            }
        } else {
            value = args[2];
        }
        if (lookup_kind == mp.MP_MAP_LOOKUP_ADD_IF_NOT_FOUND) {
            elem.?.value = value;
        }
    } else {
        value = elem.?.value;
        if (lookup_kind == mp.MP_MAP_LOOKUP_REMOVE_IF_FOUND) {
            elem.?.value = MP_OBJ_NULL; // GC-collect the removed value
        }
    }
    return value;
}

export fn npy_dt_method_get(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, dictGetHelperImpl(n_args, args, mp.MP_MAP_LOOKUP));
}
export fn npy_dt_method_pop(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, dictGetHelperImpl(n_args, args, mp.MP_MAP_LOOKUP_REMOVE_IF_FOUND));
}
export fn npy_dt_method_setdefault(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, dictGetHelperImpl(n_args, args, mp.MP_MAP_LOOKUP_ADD_IF_NOT_FOUND));
}

// ── dict_popitem ────────────────────────────────────────────────────
fn dictPopitemImpl(self_in: Obj) PyError!Obj {
    try ensureNotFixed(self_in);
    const self_map = &mirrors.MpObjDict.fromObj(self_in).map;
    const used = self_map.bits.used;
    if (used == 0) try raiseKeyErrorPopitemEmpty();
    var cur: usize = 0;
    // OrderedDict: start at last slot (LIFO).
    if (build_options.is_full and self_map.bits.is_ordered != 0) {
        cur = used - 1;
    }
    const idx = dictIterNext(self_in, &cur) orelse unreachable;
    self_map.bits.used = used - 1;
    const table = self_map.tablePtr();
    var items: [2]Obj = .{ table[idx].key, table[idx].value };
    table[idx].key = mirrors.OBJ_SENTINEL; // tombstone
    table[idx].value = MP_OBJ_NULL;
    return mp_obj_new_tuple(2, &items);
}
export fn npy_dt_method_popitem(self_in: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, dictPopitemImpl(self_in));
}

// ── dict_update ─────────────────────────────────────────────────────
// MP_OBJ_FUN_MAKE_SIG(1, 2, true) = (1<<17) | (2<<1) | 1
const ARG_SIG_UPDATE: u32 = (1 << 17) | (2 << 1) | 1;

inline fn isDictOrOrdered(o: Obj) bool {
    if (!mirrors.isObj(o)) return false;
    const t = mirrors.objBaseType(o) orelse return false;
    // Match vendor's mp_obj_is_dict_or_ordereddict: make_new == mp_obj_dict_make_new.
    const tp = mirrors.MpObjType.fromPtr(t);
    const slot = tp.getSlot(.make_new) orelse return false;
    return @intFromPtr(slot) == @intFromPtr(&mp_obj_dict_make_new);
}

fn dictUpdateImpl(n_args: usize, args: [*c]const Obj, kwargs: *mirrors.MpMap) PyError!Obj {
    try ensureNotFixed(args[0]);
    mp_arg_check_num_sig(n_args, kwargs.bits.used, ARG_SIG_UPDATE);

    if (n_args == 2) {
        if (isDictOrOrdered(args[1])) {
            if (args[1] != args[0] and mirrors.MpObjDict.fromObj(args[1]).map.alloc != 0) {
                var cur: usize = 0;
                const other_table = mirrors.MpObjDict.fromObj(args[1]).map.tablePtr();
                while (dictIterNext(args[1], &cur)) |i| {
                    const k = other_table[i].key;
                    const v = other_table[i].value;
                    const elem = mp_map_lookup(&mirrors.MpObjDict.fromObj(args[0]).map, k, mp.MP_MAP_LOOKUP_ADD_IF_NOT_FOUND);
                    elem.?.value = v;
                }
            }
        } else {
            // iterable of (key, value) pairs
            const iter = mp_getiter(args[1], null);
            while (true) {
                const next = mp_iternext(iter);
                if (next == mirrors.OBJ_STOP_ITERATION) break;
                const inneriter = mp_getiter(next, null);
                const key = mp_iternext(inneriter);
                const value = mp_iternext(inneriter);
                const stop = mp_iternext(inneriter);
                if (key == mirrors.OBJ_STOP_ITERATION or value == mirrors.OBJ_STOP_ITERATION or stop != mirrors.OBJ_STOP_ITERATION) {
                    try raiseValueErrorUpdateSeq();
                    unreachable;
                }
                const elem = mp_map_lookup(&mirrors.MpObjDict.fromObj(args[0]).map, key, mp.MP_MAP_LOOKUP_ADD_IF_NOT_FOUND);
                elem.?.value = value;
            }
        }
    }

    // update with keyword args
    var i: usize = 0;
    while (i < kwargs.alloc) : (i += 1) {
        if (kwargs.slotFilled(i)) {
            const k = kwargs.tablePtr()[i].key;
            const v = kwargs.tablePtr()[i].value;
            const elem = mp_map_lookup(&mirrors.MpObjDict.fromObj(args[0]).map, k, mp.MP_MAP_LOOKUP_ADD_IF_NOT_FOUND);
            elem.?.value = v;
        }
    }
    return mirrors.OBJ_NONE;
}
export fn npy_dt_method_update(n_args: usize, args: [*c]const Obj, kwargs: ?*mirrors.MpMap) callconv(.c) Obj {
    return pyerr.bridge(Obj, dictUpdateImpl(n_args, args, kwargs.?));
}

// ── dict view iterator ──────────────────────────────────────────────
export fn npy_dt_view_it_iternext(self_in: Obj) callconv(.c) Obj {
    const it = NpObjDictViewIt.fromObj(self_in);
    const dict_o = it.dict;
    var cur: usize = it.cur;
    const idx_opt = dictIterNext(dict_o, &cur);
    it.cur = cur;
    if (idx_opt) |idx| {
        const table = mirrors.MpObjDict.fromObj(dict_o).map.tablePtr();
        if (it.kind == DICT_VIEW_KEYS) {
            return table[idx].key;
        } else if (it.kind == DICT_VIEW_VALUES) {
            return table[idx].value;
        } else { // ITEMS (default)
            var items: [2]Obj = .{ table[idx].key, table[idx].value };
            return mp_obj_new_tuple(2, &items);
        }
    } else {
        return mirrors.OBJ_STOP_ITERATION;
    }
}

export fn npy_dt_view_getiter(view_in: Obj, iter_buf: ?*anyopaque) callconv(.c) Obj {
    std.debug.assert(@sizeOf(NpObjDictViewIt) <= @sizeOf(mirrors.MpObjIterBuf));
    const view = NpObjDictView.fromObj(view_in);
    const o: *NpObjDictViewIt = @ptrCast(@alignCast(iter_buf));
    o.base.type = &mp_type_dict_view_it;
    o.kind = view.kind;
    o.dict = view.dict;
    o.cur = 0;
    return @intFromPtr(o);
}

// ── dict_view_print ─────────────────────────────────────────────────
fn viewName(kind: c_int) [*:0]const u8 {
    return switch (kind) {
        DICT_VIEW_ITEMS => "dict_items",
        DICT_VIEW_KEYS => "dict_keys",
        DICT_VIEW_VALUES => "dict_values",
        else => unreachable,
    };
}

export fn npy_dt_view_print(print: ?*const anyopaque, self_in: Obj, _: c_int) callconv(.c) void {
    const view = NpObjDictView.fromObj(self_in);
    _ = mp_print_str(print, viewName(view.kind));
    _ = mp_print_str(print, "([");
    var iter_buf: mirrors.MpObjIterBuf = undefined;
    const self_iter = npy_dt_view_getiter(self_in, &iter_buf);
    var first = true;
    while (true) {
        const next = npy_dt_view_it_iternext(self_iter);
        if (next == mirrors.OBJ_STOP_ITERATION) break;
        if (!first) _ = mp_print_str(print, ", ");
        first = false;
        mp_obj_print_helper(print, next, mp.PRINT_REPR);
    }
    _ = mp_print_str(print, "])");
}

// ── dict_view_unary_op / binary_op ──────────────────────────────────
export fn npy_dt_view_unary_op(op: c_int, o_in: Obj) callconv(.c) Obj {
    const view = NpObjDictView.fromObj(o_in);
    // only .values() supports __hash__
    if (op == mp.MP_UNARY_OP_HASH and view.kind == DICT_VIEW_VALUES) {
        return mirrors.newSmallInt(@bitCast(o_in));
    }
    // delegate
    return npy_dt_unary_op(op, view.dict);
}

export fn npy_dt_view_binary_op(op: c_int, lhs_in: Obj, rhs_in: Obj) callconv(.c) Obj {
    const view = NpObjDictView.fromObj(lhs_in);
    if (view.kind != DICT_VIEW_KEYS) return MP_OBJ_NULL;
    if (op != mp.MP_BINARY_OP_CONTAINS) return MP_OBJ_NULL;
    return npy_dt_binary_op(op, view.dict, rhs_in);
}

// ── dict.items/keys/values ──────────────────────────────────────────
fn newDictView(dict_o: Obj, kind: c_int) Obj {
    const raw = mp_obj_malloc_helper(@sizeOf(NpObjDictView), &mp_type_dict_view).?;
    const o: *NpObjDictView = @ptrCast(@alignCast(raw));
    o.dict = dict_o;
    o.kind = kind;
    return @intFromPtr(o);
}

export fn npy_dt_method_items(self_in: Obj) callconv(.c) Obj {
    return newDictView(self_in, DICT_VIEW_ITEMS);
}
export fn npy_dt_method_keys(self_in: Obj) callconv(.c) Obj {
    return newDictView(self_in, DICT_VIEW_KEYS);
}
export fn npy_dt_method_values(self_in: Obj) callconv(.c) Obj {
    return newDictView(self_in, DICT_VIEW_VALUES);
}

// ── dict's own getiter (iterates KEYS) ──────────────────────────────
export fn npy_dt_getiter(self_in: Obj, iter_buf: ?*anyopaque) callconv(.c) Obj {
    std.debug.assert(@sizeOf(NpObjDictViewIt) <= @sizeOf(mirrors.MpObjIterBuf));
    const o: *NpObjDictViewIt = @ptrCast(@alignCast(iter_buf));
    o.base.type = &mp_type_dict_view_it;
    o.kind = DICT_VIEW_KEYS;
    o.dict = self_in;
    o.cur = 0;
    return @intFromPtr(o);
}

// ── public ABI ──────────────────────────────────────────────────────
export fn mp_obj_dict_init(self: *mirrors.MpObjDict, n_args: usize) callconv(.c) void {
    self.base.type = &mp_type_dict;
    mp_map_init(&self.map, n_args);
}

export fn mp_obj_new_dict(n_args: usize) callconv(.c) Obj {
    const raw = m_malloc(@sizeOf(mirrors.MpObjDict)).?;
    const o: *mirrors.MpObjDict = @ptrCast(@alignCast(raw));
    o.base.type = &mp_type_dict;
    mp_map_init(&o.map, n_args);
    return @intFromPtr(o);
}

export fn mp_obj_dict_len(self_in: Obj) callconv(.c) usize {
    return mirrors.MpObjDict.fromObj(self_in).map.bits.used;
}

fn dictStoreImpl(self_in: Obj, key: Obj, value: Obj) PyError!Obj {
    try ensureNotFixed(self_in);
    const elem = mp_map_lookup(&mirrors.MpObjDict.fromObj(self_in).map, key, mp.MP_MAP_LOOKUP_ADD_IF_NOT_FOUND);
    elem.?.value = value;
    return self_in;
}
export fn mp_obj_dict_store(self_in: Obj, key: Obj, value: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, dictStoreImpl(self_in, key, value));
}

fn dictDeleteImpl(self_in: Obj, key: Obj) PyError!Obj {
    var args2: [2]Obj = .{ self_in, key };
    _ = try dictGetHelperImpl(2, &args2, mp.MP_MAP_LOOKUP_REMOVE_IF_FOUND);
    return self_in;
}
export fn mp_obj_dict_delete(self_in: Obj, key: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, dictDeleteImpl(self_in, key));
}

// mp_obj_is_dict_or_ordereddict — checks make_new == mp_obj_dict_make_new.
export fn mp_obj_is_dict_or_ordereddict(o: Obj) callconv(.c) bool {
    return isDictOrOrdered(o);
}

// ── dict.fromkeys classmethod (full only) ──────────────────────────
// classmethod dict.fromkeys(iterable, value=None) — build a dict from
// `iterable`'s elements (as keys) all mapped to `value`.
export fn npy_dt_fromkeys(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    const iterable = args[1];
    const value: Obj = if (n_args > 2) args[2] else mirrors.OBJ_NONE;
    const iter = mp_getiter(iterable, null);

    // Size hint: if the iterable has __len__, pre-allocate that many slots.
    const len_o = mp_obj_len_maybe(iterable);
    const hint: usize = if (len_o == MP_OBJ_NULL) 0 else @intCast(mirrors.smallIntValue(len_o));
    const self_out = mp_obj_new_dict(hint);

    while (true) {
        const next = mp_iternext(iter);
        if (next == mirrors.OBJ_STOP_ITERATION) break;
        const elem = mp_map_lookup(&mirrors.MpObjDict.fromObj(self_out).map, next, mp.MP_MAP_LOOKUP_ADD_IF_NOT_FOUND);
        elem.?.value = value;
    }
    return self_out;
}

// ── ROM: const empty dict ───────────────────────────────────────────
pub export const mp_const_empty_dict_obj: mirrors.MpObjDict = .{
    .base = .{ .type = &mp_type_dict },
    .map = .{
        .bits = .{
            .all_keys_are_qstrs = 0,
            .is_fixed = 1,
            .is_ordered = 1,
            .used = 0,
        },
        .alloc = 0,
        .table = null,
    },
};

// ── ROM: dict methods (fun_obj wrappers) ────────────────────────────
pub export const dict_clear_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_1 },
    .fun = @ptrCast(&npy_dt_method_clear),
};
pub export const dict_copy_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_1 },
    .fun = @ptrCast(&mp_obj_dict_copy),
};
pub export const dict_get_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(2, 3, false),
    .fun = @ptrCast(&npy_dt_method_get),
};
pub export const dict_pop_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(2, 3, false),
    .fun = @ptrCast(&npy_dt_method_pop),
};
pub export const dict_setdefault_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(2, 3, false),
    .fun = @ptrCast(&npy_dt_method_setdefault),
};
pub export const dict_popitem_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_1 },
    .fun = @ptrCast(&npy_dt_method_popitem),
};
// MP_DEFINE_CONST_FUN_OBJ_KW: takes_kw=true, max=ARGS_MAX (0xffff).
pub export const dict_update_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(1, 0xffff, true),
    .fun = @ptrCast(&npy_dt_method_update),
};
pub export const dict_items_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_1 },
    .fun = @ptrCast(&npy_dt_method_items),
};
pub export const dict_keys_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_1 },
    .fun = @ptrCast(&npy_dt_method_keys),
};
pub export const dict_values_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_1 },
    .fun = @ptrCast(&npy_dt_method_values),
};

// dict.fromkeys classmethod — full only.
pub export const dict_fromkeys_fun_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(2, 3, false),
    .fun = @ptrCast(&npy_dt_fromkeys),
};
pub export const dict_fromkeys_obj: mirrors.MpObjStaticClassMethod = .{
    .base = .{ .type = &mp_type_classmethod },
    .fun = @ptrCast(&dict_fromkeys_fun_obj),
};

// ── ROM: locals_dict table ──────────────────────────────────────────
const RomEntry = extern struct {
    key: Obj,
    value: *const anyopaque,
};

const dict_locals_dict_table_nano = [_]RomEntry{
    // dict.fromkeys ungated from is_full. The vendor gate
    // (MICROPY_PY_BUILTINS_DICT_FROMKEYS) is now =1 in nano
    // (port/mpconfigport.h); the previous "buggy nano" exclusion
    // was bug-for-bug compat with the frozen reference.
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_fromkeys)), .value = &dict_fromkeys_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_clear)), .value = &dict_clear_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_copy)), .value = &dict_copy_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_get)), .value = &dict_get_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_items)), .value = &dict_items_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_keys)), .value = &dict_keys_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_pop)), .value = &dict_pop_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_popitem)), .value = &dict_popitem_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_setdefault)), .value = &dict_setdefault_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_update)), .value = &dict_update_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_values)), .value = &dict_values_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR___getitem__)), .value = &mp_op_getitem_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR___setitem__)), .value = &mp_op_setitem_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR___delitem__)), .value = &mp_op_delitem_obj },
};

const dict_locals_dict_table_full = [_]RomEntry{
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_fromkeys)), .value = &dict_fromkeys_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_clear)), .value = &dict_clear_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_copy)), .value = &dict_copy_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_get)), .value = &dict_get_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_items)), .value = &dict_items_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_keys)), .value = &dict_keys_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_pop)), .value = &dict_pop_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_popitem)), .value = &dict_popitem_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_setdefault)), .value = &dict_setdefault_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_update)), .value = &dict_update_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_values)), .value = &dict_values_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR___getitem__)), .value = &mp_op_getitem_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR___setitem__)), .value = &mp_op_setitem_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR___delitem__)), .value = &mp_op_delitem_obj },
};

// Build the locals_dict at comptime — split by config to keep the
// `dict_fromkeys_obj` row out of the nano ROM.
const dict_locals_dict_table_len = if (build_options.is_full)
    dict_locals_dict_table_full.len
else
    dict_locals_dict_table_nano.len;

pub export const dict_locals_dict: mirrors.MpObjDict = .{
    .base = .{ .type = &mp_type_dict },
    .map = .{
        .bits = .{ .all_keys_are_qstrs = 1, .is_fixed = 1, .is_ordered = 1, .used = dict_locals_dict_table_len },
        .alloc = dict_locals_dict_table_len,
        .table = if (build_options.is_full)
            @ptrCast(@constCast(&dict_locals_dict_table_full))
        else
            @ptrCast(@constCast(&dict_locals_dict_table_nano)),
    },
};

// ── ROM: mp_type_dict ───────────────────────────────────────────────
// MP_TYPE_FLAG_ITER_IS_GETITER = 0x0000.
// Slot order from MP_DEFINE_CONST_OBJ_TYPE: make_new=1, print=2,
// unary_op=3, binary_op=4, subscr=5, iter=6, locals_dict=7.
pub export const mp_type_dict: types.MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = 0x0000,
        .name = mp.MP_QSTR_dict,
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
        @ptrCast(&mp_obj_dict_make_new),
        @ptrCast(&npy_dt_print),
        @ptrCast(&npy_dt_unary_op),
        @ptrCast(&npy_dt_binary_op),
        @ptrCast(&npy_dt_subscr),
        @ptrCast(&npy_dt_getiter),
        @ptrCast(&dict_locals_dict),
        null,
        null,
        null,
        null,
    },
};

// ── ROM: mp_type_ordereddict ────────────────────────────────────────
// Same slots as dict, different qstr + parent link. Slot order from
// MP_DEFINE_CONST_OBJ_TYPE: make_new=1, print=2, unary_op=3, binary_op=4,
// subscr=5, iter=6, parent=7, locals_dict=8.
pub export const mp_type_ordereddict: types.MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = 0x0000,
        .name = mp.MP_QSTR_OrderedDict,
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
        .slot_index_parent = 7,
        .slot_index_locals_dict = 8,
    },
    .slots = .{
        @ptrCast(&mp_obj_dict_make_new),
        @ptrCast(&npy_dt_print),
        @ptrCast(&npy_dt_unary_op),
        @ptrCast(&npy_dt_binary_op),
        @ptrCast(&npy_dt_subscr),
        @ptrCast(&npy_dt_getiter),
        &mp_type_dict,
        @ptrCast(&dict_locals_dict),
        null,
        null,
        null,
    },
};

// ── ROM: dict_view + dict_view_it ───────────────────────────────────
// dict_view_it: MP_TYPE_FLAG_ITER_IS_ITERNEXT = 0x0080, iter slot only.
pub export const mp_type_dict_view_it: types.MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = mirrors.FLAG_ITER_IS_ITERNEXT,
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
        @ptrCast(&npy_dt_view_it_iternext),
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
    },
};

// dict_view: MP_TYPE_FLAG_ITER_IS_GETITER = 0x0000.
// Slot order from MP_DEFINE_CONST_OBJ_TYPE: print=1, unary_op=2,
// binary_op=3, iter=4.
pub export const mp_type_dict_view: types.MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = 0x0000,
        .name = mp.MP_QSTR_dict_view,
        .slot_index_make_new = 0,
        .slot_index_print = 1,
        .slot_index_call = 0,
        .slot_index_unary_op = 2,
        .slot_index_binary_op = 3,
        .slot_index_attr = 0,
        .slot_index_subscr = 0,
        .slot_index_iter = 4,
        .slot_index_buffer = 0,
        .slot_index_protocol = 0,
        .slot_index_parent = 0,
        .slot_index_locals_dict = 0,
    },
    .slots = .{
        @ptrCast(&npy_dt_view_print),
        @ptrCast(&npy_dt_view_unary_op),
        @ptrCast(&npy_dt_view_binary_op),
        @ptrCast(&npy_dt_view_getiter),
        null,
        null,
        null,
        null,
        null,
        null,
        null,
    },
};

comptime {
    _ = &npy_dt_print;
    _ = &mp_obj_dict_make_new;
    _ = &npy_dt_unary_op;
    _ = &npy_dt_binary_op;
    _ = &mp_obj_dict_get;
    _ = &npy_dt_subscr;
    _ = &npy_dt_method_clear;
    _ = &mp_obj_dict_copy;
    _ = &npy_dt_method_get;
    _ = &npy_dt_method_pop;
    _ = &npy_dt_method_setdefault;
    _ = &npy_dt_method_popitem;
    _ = &npy_dt_method_update;
    _ = &npy_dt_view_it_iternext;
    _ = &npy_dt_view_getiter;
    _ = &npy_dt_view_print;
    _ = &npy_dt_view_unary_op;
    _ = &npy_dt_view_binary_op;
    _ = &npy_dt_method_items;
    _ = &npy_dt_method_keys;
    _ = &npy_dt_method_values;
    _ = &npy_dt_getiter;
    _ = &mp_obj_dict_init;
    _ = &mp_obj_new_dict;
    _ = &mp_obj_dict_len;
    _ = &mp_obj_dict_store;
    _ = &mp_obj_dict_delete;
    _ = &mp_obj_is_dict_or_ordereddict;
    _ = &npy_dt_fromkeys;
    _ = &mp_const_empty_dict_obj;
    _ = &mp_type_dict;
    _ = &mp_type_ordereddict;
    _ = &mp_type_dict_view;
    _ = &mp_type_dict_view_it;
    _ = &dict_locals_dict;
}
