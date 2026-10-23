//! petitpy — Zig port of py/modstruct.c (the `struct` builtin module).
//!
//! Faithful translation: get_fmt_type, get_fmt_num, calc_size_items,
//! struct_calcsize, struct_unpack_from, struct_pack, struct_pack_into.
//!
//! Config: MICROPY_PY_STRUCT=1 under both nano + full (line 73 in
//! port/mpconfigport.h). No inner config gates — the entire module body
//! is wrapped in a single `#if MICROPY_PY_STRUCT`.
//!
//! Heavy lifting (typecode-driven byte walking, alignment, float handling
//! for 'f'/'d'/'e') stays in vendor py/binary.c via the
//! mp_binary_get_size / mp_binary_get_val / mp_binary_set_val externs.
//!
//! ADR-002 F2 — gated on build_options.feature_struct. When off, the
//! `pub export const`s for the module + the per-fn objs are dropped, the
//! helper fns/data become unreachable and the linker DCEs them out.
//!
//! The MP_REGISTER_EXTENSIBLE_MODULE marker stays in src/modules/modstruct.c
//! (a 4-line tombstone) — makemoduledefs.py scans only .c sources.

const build_options = @import("build_options");
const mp = @cImport({
    @cInclude("py/qstr.h");
});
const mirrors = @import("../mp_mirrors.zig");
const pyerr = @import("../pyerr.zig");
const PyError = pyerr.PyError;

const Obj = mirrors.Obj;
const Qstr = usize;

const enabled = build_options.feature_struct;

extern const mp_type_module: anyopaque;
extern const mp_type_dict: anyopaque;
extern const mp_type_fun_builtin_1: anyopaque;
extern const mp_type_fun_builtin_var: anyopaque;
extern const mp_type_ValueError: anyopaque;

// Vendor externs.
// NX-3 N4a: mp_obj_str_get_str now returns null + sets pyerr.pending_exc on
// bad input (non-str-or-bytes). Callers MUST check the returned ptr for null.
extern fn mp_obj_str_get_str(o: Obj) callconv(.c) ?[*]const u8;
extern fn mp_obj_get_int(o: Obj) callconv(.c) isize;
extern fn mp_obj_new_tuple(n: usize, items: [*c]const Obj) callconv(.c) Obj;
extern fn mp_obj_new_bytes(data: [*c]const u8, len: usize) callconv(.c) Obj;
extern fn mp_obj_new_bytes_from_vstr(vstr: *Vstr) callconv(.c) Obj;
extern fn mp_obj_new_exception_msg(t: *const anyopaque, msg: [*:0]const u8) callconv(.c) Obj;
extern fn mp_get_buffer(o: Obj, bufinfo: *MpBufferInfo, flags: c_uint) callconv(.c) bool;
extern fn mp_binary_get_size(struct_type: u8, val_type: u8, palign: *usize) callconv(.c) usize;
extern fn mp_binary_get_val(struct_type: u8, val_type: u8, p_base: [*c]u8, ptr: *[*c]u8) callconv(.c) Obj;
extern fn mp_binary_set_val(struct_type: u8, val_type: u8, val_in: Obj, p_base: [*c]u8, ptr: *[*c]u8) callconv(.c) void;
extern fn mp_parse_num_integer(str: [*c]const u8, len: usize, base: c_int, lex: ?*anyopaque) callconv(.c) Obj;
extern fn unichar_isdigit(c: c_uint) callconv(.c) bool;
extern fn vstr_init_len(vstr: *Vstr, len: usize) callconv(.c) void;

// mp_buffer_info_t (obj.h:616).
const MpBufferInfo = extern struct {
    buf: ?*anyopaque,
    len: usize,
    typecode: c_int,
};

// vstr_t (misc.h:202).
const Vstr = extern struct {
    alloc: usize,
    len: usize,
    buf: [*c]u8,
    fixed_buf: bool,
};

const MP_BUFFER_READ: c_uint = 1;
const MP_BUFFER_WRITE: c_uint = 2;
const MP_BUFFER_RAISE_IF_UNSUPPORTED: c_uint = 4;
const MP_OBJ_FUN_ARGS_MAX: u32 = 0xffff;

// Raise helper (PyError convention). Sets
// pyerr.pending_exc + returns error.PyRaise — C-ABI exports wrap the
// impl with pyerr.bridge which catches and returns the zero sentinel
// (callers poll pending_exc).
fn raiseValueErrorBufferTooSmall() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_ValueError, "buffer too small");
    return error.PyRaise;
}

inline fn getBufferRaise(o: Obj, bufinfo: *MpBufferInfo, flags: c_uint) void {
    _ = mp_get_buffer(o, bufinfo, flags | MP_BUFFER_RAISE_IF_UNSUPPORTED);
}

fn getFmtType(fmt: *[*c]const u8) u8 {
    var t: u8 = fmt.*[0];
    switch (t) {
        '!' => t = '>',
        '@', '=', '<', '>' => {},
        else => return '@',
    }
    fmt.* += 1;
    return t;
}

fn getFmtNum(p: *[*c]const u8) usize {
    const num_start: [*c]const u8 = p.*;
    var num: [*c]const u8 = num_start + 1;
    var len: usize = 1;
    while (unichar_isdigit(num[0])) {
        num += 1;
        len += 1;
    }
    const parsed = mp_parse_num_integer(num_start, len, 10, null);
    const val: usize = @bitCast(mirrors.smallIntValue(parsed));
    p.* = num;
    return val;
}

fn calcSizeItems(fmt_in: [*c]const u8, total_sz: *usize) usize {
    var fmt: [*c]const u8 = fmt_in;
    const fmt_type = getFmtType(&fmt);
    var total_cnt: usize = 0;
    var size: usize = 0;
    while (fmt[0] != 0) : (fmt += 1) {
        var cnt: usize = 1;
        if (unichar_isdigit(fmt[0])) {
            cnt = getFmtNum(&fmt);
        }
        if (fmt[0] == 'x') {
            size += cnt;
        } else if (fmt[0] == 's') {
            total_cnt += 1;
            size += cnt;
        } else {
            total_cnt += cnt;
            var alignv: usize = undefined;
            const sz = mp_binary_get_size(fmt_type, fmt[0], &alignv);
            while (cnt > 0) : (cnt -= 1) {
                size = (size + alignv - 1) & ~(alignv - 1);
                size += sz;
            }
        }
    }
    total_sz.* = size;
    return total_cnt;
}

fn structCalcsizeImpl(fmt_in: Obj) PyError!Obj {
    const fmt: [*c]const u8 = mp_obj_str_get_str(fmt_in) orelse return error.PyRaise;
    var size: usize = undefined;
    _ = calcSizeItems(fmt, &size);
    return mirrors.newSmallInt(@bitCast(size));
}

fn structCalcsize(fmt_in: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, structCalcsizeImpl(fmt_in));
}

fn structUnpackFromImpl(n_args: usize, args: [*c]const Obj) PyError!Obj {
    var fmt: [*c]const u8 = mp_obj_str_get_str(args[0]) orelse return error.PyRaise;
    var total_sz: usize = undefined;
    const num_items = calcSizeItems(fmt, &total_sz);
    const fmt_type = getFmtType(&fmt);
    const res_obj = mp_obj_new_tuple(num_items, null);
    const res: *MpObjTuple = @ptrFromInt(res_obj);
    var bufinfo: MpBufferInfo = undefined;
    getBufferRaise(args[1], &bufinfo, MP_BUFFER_READ);
    var p: [*c]u8 = @ptrCast(bufinfo.buf);
    const end_p: [*c]u8 = p + bufinfo.len;
    var offset: isize = 0;

    if (n_args > 2) {
        offset = mp_obj_get_int(args[2]);
        if (offset < 0) {
            offset = @as(isize, @bitCast(bufinfo.len)) + offset;
            if (offset < 0) {
                try raiseValueErrorBufferTooSmall();
            }
        }
        p += @as(usize, @bitCast(offset));
    }
    const p_base = p;

    if (@intFromPtr(p) + total_sz > @intFromPtr(end_p)) {
        try raiseValueErrorBufferTooSmall();
    }

    var i: usize = 0;
    while (i < num_items) {
        var cnt: usize = 1;
        if (unichar_isdigit(fmt[0])) {
            cnt = getFmtNum(&fmt);
        }
        if (fmt[0] == 'x') {
            p += cnt;
        } else if (fmt[0] == 's') {
            const item = mp_obj_new_bytes(p, cnt);
            p += cnt;
            res.itemsPtr()[i] = item;
            i += 1;
        } else {
            while (cnt > 0) : (cnt -= 1) {
                const item = mp_binary_get_val(fmt_type, fmt[0], p_base, &p);
                res.itemsPtr()[i] = item;
                i += 1;
            }
        }
        fmt += 1;
    }
    return res_obj;
}

fn structUnpackFrom(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, structUnpackFromImpl(n_args, args));
}

// mp_obj_tuple_t (objtuple.h:31) — flex-array items[] at end.
const MpObjTuple = extern struct {
    base: mirrors.MpObjBase,
    len: usize,

    inline fn itemsPtr(self: *MpObjTuple) [*]Obj {
        return @ptrFromInt(@intFromPtr(self) + @sizeOf(MpObjTuple));
    }
};

// Assumes there's enough room in p for all values.
fn structPackIntoInternal(fmt_in: Obj, p_init: [*c]u8, n_args: usize, args: [*c]const Obj) PyError!void {
    var fmt: [*c]const u8 = mp_obj_str_get_str(fmt_in) orelse return error.PyRaise;
    const fmt_type = getFmtType(&fmt);

    var p: [*c]u8 = p_init;
    const p_base = p;
    var i: usize = 0;
    while (i < n_args) {
        var cnt: usize = 1;
        if (fmt[0] == 0) {
            // more args than format slots — CPython raises struct.error; nano breaks.
            break;
        }
        if (unichar_isdigit(fmt[0])) {
            cnt = getFmtNum(&fmt);
        }

        if (fmt[0] == 'x') {
            @memset(p[0..cnt], 0);
            p += cnt;
        } else if (fmt[0] == 's') {
            var bufinfo: MpBufferInfo = undefined;
            getBufferRaise(args[i], &bufinfo, MP_BUFFER_READ);
            i += 1;
            var to_copy = cnt;
            if (bufinfo.len < to_copy) to_copy = bufinfo.len;
            const src: [*c]const u8 = @ptrCast(bufinfo.buf);
            @memcpy(p[0..to_copy], src[0..to_copy]);
            @memset((p + to_copy)[0 .. cnt - to_copy], 0);
            p += cnt;
        } else {
            while (cnt > 0 and i < n_args) : (cnt -= 1) {
                mp_binary_set_val(fmt_type, fmt[0], args[i], p_base, &p);
                i += 1;
            }
        }
        fmt += 1;
    }
}

fn structPackImpl(n_args: usize, args: [*c]const Obj) PyError!Obj {
    const size_obj = try structCalcsizeImpl(args[0]);
    const size: usize = @bitCast(mirrors.smallIntValue(size_obj));
    var vstr: Vstr = undefined;
    vstr_init_len(&vstr, size);
    const p: [*c]u8 = vstr.buf;
    @memset(p[0..size], 0);
    try structPackIntoInternal(args[0], p, n_args - 1, args + 1);
    return mp_obj_new_bytes_from_vstr(&vstr);
}

fn structPack(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, structPackImpl(n_args, args));
}

fn structPackIntoImpl(n_args: usize, args: [*c]const Obj) PyError!Obj {
    var bufinfo: MpBufferInfo = undefined;
    getBufferRaise(args[1], &bufinfo, MP_BUFFER_WRITE);
    var offset = mp_obj_get_int(args[2]);
    if (offset < 0) {
        offset = @as(isize, @bitCast(bufinfo.len)) + offset;
        if (offset < 0) {
            try raiseValueErrorBufferTooSmall();
        }
    }
    var p: [*c]u8 = @ptrCast(bufinfo.buf);
    const end_p: [*c]u8 = p + bufinfo.len;
    p += @as(usize, @bitCast(offset));

    const sz_obj = try structCalcsizeImpl(args[0]);
    const sz: usize = @bitCast(mirrors.smallIntValue(sz_obj));
    if (@intFromPtr(p) + sz > @intFromPtr(end_p)) {
        try raiseValueErrorBufferTooSmall();
    }

    try structPackIntoInternal(args[0], p, n_args - 3, args + 3);
    return mirrors.OBJ_NONE;
}

fn structPackInto(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, structPackIntoImpl(n_args, args));
}

const RomEntry = extern struct {
    key: Obj,
    value: *const anyopaque,
};

const Exports = if (enabled) struct {
    pub export const struct_calcsize_obj: mirrors.MpObjFunBuiltinFixed = .{
        .base = .{ .type = &mp_type_fun_builtin_1 },
        .fun = @ptrCast(&structCalcsize),
    };
    pub export const struct_unpack_from_obj: mirrors.MpObjFunBuiltinVar = .{
        .base = .{ .type = &mp_type_fun_builtin_var },
        .sig = mirrors.makeFunSig(2, 3, false),
        .fun = @ptrCast(&structUnpackFrom),
    };
    pub export const struct_pack_obj: mirrors.MpObjFunBuiltinVar = .{
        .base = .{ .type = &mp_type_fun_builtin_var },
        .sig = mirrors.makeFunSig(1, MP_OBJ_FUN_ARGS_MAX, false),
        .fun = @ptrCast(&structPack),
    };
    pub export const struct_pack_into_obj: mirrors.MpObjFunBuiltinVar = .{
        .base = .{ .type = &mp_type_fun_builtin_var },
        .sig = mirrors.makeFunSig(3, MP_OBJ_FUN_ARGS_MAX, false),
        .fun = @ptrCast(&structPackInto),
    };

    const mp_module_struct_globals_table = [_]RomEntry{
        .{
            .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR___name__)),
            .value = @ptrFromInt(mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_struct))),
        },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_calcsize)), .value = &struct_calcsize_obj },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_pack)), .value = &struct_pack_obj },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_pack_into)), .value = &struct_pack_into_obj },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_unpack)), .value = &struct_unpack_from_obj },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_unpack_from)), .value = &struct_unpack_from_obj },
    };

    pub export const mp_module_struct_globals: mirrors.MpObjDict = .{
        .base = .{ .type = &mp_type_dict },
        .map = .{
            .bits = .{
                .all_keys_are_qstrs = 1,
                .is_fixed = 1,
                .is_ordered = 1,
                .used = mp_module_struct_globals_table.len,
            },
            .alloc = mp_module_struct_globals_table.len,
            .table = @ptrCast(@constCast(&mp_module_struct_globals_table)),
        },
    };

    pub export const mp_module_struct: mirrors.MpObjModule = .{
        .base = .{ .type = &mp_type_module },
        .globals = @ptrCast(@constCast(&mp_module_struct_globals)),
    };
} else struct {};

comptime {
    if (enabled) {
        _ = &Exports.mp_module_struct;
        _ = &Exports.mp_module_struct_globals;
        _ = &Exports.struct_calcsize_obj;
        _ = &Exports.struct_unpack_from_obj;
        _ = &Exports.struct_pack_obj;
        _ = &Exports.struct_pack_into_obj;
    }
}
