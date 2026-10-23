//! petitpy — full Zig port of py/objset.c.
//!
//! Nano config (probed): SET=1, FROZENSET=1. Both types live and share
//! make_new, print, iter, unary_op, binary_op. The frozenset locals_dict
//! omits mutating methods. All hash storage lives in mp_set_t (alloc/used/
//! table) — the mp_set_* primitives are in map.zig.
//!
//! The iterator (mp_obj_set_it_t) is overlaid into the caller's
//! mp_obj_iter_buf_t (size-asserted at vendor DEBUG; no-op under nano).
//!
//! Uses .c-bridge calls (mp_check_self is a no-op under NDEBUG; raise paths
//! use the existing C runtime helpers via extern).

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

// ── mp_set_t layout (obj.h:512-516; flat — no bitfields) ────────────
const MpSet = extern struct {
    alloc: usize,
    used: usize,
    table: ?[*]Obj,
};

const MpObjSet = extern struct {
    base: mirrors.MpObjBase,
    set: MpSet,

    inline fn fromObj(o: Obj) *MpObjSet {
        return @ptrFromInt(o);
    }
};

// Iterator overlay (mp_obj_set_it_t).
const MpObjSetIt = extern struct {
    base: mirrors.MpObjBase,
    iternext: *const fn (Obj) callconv(.c) Obj,
    set: *MpObjSet,
    cur: usize,

    inline fn fromObj(o: Obj) *MpObjSetIt {
        return @ptrFromInt(o);
    }
};

// ── externs ─────────────────────────────────────────────────────────
extern const mp_type_type: anyopaque;
extern const mp_type_dict: anyopaque;
extern const mp_type_polymorph_iter: anyopaque;
extern const mp_type_fun_builtin_1: anyopaque;
extern const mp_type_fun_builtin_2: anyopaque;
extern const mp_type_fun_builtin_var: anyopaque;
extern const mp_type_KeyError: anyopaque;

extern const mp_op_contains_obj: mirrors.MpObjFunBuiltinFixed;

extern fn mp_getiter(o: Obj, iter_buf: ?*anyopaque) callconv(.c) Obj;
extern fn mp_iternext(o: Obj) callconv(.c) Obj;
extern fn mp_unary_op(op: c_int, arg: Obj) callconv(.c) Obj;
extern fn mp_obj_print_helper(print: ?*const anyopaque, o: Obj, kind: c_int) callconv(.c) void;
extern fn mp_print_str(print: ?*const anyopaque, s: [*:0]const u8) callconv(.c) c_int;
extern fn mp_arg_check_num_sig(n_args: usize, n_kw: usize, sig: u32) callconv(.c) void;
extern fn mp_obj_malloc_helper(num_bytes: usize, type_in: *const anyopaque) callconv(.c) ?*anyopaque;
extern fn mp_obj_new_exception_msg(t: *const anyopaque, msg: [*:0]const u8) callconv(.c) Obj;
extern fn mp_obj_new_exception_args(t: *const anyopaque, n_args: usize, args: [*c]const Obj) callconv(.c) Obj;
extern fn m_malloc(num_bytes: usize) callconv(.c) ?*anyopaque;
extern fn m_free(ptr: ?*anyopaque) callconv(.c) void;

// mp_set_* primitives (map.zig).
extern fn mp_set_init(set: *MpSet, n: usize) callconv(.c) void;
extern fn mp_set_lookup(set: *MpSet, index: Obj, lookup_kind: c_int) callconv(.c) Obj;
extern fn mp_set_remove_first(set: *MpSet) callconv(.c) Obj;
extern fn mp_set_clear(set: *MpSet) callconv(.c) void;

// ── helpers ─────────────────────────────────────────────────────────
// Raise helpers (PyError convention: set pending_exc and return error.PyRaise).
fn raiseKeyErrorPopEmpty() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_KeyError, "pop from an empty set");
    return error.PyRaise;
}
fn raiseKeyErrorArg(item: Obj) PyError!void {
    var args: [1]Obj = .{item};
    pyerr.pending_exc = mp_obj_new_exception_args(&mp_type_KeyError, 1, &args);
    return error.PyRaise;
}

inline fn isSetOrFrozenset(o: Obj) bool {
    return mirrors.isExactType(o, &mp_type_set) or mirrors.isExactType(o, &mp_type_frozenset);
}

inline fn setSlotIsFilled(s: *const MpSet, i: usize) bool {
    const t = s.table.?;
    return t[i] != mirrors.OBJ_NULL and t[i] != mirrors.OBJ_SENTINEL;
}

// MP_OBJ_FUN_MAKE_SIG(0, 1, false) = (1<<1) = 2
const ARG_SIG_SET_MAKE_NEW: u32 = (0 << 17) | (1 << 1) | 0;

// ── print ───────────────────────────────────────────────────────────
export fn npy_set_print(print: ?*const anyopaque, self_in: Obj, _: c_int) callconv(.c) void {
    const self = MpObjSet.fromObj(self_in);
    const is_frozen = mirrors.isExactType(self_in, &mp_type_frozenset);
    if (self.set.used == 0) {
        if (is_frozen) _ = mp_print_str(print, "frozen");
        _ = mp_print_str(print, "set()");
        return;
    }
    if (is_frozen) _ = mp_print_str(print, "frozenset(");
    _ = mp_print_str(print, "{");
    var first = true;
    var i: usize = 0;
    while (i < self.set.alloc) : (i += 1) {
        if (setSlotIsFilled(&self.set, i)) {
            if (!first) _ = mp_print_str(print, ", ");
            first = false;
            mp_obj_print_helper(print, self.set.table.?[i], mp.PRINT_REPR);
        }
    }
    _ = mp_print_str(print, "}");
    if (is_frozen) _ = mp_print_str(print, ")");
}

// ── make_new ────────────────────────────────────────────────────────
export fn npy_set_make_new(type_in: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    mp_arg_check_num_sig(n_args, n_kw, ARG_SIG_SET_MAKE_NEW);

    if (n_args == 0) {
        const set = MpObjSet.fromObj(mp_obj_new_set(0, null));
        set.base.type = type_in;
        return @intFromPtr(set);
    }
    // n_args == 1: build from an iterable.
    const set_obj = mp_obj_new_set(0, null);
    const iterable = mp_getiter(args[0], null);
    while (true) {
        const item = mp_iternext(iterable);
        if (item == mirrors.OBJ_STOP_ITERATION) break;
        mp_obj_set_store(set_obj, item);
    }
    MpObjSet.fromObj(set_obj).base.type = type_in;
    return set_obj;
}

// ── iterator ────────────────────────────────────────────────────────
export fn npy_set_it_iternext(self_in: Obj) callconv(.c) Obj {
    const self = MpObjSetIt.fromObj(self_in);
    const max = self.set.set.alloc;
    var i: usize = self.cur;
    while (i < max) : (i += 1) {
        if (setSlotIsFilled(&self.set.set, i)) {
            self.cur = i + 1;
            return self.set.set.table.?[i];
        }
    }
    return mirrors.OBJ_STOP_ITERATION;
}

export fn npy_set_getiter(set_in: Obj, iter_buf: ?*anyopaque) callconv(.c) Obj {
    const o: *MpObjSetIt = @ptrCast(@alignCast(iter_buf));
    o.base.type = &mp_type_polymorph_iter;
    o.iternext = &npy_set_it_iternext;
    o.set = MpObjSet.fromObj(set_in);
    o.cur = 0;
    return @intFromPtr(o);
}

// ── set methods ─────────────────────────────────────────────────────
fn setAddImpl(self_in: Obj, item: Obj) Obj {
    const self = MpObjSet.fromObj(self_in);
    _ = mp_set_lookup(&self.set, item, mp.MP_MAP_LOOKUP_ADD_IF_NOT_FOUND);
    return mirrors.OBJ_NONE;
}
export fn npy_set_add(self_in: Obj, item: Obj) callconv(.c) Obj {
    return setAddImpl(self_in, item);
}

fn setClearImpl(self_in: Obj) Obj {
    const self = MpObjSet.fromObj(self_in);
    mp_set_clear(&self.set);
    return mirrors.OBJ_NONE;
}
export fn npy_set_clear(self_in: Obj) callconv(.c) Obj {
    return setClearImpl(self_in);
}

fn setCopyImpl(self_in: Obj) Obj {
    const self = MpObjSet.fromObj(self_in);
    const other_raw = mp_obj_malloc_helper(@sizeOf(MpObjSet), self.base.type.?).?;
    const other: *MpObjSet = @ptrCast(@alignCast(other_raw));
    mp_set_init(&other.set, self.set.alloc);
    other.set.used = self.set.used;
    // memcpy via element-by-element since aliasing is impossible (fresh alloc).
    var i: usize = 0;
    while (i < self.set.alloc) : (i += 1) {
        other.set.table.?[i] = self.set.table.?[i];
    }
    return @intFromPtr(other);
}
export fn npy_set_copy(self_in: Obj) callconv(.c) Obj {
    return setCopyImpl(self_in);
}

export fn npy_set_discard(self_in: Obj, item: Obj) callconv(.c) Obj {
    const self = MpObjSet.fromObj(self_in);
    _ = mp_set_lookup(&self.set, item, mp.MP_MAP_LOOKUP_REMOVE_IF_FOUND);
    return mirrors.OBJ_NONE;
}

fn setDiffInt(n_args: usize, args: [*c]const Obj, update: bool) Obj {
    var self: Obj = undefined;
    if (update) {
        self = args[0];
    } else {
        self = setCopyImpl(args[0]);
    }
    var i: usize = 1;
    while (i < n_args) : (i += 1) {
        const other = args[i];
        if (self == other) {
            _ = setClearImpl(self);
        } else {
            const self_set = &MpObjSet.fromObj(self).set;
            const iter = mp_getiter(other, null);
            while (true) {
                const next = mp_iternext(iter);
                if (next == mirrors.OBJ_STOP_ITERATION) break;
                _ = mp_set_lookup(self_set, next, mp.MP_MAP_LOOKUP_REMOVE_IF_FOUND);
            }
        }
    }
    return self;
}

export fn npy_set_diff(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return setDiffInt(n_args, args, false);
}

export fn npy_set_diff_update(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    _ = setDiffInt(n_args, args, true);
    return mirrors.OBJ_NONE;
}

fn setIntersectInt(self_in: Obj, other: Obj, update: bool) Obj {
    if (self_in == other) {
        return if (update) mirrors.OBJ_NONE else setCopyImpl(self_in);
    }
    const self = MpObjSet.fromObj(self_in);
    const out = MpObjSet.fromObj(mp_obj_new_set(0, null));
    const iter = mp_getiter(other, null);
    while (true) {
        const next = mp_iternext(iter);
        if (next == mirrors.OBJ_STOP_ITERATION) break;
        if (mp_set_lookup(&self.set, next, mp.MP_MAP_LOOKUP) != mirrors.OBJ_NULL) {
            _ = setAddImpl(@intFromPtr(out), next);
        }
    }
    if (update) {
        m_free(@ptrCast(self.set.table));
        self.set.alloc = out.set.alloc;
        self.set.used = out.set.used;
        self.set.table = out.set.table;
        return mirrors.OBJ_NONE;
    }
    return @intFromPtr(out);
}

export fn npy_set_intersect(self_in: Obj, other: Obj) callconv(.c) Obj {
    return setIntersectInt(self_in, other, false);
}

export fn npy_set_intersect_update(self_in: Obj, other: Obj) callconv(.c) Obj {
    return setIntersectInt(self_in, other, true);
}

export fn npy_set_isdisjoint(self_in: Obj, other: Obj) callconv(.c) Obj {
    const self = MpObjSet.fromObj(self_in);
    var iter_buf: mirrors.MpObjIterBuf = undefined;
    const iter = mp_getiter(other, &iter_buf);
    while (true) {
        const next = mp_iternext(iter);
        if (next == mirrors.OBJ_STOP_ITERATION) break;
        if (mp_set_lookup(&self.set, next, mp.MP_MAP_LOOKUP) != mirrors.OBJ_NULL) {
            return mirrors.OBJ_FALSE;
        }
    }
    return mirrors.OBJ_TRUE;
}

fn setIssubsetInternal(self_in_in: Obj, other_in_in: Obj, proper: bool) Obj {
    var self_in = self_in_in;
    var other_in = other_in_in;
    var cleanup_self = false;
    var cleanup_other = false;
    if (!isSetOrFrozenset(self_in)) {
        self_in = npy_set_make_new(&mp_type_set, 1, 0, @ptrCast(&self_in_in));
        cleanup_self = true;
    }
    if (!isSetOrFrozenset(other_in)) {
        other_in = npy_set_make_new(&mp_type_set, 1, 0, @ptrCast(&other_in_in));
        cleanup_other = true;
    }
    const self = MpObjSet.fromObj(self_in);
    const other = MpObjSet.fromObj(other_in);
    var out: Obj = mirrors.OBJ_TRUE;
    if (proper and self.set.used == other.set.used) {
        out = mirrors.OBJ_FALSE;
    } else {
        var iter_buf: mirrors.MpObjIterBuf = undefined;
        const iter = npy_set_getiter(self_in, &iter_buf);
        while (true) {
            const next = npy_set_it_iternext(iter);
            if (next == mirrors.OBJ_STOP_ITERATION) break;
            if (mp_set_lookup(&other.set, next, mp.MP_MAP_LOOKUP) == mirrors.OBJ_NULL) {
                out = mirrors.OBJ_FALSE;
                break;
            }
        }
    }
    if (cleanup_self) _ = setClearImpl(self_in);
    if (cleanup_other) _ = setClearImpl(other_in);
    return out;
}

export fn npy_set_issubset(self_in: Obj, other_in: Obj) callconv(.c) Obj {
    return setIssubsetInternal(self_in, other_in, false);
}

fn setIssubsetProper(self_in: Obj, other_in: Obj) Obj {
    return setIssubsetInternal(self_in, other_in, true);
}

export fn npy_set_issuperset(self_in: Obj, other_in: Obj) callconv(.c) Obj {
    return setIssubsetInternal(other_in, self_in, false);
}

fn setIssupersetProper(self_in: Obj, other_in: Obj) Obj {
    return setIssubsetInternal(other_in, self_in, true);
}

fn setEqual(self_in: Obj, other_in: Obj) Obj {
    const self = MpObjSet.fromObj(self_in);
    const other = MpObjSet.fromObj(other_in);
    if (self.set.used != other.set.used) return mirrors.OBJ_FALSE;
    return npy_set_issubset(self_in, other_in);
}

fn setPopImpl(self_in: Obj) PyError!Obj {
    const self = MpObjSet.fromObj(self_in);
    const obj = mp_set_remove_first(&self.set);
    if (obj == mirrors.OBJ_NULL) try raiseKeyErrorPopEmpty();
    return obj;
}
export fn npy_set_pop(self_in: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, setPopImpl(self_in));
}

fn setRemoveImpl(self_in: Obj, item: Obj) PyError!Obj {
    const self = MpObjSet.fromObj(self_in);
    if (mp_set_lookup(&self.set, item, mp.MP_MAP_LOOKUP_REMOVE_IF_FOUND) == mirrors.OBJ_NULL) {
        try raiseKeyErrorArg(item);
    }
    return mirrors.OBJ_NONE;
}
export fn npy_set_remove(self_in: Obj, item: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, setRemoveImpl(self_in, item));
}

fn setSymdiffUpdateImpl(self_in: Obj, other_in: Obj) Obj {
    const self = MpObjSet.fromObj(self_in);
    const iter = mp_getiter(other_in, null);
    while (true) {
        const next = mp_iternext(iter);
        if (next == mirrors.OBJ_STOP_ITERATION) break;
        _ = mp_set_lookup(&self.set, next, mp.MP_MAP_LOOKUP_ADD_IF_NOT_FOUND_OR_REMOVE_IF_FOUND);
    }
    return mirrors.OBJ_NONE;
}
export fn npy_set_symdiff_update(self_in: Obj, other_in: Obj) callconv(.c) Obj {
    return setSymdiffUpdateImpl(self_in, other_in);
}

fn setSymdiffImpl(self_in: Obj, other_in: Obj) Obj {
    const self_out = setCopyImpl(self_in);
    _ = setSymdiffUpdateImpl(self_out, other_in);
    return self_out;
}
export fn npy_set_symdiff(self_in: Obj, other_in: Obj) callconv(.c) Obj {
    return setSymdiffImpl(self_in, other_in);
}

fn setUpdateOne(self: *MpObjSet, other_in: Obj) void {
    const iter = mp_getiter(other_in, null);
    while (true) {
        const next = mp_iternext(iter);
        if (next == mirrors.OBJ_STOP_ITERATION) break;
        _ = mp_set_lookup(&self.set, next, mp.MP_MAP_LOOKUP_ADD_IF_NOT_FOUND);
    }
}

export fn npy_set_update(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    var i: usize = 1;
    const self = MpObjSet.fromObj(args[0]);
    while (i < n_args) : (i += 1) {
        setUpdateOne(self, args[i]);
    }
    return mirrors.OBJ_NONE;
}

fn setUnionImpl(self_in: Obj, other_in: Obj) Obj {
    const out = setCopyImpl(self_in);
    setUpdateOne(MpObjSet.fromObj(out), other_in);
    return out;
}
export fn npy_set_union(self_in: Obj, other_in: Obj) callconv(.c) Obj {
    return setUnionImpl(self_in, other_in);
}

// ── unary_op / binary_op ────────────────────────────────────────────
export fn npy_set_unary_op(op: c_int, self_in: Obj) callconv(.c) Obj {
    const self = MpObjSet.fromObj(self_in);
    if (op == mp.MP_UNARY_OP_BOOL) {
        return mirrors.newBool(self.set.used != 0);
    } else if (op == mp.MP_UNARY_OP_LEN) {
        return mirrors.newSmallInt(@bitCast(self.set.used));
    } else if (op == mp.MP_UNARY_OP_HASH) {
        if (mirrors.isExactType(self_in, &mp_type_frozenset)) {
            // Start hash with unique value (pointer to mp_type_frozenset).
            var hash: isize = @bitCast(@intFromPtr(&mp_type_frozenset));
            const max = self.set.alloc;
            var i: usize = 0;
            while (i < max) : (i += 1) {
                if (setSlotIsFilled(&self.set, i)) {
                    hash +%= mirrors.smallIntValue(mp_unary_op(mp.MP_UNARY_OP_HASH, self.set.table.?[i]));
                }
            }
            return mirrors.newSmallInt(hash);
        }
        return mirrors.OBJ_NULL;
    }
    return mirrors.OBJ_NULL;
}

export fn npy_set_binary_op(op: c_int, lhs: Obj, rhs: Obj) callconv(.c) Obj {
    var args: [2]Obj = .{ lhs, rhs };
    const update = mirrors.isExactType(lhs, &mp_type_set);
    if (op != mp.MP_BINARY_OP_CONTAINS and !isSetOrFrozenset(rhs)) {
        return mirrors.OBJ_NULL;
    }
    switch (op) {
        mp.MP_BINARY_OP_OR => return setUnionImpl(lhs, rhs),
        mp.MP_BINARY_OP_XOR => return setSymdiffImpl(lhs, rhs),
        mp.MP_BINARY_OP_AND => return setIntersectInt(lhs, rhs, false),
        mp.MP_BINARY_OP_SUBTRACT => return setDiffInt(2, &args, false),
        mp.MP_BINARY_OP_INPLACE_OR => {
            if (update) {
                _ = npy_set_update(2, &args);
                return lhs;
            }
            return setUnionImpl(lhs, rhs);
        },
        mp.MP_BINARY_OP_INPLACE_XOR => {
            if (update) {
                _ = setSymdiffUpdateImpl(lhs, rhs);
                return lhs;
            }
            return setSymdiffImpl(lhs, rhs);
        },
        mp.MP_BINARY_OP_INPLACE_AND => {
            const out = setIntersectInt(lhs, rhs, update);
            if (update) return lhs;
            return out;
        },
        mp.MP_BINARY_OP_INPLACE_SUBTRACT => return setDiffInt(2, &args, update),
        mp.MP_BINARY_OP_LESS => return setIssubsetProper(lhs, rhs),
        mp.MP_BINARY_OP_MORE => return setIssupersetProper(lhs, rhs),
        mp.MP_BINARY_OP_EQUAL => return setEqual(lhs, rhs),
        mp.MP_BINARY_OP_LESS_EQUAL => return npy_set_issubset(lhs, rhs),
        mp.MP_BINARY_OP_MORE_EQUAL => return npy_set_issuperset(lhs, rhs),
        mp.MP_BINARY_OP_CONTAINS => {
            const o = MpObjSet.fromObj(lhs);
            const elem = mp_set_lookup(&o.set, rhs, mp.MP_MAP_LOOKUP);
            return mirrors.newBool(elem != mirrors.OBJ_NULL);
        },
        else => return mirrors.OBJ_NULL,
    }
}

// ── public ABI ──────────────────────────────────────────────────────
export fn mp_obj_new_set(n_args: usize, items: [*c]const Obj) callconv(.c) Obj {
    const raw = m_malloc(@sizeOf(MpObjSet)).?;
    const o: *MpObjSet = @ptrCast(@alignCast(raw));
    o.base.type = &mp_type_set;
    mp_set_init(&o.set, n_args);
    var i: usize = 0;
    while (i < n_args) : (i += 1) {
        _ = mp_set_lookup(&o.set, items[i], mp.MP_MAP_LOOKUP_ADD_IF_NOT_FOUND);
    }
    return @intFromPtr(o);
}

export fn mp_obj_set_store(self_in: Obj, item: Obj) callconv(.c) void {
    const self = MpObjSet.fromObj(self_in);
    _ = mp_set_lookup(&self.set, item, mp.MP_MAP_LOOKUP_ADD_IF_NOT_FOUND);
}

// ── ROM: method fun-objs ────────────────────────────────────────────
pub export const set_add_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&npy_set_add),
};
pub export const set_clear_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_1 },
    .fun = @ptrCast(&npy_set_clear),
};
pub export const set_copy_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_1 },
    .fun = @ptrCast(&npy_set_copy),
};
pub export const set_discard_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&npy_set_discard),
};
pub export const set_diff_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(1, 0xffff, false),
    .fun = @ptrCast(&npy_set_diff),
};
pub export const set_diff_update_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(1, 0xffff, false),
    .fun = @ptrCast(&npy_set_diff_update),
};
pub export const set_intersect_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&npy_set_intersect),
};
pub export const set_intersect_update_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&npy_set_intersect_update),
};
pub export const set_isdisjoint_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&npy_set_isdisjoint),
};
pub export const set_issubset_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&npy_set_issubset),
};
pub export const set_issuperset_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&npy_set_issuperset),
};
pub export const set_pop_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_1 },
    .fun = @ptrCast(&npy_set_pop),
};
pub export const set_remove_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&npy_set_remove),
};
pub export const set_symmetric_difference_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&npy_set_symdiff),
};
pub export const set_symmetric_difference_update_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&npy_set_symdiff_update),
};
pub export const set_union_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&npy_set_union),
};
pub export const set_update_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(1, 0xffff, false),
    .fun = @ptrCast(&npy_set_update),
};

// ── ROM: locals_dict tables ─────────────────────────────────────────
const RomEntry = extern struct {
    key: Obj,
    value: *const anyopaque,
};

const set_locals_dict_table = [_]RomEntry{
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_add)), .value = &set_add_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_clear)), .value = &set_clear_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_copy)), .value = &set_copy_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_discard)), .value = &set_discard_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_difference)), .value = &set_diff_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_difference_update)), .value = &set_diff_update_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_intersection)), .value = &set_intersect_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_intersection_update)), .value = &set_intersect_update_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_isdisjoint)), .value = &set_isdisjoint_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_issubset)), .value = &set_issubset_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_issuperset)), .value = &set_issuperset_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_pop)), .value = &set_pop_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_remove)), .value = &set_remove_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_symmetric_difference)), .value = &set_symmetric_difference_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_symmetric_difference_update)), .value = &set_symmetric_difference_update_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_union)), .value = &set_union_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_update)), .value = &set_update_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR___contains__)), .value = &mp_op_contains_obj },
};

pub export const set_locals_dict: mirrors.MpObjDict = .{
    .base = .{ .type = &mp_type_dict },
    .map = .{
        .bits = .{ .all_keys_are_qstrs = 1, .is_fixed = 1, .is_ordered = 1, .used = set_locals_dict_table.len },
        .alloc = set_locals_dict_table.len,
        .table = @ptrCast(@constCast(&set_locals_dict_table)),
    },
};

const frozenset_locals_dict_table = [_]RomEntry{
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_copy)), .value = &set_copy_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_difference)), .value = &set_diff_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_intersection)), .value = &set_intersect_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_isdisjoint)), .value = &set_isdisjoint_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_issubset)), .value = &set_issubset_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_issuperset)), .value = &set_issuperset_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_symmetric_difference)), .value = &set_symmetric_difference_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_union)), .value = &set_union_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR___contains__)), .value = &mp_op_contains_obj },
};

pub export const frozenset_locals_dict: mirrors.MpObjDict = .{
    .base = .{ .type = &mp_type_dict },
    .map = .{
        .bits = .{ .all_keys_are_qstrs = 1, .is_fixed = 1, .is_ordered = 1, .used = frozenset_locals_dict_table.len },
        .alloc = frozenset_locals_dict_table.len,
        .table = @ptrCast(@constCast(&frozenset_locals_dict_table)),
    },
};

// ── ROM: mp_type_set ────────────────────────────────────────────────
// MP_TYPE_FLAG_ITER_IS_GETITER = 0x0000.
// Slot order: make_new=1, print=2, unary_op=3, binary_op=4, iter=5,
// locals_dict=6.
pub export const mp_type_set: types.MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = 0x0000,
        .name = mp.MP_QSTR_set,
        .slot_index_make_new = 1,
        .slot_index_print = 2,
        .slot_index_call = 0,
        .slot_index_unary_op = 3,
        .slot_index_binary_op = 4,
        .slot_index_attr = 0,
        .slot_index_subscr = 0,
        .slot_index_iter = 5,
        .slot_index_buffer = 0,
        .slot_index_protocol = 0,
        .slot_index_parent = 0,
        .slot_index_locals_dict = 6,
    },
    .slots = .{
        @ptrCast(&npy_set_make_new),
        @ptrCast(&npy_set_print),
        @ptrCast(&npy_set_unary_op),
        @ptrCast(&npy_set_binary_op),
        @ptrCast(&npy_set_getiter),
        @ptrCast(&set_locals_dict),
        null,
        null,
        null,
        null,
        null,
    },
};

// ── ROM: mp_type_frozenset ─────────────────────────────────────────
// Flags: MP_TYPE_FLAG_EQ_CHECKS_OTHER_TYPE (0x0008) | ITER_IS_GETITER (0x0000).
pub export const mp_type_frozenset: types.MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = 0x0008,
        .name = mp.MP_QSTR_frozenset,
        .slot_index_make_new = 1,
        .slot_index_print = 2,
        .slot_index_call = 0,
        .slot_index_unary_op = 3,
        .slot_index_binary_op = 4,
        .slot_index_attr = 0,
        .slot_index_subscr = 0,
        .slot_index_iter = 5,
        .slot_index_buffer = 0,
        .slot_index_protocol = 0,
        .slot_index_parent = 0,
        .slot_index_locals_dict = 6,
    },
    .slots = .{
        @ptrCast(&npy_set_make_new),
        @ptrCast(&npy_set_print),
        @ptrCast(&npy_set_unary_op),
        @ptrCast(&npy_set_binary_op),
        @ptrCast(&npy_set_getiter),
        @ptrCast(&frozenset_locals_dict),
        null,
        null,
        null,
        null,
        null,
    },
};

comptime {
    _ = &npy_set_print;
    _ = &npy_set_make_new;
    _ = &npy_set_it_iternext;
    _ = &npy_set_getiter;
    _ = &npy_set_add;
    _ = &npy_set_clear;
    _ = &npy_set_copy;
    _ = &npy_set_discard;
    _ = &npy_set_diff;
    _ = &npy_set_diff_update;
    _ = &npy_set_intersect;
    _ = &npy_set_intersect_update;
    _ = &npy_set_isdisjoint;
    _ = &npy_set_issubset;
    _ = &npy_set_issuperset;
    _ = &npy_set_pop;
    _ = &npy_set_remove;
    _ = &npy_set_symdiff;
    _ = &npy_set_symdiff_update;
    _ = &npy_set_union;
    _ = &npy_set_update;
    _ = &npy_set_unary_op;
    _ = &npy_set_binary_op;
    _ = &mp_obj_new_set;
    _ = &mp_obj_set_store;
    _ = &mp_type_set;
    _ = &mp_type_frozenset;
    _ = &set_locals_dict;
    _ = &frozenset_locals_dict;
}
