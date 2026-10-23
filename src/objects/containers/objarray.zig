//! petitpy — full Zig port of py/objarray.c.
//!
//! Three types in one file (all enabled under nano):
//!   array.array (MICROPY_PY_ARRAY=1)
//!   bytearray   (MICROPY_PY_BUILTINS_BYTEARRAY=1)
//!   memoryview  (MICROPY_PY_BUILTINS_MEMORYVIEW=1)
//!
//! Nano config: BYTES_HEX=1, MEMORYVIEW_ITEMSIZE=0 (full has it OFF too),
//! ARRAY_SLICE_ASSIGN=0 (full has it ON). SLICE=1 always under nano.
//!
//! The mp_obj_array_t struct packs `typecode : 8` and `free :
//! (8 * sizeof(size_t) - 8)` into one size_t. We mirror that bitfield
//! pair as a `packed struct(usize)` — Zig produces byte-identical layout
//! to the C bitfield struct on the same target.
//!
//! Locals dicts (mp_obj_array_locals_dict, mp_obj_bytearray_locals_dict,
//! mp_obj_memoryview_locals_dict) live in objstr_shim.c — they share a
//! single table with str/bytes via offset slicing.

const std = @import("std");
const mp = @cImport({
    @cInclude("py/obj.h");
    @cInclude("py/runtime.h");
    @cInclude("py/binary.h");
    @cInclude("py/qstr.h");
    @cInclude("py/objstr.h");
});
const mirrors = @import("../../mp_mirrors.zig");
const argcheck = @import("../../runtime/argcheck.zig");
const objstr = @import("../strings/objstr.zig");
const types = @import("../../mp_type_roms.zig");
const pyerr = @import("../../pyerr.zig");
const PyError = pyerr.PyError;
const build_options = @import("build_options");

const Obj = mirrors.Obj;

const BYTEARRAY_TYPECODE: u8 = 1;
const MP_OBJ_ARRAY_TYPECODE_FLAG_RW: u8 = 0x80;
const TYPECODE_MASK: u8 = 0x7f;
const memview_offset_max: usize = (@as(usize, 1) << (8 * @sizeOf(usize) - 8)) - 1;

// ── mirror of mp_obj_array_t ──────────────────────────────────────
// C: typecode:8, free:(8*sizeof(size_t)-8) → packed into one size_t.
const MpObjArray = extern struct {
    base: mirrors.MpObjBase,
    bits: packed struct(usize) {
        typecode: u8,
        free: std.meta.Int(.unsigned, @bitSizeOf(usize) - 8),
    },
    len: usize,
    items: ?*anyopaque,

    inline fn fromObj(o: Obj) *MpObjArray {
        return @ptrFromInt(o);
    }
};

inline fn isMemoryview(self: *const MpObjArray) bool {
    return self.base.type == @as(?*const anyopaque, @ptrCast(&mp_type_memoryview));
}

// ── extern types/symbols ──────────────────────────────────────────
extern const mp_type_type: anyopaque;
extern const mp_type_slice: anyopaque;
extern const mp_type_bytes: anyopaque;
extern const mp_type_polymorph_iter: anyopaque;
extern const mp_type_OverflowError: anyopaque;
extern const mp_type_TypeError: anyopaque;
extern const mp_type_NotImplementedError: anyopaque;
extern const mp_type_ValueError: anyopaque;
extern const mp_type_fun_builtin_2: anyopaque;

// locals dicts come from objstr_shim.c (shared with str/bytes).
extern const mp_obj_array_locals_dict: mirrors.MpObjDict;
extern const mp_obj_bytearray_locals_dict: mirrors.MpObjDict;
extern const mp_obj_memoryview_locals_dict: mirrors.MpObjDict;

// vendor helpers (still C):
extern fn mp_binary_get_size(struct_type: u8, val_type: u8, palign: ?*usize) callconv(.c) usize;
extern fn mp_binary_get_val_array(typecode: u8, p: ?*anyopaque, index: usize) callconv(.c) Obj;
extern fn mp_binary_set_val_array(typecode: u8, p: ?*anyopaque, index: usize, val_in: Obj) callconv(.c) void;
extern fn mp_seq_cmp_bytes(op: usize, data1: [*c]const u8, len1: usize, data2: [*c]const u8, len2: usize) callconv(.c) bool;
extern fn find_subbytes(haystack: [*c]const u8, hlen: usize, needle: [*c]const u8, nlen: usize, direction: c_int) callconv(.c) [*c]const u8;
extern fn mp_get_buffer(o: Obj, bufinfo: *mp.mp_buffer_info_t, flags: c_uint) callconv(.c) bool;

// static-inline / macro helpers — re-implement in Zig.
extern const mp_type_int: anyopaque;
extern const mp_type_str: anyopaque;
extern const mp_type_float: anyopaque;

inline fn mp_get_buffer_raise(o: Obj, bufinfo: *mp.mp_buffer_info_t, flags: c_uint) void {
    _ = mp_get_buffer(o, bufinfo, flags | mp.MP_BUFFER_RAISE_IF_UNSUPPORTED);
}
inline fn mp_obj_is_int(o: Obj) bool {
    return mirrors.isSmallInt(o) or mirrors.isExactType(o, &mp_type_int);
}
inline fn mp_obj_is_float(o: Obj) bool {
    return mirrors.isExactType(o, &mp_type_float);
}
inline fn mp_obj_is_str(o: Obj) bool {
    return mirrors.isQstr(o) or mirrors.isExactType(o, &mp_type_str);
}
// NX-3 N4a: mp_obj_str_get_str returns null + sets pending_exc on bad input.
extern fn mp_obj_str_get_str(o: Obj) callconv(.c) ?[*:0]const u8;
extern fn mp_obj_get_int(o: Obj) callconv(.c) isize;
extern fn mp_obj_len_maybe(o: Obj) callconv(.c) Obj;
extern fn mp_obj_get_type(o: Obj) callconv(.c) *const anyopaque;
extern fn mp_get_index(t: *const anyopaque, len: usize, idx: Obj, is_slice: bool) callconv(.c) usize;
extern fn mp_getiter(o: Obj, iter_buf: ?*anyopaque) callconv(.c) Obj;
extern fn mp_iternext(o: Obj) callconv(.c) Obj;

inline fn mp_obj_new_bool(b: bool) Obj {
    return mirrors.newBool(b);
}
extern fn mp_obj_print_helper(print: ?*const anyopaque, o: Obj, kind: c_int) callconv(.c) void;
extern fn mp_print_str(print: ?*const anyopaque, s: [*:0]const u8) callconv(.c) c_int;
extern fn mp_printf(print: ?*const anyopaque, fmt: [*:0]const u8, ...) callconv(.c) c_int;
extern fn mp_str_print_quoted(print: ?*const anyopaque, str_data: [*c]const u8, str_len: usize, is_bytes: bool) callconv(.c) void;

extern fn mp_arg_check_num_sig(n_args: usize, n_kw: usize, sig: u32) callconv(.c) void;
extern fn mp_obj_new_exception_msg(t: *const anyopaque, msg: [*:0]const u8) callconv(.c) Obj;
extern fn mp_obj_new_exception(t: *const anyopaque) callconv(.c) Obj;

// Raise helpers (PyError convention). Each
// sets pyerr.pending_exc + returns error.PyRaise. C-ABI exports wrap
// their PyError!T impl with pyerr.bridge.
fn raiseWrongNumArgs() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_TypeError, "wrong number of arguments");
    return error.PyRaise;
}
fn raiseNotImplemented() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception(&mp_type_NotImplementedError);
    return error.PyRaise;
}
fn raiseSliceStepUnsupported() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_NotImplementedError, "only slices with step=1 (aka None) are supported");
    return error.PyRaise;
}
fn raiseMemoryviewOffsetOverflow() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_OverflowError, "memoryview offset too large");
    return error.PyRaise;
}
fn raiseSliceCompatError() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_ValueError, "lhs and rhs should be compatible");
    return error.PyRaise;
}
fn raiseArrayBytesRequired() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_NotImplementedError, "array/bytes required on right side");
    return error.PyRaise;
}

extern fn m_malloc(num_bytes: usize) callconv(.c) ?*anyopaque;
extern fn m_realloc(ptr: ?*anyopaque, new_num_bytes: usize) callconv(.c) ?*anyopaque;
extern fn memmove(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) callconv(.c) ?*anyopaque;
extern fn mp_seq_get_fast_slice_indexes(len: usize, slice: Obj, indexes: *MpBoundSlice) callconv(.c) bool;

const MpBoundSlice = extern struct { start: isize, stop: isize, step: isize };

// ── helpers ────────────────────────────────────────────────────────

inline fn arrayNew(typecode: u8, n: usize) *MpObjArray {
    const typecode_size = mp_binary_get_size('@', typecode, null);
    const o: *MpObjArray = @ptrCast(@alignCast(m_malloc(@sizeOf(MpObjArray)).?));
    o.base.type = if (typecode == BYTEARRAY_TYPECODE) @as(?*const anyopaque, @ptrCast(&mp_type_bytearray)) else @as(?*const anyopaque, @ptrCast(&mp_type_array));
    o.bits = .{ .typecode = typecode, .free = 0 };
    o.len = n;
    o.items = if (typecode_size * n == 0) null else m_malloc(typecode_size * n);
    return o;
}

fn arrayExtendImpl(array: *MpObjArray, arg: Obj, typecode: u8, len: usize) void {
    const iterable = mp_getiter(arg, null);
    var i: usize = 0;
    while (true) {
        const item = mp_iternext(iterable);
        if (item == mirrors.OBJ_STOP_ITERATION) break;
        if (len == 0) {
            _ = arrayAppend(@intFromPtr(array), item);
        } else {
            mp_binary_set_val_array(typecode, array.items, i, item);
            i += 1;
        }
    }
}

fn arrayConstruct(typecode: u8, initializer: Obj) Obj {
    // bytearrays can be raw-initialised from anything with the buffer protocol;
    // other arrays can be raw-initialised only from bytes/bytearray.
    var bufinfo: mp.mp_buffer_info_t = undefined;
    const init_type_is_bytes_like = blk: {
        if (typecode == BYTEARRAY_TYPECODE) break :blk true;
        if (mirrors.isExactType(initializer, &mp_type_bytes)) break :blk true;
        if (mirrors.isExactType(initializer, @ptrCast(&mp_type_bytearray))) break :blk true;
        break :blk false;
    };
    if (init_type_is_bytes_like and mp_get_buffer(initializer, &bufinfo, mp.MP_BUFFER_READ)) {
        const sz = mp_binary_get_size('@', typecode, null);
        const len = bufinfo.len / sz;
        const o = arrayNew(typecode, len);
        if (len * sz > 0) {
            @memcpy(@as([*]u8, @ptrCast(o.items.?))[0 .. len * sz], @as([*]const u8, @ptrCast(bufinfo.buf.?))[0 .. len * sz]);
        }
        return @intFromPtr(o);
    }

    var len: usize = 0;
    const len_in = mp_obj_len_maybe(initializer);
    if (len_in != mirrors.OBJ_NULL) {
        len = @intCast(mirrors.smallIntValue(len_in));
    }
    const array = arrayNew(typecode, len);
    arrayExtendImpl(array, initializer, typecode, len);
    return @intFromPtr(array);
}

// ── public API ─────────────────────────────────────────────────────

pub export fn mp_obj_new_memoryview(typecode: u8, nitems: usize, items: ?*anyopaque) callconv(.c) Obj {
    const self: *MpObjArray = @ptrCast(@alignCast(m_malloc(@sizeOf(MpObjArray)).?));
    self.base.type = @ptrCast(&mp_type_memoryview);
    self.bits = .{ .typecode = typecode, .free = 0 };
    self.len = nitems;
    self.items = items;
    return @intFromPtr(self);
}

pub export fn mp_obj_new_bytearray(n: usize, items: ?*const anyopaque) callconv(.c) Obj {
    const o = arrayNew(BYTEARRAY_TYPECODE, n);
    if (n > 0) {
        @memcpy(@as([*]u8, @ptrCast(o.items.?))[0..n], @as([*]const u8, @ptrCast(items.?))[0..n]);
    }
    return @intFromPtr(o);
}

pub export fn mp_obj_new_bytearray_by_ref(n: usize, items: ?*anyopaque) callconv(.c) Obj {
    const o: *MpObjArray = @ptrCast(@alignCast(m_malloc(@sizeOf(MpObjArray)).?));
    o.base.type = @ptrCast(&mp_type_bytearray);
    o.bits = .{ .typecode = BYTEARRAY_TYPECODE, .free = 0 };
    o.len = n;
    o.items = items;
    return @intFromPtr(o);
}

// ── print ──────────────────────────────────────────────────────────

export fn npy_array_print(print: ?*const anyopaque, o_in: Obj, kind: c_int) callconv(.c) void {
    _ = kind;
    const o = MpObjArray.fromObj(o_in);
    const tc: u8 = @intCast(o.bits.typecode);
    if (tc == BYTEARRAY_TYPECODE) {
        _ = mp_print_str(print, "bytearray(b");
        mp_str_print_quoted(print, @ptrCast(o.items), o.len, true);
    } else {
        _ = mp_printf(print, "array('%c'", @as(c_int, tc));
        if (o.len > 0) {
            _ = mp_print_str(print, ", [");
            var i: usize = 0;
            while (i < o.len) : (i += 1) {
                if (i > 0) _ = mp_print_str(print, ", ");
                mp_obj_print_helper(print, mp_binary_get_val_array(tc, o.items, i), mp.PRINT_REPR);
            }
            _ = mp_print_str(print, "]");
        }
    }
    _ = mp_print_str(print, ")");
}

// ── make_new ───────────────────────────────────────────────────────

fn arrayMakeNewImpl(n_args: usize, n_kw: usize, args: [*c]const Obj) PyError!Obj {
    // min=1, max=2, kw=false
    mp_arg_check_num_sig(n_args, n_kw, mirrors.makeFunSig(1, 2, false));
    const typecode_str = mp_obj_str_get_str(args[0]) orelse return error.PyRaise;
    if (n_args == 1) {
        return @intFromPtr(arrayNew(typecode_str[0], 0));
    }
    return arrayConstruct(typecode_str[0], args[1]);
}

export fn npy_array_make_new(type_in: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    _ = type_in;
    return pyerr.bridge(Obj, arrayMakeNewImpl(n_args, n_kw, args));
}

fn bytearrayMakeNewImpl(n_args: usize, n_kw: usize, args: [*c]const Obj) PyError!Obj {
    // min=0, max=3, kw=false
    mp_arg_check_num_sig(n_args, n_kw, mirrors.makeFunSig(0, 3, false));
    if (n_args == 0) {
        return @intFromPtr(arrayNew(BYTEARRAY_TYPECODE, 0));
    }
    if (mp_obj_is_int(args[0])) {
        const len: usize = @intCast(mp_obj_get_int(args[0]));
        const o = arrayNew(BYTEARRAY_TYPECODE, len);
        if (len > 0) {
            @memset(@as([*]u8, @ptrCast(o.items.?))[0..len], 0);
        }
        return @intFromPtr(o);
    }
    if (mp_obj_is_str(args[0]) and n_args == 1) {
        // TERSE error reporting (nano default).
        try raiseWrongNumArgs();
    }
    return arrayConstruct(BYTEARRAY_TYPECODE, args[0]);
}

export fn npy_bytearray_make_new(type_in: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    _ = type_in;
    if (build_options.is_full and n_kw != 0) {
        var a = argcheck.kwMakeNew(&.{ mp.MP_QSTR_source, mp.MP_QSTR_encoding, mp.MP_QSTR_errors }, objstr.codec_ctor_defaults, n_args, n_kw, args) catch return mirrors.OBJ_NULL;
        return pyerr.bridge(Obj, bytearrayMakeNewImpl(a.n, 0, &a.args));
    }
    return pyerr.bridge(Obj, bytearrayMakeNewImpl(n_args, n_kw, args));
}

export fn npy_memoryview_make_new(type_in: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    _ = type_in;
    mp_arg_check_num_sig(n_args, n_kw, mirrors.makeFunSig(1, 1, false));
    var bufinfo: mp.mp_buffer_info_t = undefined;
    mp_get_buffer_raise(args[0], &bufinfo, mp.MP_BUFFER_READ);
    const sz = mp_binary_get_size('@', @intCast(bufinfo.typecode), null);
    const obj = mp_obj_new_memoryview(@intCast(bufinfo.typecode), bufinfo.len / sz, bufinfo.buf);
    const self = MpObjArray.fromObj(obj);

    if (mp_obj_get_type(args[0]) == @as(*const anyopaque, @ptrCast(&mp_type_memoryview))) {
        const other = MpObjArray.fromObj(args[0]);
        self.bits.free = other.bits.free;
        self.items = other.items;
    }
    if (mp_get_buffer(args[0], &bufinfo, mp.MP_BUFFER_RW)) {
        self.bits.typecode |= MP_OBJ_ARRAY_TYPECODE_FLAG_RW;
    }
    return obj;
}

// ── memoryview attr (only when ITEMSIZE=1; nano has it 0, full also 0)
// Skipped — nano never enables MEMORYVIEW_ITEMSIZE.

// ── unary_op ───────────────────────────────────────────────────────

export fn npy_array_unary_op(op: c_int, o_in: Obj) callconv(.c) Obj {
    const o = MpObjArray.fromObj(o_in);
    if (op == mp.MP_UNARY_OP_BOOL) return mp_obj_new_bool(o.len != 0);
    if (op == mp.MP_UNARY_OP_LEN) return mirrors.newSmallInt(@bitCast(o.len));
    return mirrors.OBJ_NULL;
}

inline fn typecodeForComparison(typecode_in: u8, is_unsigned: *bool) u8 {
    var tc = typecode_in;
    if (tc == BYTEARRAY_TYPECODE) tc = 'B';
    if (tc <= 'Z') {
        tc += 32;
        is_unsigned.* = true;
    }
    return tc;
}

fn arrayBinaryOpImpl(op: c_int, lhs_in: Obj, rhs_in: Obj) PyError!Obj {
    const lhs = MpObjArray.fromObj(lhs_in);
    switch (op) {
        mp.MP_BINARY_OP_ADD => {
            if (isMemoryview(lhs)) return mirrors.OBJ_NULL;
            var lhs_bufinfo: mp.mp_buffer_info_t = undefined;
            var rhs_bufinfo: mp.mp_buffer_info_t = undefined;
            _ = arrayGetBuffer(lhs_in, &lhs_bufinfo, mp.MP_BUFFER_READ);
            mp_get_buffer_raise(rhs_in, &rhs_bufinfo, mp.MP_BUFFER_READ);
            // Polled sentinel: mp_get_buffer_raise may have set pending_exc
            // (e.g., rhs is an int with no buffer protocol). Propagate the
            // exception before continuing — otherwise we'd memcpy garbage
            // and crash on a NULL items pointer.
            if (pyerr.pending_exc != 0) return PyError.PyRaise;

            const sz = mp_binary_get_size('@', @intCast(lhs_bufinfo.typecode), null);
            const rhs_len = rhs_bufinfo.len / sz;
            const res = arrayNew(@intCast(lhs_bufinfo.typecode), lhs.len + rhs_len);
            // mp_seq_cat: memcpy(dest, lhs_buf, lhs_buflen) then memcpy(dest+lhs_buflen, rhs_buf, rhs_len*sz)
            const dst = @as([*]u8, @ptrCast(res.items.?));
            if (lhs_bufinfo.len > 0) {
                @memcpy(dst[0..lhs_bufinfo.len], @as([*]const u8, @ptrCast(lhs_bufinfo.buf.?))[0..lhs_bufinfo.len]);
            }
            if (rhs_len * sz > 0) {
                @memcpy((dst + lhs_bufinfo.len)[0 .. rhs_len * sz], @as([*]const u8, @ptrCast(rhs_bufinfo.buf.?))[0 .. rhs_len * sz]);
            }
            return @intFromPtr(res);
        },
        mp.MP_BINARY_OP_INPLACE_ADD => {
            if (isMemoryview(lhs)) return mirrors.OBJ_NULL;
            _ = arrayExtend(lhs_in, rhs_in);
            return lhs_in;
        },
        mp.MP_BINARY_OP_CONTAINS => {
            // bytearray-specific substring search.
            var lhs_bufinfo: mp.mp_buffer_info_t = undefined;
            var rhs_bufinfo: mp.mp_buffer_info_t = undefined;
            if (mp_get_buffer(rhs_in, &rhs_bufinfo, mp.MP_BUFFER_READ)) {
                if (!mirrors.isExactType(lhs_in, @ptrCast(&mp_type_bytearray))) {
                    return mirrors.OBJ_FALSE;
                }
                _ = arrayGetBuffer(lhs_in, &lhs_bufinfo, mp.MP_BUFFER_READ);
                const found = find_subbytes(@ptrCast(lhs_bufinfo.buf), lhs_bufinfo.len, @ptrCast(rhs_bufinfo.buf), rhs_bufinfo.len, 1);
                return mp_obj_new_bool(found != null);
            }
            if (mp_obj_is_int(rhs_in) or mp_obj_is_float(rhs_in)) {
                try raiseNotImplemented();
            }
            return mirrors.OBJ_FALSE;
        },
        mp.MP_BINARY_OP_EQUAL,
        mp.MP_BINARY_OP_LESS,
        mp.MP_BINARY_OP_LESS_EQUAL,
        mp.MP_BINARY_OP_MORE,
        mp.MP_BINARY_OP_MORE_EQUAL,
        => {
            var lhs_bufinfo: mp.mp_buffer_info_t = undefined;
            var rhs_bufinfo: mp.mp_buffer_info_t = undefined;
            _ = arrayGetBuffer(lhs_in, &lhs_bufinfo, mp.MP_BUFFER_READ);
            if (!mp_get_buffer(rhs_in, &rhs_bufinfo, mp.MP_BUFFER_READ)) {
                return mirrors.OBJ_FALSE;
            }
            var is_unsigned: bool = false;
            const lhs_code = typecodeForComparison(@intCast(lhs_bufinfo.typecode), &is_unsigned);
            const rhs_code = typecodeForComparison(@intCast(rhs_bufinfo.typecode), &is_unsigned);
            if (lhs_code == rhs_code and lhs_code != 'f' and lhs_code != 'd' and (op == mp.MP_BINARY_OP_EQUAL or is_unsigned)) {
                return mp_obj_new_bool(mp_seq_cmp_bytes(@intCast(op), @ptrCast(lhs_bufinfo.buf), lhs_bufinfo.len, @ptrCast(rhs_bufinfo.buf), rhs_bufinfo.len));
            }
            try raiseNotImplemented();
            return mirrors.OBJ_NULL;
        },
        else => return mirrors.OBJ_NULL,
    }
}

export fn npy_array_binary_op(op: c_int, lhs_in: Obj, rhs_in: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, arrayBinaryOpImpl(op, lhs_in, rhs_in));
}

// ── append / extend ────────────────────────────────────────────────

inline fn isArrayOrBytearray(o: Obj) bool {
    return mirrors.isExactType(o, @ptrCast(&mp_type_bytearray)) or mirrors.isExactType(o, @ptrCast(&mp_type_array));
}

export fn arrayAppend(self_in: Obj, arg: Obj) callconv(.c) Obj {
    std.debug.assert(isArrayOrBytearray(self_in));
    const self = MpObjArray.fromObj(self_in);
    if (self.bits.free == 0) {
        const tc: u8 = @intCast(self.bits.typecode);
        const item_sz = mp_binary_get_size('@', tc, null);
        const add_cnt: usize = 8;
        self.items = m_realloc(self.items, item_sz * (self.len + add_cnt));
        self.bits.free = @intCast(add_cnt);
        // mp_seq_clear: memset items[self.len+1 .. self.len+self.free] = 0
        // (vendor uses len+1 as start; that leaves items[len] alive for the about-to-set value)
        const start_byte = (self.len + 1) * item_sz;
        const end_byte = (self.len + add_cnt) * item_sz;
        if (end_byte > start_byte) {
            @memset((@as([*]u8, @ptrCast(self.items.?)) + start_byte)[0 .. end_byte - start_byte], 0);
        }
    }
    mp_binary_set_val_array(@intCast(self.bits.typecode), self.items, self.len, arg);
    // Polled-sentinel: vendor C uses nlr_jump from mp_binary_set_val_array
    // on TypeError; we set pyerr.pending_exc and continue. If a raise
    // occurred, do NOT bump self.len (would leave the bytearray with a
    // stale slot accounted into len, then printed as data). ADR 012 D4 /
    // workflow wf_5718c66d-29b rank 2.
    if (pyerr.pending_exc != 0) return 0;
    self.len += 1;
    self.bits.free -= 1;
    return mirrors.OBJ_NONE;
}

export fn arrayExtend(self_in: Obj, arg_in: Obj) callconv(.c) Obj {
    std.debug.assert(isArrayOrBytearray(self_in));
    const self = MpObjArray.fromObj(self_in);
    var arg_bufinfo: mp.mp_buffer_info_t = undefined;
    if (!mp_get_buffer(arg_in, &arg_bufinfo, mp.MP_BUFFER_READ)) {
        arrayExtendImpl(self, arg_in, 0, 0);
        return mirrors.OBJ_NONE;
    }
    const tc: u8 = @intCast(self.bits.typecode);
    const sz = mp_binary_get_size('@', tc, null);
    const len = arg_bufinfo.len / sz;
    if (self.bits.free < len) {
        self.items = m_realloc(self.items, (self.len + len) * sz);
        self.bits.free = 0;
        if (self_in == arg_in) {
            mp_get_buffer_raise(arg_in, &arg_bufinfo, mp.MP_BUFFER_READ);
        }
    } else {
        self.bits.free -= @intCast(len);
    }
    // mp_seq_copy: memcpy(items + self.len*sz, arg_buf, len*sz)
    if (len * sz > 0) {
        @memcpy(
            (@as([*]u8, @ptrCast(self.items.?)) + self.len * sz)[0 .. len * sz],
            @as([*]const u8, @ptrCast(arg_bufinfo.buf.?))[0 .. len * sz],
        );
    }
    self.len += len;
    return mirrors.OBJ_NONE;
}

// ── subscr ─────────────────────────────────────────────────────────

fn arraySubscrImpl(self_in: Obj, index_in: Obj, value: Obj) PyError!Obj {
    if (value == mirrors.OBJ_NULL) {
        // delete — not implemented (vendor returns NULL).
        return mirrors.OBJ_NULL;
    }
    const o = MpObjArray.fromObj(self_in);
    if (mirrors.isExactType(index_in, &mp_type_slice)) {
        var slice = MpBoundSlice{ .start = 0, .stop = 0, .step = 0 };
        if (!mp_seq_get_fast_slice_indexes(o.len, index_in, &slice)) {
            try raiseSliceStepUnsupported();
        }
        if (value != mirrors.OBJ_SENTINEL) {
            if (!build_options.is_full) {
                // nano: MICROPY_PY_ARRAY_SLICE_ASSIGN=0 → not supported.
                return mirrors.OBJ_NULL;
            }
            // Slice-assign. Port of py/objarray.c:469-542
            // (MICROPY_PY_ARRAY_SLICE_ASSIGN=1). Handles array, bytearray,
            // memoryview LHS; array-family or bytes RHS; may realloc when
            // the slice grows past the free-slot reserve.
            const tc_masked_ss: u8 = @as(u8, @intCast(o.bits.typecode)) & TYPECODE_MASK;
            const item_sz = mp_binary_get_size('@', tc_masked_ss, null);
            var src_len: usize = undefined;
            // Track src/dest as raw addresses — o.items / src.items may
            // be null for empty containers; Zig's many-item ptr type
            // panics on null even when the resulting reads are zero-byte.
            var src_addr: usize = undefined;
            var src_offs: usize = 0;

            const value_is_array_family = mirrors.isObj(value) and blk: {
                const vt = mirrors.objBaseType(value);
                break :blk vt == @as(*const anyopaque, @ptrCast(&mp_type_array)) or
                    vt == @as(*const anyopaque, @ptrCast(&mp_type_bytearray)) or
                    vt == @as(*const anyopaque, @ptrCast(&mp_type_memoryview));
            };

            if (value_is_array_family) {
                const src = MpObjArray.fromObj(value);
                const src_tc = @as(u8, @intCast(src.bits.typecode)) & TYPECODE_MASK;
                if (item_sz != mp_binary_get_size('@', src_tc, null)) {
                    try raiseSliceCompatError();
                }
                src_len = src.len;
                src_addr = @intFromPtr(src.items);
                if (mirrors.isExactType(value, @ptrCast(&mp_type_memoryview))) {
                    src_offs = @as(usize, src.bits.free) * item_sz;
                }
            } else if (mirrors.isExactType(value, &mp_type_bytes)) {
                if (item_sz != 1) {
                    try raiseSliceCompatError();
                }
                var bufinfo: mp.mp_buffer_info_t = undefined;
                mp_get_buffer_raise(value, &bufinfo, mp.MP_BUFFER_READ);
                if (pyerr.pending_exc != 0) return mirrors.OBJ_NULL;
                src_len = bufinfo.len;
                src_addr = @intFromPtr(bufinfo.buf);
            } else {
                try raiseArrayBytesRequired();
                unreachable;
            }

            const slice_span: isize = slice.stop - slice.start;
            const len_adj: isize = @as(isize, @intCast(src_len)) - slice_span;

            var dest_addr: usize = @intFromPtr(o.items);
            if (isMemoryview(o)) {
                if ((o.bits.typecode & MP_OBJ_ARRAY_TYPECODE_FLAG_RW) == 0) {
                    return mirrors.OBJ_NULL;
                }
                if (len_adj != 0) {
                    try raiseSliceCompatError();
                }
                dest_addr += @as(usize, o.bits.free) * item_sz;
            }

            const beg: usize = @intCast(slice.start);
            const end: usize = @intCast(slice.stop);

            if (len_adj > 0) {
                const grow: usize = @intCast(len_adj);
                if (grow > @as(usize, o.bits.free)) {
                    const new_alloc = (o.len + grow) * item_sz;
                    const new_items = m_realloc(o.items, new_alloc).?;
                    o.items = new_items;
                    o.bits.free = @intCast(grow);
                    if (src_addr == dest_addr) {
                        src_addr = @intFromPtr(o.items);
                    }
                    dest_addr = @intFromPtr(o.items);
                }
                // mp_seq_replace_slice_grow_inplace:
                //   memmove(dest + (beg+slice_len)*sz, dest + end*sz,
                //           (len + len_adj - (beg + slice_len))*sz)
                //   memmove(dest + beg*sz, slice, slice_len*sz)
                const tail_bytes: usize = @intCast(
                    (@as(isize, @intCast(o.len)) + len_adj) -
                        @as(isize, @intCast(beg + src_len)),
                );
                _ = memmove(
                    @ptrFromInt(dest_addr + (beg + src_len) * item_sz),
                    @ptrFromInt(dest_addr + end * item_sz),
                    tail_bytes * item_sz,
                );
                _ = memmove(
                    @ptrFromInt(dest_addr + beg * item_sz),
                    @ptrFromInt(src_addr + src_offs),
                    src_len * item_sz,
                );
            } else {
                // mp_seq_replace_slice_no_grow:
                //   memmove(dest + beg*sz, slice, slice_len*sz)
                //   memmove(dest + (beg+slice_len)*sz, dest + end*sz,
                //           (dest_len - end)*sz)
                // mp_seq_clear(dest, len + len_adj, len, sz):
                //   memset(dest + (len+len_adj)*sz, 0, (-len_adj)*sz)
                _ = memmove(
                    @ptrFromInt(dest_addr + beg * item_sz),
                    @ptrFromInt(src_addr + src_offs),
                    src_len * item_sz,
                );
                _ = memmove(
                    @ptrFromInt(dest_addr + (beg + src_len) * item_sz),
                    @ptrFromInt(dest_addr + end * item_sz),
                    (o.len - end) * item_sz,
                );
                const new_len: usize = @intCast(@as(isize, @intCast(o.len)) + len_adj);
                const shrink_by: usize = @intCast(-len_adj);
                if (shrink_by > 0) {
                    const clear_ptr: [*]u8 = @ptrFromInt(dest_addr + new_len * item_sz);
                    @memset(clear_ptr[0 .. shrink_by * item_sz], 0);
                }
            }
            o.bits.free = @intCast(@as(isize, @intCast(@as(usize, o.bits.free))) - len_adj);
            o.len = @intCast(@as(isize, @intCast(o.len)) + len_adj);
            return mirrors.OBJ_NONE;
        }
        // Load
        const tc_masked: u8 = @as(u8, @intCast(o.bits.typecode)) & TYPECODE_MASK;
        const sz = mp_binary_get_size('@', tc_masked, null);
        std.debug.assert(sz > 0);
        if (isMemoryview(o)) {
            if (@as(usize, @intCast(slice.start)) > memview_offset_max) {
                try raiseMemoryviewOffsetOverflow();
            }
            const res: *MpObjArray = @ptrCast(@alignCast(m_malloc(@sizeOf(MpObjArray)).?));
            res.* = o.*;
            res.bits.free = @intCast(@as(usize, @intCast(@as(usize, o.bits.free) + @as(usize, @intCast(slice.start)))));
            res.len = @intCast(slice.stop - slice.start);
            return @intFromPtr(res);
        }
        const span: usize = @intCast(slice.stop - slice.start);
        const res = arrayNew(@intCast(o.bits.typecode), span);
        if (span * sz > 0) {
            @memcpy(
                @as([*]u8, @ptrCast(res.items.?))[0 .. span * sz],
                (@as([*]const u8, @ptrCast(o.items.?)) + @as(usize, @intCast(slice.start)) * sz)[0 .. span * sz],
            );
        }
        return @intFromPtr(res);
    }
    var index = mp_get_index(o.base.type.?, o.len, index_in, false);
    if (pyerr.pending_exc != 0) return error.PyRaise;
    if (isMemoryview(o)) {
        index += @as(usize, o.bits.free);
        if (value != mirrors.OBJ_SENTINEL and (o.bits.typecode & MP_OBJ_ARRAY_TYPECODE_FLAG_RW) == 0) {
            // store to read-only memoryview
            return mirrors.OBJ_NULL;
        }
    }
    const tc_masked: u8 = @as(u8, @intCast(o.bits.typecode)) & TYPECODE_MASK;
    if (value == mirrors.OBJ_SENTINEL) {
        return mp_binary_get_val_array(tc_masked, o.items, index);
    }
    mp_binary_set_val_array(tc_masked, o.items, index, value);
    return mirrors.OBJ_NONE;
}

export fn npy_array_subscr(self_in: Obj, index_in: Obj, value: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, arraySubscrImpl(self_in, index_in, value));
}

// ── buffer ─────────────────────────────────────────────────────────

export fn arrayGetBuffer(o_in: Obj, bufinfo: *mp.mp_buffer_info_t, flags: c_uint) callconv(.c) isize {
    const o = MpObjArray.fromObj(o_in);
    const tc_masked: u8 = @as(u8, @intCast(o.bits.typecode)) & TYPECODE_MASK;
    const sz = mp_binary_get_size('@', tc_masked, null);
    bufinfo.buf = o.items;
    bufinfo.len = o.len * sz;
    bufinfo.typecode = tc_masked;
    if (isMemoryview(o)) {
        if ((o.bits.typecode & MP_OBJ_ARRAY_TYPECODE_FLAG_RW) == 0 and (flags & mp.MP_BUFFER_WRITE) != 0) {
            return 1;
        }
        bufinfo.buf = @ptrFromInt(@intFromPtr(bufinfo.buf) + @as(usize, o.bits.free) * sz);
    }
    return 0;
}

// ── iterator ──────────────────────────────────────────────────────

// MpObjArrayIt MUST fit in mp_obj_iter_buf_t (sizeof = base + 3*Obj =
// 32 bytes on 64-bit). Previously had base + iternext + array + offset
// + cur = 5 slots (40 bytes), overflowing the buf by 8 bytes — the
// `cur` field sat in the stack slot the FOR_ITER bytecode writes the
// value to, so every iteration clobbered cur with the byte value just
// produced. `for x in bytearray(...)` then yielded only the first
// element. Fixed by deriving offset on-the-fly from the array bits
// (memoryview test) instead of storing it.
const MpObjArrayIt = extern struct {
    base: mirrors.MpObjBase,
    iternext: *const fn (Obj) callconv(.c) Obj,
    array: *MpObjArray,
    cur: usize,

    inline fn fromObj(o: Obj) *MpObjArrayIt {
        return @ptrFromInt(o);
    }
};

inline fn arrayItOffset(arr: *const MpObjArray) usize {
    return if (isMemoryview(arr)) @as(usize, arr.bits.free) else 0;
}

export fn npy_array_it_iternext(self_in: Obj) callconv(.c) Obj {
    const self = MpObjArrayIt.fromObj(self_in);
    if (self.cur < self.array.len) {
        const tc_masked: u8 = @as(u8, @intCast(self.array.bits.typecode)) & TYPECODE_MASK;
        const out = mp_binary_get_val_array(tc_masked, self.array.items, arrayItOffset(self.array) + self.cur);
        self.cur += 1;
        return out;
    }
    return mirrors.OBJ_STOP_ITERATION;
}

export fn npy_array_iterator_new(array_in: Obj, iter_buf: ?*anyopaque) callconv(.c) Obj {
    const array = MpObjArray.fromObj(array_in);
    const o: *MpObjArrayIt = @ptrCast(@alignCast(iter_buf));
    o.base.type = &mp_type_polymorph_iter;
    o.iternext = &npy_array_it_iternext;
    o.array = array;
    o.cur = 0;
    return @intFromPtr(o);
}

// ── fun-objs for append/extend (locals dict consumes these) ────────

pub export const mp_obj_array_append_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&arrayAppend),
};
pub export const mp_obj_array_extend_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&arrayExtend),
};

// ── ROM type tables ───────────────────────────────────────────────

// mp_type_array slot order: make_new=1, print=2, unary_op=3, binary_op=4,
//                           subscr=5, iter=6, buffer=7, locals_dict=8
pub export const mp_type_array: types.MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = mirrors.FLAG_ITER_IS_GETITER,
        .name = mp.MP_QSTR_array,
        .slot_index_make_new = 1,
        .slot_index_print = 2,
        .slot_index_call = 0,
        .slot_index_unary_op = 3,
        .slot_index_binary_op = 4,
        .slot_index_attr = 0,
        .slot_index_subscr = 5,
        .slot_index_iter = 6,
        .slot_index_buffer = 7,
        .slot_index_protocol = 0,
        .slot_index_parent = 0,
        .slot_index_locals_dict = 8,
    },
    .slots = .{
        @ptrCast(&npy_array_make_new),
        @ptrCast(&npy_array_print),
        @ptrCast(&npy_array_unary_op),
        @ptrCast(&npy_array_binary_op),
        @ptrCast(&npy_array_subscr),
        @ptrCast(&npy_array_iterator_new),
        @ptrCast(&arrayGetBuffer),
        @ptrCast(&mp_obj_array_locals_dict),
        null,
        null,
        null,
    },
};

// mp_type_bytearray: + EQ_CHECKS_OTHER_TYPE | SUBSCR_ALLOWS_STACK_SLICE.
// FLAG_ITER_IS_GETITER removed (was a bug-for-bug-with-vendor leftover):
// our slot_index_iter = 6 points to npy_array_iterator_new which IS a
// real getiter (returns a new iterator object), not a __getitem__ stand-in
// — so the flag misled the runtime's for-loop dispatch into calling it
// only once and treating the result as the first element, breaking
// `for x in bytearray(...): ...` after the first iteration.
pub export const mp_type_bytearray: types.MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = mirrors.FLAG_EQ_CHECKS_OTHER_TYPE | mirrors.FLAG_SUBSCR_ALLOWS_STACK_SLICE,
        .name = mp.MP_QSTR_bytearray,
        .slot_index_make_new = 1,
        .slot_index_print = 2,
        .slot_index_call = 0,
        .slot_index_unary_op = 3,
        .slot_index_binary_op = 4,
        .slot_index_attr = 0,
        .slot_index_subscr = 5,
        .slot_index_iter = 6,
        .slot_index_buffer = 7,
        .slot_index_protocol = 0,
        .slot_index_parent = 0,
        .slot_index_locals_dict = 8,
    },
    .slots = .{
        @ptrCast(&npy_bytearray_make_new),
        @ptrCast(&npy_array_print),
        @ptrCast(&npy_array_unary_op),
        @ptrCast(&npy_array_binary_op),
        @ptrCast(&npy_array_subscr),
        @ptrCast(&npy_array_iterator_new),
        @ptrCast(&arrayGetBuffer),
        @ptrCast(&mp_obj_bytearray_locals_dict),
        null,
        null,
        null,
    },
};

// mp_type_memoryview: no print, no make_new positionally first
// nano: BYTES_HEX=1 → locals_dict slot present.
//       MEMORYVIEW_ITEMSIZE=0 → no attr slot.
// Slot order: make_new=1, unary_op=2, binary_op=3, subscr=4, iter=5,
//             buffer=6, locals_dict=7
pub export const mp_type_memoryview: types.MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = mirrors.FLAG_EQ_CHECKS_OTHER_TYPE | mirrors.FLAG_ITER_IS_GETITER | mirrors.FLAG_SUBSCR_ALLOWS_STACK_SLICE,
        .name = mp.MP_QSTR_memoryview,
        .slot_index_make_new = 1,
        .slot_index_print = 0,
        .slot_index_call = 0,
        .slot_index_unary_op = 2,
        .slot_index_binary_op = 3,
        .slot_index_attr = 0,
        .slot_index_subscr = 4,
        .slot_index_iter = 5,
        .slot_index_buffer = 6,
        .slot_index_protocol = 0,
        .slot_index_parent = 0,
        .slot_index_locals_dict = 7,
    },
    .slots = .{
        @ptrCast(&npy_memoryview_make_new),
        @ptrCast(&npy_array_unary_op),
        @ptrCast(&npy_array_binary_op),
        @ptrCast(&npy_array_subscr),
        @ptrCast(&npy_array_iterator_new),
        @ptrCast(&arrayGetBuffer),
        @ptrCast(&mp_obj_memoryview_locals_dict),
        null,
        null,
        null,
        null,
    },
};

// Force Zig to fully analyze all exports so the linker sees them.
comptime {
    _ = &npy_array_print;
    _ = &npy_array_make_new;
    _ = &npy_bytearray_make_new;
    _ = &npy_memoryview_make_new;
    _ = &npy_array_unary_op;
    _ = &npy_array_binary_op;
    _ = &npy_array_subscr;
    _ = &arrayGetBuffer;
    _ = &arrayAppend;
    _ = &arrayExtend;
    _ = &npy_array_it_iternext;
    _ = &npy_array_iterator_new;
    _ = &mp_obj_new_memoryview;
    _ = &mp_obj_new_bytearray;
    _ = &mp_obj_new_bytearray_by_ref;
    _ = &mp_type_array;
    _ = &mp_type_bytearray;
    _ = &mp_type_memoryview;
    _ = &mp_obj_array_append_obj;
    _ = &mp_obj_array_extend_obj;
}
