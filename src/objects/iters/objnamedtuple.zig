//! petitpy — Zig port of py/objnamedtuple.c.
//!
//! Builds the `collections.namedtuple` factory: `mp_namedtuple_obj` is a
//! 2-arg builtin that allocates a per-call `mp_obj_namedtuple_type_t`
//! (eight slots) wired to the shared `mp_obj_tuple_*` operator slots.
//!
//! Config: nano + full both set `MICROPY_PY_COLLECTIONS=1`,
//! `MICROPY_PY_COLLECTIONS_NAMEDTUPLE__ASDICT=0`,
//! `MICROPY_CPYTHON_COMPAT=1`, `MICROPY_ERROR_REPORTING=NORMAL` → the
//! TERSE / DETAILED / ASDICT branches in the vendor C source are dead.

const mp = @cImport({
    @cInclude("py/qstr.h");
});
const mirrors = @import("../../mp_mirrors.zig");
const pyerr = @import("../../pyerr.zig");
const PyError = pyerr.PyError;

const Obj = mirrors.Obj;
const Qstr = usize;

extern const mp_type_type: anyopaque;
extern const mp_type_tuple: anyopaque;
extern const mp_type_TypeError: anyopaque;
extern const mp_type_AttributeError: anyopaque;
extern const mp_type_str: anyopaque;
extern const mp_type_fun_builtin_2: anyopaque;

extern fn m_malloc(num_bytes: usize) callconv(.c) ?*anyopaque;
extern fn mp_obj_str_get_qstr(o: Obj) callconv(.c) Qstr;
extern fn mp_obj_get_array(o: Obj, len: *usize, items: *[*c]Obj) callconv(.c) void;
extern fn mp_obj_str_split(n_args: usize, args: [*c]const Obj) callconv(.c) Obj;
extern fn mp_obj_attrtuple_print_helper(print: ?*const anyopaque, fields: [*]const Qstr, o: *mirrors.MpObjTuple) callconv(.c) void;
extern fn mp_obj_tuple_unary_op(op: c_int, self_in: Obj) callconv(.c) Obj;
extern fn mp_obj_tuple_binary_op(op: c_int, lhs: Obj, rhs: Obj) callconv(.c) Obj;
extern fn mp_obj_tuple_subscr(self_in: Obj, index: Obj, value: Obj) callconv(.c) Obj;
extern fn mp_obj_tuple_getiter(o_in: Obj, iter_buf: ?*anyopaque) callconv(.c) Obj;
extern fn mp_printf(print: ?*const anyopaque, fmt: [*:0]const u8, ...) callconv(.c) c_int;
extern fn mp_obj_new_exception_msg(t: *const anyopaque, msg: [*:0]const u8) callconv(.c) Obj;
extern fn mp_obj_new_exception_msg_varg(t: *const anyopaque, fmt: [*:0]const u8, ...) callconv(.c) Obj;

// Raise helpers (PyError convention). One per
// distinct exception+message. Sets pyerr.pending_exc + returns
// error.PyRaise. The C-ABI exports wrap the impl with pyerr.bridge
// which catches and returns the zero sentinel (callers poll
// pending_exc).
fn raiseAttrReadOnly() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_AttributeError, "can't set attribute");
    return error.PyRaise;
}

fn raiseWrongArgCount(num_fields: usize, got: usize) PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg_varg(
        &mp_type_TypeError,
        "function takes %d positional arguments but %d were given",
        num_fields,
        got,
    );
    return error.PyRaise;
}

fn raiseUnexpectedKwarg(kw: Qstr) PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg_varg(&mp_type_TypeError, "unexpected keyword argument '%q'", kw);
    return error.PyRaise;
}

fn raiseMultipleValues(kw: Qstr) PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg_varg(&mp_type_TypeError, "function got multiple values for argument '%q'", kw);
    return error.PyRaise;
}

// Vendor `mp_obj_namedtuple_type_t` (objnamedtuple.h:31-37): an
// `mp_obj_empty_type_t` (= MpObjType, 24B prefix) + slots[8] (fixed) +
// n_fields + qstr fields[] flex array.
const NamedtupleType = extern struct {
    header: mirrors.MpObjType,
    slots: [8]?*const anyopaque,
    n_fields: usize,
    // followed by qstr fields[n_fields]

    inline fn fieldsPtr(self: *NamedtupleType) [*]Qstr {
        return @ptrFromInt(@intFromPtr(self) + @sizeOf(NamedtupleType));
    }

    inline fn fieldsConst(self: *const NamedtupleType) [*]const Qstr {
        return @ptrFromInt(@intFromPtr(self) + @sizeOf(NamedtupleType));
    }
};

inline fn findField(t: *const NamedtupleType, name: Qstr) usize {
    const fs = t.fieldsConst();
    var i: usize = 0;
    while (i < t.n_fields) : (i += 1) {
        if (fs[i] == name) return i;
    }
    return std.math.maxInt(usize);
}

fn namedtuple_print(print: ?*const anyopaque, o_in: Obj, kind: c_int) callconv(.c) void {
    _ = kind;
    const o = mirrors.MpObjTuple.fromObj(o_in);
    const t: *const NamedtupleType = @ptrCast(@alignCast(@constCast(o.base.type.?)));
    _ = mp_printf(print, "%q", @as(usize, t.header.name));
    mp_obj_attrtuple_print_helper(print, t.fieldsConst(), o);
}

fn namedtupleAttrImpl(self_in: Obj, attr: u16, dest: [*c]Obj) PyError!void {
    if (dest[0] == mirrors.OBJ_NULL) {
        // load attribute (ASDICT branch dead: nano + full set it to 0)
        const self = mirrors.MpObjTuple.fromObj(self_in);
        const t: *const NamedtupleType = @ptrCast(@alignCast(@constCast(self.base.type.?)));
        const id = findField(t, @as(Qstr, attr));
        if (id == std.math.maxInt(usize)) return;
        dest[0] = self.itemsPtr()[id];
    } else {
        // store/delete attribute → not allowed.
        try raiseAttrReadOnly();
    }
}

fn namedtuple_attr(self_in: Obj, attr: u16, dest: [*c]Obj) callconv(.c) void {
    pyerr.bridge(void, namedtupleAttrImpl(self_in, attr, dest));
}

fn namedtupleMakeNewImpl(type_in: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const Obj) PyError!Obj {
    const t: *const NamedtupleType = @ptrCast(@alignCast(@constCast(type_in.?)));
    const num_fields = t.n_fields;
    if (n_args + n_kw != num_fields) {
        // MICROPY_ERROR_REPORTING = NORMAL (the default — no override in
        // port/mpconfigport.h) → take the NORMAL branch.
        try raiseWrongArgCount(num_fields, n_args + n_kw);
    }

    // Allocate the tuple — m_new_obj_var equivalent: header + items[num_fields].
    const tuple_bytes = @sizeOf(mirrors.MpObjTuple) + @sizeOf(Obj) * num_fields;
    const tuple: *mirrors.MpObjTuple = @ptrCast(@alignCast(m_malloc(tuple_bytes).?));
    tuple.base.type = type_in;
    tuple.len = num_fields;
    const items = tuple.itemsPtr();

    // Copy positional args.
    if (n_args > 0) @memcpy(items[0..n_args], args[0..n_args]);
    // Zero the remaining (kw) slots, then fill by name.
    var z: usize = n_args;
    while (z < num_fields) : (z += 1) items[z] = mirrors.OBJ_NULL;

    var i: usize = n_args;
    while (i < n_args + 2 * n_kw) : (i += 2) {
        const kw = mp_obj_str_get_qstr(args[i]);
        const id = findField(t, kw);
        if (id == std.math.maxInt(usize)) {
            try raiseUnexpectedKwarg(kw);
        }
        if (items[id] != mirrors.OBJ_NULL) {
            try raiseMultipleValues(kw);
        }
        items[id] = args[i + 1];
    }

    return @intFromPtr(tuple);
}

fn namedtuple_make_new(type_in: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, namedtupleMakeNewImpl(type_in, n_args, n_kw, args));
}

// External entry point — declared in py/objnamedtuple.h. Header file
// is still vendor-shipped; signature must match.
export fn mp_obj_namedtuple_find_field(t: *const NamedtupleType, name: Qstr) callconv(.c) usize {
    return findField(t, name);
}

export fn mp_obj_new_namedtuple_base(n_fields: usize, fields: [*c]Obj) callconv(.c) *NamedtupleType {
    const bytes = @sizeOf(NamedtupleType) + @sizeOf(Qstr) * n_fields;
    const o: *NamedtupleType = @ptrCast(@alignCast(m_malloc(bytes).?));
    // m_malloc is not zero-init in nano (alloc.zig:16 m_malloc). The flex
    // qstr[] is fully overwritten below; the header is initialised by
    // the caller (new_namedtuple_type). Only n_fields needs writing here.
    o.n_fields = n_fields;
    const fp = o.fieldsPtr();
    var i: usize = 0;
    while (i < n_fields) : (i += 1) {
        fp[i] = mp_obj_str_get_qstr(fields[i]);
    }
    return o;
}

fn newNamedtupleType(name: Qstr, n_fields: usize, fields: [*c]Obj) Obj {
    const o = mp_obj_new_namedtuple_base(n_fields, fields);
    // Initialise the type header (mirrors the vendor MP_OBJ_TYPE_SET_SLOT
    // calls: slot_index_X = N+1; slots[N] = ptr; positions match vendor).
    o.header = .{
        .base = .{ .type = &mp_type_type },
        .flags = mirrors.FLAG_EQ_CHECKS_OTHER_TYPE, // can match tuple
        .name = @intCast(name),
        .slot_index_make_new = 1,
        .slot_index_print = 2,
        .slot_index_call = 0,
        .slot_index_unary_op = 3,
        .slot_index_binary_op = 4,
        .slot_index_attr = 5,
        .slot_index_subscr = 6,
        .slot_index_iter = 7,
        .slot_index_buffer = 0,
        .slot_index_protocol = 0,
        .slot_index_parent = 8,
        .slot_index_locals_dict = 0,
    };
    o.slots = .{
        @ptrCast(&namedtuple_make_new),
        @ptrCast(&namedtuple_print),
        @ptrCast(&mp_obj_tuple_unary_op),
        @ptrCast(&mp_obj_tuple_binary_op),
        @ptrCast(&namedtuple_attr),
        @ptrCast(&mp_obj_tuple_subscr),
        @ptrCast(&mp_obj_tuple_getiter),
        &mp_type_tuple,
    };
    return @intFromPtr(o);
}

fn new_namedtuple_type_2(name_in: Obj, fields_in: Obj) callconv(.c) Obj {
    const name = mp_obj_str_get_qstr(name_in);
    var fi = fields_in;
    // MICROPY_CPYTHON_COMPAT = 1 in both nano + full. If a string is
    // passed, split it on whitespace first.
    if (mirrors.isQstr(fi) or mirrors.isExactType(fi, &mp_type_str)) {
        fi = mp_obj_str_split(1, @ptrCast(&fi));
    }
    var n_fields: usize = 0;
    var fields: [*c]Obj = undefined;
    mp_obj_get_array(fi, &n_fields, &fields);
    return newNamedtupleType(name, n_fields, fields);
}

// MP_DEFINE_CONST_FUN_OBJ_2(mp_namedtuple_obj, new_namedtuple_type).
pub export const mp_namedtuple_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&new_namedtuple_type_2),
};

const std = @import("std");

comptime {
    _ = &mp_obj_namedtuple_find_field;
    _ = &mp_obj_new_namedtuple_base;
    _ = &mp_namedtuple_obj;
    _ = &namedtuple_make_new;
    _ = &namedtuple_print;
    _ = &namedtuple_attr;
    _ = &new_namedtuple_type_2;
}
