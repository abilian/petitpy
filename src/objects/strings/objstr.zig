//! nanopython — Zig partial port of py/objstr.c (Axis-B B1.5 W5; seam 1).
//!
//! objstr.c is the last raise-path-bearing C file blocking B2: ~2473 LOC
//! source, ~91 top-level decls, ~45 raise sites. Multi-session port.
//!
//! Seam 1: str/bytes iterators (4 fns, 0 raises) — validates the W5 pattern
//! using a small isolated cluster.
//!   - str_it_iternext: yields 1-char str via mp_obj_new_str_via_qstr
//!   - bytes_it_iternext: yields 1 small-int byte
//!   - mp_obj_new_str_iterator: overlay-init into iter_buf for str
//!   - mp_obj_new_bytes_iterator: overlay-init into iter_buf for bytes
//!
//! The mp_obj_str8_it_t struct is shim-owned (lesson #11) — Zig accesses
//! its fields via npy_str_it_* accessors.

/// MicroPython enum/flag constants via direct @cImport — replaces
/// 24 `npy_str_*` wrapper constants that were just `(int)X` casts.
const mp = @cImport({
    @cInclude("py/obj.h");
    @cInclude("py/runtime.h");
    @cInclude("py/mpprint.h");
});

const mirrors = @import("../../mp_mirrors.zig");
const argcheck = @import("../../runtime/argcheck.zig");
const opmethods = @import("../../runtime/opmethods.zig");
extern fn mp_load_method_maybe(base: Obj, attr: usize, dest: *[3]Obj) callconv(.c) void;
extern fn mp_call_method_n_kw(n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj;
const pyerr = @import("../../pyerr.zig");
const PyError = pyerr.PyError;

const Obj = mirrors.Obj;
const MP_OBJ_NULL: Obj = 0;
// Immediate-obj constants (see mp_mirrors.zig / py/obj.h). REPR_A only.
// MP_OBJ_NEW_IMMEDIATE_OBJ(n) = (n << 3) | 6.
const MP_OBJ_STOP_ITERATION: Obj = 0;
const MP_OBJ_SENTINEL: Obj = 4;
const MP_OBJ_NONE: Obj = 6;
const MP_OBJ_FALSE: Obj = 14;
const MP_OBJ_TRUE: Obj = 30;
// REPR_A small-int / qstr encodings (py/obj.h:89-96).
inline fn newSmallInt(n: isize) Obj {
    return (@as(Obj, @bitCast(n)) << 1) | 1;
}
inline fn smallIntValue(o: Obj) isize {
    return @as(isize, @bitCast(o)) >> 1;
}
inline fn newQstrObj(q: u16) Obj {
    return (@as(Obj, q) << 3) | 2;
}
inline fn newBoolObj(b: bool) Obj {
    return if (b) MP_OBJ_TRUE else MP_OBJ_FALSE;
}

// ── inline exception constructors ─────────────────────────────────────
// Previously dispatched through ~17 `npy_str_make_X_exc()` shim helpers in
// objstr_shim.c (~80 LOC); each was a one-liner wrapping mp_obj_new_exception_msg
// with a TERSE error string. Bringing them inline closes that arc of the shim.
extern fn mp_obj_new_exception(t: *const anyopaque) callconv(.c) Obj;
extern fn mp_obj_new_exception_msg(t: *const anyopaque, msg: [*:0]const u8) callconv(.c) Obj;
// mp_obj_new_exception_arg1 is static inline in py/obj.h — call the underlying
// mp_obj_exception_make_new directly. (n_args=1, n_kw=0, args=&arg).
extern fn mp_obj_exception_make_new(t: *const anyopaque, n_args: usize, n_kw: usize, args: [*]const Obj) callconv(.c) Obj;
extern const mp_type_TypeError: anyopaque;
extern const mp_type_ValueError: anyopaque;
extern const mp_type_IndexError: anyopaque;
extern const mp_type_KeyError: anyopaque;
extern const mp_type_NotImplementedError: anyopaque;

inline fn excBadImplicitConv() Obj {
    return mp_obj_new_exception_msg(&mp_type_TypeError, "can't convert to str implicitly");
}
inline fn excSubstrNotFound() Obj {
    return mp_obj_new_exception_msg(&mp_type_ValueError, "substring not found");
}
inline fn excValueOutOfRange() Obj {
    return mp_obj_new_exception_msg(&mp_type_ValueError, "bytes value out of range");
}
inline fn excJoinType() Obj {
    return mp_obj_new_exception_msg(&mp_type_TypeError, "join expects a list of str/bytes objects consistent with self object");
}
inline fn excEmptySep() Obj {
    return mp_obj_new_exception_msg(&mp_type_ValueError, "empty separator");
}
inline fn excNonHexDigit() Obj {
    return mp_obj_new_exception_msg(&mp_type_ValueError, "non-hex digit");
}
inline fn excRsplitNone() Obj {
    return mp_obj_new_exception_msg(&mp_type_NotImplementedError, "rsplit(None,n)");
}
inline fn excNegLen() Obj {
    return mp_obj_new_exception(&mp_type_ValueError);
}
inline fn excWrongArgs() Obj {
    return mp_obj_new_exception_msg(&mp_type_TypeError, "wrong number of arguments");
}
inline fn excBadFormatStr() Obj {
    return mp_obj_new_exception_msg(&mp_type_ValueError, "bad format string");
}
inline fn excFormatNeedsDict() Obj {
    return mp_obj_new_exception_msg(&mp_type_TypeError, "format needs a dict");
}
inline fn excMoreArgs() Obj {
    return mp_obj_new_exception_msg(&mp_type_TypeError, "format string needs more arguments");
}
inline fn excPctC() Obj {
    return mp_obj_new_exception_msg(&mp_type_TypeError, "%c needs int or char");
}
inline fn excIntegerNeeded() Obj {
    return mp_obj_new_exception_msg(&mp_type_TypeError, "integer needed");
}
inline fn excExtraArgs() Obj {
    return mp_obj_new_exception_msg(&mp_type_TypeError, "format string didn't convert all arguments");
}
inline fn excIndexOOR() Obj {
    return mp_obj_new_exception_msg(&mp_type_IndexError, "tuple index out of range");
}
inline fn excKeyErr(key: Obj) Obj {
    const args: [1]Obj = .{key};
    return mp_obj_exception_make_new(&mp_type_KeyError, 1, 0, &args);
}
inline fn excAttrsNotSupp() Obj {
    return mp_obj_new_exception_msg(&mp_type_NotImplementedError, "attributes not supported");
}

// ── inline type-pointer wrappers ──────────────────────────────────────
// Inline replacements for the three npy_str_type_*_ptr() shim helpers.
// Returns `?*const anyopaque` to match npy_str_obj_type's return type so the
// equality comparisons at call sites don't need extra casts.
// mp_type_str / mp_type_bytes / mp_type_bytearray are extern'd at file scope
// (~line 2166 / 2204) and are accessible from anywhere in this file.
inline fn typeStrPtr() ?*const anyopaque {
    return @as(?*const anyopaque, &mp_type_str);
}
inline fn typeBytesPtr() ?*const anyopaque {
    return @as(?*const anyopaque, &mp_type_bytes);
}
inline fn typeBytearrayPtr() ?*const anyopaque {
    return @as(?*const anyopaque, &mp_type_bytearray);
}
// Inline replacement for npy_str_const_empty_bytes(). The CPP macro
// `mp_const_empty_bytes` expands to `MP_OBJ_FROM_PTR(&mp_const_empty_bytes_obj)`
// — under REPR_A that's just @intFromPtr. mp_const_empty_bytes_obj is the
// pub export const defined further down this file (ROM block).
inline fn constEmptyBytes() Obj {
    return @intFromPtr(&mp_const_empty_bytes_obj);
}

// mp_obj_str_get_data + mp_obj_new_str_via_qstr: defined as `export fn` below
// (seams 14 / 14c).

// mp_print_t* is passed as opaque ?*const anyopaque throughout (lesson #11
// — mp_print_t holds a function pointer field that translate-c attaches as
// a method).
const Print = ?*const anyopaque;

// ── inline replacements for objstr_shim.c thin wrappers ──────────────
// Each helper mirrors the C ABI of an npy_str_* shim wrapper so callsites
// translate as a one-token rename (c.npy_str_X → npyStrX). The actual
// vendor extern is called from this file directly. The C-side wrappers
// in objstr_shim.c are deleted in the same change.
//
// vstr_t layout (misc.h: { size_t alloc; size_t len; char *buf; bool
// fixed_buf; }) — 32 bytes on 64-bit. Match VstrT in vstr.zig.
const VstrT = extern struct {
    alloc: usize,
    len: usize,
    buf: [*c]u8,
    fixed_buf: bool,
};
const MpBufInfo = extern struct {
    buf: ?*anyopaque,
    len: usize,
    typecode: c_int,
};

// Vendor externs used by the inline helpers. Use @extern bindings so
// these can have Zig-level names that don't collide with existing fn
// extern decls further down in the file.
const ext_vstr_init_len: *const fn (*VstrT, usize) callconv(.c) void =
    @extern(*const fn (*VstrT, usize) callconv(.c) void, .{ .name = "vstr_init_len" });
const ext_vstr_init: *const fn (*VstrT, usize) callconv(.c) void =
    @extern(*const fn (*VstrT, usize) callconv(.c) void, .{ .name = "vstr_init" });
const ext_vstr_add_byte: *const fn (*VstrT, u8) callconv(.c) void =
    @extern(*const fn (*VstrT, u8) callconv(.c) void, .{ .name = "vstr_add_byte" });
const ext_mp_obj_new_list: *const fn (usize, ?[*]const Obj) callconv(.c) Obj =
    @extern(*const fn (usize, ?[*]const Obj) callconv(.c) Obj, .{ .name = "mp_obj_new_list" });
const ext_mp_obj_list_append: *const fn (Obj, Obj) callconv(.c) Obj =
    @extern(*const fn (Obj, Obj) callconv(.c) Obj, .{ .name = "mp_obj_list_append" });
const ext_mp_obj_list_make_new: *const fn (?*const anyopaque, usize, usize, [*c]const Obj) callconv(.c) Obj =
    @extern(*const fn (?*const anyopaque, usize, usize, [*c]const Obj) callconv(.c) Obj, .{ .name = "mp_obj_list_make_new" });
const ext_mp_obj_get_array: *const fn (Obj, *usize, *[*c]Obj) callconv(.c) void =
    @extern(*const fn (Obj, *usize, *[*c]Obj) callconv(.c) void, .{ .name = "mp_obj_get_array" });
const ext_mp_obj_dict_get: *const fn (Obj, Obj) callconv(.c) Obj =
    @extern(*const fn (Obj, Obj) callconv(.c) Obj, .{ .name = "mp_obj_dict_get" });
const ext_mp_obj_len_maybe: *const fn (Obj) callconv(.c) Obj =
    @extern(*const fn (Obj) callconv(.c) Obj, .{ .name = "mp_obj_len_maybe" });
const ext_mp_get_buffer: *const fn (Obj, *MpBufInfo, c_uint) callconv(.c) bool =
    @extern(*const fn (Obj, *MpBufInfo, c_uint) callconv(.c) bool, .{ .name = "mp_get_buffer" });
// mp_get_buffer_raise is `static inline` in vendor py/obj.h — not link-callable.
// Inline it as mp_get_buffer with the RAISE flag (= 4).
const MP_BUFFER_RAISE_IF_UNSUPPORTED: c_uint = 4;
const ext_mp_obj_tuple_get: *const fn (Obj, *usize, *[*c]Obj) callconv(.c) void =
    @extern(*const fn (Obj, *usize, *[*c]Obj) callconv(.c) void, .{ .name = "mp_obj_tuple_get" });
// mp_obj_is_tuple_compatible is a C macro in vendor objtuple.h:65 —
//   (MP_OBJ_TYPE_GET_SLOT_OR_NULL(get_type(o), iter) == mp_obj_tuple_getiter)
// Inline it here as a Zig fn so the extern doesn't go undefined under
// our strangled build (vendor objtuple.c isn't in the compile graph).
extern fn mp_obj_tuple_getiter(o: Obj, iter_buf: ?*anyopaque) callconv(.c) Obj;
fn ext_mp_obj_is_tuple_compatible(o: Obj) callconv(.c) bool {
    if (!mirrors.isObj(o)) return false;
    const t = mirrors.objBaseType(o) orelse return false;
    const tp = mirrors.MpObjType.fromPtr(t);
    const slot = tp.getSlot(.iter) orelse return false;
    return @intFromPtr(slot) == @intFromPtr(&mp_obj_tuple_getiter);
}
const ext_mp_seq_multiply: *const fn (?*const anyopaque, usize, usize, usize, ?*anyopaque) callconv(.c) void =
    @extern(*const fn (?*const anyopaque, usize, usize, usize, ?*anyopaque) callconv(.c) void, .{ .name = "mp_seq_multiply" });
const ext_mp_arg_parse_all: *const fn (usize, [*c]const Obj, ?*anyopaque, usize, [*c]const u8, [*c]u8) callconv(.c) void =
    @extern(*const fn (usize, [*c]const Obj, ?*anyopaque, usize, [*c]const u8, [*c]u8) callconv(.c) void, .{ .name = "mp_arg_parse_all" });
const ext_mp_map_lookup: *const fn (?*anyopaque, Obj, c_uint) callconv(.c) ?*MpMapElem =
    @extern(*const fn (?*anyopaque, Obj, c_uint) callconv(.c) ?*MpMapElem, .{ .name = "mp_map_lookup" });
const ext_mp_seq_get_fast_slice_indexes: *const fn (usize, Obj, *MpBoundSlice) callconv(.c) bool =
    @extern(*const fn (usize, Obj, *MpBoundSlice) callconv(.c) bool, .{ .name = "mp_seq_get_fast_slice_indexes" });

const MpMapElem = extern struct { key: Obj, value: Obj };
// Matches vendor mp_bound_slice_t (obj.h): all three fields are mp_int_t
// (signed intptr_t). The earlier `start: usize, stop: usize` was fine for
// step==1 cases (stop >= start always) but wrong for negative-step slices
// where stop can be -1. ADR 010 §C3 (str slice with step != 1).
const MpBoundSlice = extern struct { start: isize, stop: isize, step: isize };

// MP_MAP_LOOKUP = 0 (mp_map_lookup_kind_t in py/obj.h).
const MP_MAP_LOOKUP_KIND: c_uint = 0;

// mp_arg_t mirror — { uint16_t qst; uint16_t flags; union { ... } default_val; }
// mp_arg_flag_t (py/runtime.h:46): BOOL=0x001, INT=0x002, OBJ=0x003,
// KIND_MASK=0x0ff, REQUIRED=0x100, KW_ONLY=0x200.
const MpArgT = extern struct {
    qst: u16,
    flags: u16,
    default_val: extern union { u_bool: c_uint, u_int: isize, u_obj: Obj, u_rom_obj: ?*const anyopaque },
};
const MpArgVal = extern union { u_bool: c_uint, u_int: isize, u_obj: Obj, u_rom_obj: ?*const anyopaque };
// Inline npyStr* helpers — each replaces a shim wrapper one-for-one.
inline fn npyStrObjStrDataLen(obj: Obj, data_out: *[*]const u8) usize {
    if ((obj & 7) == 2) {
        // qstr
        var len: usize = 0;
        const data = qstr_data(@intCast(obj >> 3), &len);
        data_out.* = data;
        return len;
    }
    const s = mirrors.MpObjStr.fromObj(obj);
    data_out.* = s.data;
    return s.len;
}
inline fn npyStrObjStrLen(obj: Obj) usize {
    if ((obj & 7) == 2) {
        var len: usize = 0;
        _ = qstr_data(@intCast(obj >> 3), &len);
        return len;
    }
    return mirrors.MpObjStr.fromObj(obj).len;
}
inline fn npyStrSizeofVstr() usize {
    return @sizeOf(VstrT);
}
inline fn npyStrVstrInitLen(storage: *anyopaque, len: usize) ?*anyopaque {
    const v: *VstrT = @ptrCast(@alignCast(storage));
    ext_vstr_init_len(v, len);
    return @ptrCast(v.buf);
}
inline fn npyStrVstrInit(storage: *anyopaque, alloc: usize) void {
    ext_vstr_init(@ptrCast(@alignCast(storage)), alloc);
}
inline fn npyStrVstrAddByte(storage: *anyopaque, b: u8) void {
    ext_vstr_add_byte(@ptrCast(@alignCast(storage)), b);
}
inline fn npyStrVstrToObj(type_in: ?*const anyopaque, storage: *anyopaque) Obj {
    return mp_obj_new_str_type_from_vstr(type_in, storage);
}
inline fn npyStrVstrToBytes(storage: *anyopaque) Obj {
    return mp_obj_new_bytes_from_vstr(storage);
}
inline fn npyStrVstrSetLen(storage: *anyopaque, len: usize) void {
    const v: *VstrT = @ptrCast(@alignCast(storage));
    v.len = len;
}
inline fn npyStrObjLenMaybe(o: Obj) Obj {
    return ext_mp_obj_len_maybe(o);
}
inline fn npyStrNewStrOfType(t: ?*const anyopaque, data: [*]const u8, len: usize) Obj {
    return mp_obj_new_str_of_type(t, data, len);
}
inline fn npyStrListNew(n: isize) Obj {
    return ext_mp_obj_new_list(@intCast(n), null);
}
inline fn npyStrListAppend(list: Obj, v: Obj) Obj {
    return ext_mp_obj_list_append(list, v);
}
inline fn npyStrListItemsMut(list: Obj) [*]Obj {
    return mirrors.MpObjList.fromObj(list).items;
}
inline fn npyStrListFinalizeRsplit(list: Obj, idx: usize, org_splits: isize) void {
    const l = mirrors.MpObjList.fromObj(list);
    if (idx != 0) {
        const used: usize = @as(usize, @intCast(org_splits)) + 1 - idx;
        // memmove (items may overlap on shift-down)
        const dst = l.items;
        const src = l.items + idx;
        var i: usize = 0;
        while (i < used) : (i += 1) dst[i] = src[i];
        // mp_seq_clear is a macro: memset(start + len*item_sz, 0, (alloc - len) * item_sz)
        const tail_start: [*]u8 = @ptrCast(l.items + used);
        const tail_bytes: usize = (l.alloc - used) * @sizeOf(Obj);
        @memset(tail_start[0..tail_bytes], 0);
        l.len = used;
    }
}
inline fn npyStrListMakeNewFromArg(arg: Obj) Obj {
    var a: Obj = arg;
    return ext_mp_obj_list_make_new(&mp_type_list, 1, 0, @ptrCast(&a));
}
inline fn npyStrObjGetArray(o: Obj, len_out: *usize, items_out: *[*c]Obj) void {
    ext_mp_obj_get_array(o, len_out, items_out);
}
inline fn npyStrTupleGet(o: Obj, len_out: *usize, items_out: *[*c]Obj) void {
    ext_mp_obj_tuple_get(o, len_out, items_out);
}
inline fn npyStrIsTupleCompatible(o: Obj) c_int {
    return if (ext_mp_obj_is_tuple_compatible(o)) 1 else 0;
}
inline fn npyStrDictGet(d: Obj, k: Obj) Obj {
    return ext_mp_obj_dict_get(d, k);
}
inline fn npyStrKwargsLookup(kwargs: ?*anyopaque, key: Obj) Obj {
    const elem = ext_mp_map_lookup(kwargs, key, MP_MAP_LOOKUP_KIND);
    return if (elem) |e| e.value else 0;
}
inline fn npyStrConcatBytes(t: ?*const anyopaque, lhs: [*]const u8, lhs_len: usize, rhs: [*]const u8, rhs_len: usize) Obj {
    var vstr: VstrT = undefined;
    ext_vstr_init_len(&vstr, lhs_len + rhs_len);
    @memcpy(vstr.buf[0..lhs_len], lhs[0..lhs_len]);
    @memcpy((vstr.buf + lhs_len)[0..rhs_len], rhs[0..rhs_len]);
    return mp_obj_new_str_type_from_vstr(t, &vstr);
}
inline fn npyStrMultiplyBytes(t: ?*const anyopaque, data: [*]const u8, len: usize, n: isize) Obj {
    var vstr: VstrT = undefined;
    const total: usize = len * @as(usize, @intCast(n));
    ext_vstr_init_len(&vstr, total);
    ext_mp_seq_multiply(@ptrCast(data), @sizeOf(u8), len, @intCast(n), @ptrCast(vstr.buf));
    return mp_obj_new_str_type_from_vstr(t, &vstr);
}
inline fn npyStrGetBufferRead(o: Obj, data_out: *[*]const u8, len_out: *usize) c_int {
    var bi: MpBufInfo = undefined;
    if (!ext_mp_get_buffer(o, &bi, mp.MP_BUFFER_READ)) return 0;
    data_out.* = @ptrCast(bi.buf);
    len_out.* = bi.len;
    return 1;
}
inline fn npyStrGetBufferRaise(o: Obj, data_out: *[*]const u8, len_out: *usize) c_int {
    var bi: MpBufInfo = undefined;
    _ = ext_mp_get_buffer(o, &bi, mp.MP_BUFFER_READ | MP_BUFFER_RAISE_IF_UNSUPPORTED);
    data_out.* = @ptrCast(bi.buf);
    len_out.* = bi.len;
    return 1;
}
inline fn npyStrBufinfoSetRead(bufinfo: ?*anyopaque, buf: [*]const u8, len: usize) void {
    const b: *MpBufInfo = @ptrCast(@alignCast(bufinfo));
    b.buf = @ptrCast(@constCast(buf));
    b.len = len;
    b.typecode = 'B';
}
inline fn npyStrSplitlinesParseKeepends(n_args: usize, pos_args: [*c]const Obj, kw_args: ?*anyopaque) c_int {
    // The previous mp_arg_parse_all path had .flags = 0x008 (which isn't a
    // valid MP_ARG kind — the real value is 0x001 per py/runtime.h:46-53)
    // and silently fell through to MP_ARG_OBJ semantics. That wrote the raw
    // Obj to u_obj; reading u_bool from the low 4 bytes returned 14 for
    // False (the tagged-immediate value), so keepends was effectively True
    // for any explicit arg. Bypass the parser — we only need one bool here.
    if (n_args >= 2) {
        return if (mp_obj_is_true(pos_args[1])) 1 else 0;
    }
    if (kw_args != null) {
        const km: *const mirrors.MpMap = @ptrCast(@alignCast(kw_args));
        if (km.bits.used != 0) {
            const e = ext_mp_map_lookup(@constCast(km), mirrors.objFromQstr(mp.MP_QSTR_keepends), MP_MAP_LOOKUP_KIND);
            if (e) |elem| return if (mp_obj_is_true(elem.value)) 1 else 0;
        }
    }
    return 0; // default keepends=False
}

extern fn mp_obj_is_true(o: Obj) callconv(.c) bool;
extern fn mp_obj_slice_indices(slice: Obj, length: isize, indexes: *MpBoundSlice) callconv(.c) void;

// Number of items a bound slice selects. A signed walk, so negative-step
// slices (stop < start) work naturally.
fn sliceCount(slice: MpBoundSlice) usize {
    const step = slice.step;
    if (step > 0 and slice.stop > slice.start) return @intCast(@divFloor(slice.stop - slice.start + step - 1, step));
    if (step < 0 and slice.start > slice.stop) return @intCast(@divFloor(slice.start - slice.stop + (-step) - 1, -step));
    return 0;
}

inline fn npyStrSliceLoad(self_in: Obj, index_in: Obj) PyError!Obj {
    const self_type = mp_obj_get_type(self_in);
    var data: [*]const u8 = undefined;
    const len = npyStrObjStrDataLen(self_in, &data);
    var slice: MpBoundSlice = undefined;
    if (ext_mp_seq_get_fast_slice_indexes(len, index_in, &slice)) {
        // Fast path: step=1.
        const start: usize = @intCast(slice.start);
        const stop: usize = @intCast(slice.stop);
        return mp_obj_new_str_of_type(self_type, data + start, stop - start);
    }
    // ADR 010 §C3 — slice with step != 1 (e.g. "abc"[::-1]). Vendor MP
    // raises NotImplementedError here; we extend with a real implementation
    // by walking mp_obj_slice_indices's start/stop/step and copying byte
    // by byte into a freshly allocated buffer. Faithful to CPython's
    // behavior for byte strings (bytes by index, not Unicode code points,
    // matching MICROPY_PY_BUILTINS_STR_UNICODE=0 on nano).
    mp_obj_slice_indices(index_in, @intCast(len), &slice);
    const step = slice.step;
    const count = sliceCount(slice);
    if (count == 0) {
        return mp_obj_new_str_of_type(self_type, data, 0);
    }
    // Allocate a flexible buffer via m_malloc; mp_obj_new_str_of_type
    // copies from the buffer so we don't need to keep it.
    const raw = step_slice_m_malloc(count) orelse return error.PyRaise;
    const buf: [*]u8 = @ptrCast(raw);
    var i: isize = slice.start;
    var j: usize = 0;
    while (j < count) : (j += 1) {
        buf[j] = data[@intCast(i)];
        i += step;
    }
    const out = mp_obj_new_str_of_type(self_type, buf, count);
    step_slice_m_free(raw);
    return out;
}

extern fn m_free(ptr: ?*anyopaque) callconv(.c) void;
inline fn step_slice_m_malloc(n: usize) ?*anyopaque {
    return @as(?*anyopaque, m_malloc(n));
}
inline fn step_slice_m_free(p: ?*anyopaque) void {
    m_free(p);
}

// Overlay struct mirror of mp_obj_str8_it_t (was C-side shim). 4 fields:
// base, iternext fn ptr, str obj, cur index. The iternext fn ptr is stored
// as ?*const anyopaque to keep the layout opaque.
const MpObjStr8It = extern struct {
    base: mirrors.MpObjBase,
    iternext: ?*const anyopaque,
    str: Obj,
    cur: usize,
};
extern const mp_type_polymorph_iter: anyopaque;

export fn str_it_iternext(self_in: Obj) callconv(.c) Obj {
    const self: *MpObjStr8It = @ptrFromInt(self_in);
    var len: usize = 0;
    const data = mp_obj_str_get_data(self.str, &len);
    if (self.cur < len) {
        const cur = data + self.cur;
        const n = @intFromPtr(utf8NextChar(cur)) - @intFromPtr(cur);
        const out = mp_obj_new_str_via_qstr(cur, n);
        self.cur += n;
        return out;
    }
    return MP_OBJ_STOP_ITERATION;
}

export fn mp_obj_new_str_iterator(str: Obj, iter_buf: ?*anyopaque) callconv(.c) Obj {
    const o: *MpObjStr8It = @ptrCast(@alignCast(iter_buf));
    o.base.type = &mp_type_polymorph_iter;
    o.iternext = @ptrCast(&str_it_iternext);
    o.str = str;
    o.cur = 0;
    return @intFromPtr(o);
}

export fn bytes_it_iternext(self_in: Obj) callconv(.c) Obj {
    const self: *MpObjStr8It = @ptrFromInt(self_in);
    var len: usize = 0;
    const data = mp_obj_str_get_data(self.str, &len);
    if (self.cur < len) {
        const out = newSmallInt(@intCast(data[self.cur]));
        self.cur += 1;
        return out;
    }
    return MP_OBJ_STOP_ITERATION;
}

export fn mp_obj_new_bytes_iterator(str: Obj, iter_buf: ?*anyopaque) callconv(.c) Obj {
    const o: *MpObjStr8It = @ptrCast(@alignCast(iter_buf));
    o.base.type = &mp_type_polymorph_iter;
    o.iternext = @ptrCast(&bytes_it_iternext);
    o.str = str;
    o.cur = 0;
    return @intFromPtr(o);
}

// ── seam 2: find_subbytes (0 raises) ──
//
// Like strstr but with explicit lengths and allowing \0 bytes. Two-direction
// search: direction +1 = forward (first occurrence), -1 = backward (last).
// Returns ?[*]const u8 — NULL when no match.

export fn find_subbytes(haystack: [*]const u8, hlen: usize, needle: [*]const u8, nlen: usize, direction: c_int) callconv(.c) ?[*]const u8 {
    if (hlen >= nlen) {
        var idx: usize = undefined;
        var idx_end: usize = undefined;
        if (direction > 0) {
            idx = 0;
            idx_end = hlen - nlen;
        } else {
            idx = hlen - nlen;
            idx_end = 0;
        }
        while (true) {
            if (std.mem.eql(u8, haystack[idx..][0..nlen], needle[0..nlen])) {
                return haystack + idx;
            }
            if (idx == idx_end) break;
            if (direction > 0) idx += 1 else idx -= 1;
        }
    }
    return null;
}

// ── seam 3: print helpers (0 raises) ──
//
// Ports mp_str_print_quoted (the escaping printer for repr() output) +
// str_print (the type slot fn). mp_str_print_json is dead under nano
// (MICROPY_PY_JSON=0) and is not ported.
//
// Variadic mp_printf format strings are bridged via dedicated shim wrappers
// per format (carryforward from W4 objtype seam 12 — Zig extern variadic
// has ABI hazards).
//
// str_print was static in the C original; here it must be a non-static
// export so the shim's MP_DEFINE_CONST_OBJ_TYPE for mp_type_str / mp_type_bytes
// can reference it by name.

// Direct vendor extern — replaces npy_str_print_str shim (1-line wrapper).
extern fn mp_print_str(print: Print, str: [*:0]const u8) callconv(.c) c_int;

// mp_print_t mirror (16B: data + print_strn fn ptr). Used to inline the
// per-format wrappers (printf_char / printf_escape_char / printf_hex_byte)
// and invoke_print_strn — avoids dragging in mp_printf's variadic ABI.
const PrintStrnFn = *const fn (?*anyopaque, [*c]const u8, usize) callconv(.c) void;
const PrintTMirror = extern struct { data: ?*anyopaque, print_strn: PrintStrnFn };
inline fn printInvokeStrn(print: Print, s: [*]const u8, len: usize) void {
    const p: *const PrintTMirror = @ptrCast(@alignCast(print));
    p.print_strn(p.data, @ptrCast(s), len);
}
inline fn printChar(print: Print, ch: c_int) void {
    const buf: [1]u8 = .{@intCast(ch & 0xff)};
    printInvokeStrn(print, &buf, 1);
}
inline fn printEscapeChar(print: Print, ch: c_int) void {
    const buf: [2]u8 = .{ '\\', @intCast(ch & 0xff) };
    printInvokeStrn(print, &buf, 2);
}
inline fn printHexByte(print: Print, b: c_uint) void {
    const hex = "0123456789abcdef";
    const v: u8 = @intCast(b & 0xff);
    const buf: [4]u8 = .{ '\\', 'x', hex[v >> 4], hex[v & 0xf] };
    printInvokeStrn(print, &buf, 4);
}

export fn mp_str_print_quoted(print: Print, str_data: [*]const u8, str_len: usize, is_bytes: bool) callconv(.c) void {
    var has_single_quote = false;
    var has_double_quote = false;
    {
        var i: usize = 0;
        while (!has_double_quote and i < str_len) : (i += 1) {
            const ch = str_data[i];
            if (ch == '\'') {
                has_single_quote = true;
            } else if (ch == '"') {
                has_double_quote = true;
            }
        }
    }
    var quote_char: c_int = '\'';
    if (has_single_quote and !has_double_quote) {
        quote_char = '"';
    }
    printChar(print, quote_char);
    var i: usize = 0;
    while (i < str_len) : (i += 1) {
        const ch = str_data[i];
        if (@as(c_int, ch) == quote_char) {
            printEscapeChar(print, quote_char);
        } else if (ch == '\\') {
            _ = mp_print_str(print, "\\\\");
        } else if (ch >= 0x20 and ch != 0x7f and (!is_bytes or ch < 0x80)) {
            // In strings, anything which is not ascii control character is
            // printed as is, this includes characters in range 0x80-0xff
            // (which can be non-Latin letters, etc.).
            printChar(print, @as(c_int, ch));
        } else if (ch == '\n') {
            _ = mp_print_str(print, "\\n");
        } else if (ch == '\r') {
            _ = mp_print_str(print, "\\r");
        } else if (ch == '\t') {
            _ = mp_print_str(print, "\\t");
        } else {
            printHexByte(print, @as(c_uint, ch));
        }
    }
    printChar(print, quote_char);
}

export fn str_print(print: Print, self_in: Obj, kind: c_int) callconv(.c) void {
    var str_len: usize = 0;
    const str_data = mp_obj_str_get_data(self_in, &str_len);
    const is_bytes: bool = mirrors.isExactType(self_in, &mp_type_bytes);
    if (kind == mp.PRINT_RAW or (kind == mp.PRINT_STR and !is_bytes)) {
        printInvokeStrn(print, str_data, str_len);
    } else {
        if (is_bytes) {
            printInvokeStrn(print, "b", 1);
        }
        mp_str_print_quoted(print, str_data, str_len, is_bytes);
    }
}

// ── seam 4: helper utilities + bad_implicit_conversion (1 NORETURN raise) ──
//
// Tightly-coupled internal helpers:
//   - bad_implicit_conversion: NORETURN TypeError ("can't convert to str
//     implicitly"). 3 in-shim callers + soon str_check_arg_type from Zig.
//     B1-mode direct longjmp via npy_pyerr_nlr_jump (runtime.zig idiom).
//   - str_check_arg_type: argument-type guard. Under nano,
//     MICROPY_PY_BUILTINS_BYTEARRAY=0 → bytearray branch dead, so the body
//     reduces to one `if (arg_type != self_type) bad_implicit_conversion(arg)`.
//   - check_is_str_or_bytes: under nano + -DNDEBUG, mp_check_self is a no-op.
//     Body becomes empty.
//   - get_substring_data: parses optional [start, end] args and computes a
//     sub-range pointer. Calls C-side str_index_to_ptr which can raise;
//     longjmp passes through this Zig frame harmlessly (no defers).
//
// TypePtr = `?*const anyopaque` opaque mp_obj_type_t pointer (lesson #11).

const TypePtr = ?*const anyopaque;

// str_index_to_ptr is ported in seam 6 as an `export fn` below.
// The forward decl here lets seam 4 (get_substring_data) reference it.

/// NX-3 N4a: polled-sentinel. Sets pending_exc + returns. Was noreturn
/// (longjmp via npy_pyerr_nlr_jump); callers now MUST check pending_exc.
export fn bad_implicit_conversion(self_in: Obj) callconv(.c) void {
    _ = self_in; // TERSE form ignores it (no varg %q substitution)
    pyerr.pending_exc = excBadImplicitConv();
}

export fn str_check_arg_type(self_type: TypePtr, arg: Obj) callconv(.c) void {
    var arg_t = mp_obj_get_type(arg);
    var self_t = self_type;
    // Normalize bytes ↔ bytearray for type compatibility (vendor objstr.c
    // lines 53-60). Was previously gated on is_full as bug-for-bug compat
    // with the frozen nano-C reference. Ungated for nano because
    // `bytearray(b"...").find(b"...")` and similar should obviously work —
    // bytes and bytearray have the same byte-semantics.
    const bytearray_type = typeBytearrayPtr();
    const bytes_type = typeBytesPtr();
    if (arg_t == bytearray_type) arg_t = bytes_type;
    if (self_t == bytearray_type) self_t = bytes_type;
    if (arg_t != self_t) {
        bad_implicit_conversion(arg);
    }
}

export fn check_is_str_or_bytes(self_in: Obj) callconv(.c) void {
    _ = self_in; // mp_check_self(assert(...)) is a no-op under nano + -DNDEBUG
}

export fn get_substring_data(obj: Obj, n_args: usize, args: [*c]const Obj, len_out: ?*usize) callconv(.c) [*]const u8 {
    var str_data: [*]const u8 = undefined;
    var str_len: usize = npyStrObjStrDataLen(obj, @ptrCast(&str_data));
    var str_ptr = str_data;
    if (n_args > 0) {
        const self_type = mp_obj_get_type(obj);
        var end_ptr: [*]const u8 = str_data + str_len;
        if (n_args > 1 and args[1] != MP_OBJ_NONE) {
            end_ptr = str_index_to_ptr(self_type, str_data, str_len, args[1], true);
        }
        if (args[0] != MP_OBJ_NONE) {
            str_ptr = str_index_to_ptr(self_type, str_data, str_len, args[0], true);
        }
        // MAX(end - str, 0): if end < str (overflow when both are pointers),
        // clamp to 0. Compute as signed isize first.
        const diff: isize = @as(isize, @intCast(@intFromPtr(end_ptr))) - @as(isize, @intCast(@intFromPtr(str_ptr)));
        str_len = if (diff > 0) @as(usize, @intCast(diff)) else 0;
    }
    if (len_out) |p| p.* = str_len;
    return str_ptr;
}

// ── seam 7: find family (1 raise) ──
//
// 8 fns: str_finder (core walker) + 4 wrappers + str_startendswith + 2
// more wrappers. Builds on already-Zig find_subbytes (seam 2) +
// get_substring_data + check_is_str_or_bytes + str_check_arg_type (seam 4).
//
// Single raise: ValueError "substring not found" when is_index=true and the
// needle is absent. Bridged via the standard convention (impl returns
// PyError!Obj, export wraps with pyerr.bridge).

extern fn mp_obj_tuple_get(self_in: Obj, len_out: *usize, items_out: *[*c]Obj) callconv(.c) void;

fn raiseSubstrNotFound() PyError!void {
    pyerr.pending_exc = excSubstrNotFound();
    return error.PyRaise;
}

fn strFinderImpl(n_args: usize, args: [*c]const Obj, direction: c_int, is_index: bool) PyError!Obj {
    const self_type = mp_obj_get_type(args[0]);
    check_is_str_or_bytes(args[0]);

    str_check_arg_type(self_type, args[1]);
    if (pyerr.pending_exc != 0) return error.PyRaise; // B2 polled-sentinel

    var haystack: [*]const u8 = undefined;
    const haystack_len = npyStrObjStrDataLen(args[0], @ptrCast(&haystack));
    var needle: [*]const u8 = undefined;
    const needle_len = npyStrObjStrDataLen(args[1], @ptrCast(&needle));

    var start: [*]const u8 = haystack;
    var end: [*]const u8 = haystack + haystack_len;
    if (n_args >= 3 and args[2] != MP_OBJ_NONE) {
        start = str_index_to_ptr(self_type, haystack, haystack_len, args[2], true);
    }
    if (n_args >= 4 and args[3] != MP_OBJ_NONE) {
        end = str_index_to_ptr(self_type, haystack, haystack_len, args[3], true);
    }

    // out_error: shared not-found block. C uses `goto out_error;` from
    // (end < start) AND from (p == NULL). We inline as a flag.
    var p: ?[*]const u8 = null;
    if (@intFromPtr(end) >= @intFromPtr(start)) {
        const span: usize = @intFromPtr(end) - @intFromPtr(start);
        p = find_subbytes(start, span, needle, needle_len, direction);
    }
    if (p == null) {
        if (is_index) {
            try raiseSubstrNotFound();
            unreachable;
        } else {
            return newSmallInt(-1);
        }
    }
    // Found. A unicode str reports the code-point index, as vendor
    // str_finder does; bytes and byte strings report the byte offset.
    if (comptime build_options.str_unicode) {
        if (self_type == typeStrPtr()) return newSmallInt(@intCast(utf8_ptr_to_index(haystack, p.?)));
    }
    const offset: isize = @as(isize, @intCast(@intFromPtr(p.?))) - @as(isize, @intCast(@intFromPtr(haystack)));
    return newSmallInt(offset);
}

export fn str_find(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, strFinderImpl(n_args, args, 1, false));
}
export fn str_rfind(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, strFinderImpl(n_args, args, -1, false));
}
export fn str_index(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, strFinderImpl(n_args, args, 1, true));
}
export fn str_rindex(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, strFinderImpl(n_args, args, -1, true));
}

fn strStartendswithImpl(n_args: usize, args: [*c]const Obj, ends_with: bool) Obj {
    var str_len: usize = 0;
    const str_ptr = get_substring_data(args[0], n_args - 2, args + 2, &str_len);
    var n_prefixes: usize = 1;
    // C: mp_obj_t *prefixes = (mp_obj_t *)&args[1]; — points at args[1]
    // as a 1-element array. We re-produce by capturing &args[1].
    var prefixes: [*c]Obj = @ptrCast(@constCast(args + 1));
    if (mirrors.isExactType(args[1], &mp_type_tuple)) {
        mp_obj_tuple_get(args[1], &n_prefixes, &prefixes);
    }
    var i: usize = 0;
    while (i < n_prefixes) : (i += 1) {
        var prefix_len: usize = 0;
        const prefix = mp_obj_str_get_data(prefixes[i], &prefix_len);
        // B2: mp_obj_str_get_data may have polled-raised TypeError.
        if (pyerr.pending_exc != 0) return 0;
        const s_offset: usize = if (ends_with) (if (str_len >= prefix_len) (str_len - prefix_len) else 0) else 0;
        if (prefix_len <= str_len) {
            const s = str_ptr + s_offset;
            // memcmp via std.mem.eql
            if (std.mem.eql(u8, s[0..prefix_len], prefix[0..prefix_len])) {
                return MP_OBJ_TRUE;
            }
        }
    }
    return MP_OBJ_FALSE;
}

export fn str_startswith(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return strStartendswithImpl(n_args, args, false);
}
export fn str_endswith(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return strStartendswithImpl(n_args, args, true);
}

// ── seam 6: mp_obj_str_binary_op + bytes_subscr (~150 LOC, indirect raises) ──
//
// mp_obj_str_binary_op handles +, *, ==, !=, <, <=, >, >=, in, % for str/bytes.
// Under nano:
//   - STR_OP_MODULO=0 → MODULO branch returns MP_OBJ_NULL early (no call to
//     str_modulo_format).
//   - SLICE=0 → bytes_subscr slice branch dead → only int-index load remains.
//   - UNICODE=0 → bytes_subscr always returns a 1-char str/bytes object.
//
// Only indirect raise: bad_implicit_conversion in the CONTAINS-on-incompatible
// branch (already-Zig from seam 4 — NORETURN longjmp passes through cleanly).
//
// vstr-build is kept C-side via shim wrappers npy_str_concat_bytes and
// npy_str_multiply_bytes (lesson #11 — vstr_t flexible-array layout).

extern fn mp_obj_get_int_maybe(arg: Obj, value: *isize) callconv(.c) bool;
extern fn mp_getiter(o: Obj, iter_buf: ?*anyopaque) callconv(.c) Obj;
extern fn mp_iternext(iter: Obj) callconv(.c) Obj;
extern fn mp_seq_cmp_bytes(op: c_uint, data1: [*]const u8, len1: usize, data2: [*]const u8, len2: usize) callconv(.c) bool;

fn raiseBadImplicitConv() PyError!void {
    pyerr.pending_exc = excBadImplicitConv();
    return error.PyRaise;
}

fn mpObjStrBinaryOpImpl(op: c_int, lhs_in: Obj, rhs_in: Obj) PyError!Obj {
    // STR_OP_MODULO (0.2): "%d %s" % (...) dispatches to str_modulo_format.
    if (op == mp.MP_BINARY_OP_MODULO) {
        // Vendor objstr.c:354-369 builds (args, n_args, dict):
        //   tuple rhs → mp_obj_tuple_get; dict = MP_OBJ_NULL.
        //   dict rhs  → dict = rhs; args = &rhs_in (single).
        //   else      → args = &rhs_in; dict = MP_OBJ_NULL.
        // The "dict = MP_OBJ_NULL" sentinel is critical: the formatter
        // checks `dict == MP_OBJ_NULL` (=0) to know whether %(key) lookups
        // are legal. Earlier port mistakenly passed mp_const_none (=6),
        // which broke dict-format mode.
        // Accept exact tuple AND tuple-compatible types (namedtuple is
        // a tuple subclass that inherits the tuple iter slot). Vendor
        // objstr.c:361. The is_full gate was bug-for-bug compat —
        // \"hello %d\" % namedtuple(1, 2) should obviously work.
        const is_tuple_like = mirrors.isExactType(rhs_in, &mp_type_tuple) or
            npyStrIsTupleCompatible(rhs_in) != 0;
        if (is_tuple_like) {
            var n: usize = 0;
            var items: [*c]Obj = undefined;
            npyStrTupleGet(rhs_in, &n, &items);
            return str_modulo_format(lhs_in, n, items, MP_OBJ_NULL);
        }
        var single: [1]Obj = .{rhs_in};
        const dict: Obj = if (mp_obj_get_type(rhs_in) == @as(?*const anyopaque, &mp_type_dict))
            rhs_in
        else
            MP_OBJ_NULL;
        return str_modulo_format(lhs_in, 1, &single, dict);
    }

    const lhs_type = mp_obj_get_type(lhs_in);
    var lhs_data: [*]const u8 = undefined;
    const lhs_len = npyStrObjStrDataLen(lhs_in, @ptrCast(&lhs_data));

    // MULTIPLY.
    if (op == mp.MP_BINARY_OP_MULTIPLY) {
        var n: isize = 0;
        if (!mp_obj_get_int_maybe(rhs_in, &n)) {
            return MP_OBJ_NULL;
        }
        if (n <= 0) {
            if (lhs_type == typeStrPtr()) {
                return newQstrObj(mp.MP_QSTR_);
            } else {
                return constEmptyBytes();
            }
        }
        return npyStrMultiplyBytes(lhs_type, lhs_data, lhs_len, n);
    }

    // Extract rhs data, falling through with rhs_data/rhs_len populated.
    var rhs_data: [*]const u8 = undefined;
    var rhs_len: usize = 0;
    if (lhs_type == mp_obj_get_type(rhs_in)) {
        rhs_len = npyStrObjStrDataLen(rhs_in, @ptrCast(&rhs_data));
    } else if (lhs_type == typeBytesPtr()) {
        if (npyStrGetBufferRead(rhs_in, @ptrCast(&rhs_data), &rhs_len) == 0) {
            return MP_OBJ_NULL;
        }
    } else {
        // LHS is str, RHS incompatible. CONTAINS must raise; others fall.
        if (op == mp.MP_BINARY_OP_CONTAINS) {
            try raiseBadImplicitConv();
            unreachable;
        }
        return MP_OBJ_NULL;
    }

    if (op == mp.MP_BINARY_OP_ADD or op == mp.MP_BINARY_OP_INPLACE_ADD) {
        if (lhs_len == 0 and mp_obj_get_type(rhs_in) == lhs_type) {
            return rhs_in;
        }
        if (rhs_len == 0) {
            return lhs_in;
        }
        return npyStrConcatBytes(lhs_type, lhs_data, lhs_len, rhs_data, rhs_len);
    } else if (op == mp.MP_BINARY_OP_CONTAINS) {
        const hit: bool = find_subbytes(lhs_data, lhs_len, rhs_data, rhs_len, 1) != null;
        return newBoolObj(hit);
    } else if (op == mp.MP_BINARY_OP_EQUAL or
        op == mp.MP_BINARY_OP_LESS or
        op == mp.MP_BINARY_OP_LESS_EQUAL or
        op == mp.MP_BINARY_OP_MORE or
        op == mp.MP_BINARY_OP_MORE_EQUAL)
    {
        const cmp: bool = mp_seq_cmp_bytes(@intCast(op), lhs_data, lhs_len, rhs_data, rhs_len);
        return newBoolObj(cmp);
    }
    return MP_OBJ_NULL;
}

export fn mp_obj_str_binary_op(op: c_int, lhs_in: Obj, rhs_in: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, mpObjStrBinaryOpImpl(op, lhs_in, rhs_in));
}

// objstrunicode.c defines its own version under MICROPY_PY_BUILTINS_STR_UNICODE
// (UTF-8 step semantics). Under nano (UNICODE=0), our byte-stepping version
// is the live one. Renamed to _nano_X + conditional @export under !is_full
// to avoid duplicate symbol against vendor.
fn _nano_str_index_to_ptr(t: TypePtr, self_data: [*]const u8, self_len: usize, index: Obj, is_slice: bool) callconv(.c) [*]const u8 {
    const index_val = mp_get_index(t, self_len, index, is_slice);
    return self_data + index_val;
}
extern fn str_index_to_ptr(t: TypePtr, self_data: [*]const u8, self_len: usize, index: Obj, is_slice: bool) callconv(.c) [*]const u8;

extern fn mp_get_index(t: TypePtr, len: usize, index: Obj, is_slice: bool) callconv(.c) usize;

// ── Full-arm str_index_to_ptr port ───────────────────────────────────
// Vendor objstrunicode.c:115. Under STR_UNICODE=1, str is UTF-8; indexing
// by code-point requires walking the byte stream. For bytes/bytearray the
// path is identical to the nano version (byte index = code-point index).
//
// Polled-sentinel raise: out-of-range raises IndexError; non-int index
// raises TypeError. Callers (get_substring_data, strFinderImpl) must
// poll pending_exc.
inline fn isUtf8Cont(b: u8) bool {
    return (b & 0xc0) == 0x80;
}
fn _full_str_index_to_ptr(t: TypePtr, self_data: [*]const u8, self_len: usize, index: Obj, is_slice: bool) callconv(.c) [*]const u8 {
    if (t == typeBytesPtr() or (typeBytearrayPtr() != null and t == typeBytearrayPtr())) {
        const index_val = mp_get_index(t, self_len, index, is_slice);
        return self_data + index_val;
    }
    // str (UTF-8): walk code-points.
    var i: isize = 0;
    if (mirrors.isSmallInt(index)) {
        i = mirrors.smallIntValue(index);
    } else if (!mp_obj_get_int_maybe(index, &i)) {
        pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_TypeError, "string indices must be integers");
        return self_data;
    }
    const top = self_data + self_len;
    if (i < 0) {
        // Vendor: `for (s = top - 1; i; --s)` with `++i` on non-cont byte.
        // We use intptr_t arithmetic to allow s to "go below" self_data
        // and still detect it without UB.
        var s_addr: isize = @as(isize, @bitCast(@intFromPtr(top))) - 1;
        const data_addr: isize = @as(isize, @bitCast(@intFromPtr(self_data)));
        while (i != 0) {
            if (s_addr < data_addr) {
                if (is_slice) return self_data;
                pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_IndexError, "string index out of range");
                return self_data;
            }
            const s_ptr: [*]const u8 = @ptrFromInt(@as(usize, @bitCast(s_addr)));
            if (!isUtf8Cont(s_ptr[0])) {
                i += 1;
            }
            s_addr -= 1;
        }
        // Vendor: ++s after the loop (we ended with one extra decrement).
        s_addr += 1;
        return @ptrFromInt(@as(usize, @bitCast(s_addr)));
    } else {
        var s = self_data;
        while (true) {
            if (@intFromPtr(s) >= @intFromPtr(top)) {
                if (is_slice) return top;
                pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_IndexError, "string index out of range");
                return self_data;
            }
            if (i == 0) return s;
            i -= 1;
            s += 1;
            while (@intFromPtr(s) < @intFromPtr(top) and isUtf8Cont(s[0])) {
                s += 1;
            }
        }
    }
}

// This is used for both bytes and 8-bit strings. Not used for unicode strings.
// Under nano SLICE=0 → slice branch dead. Under UNICODE=0, str always returns
// a 1-char str via mp_obj_new_str_via_qstr (bytes returns small-int byte).
fn bytesSubscrImpl(self_in: Obj, index: Obj, value: Obj) PyError!Obj {
    const t = mp_obj_get_type(self_in);
    var self_data: [*]const u8 = undefined;
    const self_len = npyStrObjStrDataLen(self_in, @ptrCast(&self_data));
    if (value == MP_OBJ_SENTINEL) {
        // load
        if (mirrors.isExactType(index, &mp_type_slice)) {
            return try npyStrSliceLoad(self_in, index);
        }
        const index_val = mp_get_index(t, self_len, index, false);
        if (t == typeBytesPtr()) {
            return newSmallInt(@intCast(self_data[index_val]));
        } else {
            return mp_obj_new_str_via_qstr(self_data + index_val, 1);
        }
    } else {
        return MP_OBJ_NULL;
    }
}

export fn bytes_subscr(self_in: Obj, index: Obj, value: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, bytesSubscrImpl(self_in, index, value));
}

// Vendor objstrunicode.c str_subscr: the full arm's str (STR_UNICODE=1) is
// UTF-8 and indexes count code points. An ASCII string, where the two
// agree, takes the byte path. Steps other than 1 are supported, as on the
// byte path; vendor raises NotImplementedError for them.
fn strSubscrImpl(self_in: Obj, index: Obj, value: Obj) PyError!Obj {
    if (value != MP_OBJ_SENTINEL) return MP_OBJ_NULL;
    var data: [*]const u8 = undefined;
    const len = npyStrObjStrDataLen(self_in, @ptrCast(&data));
    const n_chars = utf8Charlen(data, len);
    if (n_chars == len) return bytesSubscrImpl(self_in, index, value);
    const t = mp_obj_get_type(self_in);
    if (!mirrors.isExactType(index, &mp_type_slice)) {
        const c = str_index_to_ptr(t, data, len, index, false);
        if (pyerr.pending_exc != 0) return error.PyRaise;
        return mp_obj_new_str_via_qstr(c, @intFromPtr(utf8NextChar(c)) - @intFromPtr(c));
    }
    // Byte offset of each code point, then one past the end.
    const offs_raw = step_slice_m_malloc((n_chars + 1) * @sizeOf(usize)) orelse return error.PyRaise;
    defer step_slice_m_free(offs_raw);
    const offs: [*]usize = @ptrCast(@alignCast(offs_raw));
    var k: usize = 0;
    for (0..len) |b| {
        if (!isUtf8Cont(data[b])) {
            offs[k] = b;
            k += 1;
        }
    }
    offs[n_chars] = len;
    var slice: MpBoundSlice = undefined;
    if (ext_mp_seq_get_fast_slice_indexes(n_chars, index, &slice)) {
        const start = offs[@intCast(slice.start)];
        return mp_obj_new_str_of_type(t, data + start, offs[@intCast(slice.stop)] - start);
    }
    mp_obj_slice_indices(index, @intCast(n_chars), &slice);
    const count = sliceCount(slice);
    var n_bytes: usize = 0;
    var i = slice.start;
    for (0..count) |_| {
        const c: usize = @intCast(i);
        n_bytes += offs[c + 1] - offs[c];
        i += slice.step;
    }
    if (n_bytes == 0) return mp_obj_new_str_of_type(t, data, 0);
    const raw = step_slice_m_malloc(n_bytes) orelse return error.PyRaise;
    defer step_slice_m_free(raw);
    const buf: [*]u8 = @ptrCast(raw);
    var j: usize = 0;
    i = slice.start;
    for (0..count) |_| {
        const c: usize = @intCast(i);
        const n = offs[c + 1] - offs[c];
        @memcpy(buf[j .. j + n], data[offs[c] .. offs[c] + n]);
        j += n;
        i += slice.step;
    }
    return mp_obj_new_str_of_type(t, buf, n_bytes);
}

export fn str_subscr(self_in: Obj, index: Obj, value: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, strSubscrImpl(self_in, index, value));
}

// ── seam 12: case + char-class predicates (0 raises) ──
//
// 9 fns. unichar_* are pub exports in src/unicode.zig — taken via
// `&unichar_tolower` ptrs and passed to the dispatch fns.
//
// Under nano UNICODE=0, GET_STR_DATA_LEN yields plain bytes (each byte is
// a unichar). The unichar_* fns take u32 and return u32 (case) or bool
// (predicate); the cast u8 → u32 is widening, the result u32 → u8 needs
// `@truncate` (always safe under nano because the chars are ASCII range).
//
// vstr-build uses the [64]u8 storage pattern from objint.zig.

extern fn unichar_tolower(c: u32) callconv(.c) u32;
extern fn unichar_toupper(c: u32) callconv(.c) u32;
extern fn unichar_isspace(c: u32) callconv(.c) bool;
extern fn unichar_isalpha(c: u32) callconv(.c) bool;
extern fn unichar_isdigit(c: u32) callconv(.c) bool;
extern fn unichar_isupper(c: u32) callconv(.c) bool;
extern fn unichar_islower(c: u32) callconv(.c) bool;

const CaseFn = *const fn (u32) callconv(.c) u32;
const PredFn = *const fn (u32) callconv(.c) bool;

fn strCaseconv(op: CaseFn, self_in: Obj) Obj {
    var self_data: [*]const u8 = undefined;
    const self_len = npyStrObjStrDataLen(self_in, @ptrCast(&self_data));
    var vstr_storage: [64]u8 align(16) = undefined;
    std.debug.assert(npyStrSizeofVstr() <= vstr_storage.len);
    const data: [*c]u8 = @ptrCast(@alignCast(npyStrVstrInitLen(&vstr_storage, self_len).?));
    var i: usize = 0;
    while (i < self_len) : (i += 1) {
        data[i] = @truncate(op(self_data[i]));
    }
    return npyStrVstrToObj(mp_obj_get_type(self_in), &vstr_storage);
}

export fn str_lower(self_in: Obj) callconv(.c) Obj {
    return strCaseconv(&unichar_tolower, self_in);
}
export fn str_upper(self_in: Obj) callconv(.c) Obj {
    return strCaseconv(&unichar_toupper, self_in);
}

// "hello world".title() → "Hello World" (capitalize each word).
// A "word boundary" is any non-alpha char. Implementation mirrors
// CPython's str.title.
export fn str_title(self_in: Obj) callconv(.c) Obj {
    var self_data: [*]const u8 = undefined;
    const self_len = npyStrObjStrDataLen(self_in, @ptrCast(&self_data));
    var vstr_storage: VstrT = undefined;
    const data: [*c]u8 = @ptrCast(@alignCast(npyStrVstrInitLen(&vstr_storage, self_len).?));
    var prev_is_alpha = false;
    var i: usize = 0;
    while (i < self_len) : (i += 1) {
        const c = self_data[i];
        const is_alpha = unichar_isalpha(c);
        if (is_alpha and !prev_is_alpha) {
            data[i] = @truncate(unichar_toupper(c));
        } else if (is_alpha) {
            data[i] = @truncate(unichar_tolower(c));
        } else {
            data[i] = c;
        }
        prev_is_alpha = is_alpha;
    }
    return npyStrVstrToObj(mp_obj_get_type(self_in), &vstr_storage);
}

// "Hello world".capitalize() → "Hello world" (first char upper, rest lower)
export fn str_capitalize(self_in: Obj) callconv(.c) Obj {
    var self_data: [*]const u8 = undefined;
    const self_len = npyStrObjStrDataLen(self_in, @ptrCast(&self_data));
    var vstr_storage: VstrT = undefined;
    const data: [*c]u8 = @ptrCast(@alignCast(npyStrVstrInitLen(&vstr_storage, self_len).?));
    var i: usize = 0;
    while (i < self_len) : (i += 1) {
        data[i] = if (i == 0)
            @truncate(unichar_toupper(self_data[i]))
        else
            @truncate(unichar_tolower(self_data[i]));
    }
    return npyStrVstrToObj(mp_obj_get_type(self_in), &vstr_storage);
}

// "42".zfill(5) → "00042"; "-42".zfill(5) → "-0042". Pad with zeros on
// the left to reach `width`; if string starts with '+' or '-', the sign
// stays leftmost and padding goes between it and the rest.
export fn str_zfill(self_in: Obj, width_obj: Obj) callconv(.c) Obj {
    var self_data: [*]const u8 = undefined;
    const self_len = npyStrObjStrDataLen(self_in, @ptrCast(&self_data));
    const width: usize = @intCast(mp_obj_get_int(width_obj));
    if (width <= self_len) {
        // Already long enough — return self.
        return self_in;
    }
    const pad_count = width - self_len;
    var vstr_storage: VstrT = undefined;
    const data: [*c]u8 = @ptrCast(@alignCast(npyStrVstrInitLen(&vstr_storage, width).?));
    var sign_chars: usize = 0;
    if (self_len > 0 and (self_data[0] == '+' or self_data[0] == '-')) {
        data[0] = self_data[0];
        sign_chars = 1;
    }
    // pad zeros after the sign
    var i: usize = sign_chars;
    while (i < sign_chars + pad_count) : (i += 1) {
        data[i] = '0';
    }
    // rest of the string after the sign
    var src_i: usize = sign_chars;
    while (src_i < self_len) : (src_i += 1) {
        data[i] = self_data[src_i];
        i += 1;
    }
    return npyStrVstrToObj(mp_obj_get_type(self_in), &vstr_storage);
}

// __qstr_shadow_begin__
// MP_QSTR_isalnum
// MP_QSTR_ljust
// MP_QSTR_rjust
// MP_QSTR_capitalize
// MP_QSTR_zfill
// MP_QSTR_title
// MP_QSTR_maxsplit
// MP_QSTR_encoding
// MP_QSTR_errors
// MP_QSTR_source
// MP_QSTR___format__
// __qstr_shadow_end__

fn strUniIstype(f: PredFn, self_in: Obj) Obj {
    var self_data: [*]const u8 = undefined;
    const self_len = npyStrObjStrDataLen(self_in, @ptrCast(&self_data));
    if (self_len == 0) {
        return MP_OBJ_FALSE;
    }
    if (f != &unichar_isupper and f != &unichar_islower) {
        var i: usize = 0;
        while (i < self_len) : (i += 1) {
            if (!f(self_data[i])) {
                return MP_OBJ_FALSE;
            }
        }
    } else {
        var contains_alpha = false;
        var i: usize = 0;
        while (i < self_len) : (i += 1) {
            // Only check alphanumeric characters.
            if (unichar_isalpha(self_data[i])) {
                contains_alpha = true;
                if (!f(self_data[i])) {
                    return MP_OBJ_FALSE;
                }
            }
        }
        if (!contains_alpha) {
            return MP_OBJ_FALSE;
        }
    }
    return MP_OBJ_TRUE;
}

export fn str_isspace(self_in: Obj) callconv(.c) Obj {
    return strUniIstype(&unichar_isspace, self_in);
}
export fn str_isalpha(self_in: Obj) callconv(.c) Obj {
    return strUniIstype(&unichar_isalpha, self_in);
}
export fn str_isdigit(self_in: Obj) callconv(.c) Obj {
    return strUniIstype(&unichar_isdigit, self_in);
}
export fn str_isupper(self_in: Obj) callconv(.c) Obj {
    return strUniIstype(&unichar_isupper, self_in);
}
export fn str_islower(self_in: Obj) callconv(.c) Obj {
    return strUniIstype(&unichar_islower, self_in);
}

// CPython's str.isalnum(): True iff non-empty AND every character is
// alpha-or-digit. Vendor MP has it under MICROPY_PY_BUILTINS_STR_OP_ALNUM,
// but that's not in our nano carveout; ship a small Zig predicate.
fn unichar_isalnum_(c: u32) callconv(.c) bool {
    return unichar_isalpha(c) or unichar_isdigit(c);
}
export fn str_isalnum(self_in: Obj) callconv(.c) Obj {
    return strUniIstype(&unichar_isalnum_, self_in);
}

// ── seam 11: str_replace (0 raises live) ──
//
// Other seam-11 fns (str_count, str_partition, str_rpartition,
// str_partitioner) are all dead under nano (STR_COUNT=0, STR_PARTITION=0).
//
// 2-pass algorithm: pass 1 computes the required replaced length without
// allocating, pass 2 allocates the vstr buf and does the actual copies.
// `data == NULL` flags pass 1; on pass 1 the `if (data != NULL) memcpy()`
// branches are skipped, so only `replaced_str_index` advances. After
// pass 1 we either bail (no occurrences → return args[0]) or allocate
// vstr of that length and loop again.

extern fn mp_obj_get_int(arg: Obj) callconv(.c) isize;

export fn str_replace(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    check_is_str_or_bytes(args[0]);

    var max_rep: isize = -1;
    if (n_args == 4) {
        max_rep = mp_obj_get_int(args[3]);
        if (max_rep == 0) {
            return args[0];
        } else if (max_rep < 0) {
            max_rep = -1;
        }
    }

    const self_type = mp_obj_get_type(args[0]);
    str_check_arg_type(self_type, args[1]);
    if (pyerr.pending_exc != 0) return 0; // B2 sentinel
    str_check_arg_type(self_type, args[2]);
    if (pyerr.pending_exc != 0) return 0; // B2 sentinel

    var str_ptr: [*]const u8 = undefined;
    const str_len = npyStrObjStrDataLen(args[0], @ptrCast(&str_ptr));
    var old_ptr: [*]const u8 = undefined;
    const old_len = npyStrObjStrDataLen(args[1], @ptrCast(&old_ptr));
    var new_ptr: [*]const u8 = undefined;
    const new_len = npyStrObjStrDataLen(args[2], @ptrCast(&new_ptr));

    if (old_len > str_len) {
        return args[0];
    }

    var vstr_storage: [64]u8 align(16) = undefined;
    std.debug.assert(npyStrSizeofVstr() <= vstr_storage.len);
    var data: ?[*]u8 = null;

    while (true) {
        var replaced_str_index: usize = 0;
        var num_replacements_done: usize = 0;
        var offset_ptr: [*]const u8 = str_ptr;
        var str_len_remain: usize = str_len;
        if (old_len == 0) {
            // if old is empty, the replacement starts at index 0
            if (data) |d| @memcpy(d[0..new_len], new_ptr[0..new_len]);
            replaced_str_index += new_len;
            num_replacements_done += 1;
        }
        while (num_replacements_done != @as(usize, @bitCast(max_rep)) and str_len_remain > 0) {
            const occ_opt = find_subbytes(offset_ptr, str_len_remain, old_ptr, old_len, 1);
            if (occ_opt == null) break;
            var occ = occ_opt.?;
            if (old_len == 0) {
                occ += 1;
            }
            const pre_len: usize = @intFromPtr(occ) - @intFromPtr(offset_ptr);
            if (data) |d| @memcpy((d + replaced_str_index)[0..pre_len], offset_ptr[0..pre_len]);
            replaced_str_index += pre_len;
            if (data) |d| @memcpy((d + replaced_str_index)[0..new_len], new_ptr[0..new_len]);
            replaced_str_index += new_len;
            offset_ptr = occ + old_len;
            // str_len_remain = str + str_len - offset_ptr
            str_len_remain = (@intFromPtr(str_ptr) + str_len) - @intFromPtr(offset_ptr);
            num_replacements_done += 1;
        }

        // copy tail
        if (data) |d| @memcpy((d + replaced_str_index)[0..str_len_remain], offset_ptr[0..str_len_remain]);
        replaced_str_index += str_len_remain;

        if (data == null) {
            // pass 1
            if (num_replacements_done == 0) {
                return args[0];
            }
            data = @as([*]u8, @ptrCast(@alignCast(npyStrVstrInitLen(&vstr_storage, replaced_str_index).?)));
        } else {
            break; // pass 2 done
        }
    }

    return npyStrVstrToObj(self_type, &vstr_storage);
}

// ── seam 8: split/join/strip (4 raises live) ──
//
// 6 live fns under nano:
//   str_join          (1 raise: TypeError inconsistent-types)
//   mp_obj_str_split  (1 raise: ValueError empty separator)
//   str_rsplit        (2 raises: NotImpl rsplit(None,n), ValueError empty sep)
//   str_uni_strip + str_strip/lstrip/rstrip (0 raises)
// Dead: str_splitlines (SPLITLINES=0), str_center (CENTER=0).

fn raiseJoinType() PyError!void {
    pyerr.pending_exc = excJoinType();
    return error.PyRaise;
}
fn raiseEmptySep() PyError!void {
    pyerr.pending_exc = excEmptySep();
    return error.PyRaise;
}
fn raiseRsplitNone() PyError!void {
    pyerr.pending_exc = excRsplitNone();
    return error.PyRaise;
}

// On full, an instance of a str subclass joins as its str, as in CPython.
inline fn joinItem(o: Obj) Obj {
    return if (comptime build_options.is_full) opmethods.nativeBase(o) else o;
}

fn strJoinImpl(self_in: Obj, arg_in: Obj) PyError!Obj {
    check_is_str_or_bytes(self_in);
    const self_type = mp_obj_get_type(self_in);
    const ret_type = self_type;

    var sep_str: [*]const u8 = undefined;
    const sep_len = npyStrObjStrDataLen(self_in, @ptrCast(&sep_str));

    var seq_len: usize = 0;
    var seq_items: [*c]Obj = undefined;
    var arg = arg_in;
    if (!mirrors.isExactType(arg, &mp_type_list) and !mirrors.isExactType(arg, &mp_type_tuple)) {
        arg = npyStrListMakeNewFromArg(arg);
    }
    npyStrObjGetArray(arg, &seq_len, @ptrCast(&seq_items));

    var required_len: usize = 0;
    var i: usize = 0;
    // bytes↔bytearray normalize. bytearray is built on both arms (vendor
    // MICROPY_PY_BUILTINS_BYTEARRAY=1 on nano), so the prior is_full gate
    // here was wrong — ADR 012 D4 WRONG #2.
    const bytearray_type = typeBytearrayPtr();
    const bytes_type = typeBytesPtr();
    var norm_self_t = self_type;
    if (norm_self_t == bytearray_type) norm_self_t = bytes_type;
    while (i < seq_len) : (i += 1) {
        const item = joinItem(seq_items[i]);
        var seq_type = mp_obj_get_type(item);
        if (seq_type == bytearray_type) seq_type = bytes_type;
        if (seq_type != norm_self_t) {
            try raiseJoinType();
            unreachable;
        }
        if (i > 0) required_len += sep_len;
        required_len += npyStrObjStrLen(item);
    }

    var vstr_storage: [64]u8 align(16) = undefined;
    std.debug.assert(npyStrSizeofVstr() <= vstr_storage.len);
    const buf: [*c]u8 = @ptrCast(@alignCast(npyStrVstrInitLen(&vstr_storage, required_len).?));
    var data: [*]u8 = @ptrCast(buf);
    i = 0;
    while (i < seq_len) : (i += 1) {
        if (i > 0) {
            @memcpy(data[0..sep_len], sep_str[0..sep_len]);
            data += sep_len;
        }
        var s: [*]const u8 = undefined;
        const l = npyStrObjStrDataLen(joinItem(seq_items[i]), @ptrCast(&s));
        @memcpy(data[0..l], s[0..l]);
        data += l;
    }
    return npyStrVstrToObj(ret_type, &vstr_storage);
}

export fn str_join(self_in: Obj, arg: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, strJoinImpl(self_in, arg));
}

fn strSplitImpl(n_args: usize, args: [*c]const Obj) PyError!Obj {
    const self_type = mp_obj_get_type(args[0]);
    var splits: isize = -1;
    var sep: Obj = MP_OBJ_NONE;
    if (n_args > 1) {
        sep = args[1];
        if (n_args > 2) {
            splits = mp_obj_get_int(args[2]);
        }
    }
    const res = npyStrListNew(0);
    var s: [*]const u8 = undefined;
    const slen = npyStrObjStrDataLen(args[0], @ptrCast(&s));
    const top: [*]const u8 = s + slen;
    var p = s;

    if (sep == MP_OBJ_NONE) {
        // sep not given, separate on whitespace.
        while (@intFromPtr(p) < @intFromPtr(top) and unichar_isspace(p[0])) : (p += 1) {}
        while (@intFromPtr(p) < @intFromPtr(top) and splits != 0) {
            const start = p;
            while (@intFromPtr(p) < @intFromPtr(top) and !unichar_isspace(p[0])) : (p += 1) {}
            const span: usize = @intFromPtr(p) - @intFromPtr(start);
            _ = npyStrListAppend(res, npyStrNewStrOfType(self_type, start, span));
            if (@intFromPtr(p) >= @intFromPtr(top)) break;
            while (@intFromPtr(p) < @intFromPtr(top) and unichar_isspace(p[0])) : (p += 1) {}
            if (splits > 0) splits -= 1;
        }
        if (@intFromPtr(p) < @intFromPtr(top)) {
            const tail_len: usize = @intFromPtr(top) - @intFromPtr(p);
            _ = npyStrListAppend(res, npyStrNewStrOfType(self_type, p, tail_len));
        }
    } else {
        // sep given.
        str_check_arg_type(self_type, sep);
        if (pyerr.pending_exc != 0) return error.PyRaise; // B2
        var sep_str: [*]const u8 = undefined;
        const sep_len = npyStrObjStrDataLen(sep, @ptrCast(&sep_str));
        if (sep_len == 0) {
            try raiseEmptySep();
            unreachable;
        }
        while (true) {
            const start = p;
            while (true) {
                if (splits == 0 or @intFromPtr(p) + sep_len > @intFromPtr(top)) {
                    p = top;
                    break;
                } else if (std.mem.eql(u8, p[0..sep_len], sep_str[0..sep_len])) {
                    break;
                }
                p += 1;
            }
            const span: usize = @intFromPtr(p) - @intFromPtr(start);
            _ = npyStrListAppend(res, npyStrNewStrOfType(self_type, start, span));
            if (@intFromPtr(p) >= @intFromPtr(top)) break;
            p += sep_len;
            if (splits > 0) splits -= 1;
        }
    }
    return res;
}

export fn mp_obj_str_split(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, strSplitImpl(n_args, args));
}

fn strRsplitImpl(n_args: usize, args: [*c]const Obj) PyError!Obj {
    if (n_args < 3) {
        return try strSplitImpl(n_args, args);
    }
    const self_type = mp_obj_get_type(args[0]);
    const sep = args[1];
    var s: [*]const u8 = undefined;
    const slen = npyStrObjStrDataLen(args[0], @ptrCast(&s));

    var splits: isize = mp_obj_get_int(args[2]);
    if (splits < 0) {
        return try strSplitImpl(n_args, args);
    }
    const org_splits = splits;
    const res = npyStrListNew(splits + 1);
    const items = npyStrListItemsMut(res);
    var idx: isize = splits;

    if (sep == MP_OBJ_NONE) {
        try raiseRsplitNone();
        unreachable;
    }
    var sep_str: [*]const u8 = undefined;
    const sep_len = npyStrObjStrDataLen(sep, @ptrCast(&sep_str));
    if (sep_len == 0) {
        try raiseEmptySep();
        unreachable;
    }
    const beg = s;
    var last: [*]const u8 = s + slen;
    while (true) {
        var p: [*]const u8 = last - sep_len;
        while (true) {
            if (splits == 0 or @intFromPtr(p) < @intFromPtr(beg)) break;
            if (std.mem.eql(u8, p[0..sep_len], sep_str[0..sep_len])) break;
            p -= 1;
        }
        if (@intFromPtr(p) < @intFromPtr(beg) or splits == 0) {
            const span: usize = @intFromPtr(last) - @intFromPtr(beg);
            items[@intCast(idx)] = npyStrNewStrOfType(self_type, beg, span);
            break;
        }
        const right_off = p + sep_len;
        const right_len: usize = @intFromPtr(last) - @intFromPtr(right_off);
        items[@intCast(idx)] = npyStrNewStrOfType(self_type, right_off, right_len);
        idx -= 1;
        last = p;
        splits -= 1;
    }
    npyStrListFinalizeRsplit(res, @intCast(idx), org_splits);
    return res;
}

export fn str_rsplit(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, strRsplitImpl(n_args, args));
}

const STRIP_TYPE_L: c_int = 0;
const STRIP_TYPE_R: c_int = 1;
const STRIP_TYPE_S: c_int = 2;

fn strUniStrip(stype: c_int, n_args: usize, args: [*c]const Obj) Obj {
    check_is_str_or_bytes(args[0]);
    const self_type = mp_obj_get_type(args[0]);

    const ws: []const u8 = " \t\n\r\x0b\x0c";
    var chars_to_del: [*]const u8 = undefined;
    var chars_to_del_len: usize = 0;
    if (n_args == 1) {
        chars_to_del = ws.ptr;
        chars_to_del_len = ws.len;
    } else {
        str_check_arg_type(self_type, args[1]);
        chars_to_del_len = npyStrObjStrDataLen(args[1], @ptrCast(&chars_to_del));
    }

    var orig_str: [*]const u8 = undefined;
    const orig_str_len = npyStrObjStrDataLen(args[0], @ptrCast(&orig_str));

    var first_good_char_pos: usize = 0;
    var first_good_char_pos_set = false;
    var last_good_char_pos: usize = 0;
    var i: usize = 0;
    var delta: isize = 1;
    if (stype == STRIP_TYPE_R) {
        if (orig_str_len > 0) i = orig_str_len - 1;
        delta = -1;
    }
    var len_remaining: usize = orig_str_len;
    while (len_remaining > 0) : (len_remaining -= 1) {
        if (find_subbytes(chars_to_del, chars_to_del_len, orig_str + i, 1, 1) == null) {
            if (!first_good_char_pos_set) {
                first_good_char_pos_set = true;
                first_good_char_pos = i;
                if (stype == STRIP_TYPE_L) {
                    last_good_char_pos = orig_str_len - 1;
                    break;
                } else if (stype == STRIP_TYPE_R) {
                    first_good_char_pos = 0;
                    last_good_char_pos = i;
                    break;
                }
            }
            last_good_char_pos = i;
        }
        if (delta > 0) i +%= 1 else i -%= 1;
    }

    if (!first_good_char_pos_set) {
        if (self_type == typeStrPtr()) {
            return newQstrObj(mp.MP_QSTR_);
        } else {
            return constEmptyBytes();
        }
    }

    std.debug.assert(last_good_char_pos >= first_good_char_pos);
    const stripped_len = last_good_char_pos - first_good_char_pos + 1;
    if (stripped_len == orig_str_len) {
        std.debug.assert(first_good_char_pos == 0);
        return args[0];
    }
    return npyStrNewStrOfType(self_type, orig_str + first_good_char_pos, stripped_len);
}

export fn str_strip(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return strUniStrip(STRIP_TYPE_S, n_args, args);
}
export fn str_lstrip(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return strUniStrip(STRIP_TYPE_L, n_args, args);
}
export fn str_rstrip(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return strUniStrip(STRIP_TYPE_R, n_args, args);
}

// ── seam 5: mp_obj_str_make_new + bytes_make_new (2 raises live) ──
//
// Body branches live in shim helpers (npy_str_make_new_case1 etc.) to keep
// mp_obj_str_t struct writes + vstr setup + qstr ops shim-side. The Zig
// body is a clean dispatcher with the 2 raise sites visible.
//
// Dead under nano: CPYTHON_COMPAT (n_kw check), STR_UNICODE_CHECK (utf8),
// FULL_CHECKS (bytes-value-OOR), MICROPY_ERROR_REPORTING > TERSE (varg raise).

fn raiseNegLen() PyError!void {
    pyerr.pending_exc = excNegLen();
    return error.PyRaise;
}
fn raiseWrongArgs() PyError!void {
    pyerr.pending_exc = excWrongArgs();
    return error.PyRaise;
}
fn raiseValueOutOfRange() PyError!void {
    pyerr.pending_exc = excValueOutOfRange();
    return error.PyRaise;
}

// Direct vendor extern — replaces npy_str_arg_check_num shim.
// MP_OBJ_FUN_MAKE_SIG(n_min=0, n_max=3, takes_kw=false) = (0<<17)|(3<<1)|0 = 6.
extern fn mp_arg_check_num_sig(n_args: usize, n_kw: usize, sig: u32) callconv(.c) void;

// Inline replacement for npy_str_make_new_default_bytes shim helper.
// Mirrors the C: GET_STR_DATA_LEN+GET_STR_HASH (via MpObjStr mirror /
// qstr accessors), then qstr_find_strn → qstr obj fast path, else
// allocate a fresh MpObjStr that references the source data.
fn makeNewDefaultBytes(type_in: TypePtr, arg0: Obj) Obj {
    const sdl = strDataLen(arg0);
    var str_hash = getStrHash(arg0);
    if (str_hash == 0) {
        str_hash = qstr_compute_hash(sdl.data, sdl.len);
    }
    const q = qstr_find_strn(sdl.data, sdl.len);
    if (q != MP_QSTRnull) {
        return qstrToObj(q);
    }
    const raw = mp_obj_malloc_helper(@sizeOf(mirrors.MpObjStr), type_in);
    const o: *mirrors.MpObjStr = @ptrCast(@alignCast(raw));
    o.len = sdl.len;
    o.data = sdl.data;
    o.hash = str_hash;
    return @intFromPtr(o);
}

// Inline replacement for npy_str_bytes_make_new_str_arg shim helper.
// Same shape as makeNewDefaultBytes but skips the qstr fast path
// (bytes payload from a str arg is never folded back to a qstr).
fn bytesMakeNewStrArg(arg0: Obj) Obj {
    const sdl = strDataLen(arg0);
    var str_hash = getStrHash(arg0);
    if (str_hash == 0) {
        str_hash = qstr_compute_hash(sdl.data, sdl.len);
    }
    const raw = mp_obj_malloc_helper(@sizeOf(mirrors.MpObjStr), &mp_type_bytes);
    const o: *mirrors.MpObjStr = @ptrCast(@alignCast(raw));
    o.len = sdl.len;
    o.data = sdl.data;
    o.hash = str_hash;
    return @intFromPtr(o);
}

// vstr_t + mp_print_t layout for in-place bundle construction. vstr_t is
// 32B; mp_print_t is 16B; total 48B. We pass opaque storage to vstr_init_print
// (sets up print->data = vstr, print->print_strn = vstr_add_strn). The
// underlying mp_obj_print_helper then writes via that print bundle.
extern fn vstr_init_print(v: *anyopaque, sz: usize, print: *anyopaque) callconv(.c) void;
extern fn mp_obj_print_helper(print: ?*const anyopaque, o: Obj, kind: c_int) callconv(.c) void;
extern fn mp_get_buffer(o: Obj, bufinfo: *mp.mp_buffer_info_t, flags: c_uint) callconv(.c) bool;
extern fn vstr_add_byte(v: ?*anyopaque, b: u8) callconv(.c) void;
extern fn vstr_null_terminated_str(v: ?*anyopaque) callconv(.c) [*c]u8;
extern fn mp_print_strn(print: ?*const anyopaque, str: [*c]const u8, len: usize, flags: c_uint, fill: u8, width: c_int) callconv(.c) c_int;
extern fn mp_print_mp_int(print: ?*const anyopaque, x: Obj, base: c_uint, base_char: c_int, flags: c_uint, fill: u8, width: c_int, prec: c_int) callconv(.c) c_int;
extern fn mp_print_float(print: ?*const anyopaque, f: f64, fmt: u8, flags: c_uint, fill: u8, width: c_int, prec: c_int) callconv(.c) c_int;
extern fn mp_obj_get_float(o: Obj) callconv(.c) f64;

inline fn mpGetBufferRaise(o: Obj, bufinfo: *mp.mp_buffer_info_t, flags: c_uint) void {
    _ = mp_get_buffer(o, bufinfo, flags | mp.MP_BUFFER_RAISE_IF_UNSUPPORTED);
}

// ── vstr+mp_print bundle: storage is [vstr_t | mp_print_t] back-to-back.
// vstr_t is 32B on 64-bit (alloc+len+buf+fixed_buf — see vstr.zig), mp_print_t
// is 16B (data + print_strn fn ptr). The shim helpers npy_str_vstr_print_*
// hid this layout; with the layout proven stable we inline the offsets.
const VSP_PRINT_OFFSET: usize = 32; // sizeof(vstr_t) on 64-bit; asserted at comptime via the storage[64] sizing.
inline fn vspVstr(storage: *anyopaque) *anyopaque {
    return storage;
}
inline fn vspPrint(storage: *anyopaque) *anyopaque {
    return @ptrFromInt(@intFromPtr(storage) + VSP_PRINT_OFFSET);
}
inline fn vspInit(storage: *anyopaque, initial_alloc: usize) void {
    vstr_init_print(vspVstr(storage), initial_alloc, vspPrint(storage));
}
inline fn vspAddByte(storage: *anyopaque, b: u8) void {
    vstr_add_byte(vspVstr(storage), b);
}
inline fn vspLen(storage: *const anyopaque) usize {
    // vstr_t: { alloc, len, buf, fixed_buf } — len is the second usize field.
    const fields = @as([*]const usize, @ptrCast(@alignCast(storage)));
    return fields[1];
}
inline fn vspNulTerminated(storage: *anyopaque) [*c]const u8 {
    return vstr_null_terminated_str(vspVstr(storage));
}
inline fn vspClear(storage: *anyopaque) void {
    vstr_clear(vspVstr(storage));
}
inline fn vspToObj(type_ptr: TypePtr, storage: *anyopaque) Obj {
    return mp_obj_new_str_type_from_vstr(type_ptr, vspVstr(storage));
}
inline fn vspPrintStrn(storage: *anyopaque, s: [*c]const u8, n: usize, flags: c_uint, fill: u8, width: c_int) void {
    _ = mp_print_strn(vspPrint(storage), s, n, flags, fill, width);
}
inline fn vspPrintMpInt(storage: *anyopaque, v: Obj, base: c_uint, base_char: c_int, flags: c_uint, fill: u8, width: c_int, prec: c_int) void {
    _ = mp_print_mp_int(vspPrint(storage), v, base, base_char, flags, fill, width, prec);
}
inline fn vspPrintFloat(storage: *anyopaque, arg: Obj, fmt: u8, flags: c_uint, fill: u8, width: c_int, prec: c_int) void {
    // Vendor py/objfloat.c and py/formatfloat.c are in the nano build
    // via the float-arm carveout — ungated.
    _ = mp_print_float(vspPrint(storage), mp_obj_get_float(arg), fmt, flags, fill, width, prec);
}
inline fn vspPrintFloatPct(storage: *anyopaque, arg: Obj, flags: c_uint, fill: u8, width: c_int, prec: c_int) void {
    const v = mp_obj_get_float(arg) * 100.0;
    _ = mp_print_float(vspPrint(storage), v, 'f', flags, fill, width, prec);
}
// 'r'/'s' conv helper: print arg into a temporary bundle, then copy (with
// width/flags clamp) into the outer bundle.
inline fn vspPrintHelperIntoTemp(outer_storage: *anyopaque, arg: Obj, kind: c_int, flags: c_uint, width: c_int, prec_in: c_int) void {
    var tmp: [64]u8 align(16) = undefined;
    vspInit(@ptrCast(&tmp), 16);
    mp_obj_print_helper(@ptrCast(vspPrint(@ptrCast(&tmp))), arg, kind);
    var vlen: c_int = @intCast(vspLen(@ptrCast(&tmp)));
    var prec = prec_in;
    if (prec < 0) prec = vlen;
    if (vlen > prec) vlen = prec;
    // vstr.buf is the third pointer field of vstr_t.
    const v_buf: [*c]const u8 = @as([*c]const [*c]u8, @ptrCast(@alignCast(&tmp)))[2];
    vspPrintStrn(outer_storage, v_buf, @intCast(vlen), flags, ' ', width);
    vspClear(@ptrCast(&tmp));
}

// Inline replacement for npy_str_make_new_case1 (objstr_shim.c).
// Builds a fresh vstr+print bundle, asks the arg to print itself as str,
// and returns the new str/bytes object.
inline fn makeNewCase1(type_ptr: TypePtr, arg0: Obj) Obj {
    var vstr_buf: [32]u8 align(16) = undefined;
    var print_buf: [16]u8 align(8) = undefined;
    vstr_init_print(&vstr_buf, 16, &print_buf);
    mp_obj_print_helper(@ptrCast(&print_buf), arg0, mp.PRINT_STR);
    return mp_obj_new_str_type_from_vstr(type_ptr, &vstr_buf);
}

// Inline replacement for npy_str_make_new_default_other (objstr_shim.c).
// Pulls a read buffer from the arg (raises TypeError if it doesn't support
// the buffer protocol — longjmp under B1, harmless through Zig frames) and
// wraps it as a str. bufinfo.buf can be NULL for empty buffers (e.g.
// bytearray(b'') backed by no allocation); short-circuit to the empty qstr
// so we never feed a null ptr through mp_obj_new_str's [*]const u8 param.
inline fn makeNewDefaultOther(arg0: Obj) Obj {
    var bufinfo: mp.mp_buffer_info_t = undefined;
    mpGetBufferRaise(arg0, &bufinfo, mp.MP_BUFFER_READ);
    if (bufinfo.buf == null) return newQstrObj(mp.MP_QSTR_);
    return mp_obj_new_str(@ptrCast(bufinfo.buf), bufinfo.len);
}

fn strMakeNewImpl(type_ptr: TypePtr, n_args: usize, n_kw: usize, args: [*c]const Obj) Obj {
    mp_arg_check_num_sig(n_args, n_kw, 6);
    switch (n_args) {
        0 => return newQstrObj(mp.MP_QSTR_),
        1 => return makeNewCase1(type_ptr, args[0]),
        else => {
            // 2 or 3 args
            if (mp_obj_get_type(args[0]) == typeBytesPtr()) {
                return makeNewDefaultBytes(type_ptr, args[0]);
            } else {
                return makeNewDefaultOther(args[0]);
            }
        },
    }
}

export fn mp_obj_str_make_new(type_ptr: TypePtr, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    if (build_options.is_full and n_kw != 0) {
        var a = argcheck.kwMakeNew(&.{ mq.MP_QSTR_object, mq.MP_QSTR_encoding, mq.MP_QSTR_errors }, codec_ctor_defaults, n_args, n_kw, args) catch return mirrors.OBJ_NULL;
        return strMakeNewImpl(type_ptr, a.n, 0, &a.args);
    }
    return strMakeNewImpl(type_ptr, n_args, n_kw, args);
}

/// `str(object, encoding, errors)` and `bytes(source, encoding, errors)`.
pub const codec_ctor_defaults = [_]Obj{ mirrors.OBJ_NULL, mirrors.objFromQstr(mq.MP_QSTR_utf_hyphen_8), mirrors.OBJ_NULL };

fn bytesMakeNewImpl(n_args: usize, args: [*c]const Obj) PyError!Obj {
    if (n_args == 0) return constEmptyBytes();
    if (mp_obj_get_type(args[0]) == typeBytesPtr()) return args[0];
    if (objIsStr(args[0])) {
        if (n_args < 2 or n_args > 3) {
            try raiseWrongArgs();
            unreachable;
        }
        return bytesMakeNewStrArg(args[0]);
    }
    if (n_args > 1) {
        try raiseWrongArgs();
        unreachable;
    }
    if (mirrors.isSmallInt(args[0])) {
        const len = smallIntValue(args[0]);
        if (len < 0) {
            try raiseNegLen();
            unreachable;
        }
        // Inline replacement for npy_str_bytes_make_new_int_arg shim.
        var vstr: VstrT = undefined;
        const ulen: usize = @intCast(len);
        ext_vstr_init_len(&vstr, ulen);
        @memset(vstr.buf[0..ulen], 0);
        return mp_obj_new_bytes_from_vstr(&vstr);
    }
    // Inline replacement for npy_str_bytes_make_new_try_buffer shim.
    var bufinfo: MpBufInfo = undefined;
    if (ext_mp_get_buffer(args[0], &bufinfo, mp.MP_BUFFER_READ)) {
        return mp_obj_new_bytes(@ptrCast(bufinfo.buf), bufinfo.len);
    }
    // bytes_make_new iter path: walk iterable, accumulate bytes via vstr.
    // W6 long-tail: was a C-static helper using mp_obj_get_int (raise-able)
    // — now pure Zig. The mp_obj_get_int call still longjmps under B1
    // (passes through harmlessly).
    var vstr_storage: [64]u8 align(16) = undefined;
    std.debug.assert(npyStrSizeofVstr() <= vstr_storage.len);
    const len_in = npyStrObjLenMaybe(args[0]);
    if (len_in == MP_OBJ_NULL) {
        npyStrVstrInit(&vstr_storage, 16);
    } else {
        const len: usize = @intCast(smallIntValue(len_in));
        npyStrVstrInit(&vstr_storage, len);
    }
    var iter_buf: [64]u8 align(16) = undefined;
    const iterable = mp_getiter(args[0], &iter_buf);
    const stop = MP_OBJ_STOP_ITERATION;
    while (true) {
        const item = mp_iternext(iterable);
        if (item == stop) break;
        const val = mp_obj_get_int(item);
        // bytes value must be 0..255. Vendor objstr.c:310-314 gates this
        // on MICROPY_FULL_CHECKS; was is_full-gated on nano so values
        // outside 0..255 silently truncated. ADR 012 D4 WRONG #3 —
        // correctness wins over a meaningless size cut. If a future
        // size-minimal profile wants to drop the check, add a
        // build_options.full_checks flag then.
        if (val < 0 or val > 255) {
            try raiseValueOutOfRange();
            unreachable;
        }
        npyStrVstrAddByte(&vstr_storage, @truncate(@as(u32, @bitCast(@as(i32, @intCast(val))))));
    }
    return npyStrVstrToBytes(&vstr_storage);
}

export fn bytes_make_new(type_in: TypePtr, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    _ = type_in;
    if (build_options.is_full and n_kw != 0) {
        var a = argcheck.kwMakeNew(&.{ mq.MP_QSTR_source, mq.MP_QSTR_encoding, mq.MP_QSTR_errors }, codec_ctor_defaults, n_args, n_kw, args) catch return mirrors.OBJ_NULL;
        return pyerr.bridge(Obj, bytesMakeNewImpl(a.n, &a.args));
    }
    return pyerr.bridge(Obj, bytesMakeNewImpl(n_args, args));
}

// ── TRUE-ZIG-PORT batch (post-restructure): str.splitlines, bytes.hex,
//   bytes.fromhex, bytes.hex (as str), mp_obj_str_get_buffer ──────────
//
// Five ports landed together as a single Phase-1 batch. Algorithm bodies
// lifted verbatim from objstr_shim.c. Whole-file pace — no per-fn comments.

extern fn unichar_isxdigit(c: u32) callconv(.c) bool;
extern fn unichar_xdigit_value(c: u32) callconv(.c) u32;
extern fn mp_obj_new_list(n: usize, items: ?[*]const Obj) callconv(.c) Obj;
extern fn mp_obj_list_append(self: Obj, item: Obj) callconv(.c) Obj;

fn raiseNonHexDigit() PyError!void {
    pyerr.pending_exc = excNonHexDigit();
    return error.PyRaise;
}

fn bytesHexImpl(n_args: usize, args: [*c]const Obj, type_in: TypePtr) PyError!Obj {
    var data: [*]const u8 = undefined;
    var data_len: usize = undefined;
    if (npyStrGetBufferRaise(args[0], @ptrCast(&data), &data_len) == 0) {
        return error.PyRaise;
    }
    if (data_len == 0) return constEmptyBytes();

    var out_len: usize = data_len * 2;
    var sep_byte: u8 = 0;
    var has_sep = false;
    if (n_args > 1) {
        out_len += data_len - 1;
        var sep_data: [*]const u8 = undefined;
        _ = npyStrObjStrDataLen(args[1], @ptrCast(&sep_data));
        sep_byte = sep_data[0];
        has_sep = true;
    }

    var vstr_storage: [64]u8 align(16) = undefined;
    std.debug.assert(npyStrSizeofVstr() <= vstr_storage.len);
    const buf: [*]u8 = @ptrCast(npyStrVstrInitLen(&vstr_storage, out_len).?);

    var in: [*]const u8 = data;
    var out: [*]u8 = buf;
    var i = data_len;
    while (i > 0) : (i -= 1) {
        var d: u8 = in[0] >> 4;
        if (d > 9) d += 'a' - '9' - 1;
        out[0] = d + '0';
        out += 1;
        d = in[0] & 0xf;
        in += 1;
        if (d > 9) d += 'a' - '9' - 1;
        out[0] = d + '0';
        out += 1;
        if (has_sep and i != 1) {
            out[0] = sep_byte;
            out += 1;
        }
    }
    return npyStrVstrToObj(type_in, &vstr_storage);
}

export fn mp_obj_bytes_hex(n_args: usize, args: [*c]const Obj, type_in: TypePtr) callconv(.c) Obj {
    return pyerr.bridge(Obj, bytesHexImpl(n_args, args, type_in));
}

export fn bytes_hex_as_str(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return mp_obj_bytes_hex(n_args, args, typeStrPtr());
}

fn bytesFromHexImpl(type_in: Obj, data_obj: Obj, sep_obj: Obj) PyError!Obj {
    var data: [*]const u8 = undefined;
    var data_len: usize = undefined;
    if (npyStrGetBufferRaise(data_obj, @ptrCast(&data), &data_len) == 0) {
        return error.PyRaise;
    }
    // ADR 010 §C4 (Lane C selective) — optional `sep` arg (CPython 3.5+).
    // When sep is a single ASCII char, each pair of hex digits may be
    // separated by that char (and whitespace stays accepted as before).
    // Multi-char separators are rejected with ValueError per CPython.
    var sep_byte: i32 = -1;
    if (sep_obj != MP_OBJ_NULL) {
        var sep_data: [*]const u8 = undefined;
        var sep_len: usize = undefined;
        if (npyStrGetBufferRaise(sep_obj, @ptrCast(&sep_data), &sep_len) == 0) {
            return error.PyRaise;
        }
        if (sep_len != 1) {
            try raiseFromHexSepLen();
            unreachable;
        }
        sep_byte = sep_data[0];
    }

    var vstr_storage: [64]u8 align(16) = undefined;
    std.debug.assert(npyStrSizeofVstr() <= vstr_storage.len);
    const buf: [*]u8 = @ptrCast(npyStrVstrInitLen(&vstr_storage, data_len / 2).?);

    var in: [*]const u8 = data;
    const in_end: [*]const u8 = data + data_len;
    var out: [*]u8 = buf;
    while (@intFromPtr(in) < @intFromPtr(in_end)) {
        const ch1: u32 = in[0];
        in += 1;
        if (unichar_isspace(ch1)) continue;
        if (sep_byte >= 0 and ch1 == @as(u32, @intCast(sep_byte))) continue;
        if (@intFromPtr(in) == @intFromPtr(in_end) or !unichar_isxdigit(ch1)) {
            try raiseNonHexDigit();
            unreachable;
        }
        const ch2: u32 = in[0];
        in += 1;
        if (!unichar_isxdigit(ch2)) {
            try raiseNonHexDigit();
            unreachable;
        }
        out[0] = @truncate((unichar_xdigit_value(ch1) << 4) | unichar_xdigit_value(ch2));
        out += 1;
    }
    const final_len = @intFromPtr(out) - @intFromPtr(buf);
    npyStrVstrSetLen(&vstr_storage, final_len);
    // type_in is an Obj wrapping the type ptr — unwrap via npy_str_obj_to_void.
    return npyStrVstrToObj(@ptrFromInt(type_in), &vstr_storage);
}

fn raiseFromHexSepLen() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_ValueError, "sep must be a single character");
    return error.PyRaise;
}

// Variadic dispatcher: (cls, data) or (cls, data, sep). sep is optional.
export fn mp_obj_bytes_fromhex_var(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    const cls = args[0];
    const data = args[1];
    const sep: Obj = if (n_args >= 3) args[2] else MP_OBJ_NULL;
    return pyerr.bridge(Obj, bytesFromHexImpl(cls, data, sep));
}

export fn mp_obj_str_get_buffer(self_in: Obj, bufinfo: ?*anyopaque, flags: usize) callconv(.c) isize {
    if (@as(c_int, @intCast(flags)) != mp.MP_BUFFER_READ) return 1;
    var data: [*]const u8 = undefined;
    const len = npyStrObjStrDataLen(self_in, @ptrCast(&data));
    npyStrBufinfoSetRead(bufinfo, data, len);
    return 0;
}

export fn str_splitlines_impl(n_args: usize, pos_args: [*c]const Obj, kw_args: ?*anyopaque) callconv(.c) Obj {
    const keepends: bool = npyStrSplitlinesParseKeepends(n_args, pos_args, kw_args) != 0;
    const self_type = mp_obj_get_type(pos_args[0]);
    const res = mp_obj_new_list(0, null);
    var data: [*]const u8 = undefined;
    const data_len = npyStrObjStrDataLen(pos_args[0], @ptrCast(&data));
    const top: [*]const u8 = data + data_len;
    var s: [*]const u8 = data;
    while (@intFromPtr(s) < @intFromPtr(top)) {
        const start = s;
        var match: usize = 0;
        while (@intFromPtr(s) < @intFromPtr(top)) : (s += 1) {
            if (s[0] == '\n') {
                match = 1;
                break;
            }
            if (s[0] == '\r') {
                match = if (@intFromPtr(s + 1) < @intFromPtr(top) and s[1] == '\n') 2 else 1;
                break;
            }
        }
        var sub_len = @intFromPtr(s) - @intFromPtr(start);
        if (keepends) sub_len += match;
        _ = mp_obj_list_append(res, npyStrNewStrOfType(self_type, start, sub_len));
        s += match;
    }
    return res;
}

// ── TRUE-ZIG-PORT (post-restructure): str.partition / rpartition ────
//
// Splits a str/bytes into a 3-tuple around the first (or last, for
// rpartition) occurrence of `arg`. If `arg` not found, the head OR
// tail of the tuple is `self` and the others are empty. Lifted from
// objstr_shim.c::str_partitioner. Empty separator raises ValueError.
// The BYTEARRAY-conversion branch is preserved (BYTEARRAY=1 in nano).

extern fn mp_obj_new_tuple(n: usize, items: [*c]const Obj) callconv(.c) Obj;

fn raisePartitionEmptySep() PyError!void {
    pyerr.pending_exc = excEmptySep();
    return error.PyRaise;
}

fn partitionerImpl(self_in: Obj, arg_in: Obj, direction: c_int) PyError!Obj {
    check_is_str_or_bytes(self_in);
    const self_type = mp_obj_get_type(self_in);
    str_check_arg_type(self_type, arg_in);
    // B2 polled-sentinel: str_check_arg_type raises (via pending_exc) on
    // type mismatch but returns normally. Must propagate before the next
    // npy_str_obj_str_data_len call — otherwise we deref a non-str arg
    // (e.g. "asdf".partition(1) reads len field at small_int+16).
    if (pyerr.pending_exc != 0) return error.PyRaise;

    var str_data: [*]const u8 = undefined;
    const str_len = npyStrObjStrDataLen(self_in, @ptrCast(&str_data));
    var sep_data: [*]const u8 = undefined;
    const sep_len = npyStrObjStrDataLen(arg_in, @ptrCast(&sep_data));

    if (sep_len == 0) {
        try raisePartitionEmptySep();
        unreachable;
    }

    var result: [3]Obj = undefined;
    if (self_type == typeStrPtr()) {
        result[0] = newQstrObj(mp.MP_QSTR_);
        result[1] = newQstrObj(mp.MP_QSTR_);
        result[2] = newQstrObj(mp.MP_QSTR_);
    } else {
        result[0] = constEmptyBytes();
        result[1] = constEmptyBytes();
        result[2] = constEmptyBytes();
    }
    if (direction > 0) {
        result[0] = self_in;
    } else {
        result[2] = self_in;
    }

    // BYTEARRAY: if arg has a different type than self (e.g. bytes vs
    // bytearray separator), wrap a copy of sep in self's type.
    var arg = arg_in;
    if (mp_obj_get_type(arg_in) != self_type) {
        arg = npyStrNewStrOfType(self_type, sep_data, sep_len);
    }

    const position_ptr = find_subbytes(str_data, str_len, sep_data, sep_len, direction);
    if (position_ptr) |hit| {
        const position = @intFromPtr(hit) - @intFromPtr(str_data);
        result[0] = npyStrNewStrOfType(self_type, str_data, position);
        result[1] = arg;
        result[2] = npyStrNewStrOfType(self_type, str_data + position + sep_len, str_len - position - sep_len);
    }

    return mp_obj_new_tuple(3, &result);
}

export fn str_partition(self_in: Obj, arg: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, partitionerImpl(self_in, arg, 1));
}
export fn str_rpartition(self_in: Obj, arg: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, partitionerImpl(self_in, arg, -1));
}

// ── TRUE-ZIG-PORT (post-restructure): str.count ─────────────────────
//
// Counts non-overlapping occurrences of `needle` in `args[0]`, with
// optional [start:end] slice. Empty needle → utf8_charlen(slice)+1.
// Lifted from objstr_shim.c::str_count; algorithm preserved verbatim.
// Under nano MICROPY_PY_BUILTINS_STR_UNICODE=0 a str is bytes, and the
// utf8 helpers reduce to byte steps; under full (STR_UNICODE=1) they walk
// UTF-8 code points (src/support/unicode.zig).

extern fn utf8_next_char(s: [*]const u8) callconv(.c) [*]const u8;
extern fn utf8_ptr_to_index(s: [*]const u8, ptr: [*]const u8) callconv(.c) usize;

inline fn utf8NextChar(s: [*]const u8) [*]const u8 {
    return if (comptime build_options.str_unicode) utf8_next_char(s) else s + 1;
}
inline fn utf8Charlen(s: [*]const u8, len: usize) usize {
    return if (comptime build_options.str_unicode) utf8_charlen(s, len) else len;
}

const build_options = @import("build_options");

export fn str_count(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    const self_type = mp_obj_get_type(args[0]);
    check_is_str_or_bytes(args[0]);
    str_check_arg_type(self_type, args[1]);
    if (pyerr.pending_exc != 0) return MP_OBJ_NULL;

    var haystack: [*]const u8 = undefined;
    const haystack_len = npyStrObjStrDataLen(args[0], @ptrCast(&haystack));
    var needle: [*]const u8 = undefined;
    const needle_len = npyStrObjStrDataLen(args[1], @ptrCast(&needle));

    var start: [*]const u8 = haystack;
    var end: [*]const u8 = haystack + haystack_len;
    if (n_args >= 3 and args[2] != MP_OBJ_NONE) {
        start = str_index_to_ptr(self_type, haystack, haystack_len, args[2], true);
    }
    if (n_args >= 4 and args[3] != MP_OBJ_NONE) {
        end = str_index_to_ptr(self_type, haystack, haystack_len, args[3], true);
    }

    if (needle_len == 0) {
        const slice_len = @intFromPtr(end) - @intFromPtr(start);
        return newSmallInt(@intCast(utf8Charlen(start, slice_len) + 1));
    }

    const is_str = (self_type == typeStrPtr());
    var num: isize = 0;
    var ptr: [*]const u8 = start;
    while (@intFromPtr(ptr) + needle_len <= @intFromPtr(end)) {
        if (std.mem.eql(u8, ptr[0..needle_len], needle[0..needle_len])) {
            num += 1;
            ptr = ptr + needle_len;
        } else if (is_str) {
            ptr = utf8NextChar(ptr);
        } else {
            ptr = ptr + 1;
        }
    }
    return newSmallInt(num);
}

// ── TRUE-ZIG-PORT (post-restructure): str.center ────────────────────
//
// Pads a string to `width` with spaces, centred. If already wider,
// returns self unchanged. Lifted from objstr_shim.c::str_center. Uses
// the existing npy_str_vstr_* helpers that hide the vstr_t layout.
// mp_obj_get_int is already declared as extern at line ~579.

export fn str_center(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    const str_in = args[0];
    const width_in = args[1];
    var str_data: [*]const u8 = undefined;
    const str_len = npyStrObjStrDataLen(str_in, @ptrCast(&str_data));
    const width: usize = @intCast(mp_obj_get_int(width_in));
    // Width counts characters; the buffer counts bytes.
    const n_chars = utf8Charlen(str_data, str_len);
    if (n_chars >= width) return str_in;
    const out_len = str_len + (width - n_chars);

    // Optional fillchar (default ' '). Must be a 1-character string.
    var fill: u8 = ' ';
    if (n_args >= 3) {
        var fill_data: [*]const u8 = undefined;
        const fill_len = npyStrObjStrDataLen(args[2], @ptrCast(&fill_data));
        if (fill_len != 1) {
            // CPython raises TypeError; we go with the strip-style msg.
            pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_TypeError, "fillchar must be 1 character");
            return 0;
        }
        fill = fill_data[0];
    }

    var vstr_storage: [64]u8 align(16) = undefined;
    std.debug.assert(npyStrSizeofVstr() <= vstr_storage.len);
    const buf: [*]u8 = @ptrCast(npyStrVstrInitLen(&vstr_storage, out_len).?);
    @memset(buf[0..out_len], fill);
    const left = (width - n_chars) / 2;
    @memcpy(buf[left .. left + str_len], str_data[0..str_len]);
    return npyStrVstrToObj(mp_obj_get_type(str_in), &vstr_storage);
}

// ── str.ljust / str.rjust ──────────────────────────────────────────
//
// Pads on the right (ljust) or left (rjust) to `width` with `fillchar`
// (default space). Same shape as str_center; the difference is the
// fill goes all on one side. Mostly used by formatting and column-
// aligning code. Vendor MP doesn't expose these on nano (gated to
// MICROPY_PY_BUILTINS_STR_LJUST=full), so we ship our own.

fn strPadOneSide(n_args: usize, args: [*c]const Obj, left_padded: bool) Obj {
    const str_in = args[0];
    const width_in = args[1];
    var str_data: [*]const u8 = undefined;
    const str_len = npyStrObjStrDataLen(str_in, @ptrCast(&str_data));
    const width: usize = @intCast(mp_obj_get_int(width_in));
    // Width counts characters; the buffer counts bytes.
    const n_chars = utf8Charlen(str_data, str_len);
    if (n_chars >= width) return str_in;
    const out_len = str_len + (width - n_chars);

    var fill: u8 = ' ';
    if (n_args >= 3) {
        var fill_data: [*]const u8 = undefined;
        const fill_len = npyStrObjStrDataLen(args[2], @ptrCast(&fill_data));
        if (fill_len != 1) {
            pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_TypeError, "fillchar must be 1 character");
            return 0;
        }
        fill = fill_data[0];
    }

    var vstr_storage: [64]u8 align(16) = undefined;
    std.debug.assert(npyStrSizeofVstr() <= vstr_storage.len);
    const buf: [*]u8 = @ptrCast(npyStrVstrInitLen(&vstr_storage, out_len).?);
    @memset(buf[0..out_len], fill);
    const offset: usize = if (left_padded) width - n_chars else 0;
    @memcpy(buf[offset .. offset + str_len], str_data[0..str_len]);
    return npyStrVstrToObj(mp_obj_get_type(str_in), &vstr_storage);
}

export fn str_ljust(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return strPadOneSide(n_args, args, false);
}
export fn str_rjust(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return strPadOneSide(n_args, args, true);
}

// ── TRUE-ZIG-PORT (post-restructure): bytes.decode / str.encode ─────
//
// CPYTHON_COMPAT wrappers that insert a default "utf-8" second arg
// when the caller didn't supply one, then delegate to the matching
// _make_new (already Zig). Trivially small; ports back the 20 LOC of
// shim C that the strangler had left as verbatim relocation.
export fn bytes_decode(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    if (n_args == 1) {
        var new_args: [2]Obj = .{ args[0], newQstrObj(mp.MP_QSTR_utf_hyphen_8) };
        return mp_obj_str_make_new(typeStrPtr(), 2, 0, &new_args);
    }
    return mp_obj_str_make_new(typeStrPtr(), n_args, 0, args);
}
export fn str_encode(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    if (n_args == 1) {
        var new_args: [2]Obj = .{ args[0], newQstrObj(mp.MP_QSTR_utf_hyphen_8) };
        return bytes_make_new(null, 2, 0, &new_args);
    }
    return bytes_make_new(null, n_args, 0, args);
}

// ── seam 9/10 leaf helpers (1 raise) ──
//
// Shared between mp_obj_str_format_helper (seam 9) and str_modulo_format
// (seam 10). Under nano FLOAT=0 → arg_as_int reduces to identity and
// arg_looks_numeric reduces to arg_looks_integer. Only raise:
// terse_str_format_value_error → ValueError "bad format string" (NORETURN).
//
// str_to_int parses ascii digits and only updates *num if at least one
// digit was parsed (so callers see whether parsing happened by comparing
// the returned ptr to the input).

export fn str_to_int(str_ptr: [*c]const u8, top: [*c]const u8, num: *c_int) callconv(.c) [*c]const u8 {
    var p = str_ptr;
    if (@intFromPtr(p) < @intFromPtr(top) and p[0] >= '0' and p[0] <= '9') {
        num.* = 0;
        while (true) {
            num.* = num.* * 10 + (@as(c_int, p[0]) - '0');
            p += 1;
            if (!(@intFromPtr(p) < @intFromPtr(top) and p[0] >= '0' and p[0] <= '9')) break;
        }
    }
    return p;
}

export fn isalignment(ch: u8) callconv(.c) bool {
    return switch (ch) {
        '<', '>', '=', '^' => true,
        else => false,
    };
}

export fn istype(ch: u8) callconv(.c) bool {
    return switch (ch) {
        'b', 'c', 'd', 'e', 'E', 'f', 'F', 'g', 'G', 'n', 'o', 's', 'x', 'X', '%' => true,
        else => false,
    };
}

export fn arg_looks_integer(arg: Obj) callconv(.c) bool {
    return objIsBool(arg) or objIsInt(arg);
}

// v0.2 #5: FLOAT=1 — numeric also includes float (and complex but we
// have COMPLEX=0).
export fn arg_looks_numeric(arg: Obj) callconv(.c) bool {
    return arg_looks_integer(arg) or objIsFloat(arg);
}

// Under nano FLOAT=0 → identity (the float→int conversion branch is dead).
// `"%d" % 3.0` formats the float's int value (vendor objstr.c).
export fn arg_as_int(arg: Obj) callconv(.c) Obj {
    if (objIsFloat(arg)) return mp_obj_new_int_from_float(@as(*const mirrors.MpObjFloat, @ptrFromInt(arg)).value);
    return arg;
}
extern fn mp_obj_new_int_from_float(val: f64) callconv(.c) Obj;

/// NX-3 N4a: polled-sentinel. Sets pending_exc + returns. Was noreturn
/// (longjmp via npy_pyerr_nlr_jump); callers now MUST check pending_exc.
export fn terse_str_format_value_error() callconv(.c) void {
    pyerr.pending_exc = excBadFormatStr();
}

/// B2 Phase B-11: polled sibling for callers in PyError-returning Zig fns.
fn terseStrFormatValueErrorPolled() PyError!void {
    pyerr.pending_exc = excBadFormatStr();
    return error.PyRaise;
}

// ── seam 10: str_modulo_format (%-format, ~5 live raises) ──
//
// Walks the format pattern byte-by-byte; on '%' parses a conversion spec
// (optional dict key, flags, width, precision, type char) and emits the
// formatted argument into a shim-owned vstr+print bundle.
//
// vstr_t + mp_print_t storage is opaque ([128]u8) and bundle ops live in
// the shim (lesson #11). The Zig dispatcher owns the parser state machine
// and the 5 raise sites + 3 terse_str_format_value_error fall-through cases.
//
// Under nano (FLOAT=0): the e/E/f/F/g/G branch is dead. (TERSE): non-TERSE
// raise variants are dead — only the short-form raises are live.

fn raiseFormatNeedsDict() PyError!void {
    pyerr.pending_exc = excFormatNeedsDict();
    return error.PyRaise;
}
fn raiseMoreArgs() PyError!void {
    pyerr.pending_exc = excMoreArgs();
    return error.PyRaise;
}
fn raisePctC() PyError!void {
    pyerr.pending_exc = excPctC();
    return error.PyRaise;
}
fn raiseIntegerNeeded() PyError!void {
    pyerr.pending_exc = excIntegerNeeded();
    return error.PyRaise;
}
fn raiseExtraArgs() PyError!void {
    pyerr.pending_exc = excExtraArgs();
    return error.PyRaise;
}

fn strModuloFormatImpl(pattern: Obj, n_args: usize, args: [*c]const Obj, dict: Obj) PyError!Obj {
    check_is_str_or_bytes(pattern);
    var str: [*]const u8 = undefined;
    const len = npyStrObjStrDataLen(pattern, @ptrCast(&str));
    const is_bytes = mirrors.isExactType(pattern, &mp_type_bytes);
    var arg_i: usize = 0;

    // [vstr_t | mp_print_t] storage — 128 bytes is plenty (vstr=4×ptr, print=2×ptr).
    var vsp_storage: [128]u8 align(16) = undefined;
    // vstr_t (32B) + mp_print_t (16B) = 48B; storage is 128B.
    std.debug.assert(VSP_PRINT_OFFSET + 16 <= vsp_storage.len);
    vspInit(@ptrCast(&vsp_storage), 16);

    const top: [*]const u8 = str + len;
    var p = str;
    while (@intFromPtr(p) < @intFromPtr(top)) {
        var arg: Obj = 0;
        if (p[0] != '%') {
            vspAddByte(@ptrCast(&vsp_storage), p[0]);
            p += 1;
            continue;
        }
        p += 1;
        if (@intFromPtr(p) >= @intFromPtr(top)) {
            // incomplete_format
            try terseStrFormatValueErrorPolled();
        }
        if (p[0] == '%') {
            vspAddByte(@ptrCast(&vsp_storage), '%');
            p += 1;
            continue;
        }

        // Dictionary value lookup
        if (p[0] == '(') {
            if (dict == MP_OBJ_NULL) {
                try raiseFormatNeedsDict();
                unreachable;
            }
            arg_i = 1; // consume the single dict argument
            p += 1;
            const key = p;
            while (p[0] != ')') {
                if (@intFromPtr(p) >= @intFromPtr(top)) {
                    try terseStrFormatValueErrorPolled();
                }
                p += 1;
            }
            const key_len: usize = @intFromPtr(p) - @intFromPtr(key);
            const k_obj = mp_obj_new_str_via_qstr(key, key_len);
            arg = npyStrDictGet(dict, k_obj);
            // Missing dict key → KeyError(key), matching vendor
            // py/objstr.c:1720. Without this, the arg==0 check below
            // routes to "format string needs more arguments"
            // (TypeError), which is what our nano/full has raised
            // since day 1.
            if (arg == 0) {
                try raiseKeyErr(k_obj);
                unreachable;
            }
            p += 1;
        }

        // Parse flags.
        var flags: c_int = 0;
        var fill: c_int = ' ';
        var alt: c_int = 0;
        while (@intFromPtr(p) < @intFromPtr(top)) {
            const ch = p[0];
            if (ch == '-') {
                flags |= mp.PF_FLAG_LEFT_ADJUST;
            } else if (ch == '+') {
                flags |= mp.PF_FLAG_SHOW_SIGN;
            } else if (ch == ' ') {
                flags |= mp.PF_FLAG_SPACE_SIGN;
            } else if (ch == '#') {
                alt = mp.PF_FLAG_SHOW_PREFIX;
            } else if (ch == '0') {
                flags |= mp.PF_FLAG_PAD_AFTER_SIGN;
                fill = '0';
            } else {
                break;
            }
            p += 1;
        }

        // Parse width.
        var width: c_int = 0;
        if (@intFromPtr(p) < @intFromPtr(top)) {
            if (p[0] == '*') {
                if (arg_i >= n_args) {
                    try raiseMoreArgs();
                    unreachable;
                }
                width = @intCast(mp_obj_get_int(args[arg_i]));
                arg_i += 1;
                p += 1;
            } else {
                p = str_to_int(p, top, &width);
            }
        }

        // Parse precision.
        var prec: c_int = -1;
        if (@intFromPtr(p) < @intFromPtr(top) and p[0] == '.') {
            p += 1;
            if (@intFromPtr(p) < @intFromPtr(top)) {
                if (p[0] == '*') {
                    if (arg_i >= n_args) {
                        try raiseMoreArgs();
                        unreachable;
                    }
                    prec = @intCast(mp_obj_get_int(args[arg_i]));
                    arg_i += 1;
                    p += 1;
                } else {
                    prec = 0;
                    p = str_to_int(p, top, &prec);
                }
            }
        }

        if (@intFromPtr(p) >= @intFromPtr(top)) {
            try terseStrFormatValueErrorPolled();
        }

        // Tuple value lookup (when not a dict key).
        if (arg == 0) {
            if (arg_i >= n_args) {
                try raiseMoreArgs();
                unreachable;
            }
            arg = args[arg_i];
            arg_i += 1;
        }

        const conv = p[0];
        // On full, an instance of an int, float or str subclass formats as
        // its native value, except under %s, %r and %a, which call its
        // own __str__ or __repr__.
        if (comptime build_options.is_full) {
            if (conv != 's' and conv != 'r' and conv != 'a') arg = opmethods.nativeBase(arg);
        }
        switch (conv) {
            'c' => {
                if (objIsStr(arg)) {
                    var slen: usize = 0;
                    var sdata: [*]const u8 = undefined;
                    sdata = @ptrCast(mp_obj_str_get_data(arg, &slen));
                    if (slen != 1) {
                        try raisePctC();
                        unreachable;
                    }
                    vspPrintStrn(@ptrCast(&vsp_storage), sdata, 1, @intCast(flags), ' ', width);
                } else if (arg_looks_integer(arg)) {
                    const ch: u8 = @truncate(@as(u32, @bitCast(@as(i32, @intCast(mp_obj_get_int(arg))))));
                    var ch_arr: [1]u8 = .{ch};
                    vspPrintStrn(@ptrCast(&vsp_storage), &ch_arr, 1, @intCast(flags), ' ', width);
                } else {
                    try raiseIntegerNeeded();
                    unreachable;
                }
            },
            'd', 'i', 'u' => {
                vspPrintMpInt(@ptrCast(&vsp_storage), arg_as_int(arg), 10, 'a', @intCast(flags), @intCast(fill), width, prec);
            },
            'o' => {
                if (alt != 0) {
                    flags |= mp.PF_FLAG_SHOW_PREFIX | mp.PF_FLAG_SHOW_OCTAL_LETTER;
                }
                vspPrintMpInt(@ptrCast(&vsp_storage), arg, 8, 'a', @intCast(flags), @intCast(fill), width, prec);
            },
            'r', 's' => {
                var print_kind: c_int = if (conv == 'r') mp.PRINT_REPR else mp.PRINT_STR;
                if (print_kind == mp.PRINT_STR and is_bytes and mp_obj_get_type(arg) == typeBytesPtr()) {
                    // b"%s" % b"1" → bytes arg printed undecorated.
                    print_kind = mp.PRINT_RAW;
                }
                vspPrintHelperIntoTemp(@ptrCast(&vsp_storage), arg, print_kind, @intCast(flags), width, prec);
            },
            'X', 'x' => {
                // base_char: 'X' → 'A' (uppercase), 'x' → 'a' (lowercase).
                const base_char: c_int = if (conv == 'X') 'A' else 'a';
                vspPrintMpInt(@ptrCast(&vsp_storage), arg, 16, base_char, @intCast(flags | alt), @intCast(fill), width, prec);
            },
            'e', 'E', 'f', 'F', 'g', 'G' => {
                // Float conversion specifiers — vendor py/objfloat.c is now
                // in the float-arm carveout so vspPrintFloat works.
                vspPrintFloat(@ptrCast(&vsp_storage), arg, @intCast(conv), @intCast(flags), @intCast(fill), width, prec);
            },
            else => {
                try terseStrFormatValueErrorPolled();
            },
        }
        p += 1;
    }

    if (dict == MP_OBJ_NULL and arg_i != n_args) {
        try raiseExtraArgs();
        unreachable;
    }

    const result_type = if (is_bytes) typeBytesPtr() else typeStrPtr();
    return vspToObj(result_type, @ptrCast(&vsp_storage));
}

export fn str_modulo_format(pattern: Obj, n_args: usize, args: [*c]const Obj, dict: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, strModuloFormatImpl(pattern, n_args, args, dict));
}

// ── seam 9: mp_obj_str_format + mp_obj_str_format_helper (17 live raises) ──
//
// The big str.format machinery. The helper is recursive (parsing format_spec
// recursively invokes the helper on the nested portion). Each invocation
// has its own stack-local [128]u8 vstr+print storage; the result vstr is
// read back from this storage by the caller.
//
// Under nano: FLOAT=0 (e/E/f/F/g/G branch dead, % type dead), TERSE
// (non-TERSE varg/long-form raises dead). Live raises:
//   - 13 terse_str_format_value_error fall-throughs (various malformed input)
//   - 2 IndexError "tuple index out of range" (auto + digit field name)
//   - 1 KeyError (kwargs lookup miss)
//   - 1 NotImplementedError "attributes not supported"

const Kwargs = ?*anyopaque; // mp_map_t*

fn raiseIndexOor() PyError!void {
    pyerr.pending_exc = excIndexOOR();
    return error.PyRaise;
}
fn raiseKeyErr(key: Obj) PyError!void {
    pyerr.pending_exc = excKeyErr(key);
    return error.PyRaise;
}
fn raiseAttrsNotSupp() PyError!void {
    pyerr.pending_exc = excAttrsNotSupp();
    return error.PyRaise;
}

// Writes the formatted result into out_storage (a [128]u8 vstr+print bundle).
// Recursion: when a format_spec is encountered, recurses with its own inner
// storage on the stack.
fn formatHelperInto(
    str_in: [*]const u8,
    top: [*]const u8,
    arg_i: *c_int,
    n_args: usize,
    args: [*c]const Obj,
    kwargs: Kwargs,
    out_storage: *[128]u8,
) PyError!void {
    vspInit(@ptrCast(out_storage), 16);

    var p = str_in;
    while (@intFromPtr(p) < @intFromPtr(top)) {
        // Handle '}' — '}}' → literal '}', otherwise raise.
        if (p[0] == '}') {
            p += 1;
            if (@intFromPtr(p) < @intFromPtr(top) and p[0] == '}') {
                vspAddByte(@ptrCast(out_storage), '}');
                p += 1;
                continue;
            }
            try terseStrFormatValueErrorPolled();
        }
        if (p[0] != '{') {
            vspAddByte(@ptrCast(out_storage), p[0]);
            p += 1;
            continue;
        }

        p += 1;
        if (@intFromPtr(p) < @intFromPtr(top) and p[0] == '{') {
            vspAddByte(@ptrCast(out_storage), '{');
            p += 1;
            continue;
        }

        // Parse: [field_name] ["!" conv] [":" format_spec] "}"
        var field_name: ?[*]const u8 = null;
        var field_name_top: ?[*]const u8 = null;
        var conversion: u8 = 0;
        var format_spec: ?[*]const u8 = null;

        if (@intFromPtr(p) < @intFromPtr(top) and p[0] != '}' and p[0] != '!' and p[0] != ':') {
            field_name = p;
            while (@intFromPtr(p) < @intFromPtr(top) and p[0] != '}' and p[0] != '!' and p[0] != ':') {
                p += 1;
            }
            field_name_top = p;
        }

        if (@intFromPtr(p) < @intFromPtr(top) and p[0] == '!') {
            p += 1;
            if (@intFromPtr(p) < @intFromPtr(top) and (p[0] == 'r' or p[0] == 's')) {
                conversion = p[0];
                p += 1;
            } else {
                try terseStrFormatValueErrorPolled();
            }
        }

        if (@intFromPtr(p) < @intFromPtr(top) and p[0] == ':') {
            p += 1;
            if (p[0] != '}') {
                format_spec = p;
                var nest: c_int = 1;
                while (@intFromPtr(p) < @intFromPtr(top)) {
                    if (p[0] == '{') {
                        nest += 1;
                    } else if (p[0] == '}') {
                        nest -= 1;
                        if (nest == 0) break;
                    }
                    p += 1;
                }
            }
        }
        if (@intFromPtr(p) >= @intFromPtr(top)) {
            try terseStrFormatValueErrorPolled();
        }
        if (p[0] != '}') {
            try terseStrFormatValueErrorPolled();
        }

        var arg: Obj = MP_OBJ_NONE;

        if (field_name) |fname_start| {
            var fname = fname_start;
            const fname_top = field_name_top.?;
            var index: c_int = 0;
            if (unichar_isdigit(fname[0])) {
                if (arg_i.* > 0) {
                    try terseStrFormatValueErrorPolled();
                }
                fname = str_to_int(fname, fname_top, &index);
                if (@as(usize, @intCast(index)) >= n_args - 1) {
                    try raiseIndexOor();
                    unreachable;
                }
                arg = args[@as(usize, @intCast(index)) + 1];
                arg_i.* = -1;
            } else {
                var lookup = fname;
                while (@intFromPtr(lookup) < @intFromPtr(fname_top) and lookup[0] != '.' and lookup[0] != '[') {
                    lookup += 1;
                }
                const fname_len: usize = @intFromPtr(lookup) - @intFromPtr(fname);
                const field_q = mp_obj_new_str_via_qstr(fname, fname_len);
                fname = lookup;
                const looked_up = npyStrKwargsLookup(kwargs, field_q);
                if (looked_up == 0) {
                    try raiseKeyErr(field_q);
                    unreachable;
                }
                arg = looked_up;
            }
            if (@intFromPtr(fname) < @intFromPtr(fname_top)) {
                try raiseAttrsNotSupp();
                unreachable;
            }
        } else {
            if (arg_i.* < 0) {
                try terseStrFormatValueErrorPolled();
            }
            if (@as(usize, @intCast(arg_i.*)) >= n_args - 1) {
                try raiseIndexOor();
                unreachable;
            }
            arg = args[@as(usize, @intCast(arg_i.*)) + 1];
            arg_i.* += 1;
        }

        if (format_spec == null and conversion == 0) {
            conversion = 's';
        }
        if (conversion != 0) {
            const print_kind: c_int = if (conversion == 's') mp.PRINT_STR else mp.PRINT_REPR;
            // Inline replacement for npy_str_print_to_new_str shim helper.
            var conv_vstr: [32]u8 align(16) = undefined;
            var conv_print: [16]u8 align(8) = undefined;
            vstr_init_print(&conv_vstr, 16, &conv_print);
            mp_obj_print_helper(@ptrCast(&conv_print), arg, print_kind);
            arg = mp_obj_new_str_type_from_vstr(&mp_type_str, &conv_vstr);
        }

        var fill: u8 = 0;
        var alignc: u8 = 0;
        var width: c_int = -1;
        var precision: c_int = -1;
        var conv_type: u8 = 0;
        var flags: c_uint = 0;

        if (format_spec) |fspec_start| {
            // mp_cstack_check() is a static-inline no-op under nano
            // (MICROPY_STACK_CHECK=0); the wrapper shim is retired.
            var inner_storage: [128]u8 align(16) = undefined;
            try formatHelperInto(fspec_start, p, arg_i, n_args, args, kwargs, &inner_storage);
            // Pointers into the inner vstr buf.
            const s_buf = vspNulTerminated(@ptrCast(&inner_storage));
            const s_len = vspLen(@ptrCast(&inner_storage));
            var s_ptr = s_buf;
            const stop_ptr: [*]const u8 = s_buf + s_len;
            if (comptime build_options.is_full) {
                // A Python `__format__` gets the spec, and its result is
                // printed as it is. An instance of an int, float or str
                // subclass is formatted as its native value.
                var dest: [3]Obj = .{ MP_OBJ_NULL, MP_OBJ_NULL, MP_OBJ_NULL };
                mp_load_method_maybe(arg, mq.MP_QSTR___format__, &dest);
                if (dest[0] != MP_OBJ_NULL) {
                    dest[2] = mp_obj_new_str(s_buf, s_len);
                    arg = mp_call_method_n_kw(1, 0, &dest);
                    if (pyerr.pending_exc != 0) return error.PyRaise;
                    s_ptr = stop_ptr; // the spec is used up
                } else {
                    arg = opmethods.nativeBase(arg);
                }
            }

            // [[fill]align][sign][#][0][width][,_][.precision][type]
            if (isalignment(s_ptr[0])) {
                alignc = s_ptr[0];
                s_ptr += 1;
            } else if (s_ptr[0] != 0 and isalignment(s_ptr[1])) {
                fill = s_ptr[0];
                alignc = s_ptr[1];
                s_ptr += 2;
            }
            if (s_ptr[0] == '+' or s_ptr[0] == '-' or s_ptr[0] == ' ') {
                if (s_ptr[0] == '+') {
                    flags |= @intCast(mp.PF_FLAG_SHOW_SIGN);
                } else if (s_ptr[0] == ' ') {
                    flags |= @intCast(mp.PF_FLAG_SPACE_SIGN);
                }
                s_ptr += 1;
            }
            if (s_ptr[0] == '#') {
                flags |= @intCast(mp.PF_FLAG_SHOW_PREFIX);
                s_ptr += 1;
            }
            if (s_ptr[0] == '0') {
                if (alignc == 0 and arg_looks_numeric(arg)) {
                    alignc = '=';
                }
                if (fill == 0) fill = '0';
            }
            s_ptr = str_to_int(s_ptr, stop_ptr, &width);
            if (s_ptr[0] == ',' or s_ptr[0] == '_') {
                flags |= @as(c_uint, s_ptr[0]) << @intCast(mp.PF_FLAG_SEP_POS);
                s_ptr += 1;
            }
            if (s_ptr[0] == '.') {
                s_ptr += 1;
                s_ptr = str_to_int(s_ptr, stop_ptr, &precision);
            }
            if (istype(s_ptr[0])) {
                conv_type = s_ptr[0];
                s_ptr += 1;
            }
            if (s_ptr[0] != 0) {
                try terseStrFormatValueErrorPolled();
            }
            vspClear(@ptrCast(&inner_storage));
        }

        if (alignc == 0) {
            alignc = if (arg_looks_numeric(arg)) '>' else '<';
        }
        if (fill == 0) fill = ' ';

        if ((flags & (@as(c_uint, @intCast(mp.PF_FLAG_SHOW_SIGN)) | @as(c_uint, @intCast(mp.PF_FLAG_SPACE_SIGN)))) != 0) {
            if (conv_type == 's' or conv_type == 'c') {
                try terseStrFormatValueErrorPolled();
            }
        }

        switch (alignc) {
            '<' => flags |= @intCast(mp.PF_FLAG_LEFT_ADJUST),
            '=' => flags |= @intCast(mp.PF_FLAG_PAD_AFTER_SIGN),
            '^' => flags |= @intCast(mp.PF_FLAG_CENTER_ADJUST),
            else => {},
        }

        if (arg_looks_integer(arg)) {
            switch (conv_type) {
                'b' => {
                    vspPrintMpInt(@ptrCast(out_storage), arg, 2, 'a', @intCast(flags), fill, width, 0);
                    p += 1;
                    continue;
                },
                'c' => {
                    const ch: u8 = @truncate(@as(u32, @bitCast(@as(i32, @intCast(mp_obj_get_int(arg))))));
                    var ch_arr: [1]u8 = .{ch};
                    vspPrintStrn(@ptrCast(out_storage), &ch_arr, 1, @intCast(flags), fill, width);
                    p += 1;
                    continue;
                },
                0, 'n', 'd' => {
                    vspPrintMpInt(@ptrCast(out_storage), arg, 10, 'a', @intCast(flags), fill, width, 0);
                    p += 1;
                    continue;
                },
                'o' => {
                    if ((flags & @as(c_uint, @intCast(mp.PF_FLAG_SHOW_PREFIX))) != 0) {
                        flags |= @intCast(mp.PF_FLAG_SHOW_OCTAL_LETTER);
                    }
                    vspPrintMpInt(@ptrCast(out_storage), arg, 8, 'a', @intCast(flags), fill, width, 0);
                    p += 1;
                    continue;
                },
                'X', 'x' => {
                    const base_char: c_int = if (conv_type == 'X') 'A' else 'a';
                    vspPrintMpInt(@ptrCast(out_storage), arg, 16, base_char, @intCast(flags), fill, width, 0);
                    p += 1;
                    continue;
                },
                'e', 'E', 'f', 'F', 'g', 'G', '%' => {
                    // Fall through to numeric branch — float branch handles these
                    // (or its TERSE-fall-through for FLOAT=0).
                },
                else => {
                    try terseStrFormatValueErrorPolled();
                },
            }
        }

        if (arg_looks_numeric(arg)) {
            // v0.2 #5: FLOAT=1 — float/integer format specs e/E/f/F/g/G/%.
            if (conv_type == 0) conv_type = 'g';
            if (conv_type == 'n') conv_type = 'g';
            switch (conv_type) {
                'e', 'E', 'f', 'F', 'g', 'G' => {
                    vspPrintFloat(@ptrCast(out_storage), arg, conv_type, @intCast(flags), fill, width, precision);
                    p += 1;
                    continue;
                },
                '%' => {
                    const pct_flags = flags | @as(c_uint, @intCast(mp.PF_FLAG_ADD_PERCENT));
                    // Get float value, multiply by 100, format as 'f'.
                    const fval_obj = arg;
                    // Use the print helper to format `val * 100` as 'f'.
                    // We need a tiny helper to do mul-by-100; for simplicity
                    // delegate to npy_str_print_float by passing a transient obj
                    // — easiest: do the *100 in shim. Pass a sentinel via type.
                    vspPrintFloatPct(@ptrCast(out_storage), fval_obj, @intCast(pct_flags), fill, width, precision);
                    p += 1;
                    continue;
                },
                else => {
                    try terseStrFormatValueErrorPolled();
                },
            }
        } else {
            if (alignc == '=') {
                try terseStrFormatValueErrorPolled();
            }
            switch (conv_type) {
                0, 's' => {
                    var slen: usize = 0;
                    const s_data = mp_obj_str_get_data(arg, &slen);
                    if (precision < 0) precision = @intCast(slen);
                    if (slen > @as(usize, @intCast(precision))) slen = @intCast(precision);
                    vspPrintStrn(@ptrCast(out_storage), s_data, slen, @intCast(flags), fill, width);
                },
                else => {
                    try terseStrFormatValueErrorPolled();
                },
            }
        }
        p += 1;
    }
}

fn mpObjStrFormatImpl(n_args: usize, args: [*c]const Obj, kwargs: Kwargs) PyError!Obj {
    check_is_str_or_bytes(args[0]);
    var str_data: [*]const u8 = undefined;
    const str_len = npyStrObjStrDataLen(args[0], @ptrCast(&str_data));
    var arg_i: c_int = 0;
    var storage: [128]u8 align(16) = undefined;
    try formatHelperInto(str_data, str_data + str_len, &arg_i, n_args, args, kwargs, &storage);
    return vspToObj(mp_obj_get_type(args[0]), @ptrCast(&storage));
}

export fn mp_obj_str_format(n_args: usize, args: [*c]const Obj, kwargs: Kwargs) callconv(.c) Obj {
    return pyerr.bridge(Obj, mpObjStrFormatImpl(n_args, args, kwargs));
}

// ── seam 14: str/bytes constructors (0 raises) ──────────────────────────
//
// W5-deferred ctor cohort: low-level allocators + qstr lookup wrappers that
// the rest of the runtime calls when building str/bytes objects.
//
// Enabled by MpObjStr mirror (mp_mirrors.zig) — no shim accessors needed
// for the layout, just direct vendor symbols for m_malloc/qstr ops and
// extern ROM &mp_type_str / &mp_type_bytes type pointers.
// (mirrors imported at top of file.)

extern fn m_malloc(num_bytes: usize) callconv(.c) ?*anyopaque;
extern fn mp_obj_malloc_helper(num_bytes: usize, type_in: ?*const anyopaque) callconv(.c) ?*anyopaque;
extern fn qstr_compute_hash(data: [*]const u8, len: usize) callconv(.c) usize;
extern fn qstr_from_strn(data: [*]const u8, len: usize) callconv(.c) usize;
extern fn qstr_find_strn(data: [*]const u8, len: usize) callconv(.c) usize;
// mp_type_str / mp_type_bytes defined as pub export below (see ROM section).

// REPR_A: MP_OBJ_NEW_QSTR(q) = (q << 3) | 2  — see py/obj.h.
inline fn qstrToObj(q: usize) Obj {
    return (q << 3) | 2;
}

export fn mp_obj_str_set_data(str: *mirrors.MpObjStr, data: [*]const u8, len: usize) callconv(.c) void {
    str.data = data;
    str.len = len;
    str.hash = qstr_compute_hash(data, len);
}

export fn mp_obj_new_str_copy(type_in: TypePtr, data: ?[*]const u8, len: usize) callconv(.c) Obj {
    const raw = mp_obj_malloc_helper(@sizeOf(mirrors.MpObjStr), type_in);
    const o: *mirrors.MpObjStr = @ptrCast(@alignCast(raw));
    o.len = len;
    if (data) |d| {
        o.hash = qstr_compute_hash(d, len);
        const p: [*]u8 = @ptrCast(m_malloc(len + 1));
        o.data = p;
        @memcpy(p[0..len], d[0..len]);
        p[len] = 0;
    }
    return @intFromPtr(o);
}

export fn mp_obj_new_str_via_qstr(data: [*]const u8, len: usize) callconv(.c) Obj {
    return qstrToObj(qstr_from_strn(data, len));
}

export fn mp_obj_new_bytes(data: [*]const u8, len: usize) callconv(.c) Obj {
    return mp_obj_new_str_copy(&mp_type_bytes, data, len);
}

extern fn qstr_data(q: usize, len_out: *usize) callconv(.c) [*]const u8;
extern fn mp_obj_new_bytearray(n: usize, items: ?*const anyopaque) callconv(.c) Obj;
extern const mp_type_bytearray: anyopaque;
extern const mp_type_dict: anyopaque;
extern const mp_type_tuple: anyopaque;
extern const mp_type_list: anyopaque;
extern const mp_type_slice: anyopaque;
extern const mp_type_int: anyopaque;
extern const mp_type_float: anyopaque;
extern fn mp_obj_get_type(o: Obj) callconv(.c) ?*const anyopaque;

// Inline replacements for npy_str_obj_is_{str,bool,int,float} + is_str_or_bytes.
// Macros from vendor py/obj.h:982-988; REPR_A immediate-obj layout (mp_mirrors).
inline fn objIsStr(o: Obj) bool {
    return mirrors.isQstr(o) or mirrors.isExactType(o, &mp_type_str);
}
inline fn objIsBool(o: Obj) bool {
    return o == mirrors.OBJ_TRUE or o == mirrors.OBJ_FALSE;
}
inline fn objIsInt(o: Obj) bool {
    return mirrors.isSmallInt(o) or mirrors.isExactType(o, &mp_type_int);
}
inline fn objIsFloat(o: Obj) bool {
    return mirrors.isExactType(o, &mp_type_float);
}
inline fn objIsStrOrBytes(o: Obj) bool {
    if (mirrors.isQstr(o)) return true;
    if (!mirrors.isObj(o)) return false;
    const t = mirrors.MpObjType.fromPtr(mirrors.objBaseType(o));
    return t.getSlot(.binary_op) == @as(?*const anyopaque, @ptrCast(&mp_obj_str_binary_op));
}

const MP_QSTRnull: u16 = 0;

// REPR_A: mp_obj_is_qstr(o) ⇔ (o & 7) == 2; MP_OBJ_QSTR_VALUE(o) = o >> 3.
inline fn objIsQstr(o: Obj) bool {
    return (o & 7) == 2;
}

const StrDataLen = struct { data: [*]const u8, len: usize };

inline fn strDataLen(o: Obj) StrDataLen {
    if (objIsQstr(o)) {
        var len: usize = 0;
        const data = qstr_data(@intCast(o >> 3), &len);
        return .{ .data = data, .len = len };
    }
    const s = mirrors.MpObjStr.fromObj(o);
    return .{ .data = s.data, .len = s.len };
}

export fn mp_obj_new_str(data: [*]const u8, len: usize) callconv(.c) Obj {
    const q = qstr_find_strn(data, len);
    if (q != MP_QSTRnull) {
        return qstrToObj(q);
    }
    return mp_obj_new_str_copy(&mp_type_str, data, len);
}

export fn mp_obj_new_str_from_cstr(str: [*:0]const u8) callconv(.c) Obj {
    var n: usize = 0;
    while (str[n] != 0) : (n += 1) {}
    return mp_obj_new_str(@ptrCast(str), n);
}

export fn mp_obj_new_str_of_type(type_in: TypePtr, data: [*]const u8, len: usize) callconv(.c) Obj {
    if (type_in == @as(TypePtr, &mp_type_str)) {
        return mp_obj_new_str(data, len);
    }
    if (type_in == @as(TypePtr, &mp_type_bytearray)) {
        return mp_obj_new_bytearray(len, data);
    }
    return mp_obj_new_bytes(data, len);
}

export fn mp_obj_str_intern(str: Obj) callconv(.c) Obj {
    const sdl = strDataLen(str);
    return mp_obj_new_str_via_qstr(sdl.data, sdl.len);
}

export fn mp_obj_str_intern_checked(obj: Obj) callconv(.c) Obj {
    var len: usize = 0;
    const data = mp_obj_str_get_data(obj, &len);
    if (data == null) {
        // Bad input → pending_exc set by mp_obj_str_get_data's polled raise.
        // Match the C path qstr_from_strn(NULL, 0) = MP_QSTRnull = empty qstr.
        return qstrToObj(MP_QSTRnull);
    }
    return mp_obj_new_str_via_qstr(@ptrCast(data), len);
}

// ── seam 14b: vstr-consuming str ctors + str equality ─────────────────
//
// mp_obj_new_str_type_from_vstr was static in C — many shim helpers
// (npy_str_concat_bytes / multiply_bytes / vstr_to_obj / vstr_print_to_obj
// and a few internal vstr-build paths) call it. The Zig port keeps the
// same name, becomes externally visible, and the shim's static decl is
// retired in favor of an extern forward decl.
//
// vstr_t layout is accessed via the existing npy_vstr_* shim helpers
// (lesson #11 — sizeof != 24, resolved empirically; see vstr.zig).

extern fn m_realloc(ptr: ?*anyopaque, new_num_bytes: usize) callconv(.c) ?*anyopaque;
extern fn vstr_clear(vstr: ?*anyopaque) callconv(.c) void;
extern fn mp_obj_new_bytearray_by_ref(n: usize, items: ?*anyopaque) callconv(.c) Obj;
extern fn qstr_hash(q: usize) callconv(.c) usize;
extern fn npy_vstr_get_alloc(v: ?*const anyopaque) callconv(.c) usize;
extern fn npy_vstr_get_len(v: ?*const anyopaque) callconv(.c) usize;
extern fn npy_vstr_get_buf(v: ?*const anyopaque) callconv(.c) [*c]u8;
extern fn npy_vstr_set_alloc(v: ?*anyopaque, a: usize) callconv(.c) void;
extern fn npy_vstr_set_buf(v: ?*anyopaque, b: [*c]u8) callconv(.c) void;

inline fn getStrHash(o: Obj) usize {
    if (objIsQstr(o)) return qstr_hash(@intCast(o >> 3));
    return mirrors.MpObjStr.fromObj(o).hash;
}

export fn mp_obj_new_str_type_from_vstr(type_in: TypePtr, vstr: ?*anyopaque) callconv(.c) Obj {
    const v_alloc = npy_vstr_get_alloc(vstr);
    const v_len = npy_vstr_get_len(vstr);
    const v_buf = npy_vstr_get_buf(vstr);

    if (type_in == @as(TypePtr, &mp_type_str)) {
        const q = qstr_find_strn(@ptrCast(v_buf), v_len);
        if (q != MP_QSTRnull) {
            vstr_clear(vstr);
            npy_vstr_set_alloc(vstr, 0);
            return qstrToObj(q);
        }
    }

    var data: [*c]u8 = undefined;
    if (v_len + 1 == v_alloc) {
        data = v_buf;
    } else {
        data = @ptrCast(m_realloc(v_buf, v_len + 1));
    }
    data[v_len] = 0;
    npy_vstr_set_buf(vstr, null);
    npy_vstr_set_alloc(vstr, 0);

    if (type_in == @as(TypePtr, &mp_type_bytearray)) {
        return mp_obj_new_bytearray_by_ref(v_len, data);
    }
    const raw = mp_obj_malloc_helper(@sizeOf(mirrors.MpObjStr), type_in);
    const o: *mirrors.MpObjStr = @ptrCast(@alignCast(raw));
    o.len = v_len;
    o.hash = qstr_compute_hash(@ptrCast(data), v_len);
    o.data = @ptrCast(data);
    return @intFromPtr(o);
}

export fn mp_obj_new_str_from_vstr(vstr: ?*anyopaque) callconv(.c) Obj {
    return mp_obj_new_str_type_from_vstr(&mp_type_str, vstr);
}

// mp_obj_new_str_from_utf8_vstr — vendor obj.h:1006 declares this when
// STR_UNICODE && STR_UNICODE_CHECK are both 1 (full's case); when either
// is 0 (nano's case) it's a macro alias to mp_obj_new_str_from_vstr.
// Vendor objstr.c:2297-2299 implements it as a one-liner that bypasses
// the utf8 check — identical to mp_obj_new_str_from_vstr above. Provide
// the symbol under STR_UNICODE so vendor extmod/modre.c links.
comptime {
    if (build_options.str_unicode) {
        @export(&mp_obj_new_str_from_vstr, .{ .name = "mp_obj_new_str_from_utf8_vstr" });
    }
}

export fn mp_obj_new_bytes_from_vstr(vstr: ?*anyopaque) callconv(.c) Obj {
    return mp_obj_new_str_type_from_vstr(&mp_type_bytes, vstr);
}

export fn mp_obj_str_equal(s1: Obj, s2: Obj) callconv(.c) bool {
    if (objIsQstr(s1) and objIsQstr(s2)) return s1 == s2;
    const h1 = getStrHash(s1);
    const h2 = getStrHash(s2);
    if (h1 != 0 and h2 != 0 and h1 != h2) return false;
    const sdl1 = strDataLen(s1);
    const sdl2 = strDataLen(s2);
    if (sdl1.len != sdl2.len) return false;
    return std.mem.eql(u8, sdl1.data[0..sdl1.len], sdl2.data[0..sdl2.len]);
}

// ── seam 14c: str accessor getters ─────────────────────────────────────
//
// Three accessors that resolve an mp_obj_t into a qstr / cstr / data+len.
// On bad input (non-str-or-bytes) two of them set pending_exc via the
// polled bad_implicit_conversion sibling; mp_obj_str_get_str keeps the
// noreturn variant (its callers depend on the no-bad-return contract).
//
// is_str_or_bytes routes through a new shim helper (npy_str_is_str_or_bytes)
// since the C macro reads the type-slot tables via MP_OBJ_TYPE_GET_SLOT_OR_NULL.

export fn mp_obj_str_get_qstr(self_in: Obj) callconv(.c) usize {
    if (objIsQstr(self_in)) {
        return @intCast(self_in >> 3);
    }
    if (mp_obj_get_type(self_in) == @as(?*const anyopaque, &mp_type_str)) {
        const self = mirrors.MpObjStr.fromObj(self_in);
        return qstr_from_strn(self.data, self.len);
    }
    bad_implicit_conversion(self_in);
    return MP_QSTRnull;
}

/// NX-3 N4a: polled-sentinel. Returns null + sets pending_exc on bad input
/// (non-str-or-bytes). Was noreturn (longjmp via bad_implicit_conversion);
/// callers MUST check the returned ptr for null AND check pending_exc.
export fn mp_obj_str_get_str(self_in: Obj) callconv(.c) ?[*]const u8 {
    if (objIsStrOrBytes(self_in)) {
        const sdl = strDataLen(self_in);
        return sdl.data;
    }
    bad_implicit_conversion(self_in);
    return null;
}

export fn mp_obj_str_get_data(self_in: Obj, len_out: *usize) callconv(.c) [*c]const u8 {
    if (objIsStrOrBytes(self_in)) {
        const sdl = strDataLen(self_in);
        len_out.* = sdl.len;
        return sdl.data;
    }
    // Bad input: polled raise (sets pending_exc); caller MUST check NULL.
    bad_implicit_conversion(self_in);
    len_out.* = 0;
    return null;
}

const std = @import("std");

// ── ROM: fn-obj defs + locals_dicts + mp_type_str / mp_type_bytes ────
//
// 22 MP_DEFINE_CONST_FUN_OBJ_* + 2 MP_DEFINE_CONST_OBJ_TYPE + 5
// MP_DEFINE_CONST_DICT_WITH_SIZE + 1 MP_DEFINE_CONST_CLASSMETHOD_OBJ
// + mp_const_empty_bytes_obj relocated VERBATIM from objstr_shim.c.
//
// All Zig-side function bodies (str_join, str_split, etc.) are already
// exported above; this block just constructs the ROM fun-obj wrappers
// + locals tables + type ROMs that reference them.

const types_mod = @import("../../mp_type_roms.zig");

extern const mp_type_type: anyopaque;
extern const mp_type_fun_builtin_1: anyopaque;
extern const mp_type_fun_builtin_2: anyopaque;
extern const mp_type_fun_builtin_var: anyopaque;
extern const mp_type_classmethod: anyopaque;
// mp_type_dict already extern'd earlier in this file (line ~2221).

const mq = @cImport({
    @cInclude("py/qstr.h");
});
const Qstr = usize;

// External array methods used in the shared locals_table.
extern const mp_obj_array_append_obj: mirrors.MpObjFunBuiltinFixed;
extern const mp_obj_array_extend_obj: mirrors.MpObjFunBuiltinFixed;

// ── fn-obj exports ────────────────────────────────────────────────────
pub export const str_join_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&str_join),
};
const split_kw = [_]usize{ 0, mq.MP_QSTR_sep, mq.MP_QSTR_maxsplit };
const split_defaults = [_]Obj{ mirrors.OBJ_NULL, mirrors.OBJ_NONE, mirrors.newSmallInt(-1) };
pub export const str_split_obj = argcheck.kwVar(1, &split_kw, split_defaults, &mp_obj_str_split);
pub export const str_rsplit_obj = argcheck.kwVar(1, &split_kw, split_defaults, &str_rsplit);
pub export const str_find_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(2, 4, false),
    .fun = @ptrCast(&str_find),
};
pub export const str_rfind_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(2, 4, false),
    .fun = @ptrCast(&str_rfind),
};
pub export const str_index_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(2, 4, false),
    .fun = @ptrCast(&str_index),
};
pub export const str_rindex_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(2, 4, false),
    .fun = @ptrCast(&str_rindex),
};
pub export const str_startswith_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(2, 4, false),
    .fun = @ptrCast(&str_startswith),
};
pub export const str_endswith_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(2, 4, false),
    .fun = @ptrCast(&str_endswith),
};
pub export const str_strip_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(1, 2, false),
    .fun = @ptrCast(&str_strip),
};
pub export const str_lstrip_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(1, 2, false),
    .fun = @ptrCast(&str_lstrip),
};
pub export const str_rstrip_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(1, 2, false),
    .fun = @ptrCast(&str_rstrip),
};
pub export const str_ljust_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(2, 3, false),
    .fun = @ptrCast(&str_ljust),
};
pub export const str_rjust_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(2, 3, false),
    .fun = @ptrCast(&str_rjust),
};
pub export const str_center_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(2, 3, false),
    .fun = @ptrCast(&str_center),
};
pub export const str_format_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(1, 0xffff, true), // KW
    .fun = @ptrCast(&mp_obj_str_format),
};
pub export const str_replace_obj = argcheck.kwVar(3, &.{ 0, 0, 0, mq.MP_QSTR_count }, .{ mirrors.OBJ_NULL, mirrors.OBJ_NULL, mirrors.OBJ_NULL, mirrors.newSmallInt(-1) }, &str_replace);
pub export const str_count_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(2, 4, false),
    .fun = @ptrCast(&str_count),
};
pub export const str_partition_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&str_partition),
};
pub export const str_rpartition_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&str_rpartition),
};
pub export const str_capitalize_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_1 },
    .fun = @ptrCast(&str_capitalize),
};
pub export const str_title_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_1 },
    .fun = @ptrCast(&str_title),
};
pub export const str_zfill_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&str_zfill),
};
pub export const str_lower_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_1 },
    .fun = @ptrCast(&str_lower),
};
pub export const str_upper_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_1 },
    .fun = @ptrCast(&str_upper),
};
pub export const str_isspace_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_1 },
    .fun = @ptrCast(&str_isspace),
};
pub export const str_isalpha_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_1 },
    .fun = @ptrCast(&str_isalpha),
};
pub export const str_isdigit_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_1 },
    .fun = @ptrCast(&str_isdigit),
};
pub export const str_isupper_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_1 },
    .fun = @ptrCast(&str_isupper),
};
pub export const str_islower_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_1 },
    .fun = @ptrCast(&str_islower),
};
pub export const str_isalnum_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_1 },
    .fun = @ptrCast(&str_isalnum),
};
const codec_kw = [_]usize{ 0, mq.MP_QSTR_encoding, mq.MP_QSTR_errors };
const codec_defaults = [_]Obj{ mirrors.OBJ_NULL, mirrors.objFromQstr(mq.MP_QSTR_utf_hyphen_8), mirrors.OBJ_NULL };
pub export const bytes_decode_obj = argcheck.kwVar(1, &codec_kw, codec_defaults, &bytes_decode);
pub export const str_encode_obj = argcheck.kwVar(1, &codec_kw, codec_defaults, &str_encode);
pub export const str_splitlines_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(1, 0xffff, true), // KW
    .fun = @ptrCast(&str_splitlines_impl),
};
// bytes_hex_as_str_obj + bytes_fromhex_obj + bytes_fromhex_classmethod_obj
// were `static` in the C shim — keep them file-local here.
const bytes_hex_as_str_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(1, 2, false),
    .fun = @ptrCast(&bytes_hex_as_str),
};
// ADR 010 §C4 — variadic now (1..2 args after cls); takes optional sep.
const bytes_fromhex_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(2, 3, false),
    .fun = @ptrCast(&mp_obj_bytes_fromhex_var),
};
const bytes_fromhex_classmethod_obj: mirrors.MpObjStaticClassMethod = .{
    .base = .{ .type = &mp_type_classmethod },
    .fun = @ptrCast(&bytes_fromhex_obj),
};

// ── shared locals table for str/bytes/bytearray/array.array/memoryview ─
const RomEntry = extern struct {
    key: Obj,
    value: *const anyopaque,
};

// All five gating flags are =1 under nano (per port/mpconfigport.h).
// Layout (must match original C order):
//   [0..2)   array/bytearray: append, extend
//   [2..4)   bytes hex: hex, fromhex
//   [4..5)   cpython compat: decode
//   [5..N-1) shared str/bytes methods (find..rstrip, format, replace,
//             count, partition, rpartition, center, lower..islower)
//   [N-1]    cpython compat: encode
const array_bytearray_str_bytes_locals_table = [_]RomEntry{
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_append)), .value = @ptrCast(&mp_obj_array_append_obj) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_extend)), .value = @ptrCast(&mp_obj_array_extend_obj) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_hex)), .value = @ptrCast(&bytes_hex_as_str_obj) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_fromhex)), .value = @ptrCast(&bytes_fromhex_classmethod_obj) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_decode)), .value = @ptrCast(&bytes_decode_obj) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_find)), .value = @ptrCast(&str_find_obj) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_rfind)), .value = @ptrCast(&str_rfind_obj) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_index)), .value = @ptrCast(&str_index_obj) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_rindex)), .value = @ptrCast(&str_rindex_obj) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_join)), .value = @ptrCast(&str_join_obj) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_split)), .value = @ptrCast(&str_split_obj) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_splitlines)), .value = @ptrCast(&str_splitlines_obj) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_rsplit)), .value = @ptrCast(&str_rsplit_obj) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_startswith)), .value = @ptrCast(&str_startswith_obj) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_endswith)), .value = @ptrCast(&str_endswith_obj) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_strip)), .value = @ptrCast(&str_strip_obj) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_lstrip)), .value = @ptrCast(&str_lstrip_obj) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_rstrip)), .value = @ptrCast(&str_rstrip_obj) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_format)), .value = @ptrCast(&str_format_obj) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_replace)), .value = @ptrCast(&str_replace_obj) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_count)), .value = @ptrCast(&str_count_obj) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_partition)), .value = @ptrCast(&str_partition_obj) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_rpartition)), .value = @ptrCast(&str_rpartition_obj) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_center)), .value = @ptrCast(&str_center_obj) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_ljust)), .value = @ptrCast(&str_ljust_obj) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_rjust)), .value = @ptrCast(&str_rjust_obj) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_lower)), .value = @ptrCast(&str_lower_obj) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_upper)), .value = @ptrCast(&str_upper_obj) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_capitalize)), .value = @ptrCast(&str_capitalize_obj) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_title)), .value = @ptrCast(&str_title_obj) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_zfill)), .value = @ptrCast(&str_zfill_obj) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_isspace)), .value = @ptrCast(&str_isspace_obj) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_isalpha)), .value = @ptrCast(&str_isalpha_obj) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_isdigit)), .value = @ptrCast(&str_isdigit_obj) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_isupper)), .value = @ptrCast(&str_isupper_obj) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_islower)), .value = @ptrCast(&str_islower_obj) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_isalnum)), .value = @ptrCast(&str_isalnum_obj) },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mq.MP_QSTR_encode)), .value = @ptrCast(&str_encode_obj) },
};
const TABLE_ENTRIES_ARRAY: usize = 2; // append, extend
const TABLE_ENTRIES_HEX: usize = 2; // hex, fromhex
const TABLE_ENTRIES_COMPAT: usize = 1; // decode (and the trailing encode entry)

// Helper to build a const MpObjDict from a slice of the shared table.
inline fn makeDict(comptime start: usize, comptime n: usize) mirrors.MpObjDict {
    return .{
        .base = .{ .type = &mp_type_dict },
        .map = .{
            .bits = .{
                .all_keys_are_qstrs = 1,
                .is_fixed = 1,
                .is_ordered = 1,
                .used = @intCast(n),
            },
            .alloc = n,
            .table = @ptrCast(@constCast(array_bytearray_str_bytes_locals_table[start..].ptr)),
        },
    };
}

// mp_obj_str_locals_dict: skip array+hex+leading-compat (decode), include
// the find..islower body + trailing encode entry.
pub export const mp_obj_str_locals_dict: mirrors.MpObjDict = makeDict(
    TABLE_ENTRIES_ARRAY + TABLE_ENTRIES_HEX + TABLE_ENTRIES_COMPAT,
    array_bytearray_str_bytes_locals_table.len - (TABLE_ENTRIES_ARRAY + TABLE_ENTRIES_HEX + TABLE_ENTRIES_COMPAT),
);
// mp_obj_bytes_locals_dict: include hex + decode + body, drop trailing encode.
pub export const mp_obj_bytes_locals_dict: mirrors.MpObjDict = makeDict(
    TABLE_ENTRIES_ARRAY,
    array_bytearray_str_bytes_locals_table.len - (TABLE_ENTRIES_ARRAY + TABLE_ENTRIES_COMPAT),
);
// mp_obj_bytearray_locals_dict: full table sans trailing encode.
pub export const mp_obj_bytearray_locals_dict: mirrors.MpObjDict = makeDict(
    0,
    array_bytearray_str_bytes_locals_table.len - TABLE_ENTRIES_COMPAT,
);
// mp_obj_array_locals_dict: array.array gets only append/extend.
pub export const mp_obj_array_locals_dict: mirrors.MpObjDict = makeDict(0, TABLE_ENTRIES_ARRAY);
// mp_obj_memoryview_locals_dict: just the "hex" entry.
pub export const mp_obj_memoryview_locals_dict: mirrors.MpObjDict = makeDict(TABLE_ENTRIES_ARRAY, 1);

// ── str_unary_op (full-only) ──────────────────────────────────────────
// Vendor py/objstrunicode.c:101 uni_unary_op. Under STR_UNICODE=1 (full)
// the type's unary_op slot handles LEN by returning utf8_charlen, and
// BOOL by str_len!=0. Under nano STR_UNICODE=0 → no unary_op slot,
// len(str) is satisfied by the byte fast-path in obj.zig:isStrOrBytesForLen.
extern fn utf8_charlen(s: [*]const u8, n: usize) callconv(.c) usize;
fn str_unary_op_full(op: c_int, self_in: Obj) callconv(.c) Obj {
    var str_len: usize = undefined;
    const str_data = mp_obj_str_get_data(self_in, &str_len);
    switch (op) {
        mp.MP_UNARY_OP_BOOL => return newBoolObj(str_len != 0),
        mp.MP_UNARY_OP_LEN => return newSmallInt(@intCast(utf8_charlen(str_data, str_len))),
        else => return MP_OBJ_NULL,
    }
}

// ── mp_type_str + mp_type_bytes ───────────────────────────────────────
// Slot indices follow vendor MP_DEFINE_CONST_OBJ_TYPE_NARGS_7 semantics:
// f1=make_new, f2=print, f3=binary_op, f4=subscr, f5=iter, f6=buffer, f7=locals_dict.
// Under full, f3=unary_op slips in; the remaining slots shift by one.
pub export const mp_type_str: types_mod.MpObjTypeFull = if (build_options.str_unicode) .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = 0x0000, // MP_TYPE_FLAG_NONE
        .name = mq.MP_QSTR_str,
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
        @ptrCast(&mp_obj_str_make_new),
        @ptrCast(&str_print),
        @ptrCast(&str_unary_op_full),
        @ptrCast(&mp_obj_str_binary_op),
        @ptrCast(&str_subscr),
        @ptrCast(&mp_obj_new_str_iterator),
        @ptrCast(&mp_obj_str_get_buffer),
        @ptrCast(&mp_obj_str_locals_dict),
        null,
        null,
        null,
    },
} else .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = 0x0000, // MP_TYPE_FLAG_NONE
        .name = mq.MP_QSTR_str,
        .slot_index_make_new = 1,
        .slot_index_print = 2,
        .slot_index_call = 0,
        .slot_index_unary_op = 0,
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
        @ptrCast(&mp_obj_str_make_new),
        @ptrCast(&str_print),
        @ptrCast(&mp_obj_str_binary_op),
        @ptrCast(&bytes_subscr),
        @ptrCast(&mp_obj_new_str_iterator),
        @ptrCast(&mp_obj_str_get_buffer),
        @ptrCast(&mp_obj_str_locals_dict),
        null,
        null,
        null,
        null,
    },
};

pub export const mp_type_bytes: types_mod.MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = 0x0000,
        .name = mq.MP_QSTR_bytes,
        .slot_index_make_new = 1,
        .slot_index_print = 2,
        .slot_index_call = 0,
        .slot_index_unary_op = 0,
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
        @ptrCast(&bytes_make_new),
        @ptrCast(&str_print),
        @ptrCast(&mp_obj_str_binary_op),
        @ptrCast(&bytes_subscr),
        @ptrCast(&mp_obj_new_bytes_iterator),
        @ptrCast(&mp_obj_str_get_buffer),
        @ptrCast(&mp_obj_bytes_locals_dict),
        null,
        null,
        null,
        null,
    },
};

// The zero-length bytes object, with data that includes a null-terminating byte.
pub export const mp_const_empty_bytes_obj: mirrors.MpObjStr = .{
    .base = .{ .type = &mp_type_bytes },
    .hash = 0,
    .len = 0,
    .data = @ptrCast(&[_]u8{0}),
};

comptime {
    _ = &str_it_iternext;
    _ = &mp_obj_new_str_iterator;
    _ = &bytes_it_iternext;
    _ = &mp_obj_new_bytes_iterator;
    _ = &find_subbytes;
    _ = &mp_str_print_quoted;
    _ = &str_print;
    _ = &bad_implicit_conversion;
    _ = &str_check_arg_type;
    _ = &check_is_str_or_bytes;
    _ = &get_substring_data;
    _ = &str_find;
    _ = &str_rfind;
    _ = &str_index;
    _ = &str_rindex;
    _ = &str_startswith;
    _ = &str_endswith;
    _ = &mp_obj_str_binary_op;
    _ = &_nano_str_index_to_ptr;
    _ = &_full_str_index_to_ptr;
    if (!build_options.str_unicode) {
        @export(&_nano_str_index_to_ptr, .{ .name = "str_index_to_ptr" });
    } else {
        @export(&_full_str_index_to_ptr, .{ .name = "str_index_to_ptr" });
    }
    _ = &bytes_subscr;
    _ = &str_lower;
    _ = &str_upper;
    _ = &str_isspace;
    _ = &str_isalpha;
    _ = &str_isdigit;
    _ = &str_isupper;
    _ = &str_islower;
    _ = &str_replace;
    _ = &str_join;
    _ = &mp_obj_str_split;
    _ = &str_rsplit;
    _ = &str_strip;
    _ = &str_lstrip;
    _ = &str_rstrip;
    _ = &mp_obj_str_make_new;
    _ = &bytes_make_new;
    _ = &bytes_decode;
    _ = &str_encode;
    _ = &str_count;
    _ = &str_center;
    _ = &str_ljust;
    _ = &str_rjust;
    _ = &str_partition;
    _ = &str_rpartition;
    _ = &mp_obj_bytes_hex;
    _ = &bytes_hex_as_str;
    _ = &mp_obj_bytes_fromhex_var;
    _ = &mp_obj_str_get_buffer;
    _ = &str_splitlines_impl;
    _ = &str_to_int;
    _ = &isalignment;
    _ = &istype;
    _ = &arg_looks_integer;
    _ = &arg_looks_numeric;
    _ = &arg_as_int;
    _ = &terse_str_format_value_error;
    _ = &str_modulo_format;
    _ = &mp_obj_str_format;
    _ = &mp_obj_str_set_data;
    _ = &mp_obj_new_str_copy;
    _ = &mp_obj_new_str_via_qstr;
    _ = &mp_obj_new_bytes;
    _ = &mp_obj_new_str;
    _ = &mp_obj_new_str_from_cstr;
    _ = &mp_obj_new_str_of_type;
    _ = &mp_obj_str_intern;
    _ = &mp_obj_str_intern_checked;
    _ = &mp_obj_new_str_type_from_vstr;
    _ = &mp_obj_new_str_from_vstr;
    _ = &mp_obj_new_bytes_from_vstr;
    _ = &mp_obj_str_equal;
    _ = &mp_obj_str_get_qstr;
    _ = &mp_obj_str_get_str;
    _ = &mp_obj_str_get_data;
    // ROM block (fun-objs + locals_dicts + mp_type_str/bytes).
    _ = &mp_type_str;
    _ = &mp_type_bytes;
    _ = &mp_const_empty_bytes_obj;
    _ = &mp_obj_str_locals_dict;
    _ = &mp_obj_bytes_locals_dict;
    _ = &mp_obj_bytearray_locals_dict;
    _ = &mp_obj_array_locals_dict;
    _ = &mp_obj_memoryview_locals_dict;
    _ = &str_join_obj;
    _ = &str_split_obj;
    _ = &str_rsplit_obj;
    _ = &str_find_obj;
    _ = &str_rfind_obj;
    _ = &str_index_obj;
    _ = &str_rindex_obj;
    _ = &str_startswith_obj;
    _ = &str_endswith_obj;
    _ = &str_strip_obj;
    _ = &str_lstrip_obj;
    _ = &str_rstrip_obj;
    _ = &str_center_obj;
    _ = &str_ljust_obj;
    _ = &str_rjust_obj;
    _ = &str_format_obj;
    _ = &str_replace_obj;
    _ = &str_count_obj;
    _ = &str_partition_obj;
    _ = &str_rpartition_obj;
    _ = &str_lower_obj;
    _ = &str_upper_obj;
    _ = &str_isspace_obj;
    _ = &str_isalpha_obj;
    _ = &str_isdigit_obj;
    _ = &str_isupper_obj;
    _ = &str_islower_obj;
    _ = &str_isalnum_obj;
    _ = &bytes_decode_obj;
    _ = &str_encode_obj;
    _ = &str_splitlines_obj;
}
