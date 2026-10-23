//! petitpy — Zig port of py/objdeque.c (collections.deque).
//!
//! Nano config (all =1 at lines 76-78 of port/mpconfigport.h):
//!   MICROPY_PY_COLLECTIONS_DEQUE, _DEQUE_ITER, _DEQUE_SUBSCR.
//! MICROPY_PY_SYS_GETSIZEOF is undefined → SIZEOF branch dropped.
//!
//! Ring buffer: alloc = maxlen+1; len = (i_put - i_get) mod alloc.
//! Iterator overlays on mp_obj_iter_buf_t (uses mp_type_polymorph_iter).

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

const FLAG_CHECK_OVERFLOW: u32 = 1;

// MP_UNARY_OP enum: BOOL=4, LEN=5.
const MP_UNARY_OP_BOOL: c_int = 4;
const MP_UNARY_OP_LEN: c_int = 5;

extern const mp_type_type: anyopaque;
extern const mp_type_dict: anyopaque;
extern const mp_type_polymorph_iter: anyopaque;
extern const mp_type_fun_builtin_1: anyopaque;
extern const mp_type_fun_builtin_2: anyopaque;
extern const mp_type_IndexError: anyopaque;
extern const mp_type_ValueError: anyopaque;

extern fn mp_arg_check_num_sig(n_args: usize, n_kw: usize, sig: u32) callconv(.c) void;
extern fn mp_obj_malloc_helper(num_bytes: usize, type_in: *const anyopaque) callconv(.c) ?*anyopaque;
extern fn mp_obj_get_int(arg: Obj) callconv(.c) isize;
extern fn mp_getiter(o: Obj, iter_buf: ?*anyopaque) callconv(.c) Obj;
extern fn mp_iternext(o: Obj) callconv(.c) Obj;
extern fn mp_get_index(t: *const anyopaque, len: usize, idx: Obj, is_slice: bool) callconv(.c) usize;
extern fn m_malloc0(num_bytes: usize) callconv(.c) ?*anyopaque;
extern fn mp_obj_new_exception(t: *const anyopaque) callconv(.c) Obj;
extern fn mp_obj_new_exception_msg(t: *const anyopaque, msg: [*:0]const u8) callconv(.c) Obj;

// Raise helpers (PyError convention). One per
// distinct exception+message. Sets pyerr.pending_exc + returns
// error.PyRaise — C-ABI exports wrap the impl with pyerr.bridge.
fn raiseValueErrorNeg() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception(&mp_type_ValueError);
    return error.PyRaise;
}
fn raiseIndexErrorFull() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_IndexError, "full");
    return error.PyRaise;
}
fn raiseIndexErrorEmpty() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_IndexError, "empty");
    return error.PyRaise;
}

const MpObjDeque = extern struct {
    base: mirrors.MpObjBase,
    alloc: usize,
    i_get: usize,
    i_put: usize,
    items: [*]Obj,
    flags: u32,

    inline fn fromObj(o: Obj) *MpObjDeque {
        return @ptrFromInt(o);
    }
};

// MP_OBJ_FUN_MAKE_SIG(2, 3, false)
const ARG_SIG_MAKE_NEW: u32 = mirrors.makeFunSig(2, 3, false);

inline fn dequeLen(self: *MpObjDeque) usize {
    if (self.i_put >= self.i_get) {
        return self.i_put - self.i_get;
    }
    return self.i_put + self.alloc - self.i_get;
}

fn dequeMakeNewImpl(type_in: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const Obj) PyError!Obj {
    mp_arg_check_num_sig(n_args, n_kw, ARG_SIG_MAKE_NEW);

    const maxlen = mp_obj_get_int(args[1]);
    if (maxlen < 0) try raiseValueErrorNeg();

    const o: *MpObjDeque = @ptrCast(@alignCast(mp_obj_malloc_helper(@sizeOf(MpObjDeque), type_in.?).?));
    o.base.type = type_in;
    o.alloc = @as(usize, @intCast(maxlen)) + 1;
    o.i_get = 0;
    o.i_put = 0;
    o.items = @ptrCast(@alignCast(m_malloc0(o.alloc * @sizeOf(Obj)).?));
    o.flags = 0;

    if (n_args > 2) {
        o.flags = @intCast(mp_obj_get_int(args[2]));
    }

    _ = try dequeExtendImpl(@intFromPtr(o), args[0]);

    return @intFromPtr(o);
}

export fn deque_make_new(type_in: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, dequeMakeNewImpl(type_in, n_args, n_kw, args));
}

export fn deque_unary_op(op: c_int, self_in: Obj) callconv(.c) Obj {
    const self = MpObjDeque.fromObj(self_in);
    switch (op) {
        MP_UNARY_OP_BOOL => return mirrors.newBool(self.i_get != self.i_put),
        MP_UNARY_OP_LEN => return mirrors.newSmallInt(@intCast(dequeLen(self))),
        else => return mirrors.OBJ_NULL,
    }
}

fn dequeAppendImpl(self_in: Obj, arg: Obj) PyError!Obj {
    const self = MpObjDeque.fromObj(self_in);

    var new_i_put = self.i_put + 1;
    if (new_i_put == self.alloc) new_i_put = 0;

    if ((self.flags & FLAG_CHECK_OVERFLOW) != 0 and new_i_put == self.i_get) {
        try raiseIndexErrorFull();
    }

    self.items[self.i_put] = arg;
    self.i_put = new_i_put;

    if (self.i_get == new_i_put) {
        self.i_get += 1;
        if (self.i_get == self.alloc) self.i_get = 0;
    }

    return mirrors.OBJ_NONE;
}

export fn deque_append(self_in: Obj, arg: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, dequeAppendImpl(self_in, arg));
}

fn dequeAppendleftImpl(self_in: Obj, arg: Obj) PyError!Obj {
    const self = MpObjDeque.fromObj(self_in);

    const new_i_get = if (self.i_get == 0) self.alloc - 1 else self.i_get - 1;

    if ((self.flags & FLAG_CHECK_OVERFLOW) != 0 and new_i_get == self.i_put) {
        try raiseIndexErrorFull();
    }

    self.i_get = new_i_get;
    self.items[self.i_get] = arg;

    // overwriting first element in deque
    if (self.i_put == new_i_get) {
        if (self.i_put == 0) {
            self.i_put = self.alloc - 1;
        } else {
            self.i_put -= 1;
        }
    }

    return mirrors.OBJ_NONE;
}

export fn deque_appendleft(self_in: Obj, arg: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, dequeAppendleftImpl(self_in, arg));
}

fn dequeExtendImpl(self_in: Obj, arg_in: Obj) PyError!Obj {
    var iter_buf: [4]Obj = undefined; // mp_obj_iter_buf_t fits in ~4 slots
    const iter = mp_getiter(arg_in, &iter_buf);
    while (true) {
        const item = mp_iternext(iter);
        if (item == mirrors.OBJ_STOP_ITERATION) break;
        _ = try dequeAppendImpl(self_in, item);
    }
    return mirrors.OBJ_NONE;
}

export fn deque_extend(self_in: Obj, arg_in: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, dequeExtendImpl(self_in, arg_in));
}

fn dequePopleftImpl(self_in: Obj) PyError!Obj {
    const self = MpObjDeque.fromObj(self_in);

    if (self.i_get == self.i_put) try raiseIndexErrorEmpty();

    const ret = self.items[self.i_get];
    self.items[self.i_get] = mirrors.OBJ_NULL;

    self.i_get += 1;
    if (self.i_get == self.alloc) self.i_get = 0;

    return ret;
}

export fn deque_popleft(self_in: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, dequePopleftImpl(self_in));
}

fn dequePopImpl(self_in: Obj) PyError!Obj {
    const self = MpObjDeque.fromObj(self_in);

    if (self.i_get == self.i_put) try raiseIndexErrorEmpty();

    if (self.i_put == 0) {
        self.i_put = self.alloc - 1;
    } else {
        self.i_put -= 1;
    }

    const ret = self.items[self.i_put];
    self.items[self.i_put] = mirrors.OBJ_NULL;

    return ret;
}

export fn deque_pop(self_in: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, dequePopImpl(self_in));
}

export fn deque_subscr(self_in: Obj, index: Obj, value: Obj) callconv(.c) Obj {
    if (value == mirrors.OBJ_NULL) {
        // delete not supported, fall back to mp_obj_subscr() error message
        return mirrors.OBJ_NULL;
    }
    const self = MpObjDeque.fromObj(self_in);

    const offset = mp_get_index(self.base.type.?, dequeLen(self), index, false);
    if (pyerr.pending_exc != 0) return mirrors.OBJ_NULL;
    var index_val = self.i_get + offset;
    if (index_val >= self.alloc) index_val -= self.alloc;

    if (value == mirrors.OBJ_SENTINEL) {
        return self.items[index_val];
    } else {
        self.items[index_val] = value;
        return mirrors.OBJ_NONE;
    }
}

// ── deque iterator (overlays on mp_obj_iter_buf_t) ───────────────────

const MpObjDequeIt = extern struct {
    base: mirrors.MpObjBase,
    iternext: *const fn (Obj) callconv(.c) Obj,
    deque: Obj,
    cur: usize,
};

export fn deque_it_iternext(self_in: Obj) callconv(.c) Obj {
    const self: *MpObjDequeIt = @ptrFromInt(self_in);
    const deque = MpObjDeque.fromObj(self.deque);
    if (self.cur != deque.i_put) {
        const o_out = deque.items[self.cur];
        self.cur += 1;
        if (self.cur == deque.alloc) self.cur = 0;
        return o_out;
    }
    return mirrors.OBJ_STOP_ITERATION;
}

export fn mp_obj_new_deque_it(deque: Obj, iter_buf: ?*anyopaque) callconv(.c) Obj {
    const deque_ = MpObjDeque.fromObj(deque);
    const o: *MpObjDequeIt = @ptrCast(@alignCast(iter_buf));
    o.base.type = &mp_type_polymorph_iter;
    o.iternext = &deque_it_iternext;
    o.deque = deque;
    o.cur = deque_.i_get;
    return @intFromPtr(o);
}

// ── ROM: method fn-objs + locals_dict + mp_type_deque ───────────────

pub export const deque_append_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&deque_append),
};
pub export const deque_appendleft_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&deque_appendleft),
};
pub export const deque_extend_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&deque_extend),
};
pub export const deque_pop_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_1 },
    .fun = @ptrCast(&deque_pop),
};
pub export const deque_popleft_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_1 },
    .fun = @ptrCast(&deque_popleft),
};

const RomEntry = extern struct {
    key: Obj,
    value: *const anyopaque,
};

const deque_locals_dict_table = [_]RomEntry{
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_append)), .value = &deque_append_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_appendleft)), .value = &deque_appendleft_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_extend)), .value = &deque_extend_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_pop)), .value = &deque_pop_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_popleft)), .value = &deque_popleft_obj },
};

pub export const deque_locals_dict: mirrors.MpObjDict = .{
    .base = .{ .type = &mp_type_dict },
    .map = .{
        .bits = .{ .all_keys_are_qstrs = 1, .is_fixed = 1, .is_ordered = 1, .used = deque_locals_dict_table.len },
        .alloc = deque_locals_dict_table.len,
        .table = @ptrCast(@constCast(&deque_locals_dict_table)),
    },
};

// Slot order: make_new=1, unary_op=2, subscr=3, iter=4, locals_dict=5
pub export const mp_type_deque: types.MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = 0x0000, // MP_TYPE_FLAG_ITER_IS_GETITER = 0
        .name = mp.MP_QSTR_deque,
        .slot_index_make_new = 1,
        .slot_index_print = 0,
        .slot_index_call = 0,
        .slot_index_unary_op = 2,
        .slot_index_binary_op = 0,
        .slot_index_attr = 0,
        .slot_index_subscr = 3,
        .slot_index_iter = 4,
        .slot_index_buffer = 0,
        .slot_index_protocol = 0,
        .slot_index_parent = 0,
        .slot_index_locals_dict = 5,
    },
    .slots = .{
        @ptrCast(&deque_make_new),
        @ptrCast(&deque_unary_op),
        @ptrCast(&deque_subscr),
        @ptrCast(&mp_obj_new_deque_it),
        @ptrCast(&deque_locals_dict),
        null, null, null, null, null, null,
    },
};

comptime {
    _ = &deque_make_new;
    _ = &deque_unary_op;
    _ = &deque_append;
    _ = &deque_appendleft;
    _ = &deque_extend;
    _ = &deque_pop;
    _ = &deque_popleft;
    _ = &deque_subscr;
    _ = &deque_it_iternext;
    _ = &mp_obj_new_deque_it;
    _ = &mp_type_deque;
    _ = &deque_locals_dict;
}
