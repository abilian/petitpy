//! petitpy — Zig port of py/objexcept.c.
//!
//! Includes the easy half (predicates + accessors) lifted previously, plus
//! the previously-VERBATIM B2 half: the static `mp_type_BaseException` ROM
//! + ~25 derived exception type ROMs, `mp_obj_new_exception_msg_varg`/
//! `_vlist`, and the small allocator helpers that used to be `npy_objexcept_*`
//! shim wrappers.
//!
//! Config gates:
//!   MICROPY_ENABLE_EMERGENCY_EXCEPTION_BUF = 0 (nano + full) → emergency-buf
//!     fallback paths collapse to "return NULL" / "no init"; helpers shrink to
//!     plain m_new_obj_maybe + empty-tuple-singleton fallback.
//!   MICROPY_ROM_TEXT_COMPRESSION = 0 → no MP_IS_COMPRESSED_ROM_STRING / decompress.
//!   MICROPY_ERROR_REPORTING != NONE (default DETAILED) → msg/vlist live.
//!   MICROPY_PY_ASYNC_AWAIT: 0 in nano (StopAsyncIteration absent), 1 in full.
//!   MICROPY_EMIT_NATIVE = 0 (both) → ViperTypeError absent.
//!   MICROPY_PY_BUILTINS_STR_UNICODE: 0 in nano, 1 in full → UnicodeError under full.

const std = @import("std");

const mp = @cImport({
    @cInclude("py/obj.h");
    @cInclude("py/objexcept.h");
    @cInclude("py/runtime.h");
});
const mirrors = @import("../../mp_mirrors.zig");
const state = @import("../../runtime/mpstate.zig");

const Obj = usize;
const TypePtr = ?*const anyopaque;
const MP_OBJ_NULL: Obj = 0;
// REPR_A immediate-obj encoding: mp_const_none = (0 << 3) | 6 = 6.
const MP_OBJ_NONE: Obj = 6;

// ── Externs (C ABI surface used by the body) ──────────────────────────
extern fn mp_obj_get_type(o: Obj) callconv(.c) TypePtr;
extern fn mp_obj_is_subclass_fast(object: Obj, classinfo: Obj) callconv(.c) bool;
extern fn mp_arg_check_num_sig(n_args: usize, n_kw: usize, sig: u32) callconv(.c) void;
extern fn mp_print_str(print: ?*const anyopaque, str: [*:0]const u8) callconv(.c) c_int;
extern fn mp_printf(print: ?*const anyopaque, fmt: [*:0]const u8, ...) callconv(.c) c_int;
// mp_obj_new_exception_msg_varg / _vlist are in
// src/objects/strings/va_ops.c (see that file for why the va_list
// surface moved to C on aarch64-Linux). mp_vprintf too.
extern fn mp_obj_print_helper(print: ?*const anyopaque, o: Obj, kind: c_int) callconv(.c) void;
extern fn mp_obj_tuple_print(print: ?*const anyopaque, o: Obj, kind: c_int) callconv(.c) void;
extern fn qstr_str(q: usize) callconv(.c) [*:0]const u8;
// Matches moderrno.zig:165 (returns usize, not u16).
extern fn mp_errno_to_str(o: Obj) callconv(.c) usize;
extern fn qstr_compute_hash(data: [*]const u8, len: usize) callconv(.c) usize;
extern fn m_malloc_maybe(num_bytes: usize) callconv(.c) ?*anyopaque;
extern fn m_realloc_maybe(ptr: ?*anyopaque, new_num_bytes: usize, allow_move: bool) callconv(.c) ?*anyopaque;
extern const mp_type_type: anyopaque;
extern const mp_type_tuple: anyopaque;
extern const mp_type_str: anyopaque;
extern const mp_const_empty_tuple_obj: anyopaque;

inline fn typeAsObj(t: TypePtr) Obj {
    return @intFromPtr(t);
}

/// Comptime helper: look up a #define from the @cImported `mp` namespace and
/// coerce its value (which @cImport may translate as comptime_int / c_int /
/// bool depending on the surrounding #define expression) to a Zig bool.
inline fn configFlag(comptime name: []const u8) bool {
    if (!@hasDecl(mp, name)) return false;
    const v = @field(mp, name);
    return switch (@typeInfo(@TypeOf(v))) {
        .bool => v,
        .int, .comptime_int => v != 0,
        else => @compileError("unexpected config flag type"),
    };
}

/// Resolve native exception payload: native subclasses store data inline,
/// Python subclasses keep it in `instance->subobj[0]`.
fn getNativeException(self_in: Obj) *mirrors.MpObjException {
    if (isNativeExceptionInstance(self_in)) {
        return mirrors.MpObjException.fromObj(self_in);
    }
    return mirrors.MpObjException.fromObj(mirrors.MpObjInstance.fromObj(self_in).subobjPtr()[0]);
}

inline fn typeMakeNewIsExc(t: TypePtr) bool {
    if (t == null) return false;
    const ty = mirrors.MpObjType.fromPtr(t);
    const slot = ty.getSlot(.make_new) orelse return false;
    return slot == @as(?*const anyopaque, @ptrCast(&mp_obj_exception_make_new));
}

inline fn objIsExactType(o: Obj, t: *const anyopaque) bool {
    // mp_obj_is_obj(o) && base.type == t. REPR_A: low 3 bits must be 0.
    if ((o & 3) != 0) return false;
    return mirrors.MpObjException.fromObj(o).base.type == t;
}

fn isNativeExceptionInstance(self_in: Obj) bool {
    return typeMakeNewIsExc(mp_obj_get_type(self_in));
}

export fn mp_obj_is_native_exception_instance(self_in: Obj) callconv(.c) bool {
    return isNativeExceptionInstance(self_in);
}

export fn mp_obj_is_exception_type(self_in: Obj) callconv(.c) bool {
    if (objIsExactType(self_in, &mp_type_type)) {
        // self_in IS a type object — check its make_new slot
        const t: TypePtr = @ptrFromInt(self_in);
        if (typeMakeNewIsExc(t)) return true;
    }
    return mp_obj_is_subclass_fast(self_in, @intFromPtr(&mp_type_BaseException));
}

export fn mp_obj_is_exception_instance(self_in: Obj) callconv(.c) bool {
    return mp_obj_is_exception_type(typeAsObj(mp_obj_get_type(self_in)));
}

export fn mp_obj_exception_match(exc: Obj, exc_type: Obj) callconv(.c) bool {
    var e = exc;
    if (mp_obj_is_exception_instance(e)) {
        e = typeAsObj(mp_obj_get_type(e));
    }
    return mp_obj_is_subclass_fast(e, exc_type);
}

export fn mp_obj_exception_clear_traceback(self_in: Obj) callconv(.c) void {
    getNativeException(self_in).traceback_data = null;
}

export fn mp_obj_exception_get_value(self_in: Obj) callconv(.c) Obj {
    const self = getNativeException(self_in);
    const args = self.args.?;
    if (args.len == 0) {
        return MP_OBJ_NONE;
    }
    // No decompress_error_text_maybe call: MICROPY_ROM_TEXT_COMPRESSION=0 on nano.
    return args.itemsPtr()[0];
}

export fn mp_obj_exception_get_traceback(self_in: Obj, n: *usize, values: *?[*]usize) callconv(.c) void {
    const self = getNativeException(self_in);
    if (self.traceback_data) |td| {
        n.* = self.tb_bits.traceback_len;
        values.* = td;
    } else {
        n.* = 0;
        values.* = null;
    }
}

export fn mp_obj_exception_attr(self_in: Obj, attr: u16, dest: [*c]Obj) callconv(.c) void {
    const self = mirrors.MpObjException.fromObj(self_in);
    if (dest[0] != MP_OBJ_NULL) {
        // store/delete attribute
        if (attr == mp.MP_QSTR___traceback__ and dest[1] == MP_OBJ_NONE) {
            // Allow 'exc.__traceback__ = None' as pre-allocation optimisation.
            self.tb_bits.traceback_len = 0;
            dest[0] = MP_OBJ_NULL;
        } else if (attr == mp.MP_QSTR___cause__ and dest[1] != MP_OBJ_NULL) {
            if (causeSlot(self)) |slot| {
                slot.* = dest[1];
                dest[0] = MP_OBJ_NULL;
            }
        }
        return;
    }
    if (attr == mp.MP_QSTR___cause__ or attr == mp.MP_QSTR___suppress_context__) {
        const cause = if (causeSlot(self)) |slot| slot.* else 0;
        dest[0] = if (attr == mp.MP_QSTR___cause__)
            (if (cause == 0) MP_OBJ_NONE else cause)
        else
            mirrors.newBool(cause != 0);
        return;
    }
    if (attr == mp.MP_QSTR___context__) {
        dest[0] = MP_OBJ_NONE; // implicit chaining is not recorded
        return;
    }
    if (attr == mp.MP_QSTR_args) {
        // decompress_error_text_maybe is a no-op under nano (ROM compression off).
        dest[0] = @intFromPtr(self.args);
    } else if (attr == mp.MP_QSTR_value or attr == mp.MP_QSTR_errno) {
        // Aliases for args[0]: .value (StopIteration) / .errno (OSError).
        dest[0] = mp_obj_exception_get_value(self_in);
    }
}

const PRINT_STR: c_int = 0;
const PRINT_REPR: c_int = 1;
const PRINT_EXC: c_int = 2;
const PRINT_EXC_SUBCLASS: c_int = 0x80;

export fn mp_obj_exception_print(print: ?*const anyopaque, o_in: Obj, kind: c_int) callconv(.c) void {
    const o = mirrors.MpObjException.fromObj(o_in);
    const k = kind & ~PRINT_EXC_SUBCLASS;
    const is_subclass = (kind & PRINT_EXC_SUBCLASS) != 0;
    if (!is_subclass and (k == PRINT_REPR or k == PRINT_EXC)) {
        const ty = mirrors.MpObjType.fromPtr(o.base.type);
        _ = mp_print_str(print, qstr_str(ty.name));
    }
    if (k == PRINT_EXC) {
        _ = mp_print_str(print, ": ");
    }
    // decompress_error_text_maybe omitted: nano has ROM compression off.

    if (k == PRINT_STR or k == PRINT_EXC) {
        const args_opt = o.args;
        if (args_opt == null or args_opt.?.len == 0) {
            _ = mp_print_str(print, "");
            return;
        }
        const args = args_opt.?;
        const items = args.itemsPtr();

        if (comptime mp.MICROPY_PY_ERRNO != 0) {
            // OSError: nicer "[Errno N] name: msg" form.
            const is_oserror = o.base.type == @as(?*const anyopaque, @ptrCast(&mp_type_OSError));
            if (is_oserror and args.len > 0 and args.len < 3 and (items[0] & 1) != 0) {
                const qst = mp_errno_to_str(items[0]);
                if (qst != mp.MP_QSTRnull) {
                    const val: isize = @as(isize, @bitCast(items[0])) >> 1;
                    _ = mp_printf(print, "[Errno %d] %q", @as(c_int, @intCast(val)), @as(c_uint, @intCast(qst)));
                    if (args.len > 1) {
                        _ = mp_print_str(print, ": ");
                        mp_obj_print_helper(print, items[1], PRINT_STR);
                    }
                    return;
                }
            }
        }
        if (args.len == 1) {
            mp_obj_print_helper(print, items[0], PRINT_STR);
            return;
        }
    }
    mp_obj_tuple_print(print, @intFromPtr(o.args), kind);
}

// ── Allocation helpers (lifted from objexcept_shim.c) ─────────────────
//
// Under nano + full: MICROPY_ENABLE_EMERGENCY_EXCEPTION_BUF = 0 — the
// emergency-buf fallback collapses to "return NULL" / unused MP_STATE_VM
// slot. We keep `mp_emergency_exception_obj` as the last-resort allocator
// per the vendor invariant ("Always returns non-NULL"); the state slot is
// pre-existing in StateVm.

// __cause__ (PEP 3134). A heap exception carries it after the
// vendor-shaped part; the VM state and static exceptions embed that part
// at 32 bytes and have no cause. 0 means no `raise ... from`: __cause__
// is None and __suppress_context__ False.
// __qstr_shadow_begin__
// MP_QSTR___cause__
// MP_QSTR_ModuleNotFoundError
// MP_QSTR___context__
// MP_QSTR___suppress_context__
// __qstr_shadow_end__
const HeapException = extern struct {
    exc: mirrors.MpObjException,
    cause: Obj,
};
extern fn gc_nbytes(ptr: ?*const anyopaque) usize;

fn causeSlot(self: *mirrors.MpObjException) ?*Obj {
    if (gc_nbytes(self) < @sizeOf(HeapException)) return null;
    return &@as(*HeapException, @ptrCast(@alignCast(self))).cause;
}

/// Record `raise exc from cause`; a no-op for exceptions without a slot.
pub export fn npy_exception_set_cause(exc: Obj, cause: Obj) callconv(.c) void {
    if (causeSlot(getNativeException(exc))) |slot| slot.* = cause;
}

/// The cause recorded by `raise ... from`, or 0 when there is none.
pub export fn npy_exception_get_cause(exc: Obj) callconv(.c) Obj {
    return if (causeSlot(getNativeException(exc))) |slot| slot.* else 0;
}

fn allocExc() *mirrors.MpObjException {
    if (m_malloc_maybe(@sizeOf(HeapException))) |p| {
        const heap: *HeapException = @ptrCast(@alignCast(p));
        heap.cause = 0;
        return &heap.exc;
    }
    // The state-local mirror is a structural twin of MpObjException; cast
    // through opaque to bridge the two extern struct types.
    return @ptrCast(@alignCast(&state.vmState().mp_emergency_exception_obj));
}

fn allocStr() ?*mirrors.MpObjStr {
    if (m_malloc_maybe(@sizeOf(mirrors.MpObjStr))) |p| {
        return @ptrCast(@alignCast(p));
    }
    return null;
}

fn makeArgsTuple(n_args: usize, args_in: [*c]const Obj) *mirrors.MpObjTuple {
    if (n_args == 0) {
        return @ptrFromInt(@intFromPtr(&mp_const_empty_tuple_obj));
    }
    const total: usize = @sizeOf(mirrors.MpObjTuple) + n_args * @sizeOf(Obj);
    const p = m_malloc_maybe(total) orelse {
        return @ptrFromInt(@intFromPtr(&mp_const_empty_tuple_obj));
    };
    const o_tuple: *mirrors.MpObjTuple = @ptrCast(@alignCast(p));
    o_tuple.base.type = &mp_type_tuple;
    o_tuple.len = n_args;
    const dst: [*]u8 = @ptrCast(o_tuple.itemsPtr());
    const src: [*]const u8 = @ptrCast(args_in);
    @memcpy(dst[0 .. n_args * @sizeOf(Obj)], src[0 .. n_args * @sizeOf(Obj)]);
    return o_tuple;
}

// Encodes the `mp_arg_check_num` sig argument: (n_min, n_max, takes_kw).
// MP_OBJ_FUN_ARGS_MAX=0xffff, so (0, 0xffff, false) → 0x1fffe.
const MP_ARG_SIG_MAKE_NEW: u32 = (0 << 17) | (mp.MP_OBJ_FUN_ARGS_MAX << 1) | 0;

export fn mp_obj_exception_make_new(type_: TypePtr, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    mp_arg_check_num_sig(n_args, n_kw, MP_ARG_SIG_MAKE_NEW);

    const o_exc = allocExc();
    o_exc.base.type = type_;
    o_exc.traceback_data = null;
    o_exc.args = makeArgsTuple(n_args, args);
    return @intFromPtr(o_exc);
}

inline fn cstrLen(s: [*:0]const u8) usize {
    var n: usize = 0;
    while (s[n] != 0) : (n += 1) {}
    return n;
}

export fn mp_obj_new_exception_msg(exc_type: TypePtr, msg: [*:0]const u8) callconv(.c) Obj {
    // Caller invariant (was an assert in C): exc_type's make_new slot points at our make_new.
    const o_str = allocStr() orelse {
        return mp_obj_exception_make_new(exc_type, 0, 0, null);
    };
    o_str.base.type = &mp_type_str;
    const len = cstrLen(msg);
    o_str.len = len;
    o_str.data = @ptrCast(msg);
    // Under nano (no ROM compression), compute hash now.
    // Under the full build (compression on), leave hash=0 for lazy compute.
    // MICROPY_ROM_TEXT_COMPRESSION is undefined when off, hence @hasDecl.
    const compression_on = comptime @hasDecl(mp, "MICROPY_ROM_TEXT_COMPRESSION") and mp.MICROPY_ROM_TEXT_COMPRESSION != 0;
    if (comptime compression_on) {
        o_str.hash = 0;
    } else {
        o_str.hash = qstr_compute_hash(@ptrCast(msg), len);
    }
    const arg: Obj = @intFromPtr(o_str);
    return mp_obj_exception_make_new(exc_type, 1, 0, @ptrCast(&arg));
}

// ── mp_obj_exception_add_traceback ────────────────────────────────────

const TRACEBACK_ENTRY_LEN: usize = 3;

inline fn tracebackMaxEntries() isize {
    // MICROPY_PY_SYS_TRACEBACKLIMIT = 0 in both nano (MINIMUM ROM level) and
    // full (explicit `#define ... (0)` override). No SYS_MUTABLE_TRACEBACKLIMIT
    // slot exists in root_pointers under either arm — return -1 (no limit).
    return -1;
}

inline fn tracebackAllocInitial(alloc_out: *usize) ?[*]usize {
    if (m_malloc_maybe(@sizeOf(usize) * TRACEBACK_ENTRY_LEN)) |p| {
        alloc_out.* = TRACEBACK_ENTRY_LEN;
        return @ptrCast(@alignCast(p));
    }
    return null;
}

inline fn tracebackRenew(old: [*]usize, old_alloc: usize) ?[*]usize {
    const new_count = old_alloc + TRACEBACK_ENTRY_LEN;
    const new_bytes = @sizeOf(usize) * new_count;
    const p = m_realloc_maybe(@ptrCast(old), new_bytes, true);
    if (p == null) return null;
    return @ptrCast(@alignCast(p));
}

export fn mp_obj_exception_add_traceback(self_in: Obj, file: usize, line: usize, block: usize) callconv(.c) void {
    const self = getNativeException(self_in);

    // (config-gated) honour SYS_TRACEBACKLIMIT: drop oldest entry if at cap.
    const max_entries = tracebackMaxEntries();
    if (max_entries == 0) return;
    if (max_entries > 0 and self.traceback_data != null and self.tb_bits.traceback_len >= @as(usize, @intCast(max_entries))) {
        self.tb_bits.traceback_len -= TRACEBACK_ENTRY_LEN;
        const td = self.traceback_data.?;
        const n = self.tb_bits.traceback_len;
        std.mem.copyForwards(usize, td[0..n], td[TRACEBACK_ENTRY_LEN .. TRACEBACK_ENTRY_LEN + n]);
    }

    if (self.traceback_data == null) {
        var alloc_out: usize = 0;
        const td = tracebackAllocInitial(&alloc_out) orelse return;
        self.traceback_data = td;
        self.tb_bits.traceback_alloc = @intCast(alloc_out);
        self.tb_bits.traceback_len = 0;
    } else if (self.tb_bits.traceback_len + TRACEBACK_ENTRY_LEN > self.tb_bits.traceback_alloc) {
        const renewed = tracebackRenew(self.traceback_data.?, self.tb_bits.traceback_alloc) orelse return;
        self.traceback_data = renewed;
        self.tb_bits.traceback_alloc += TRACEBACK_ENTRY_LEN;
    }

    const td = self.traceback_data.?;
    const idx = self.tb_bits.traceback_len;
    // traceback_len is sized usize/2 (u32 on 64-bit, u16 on 32-bit hosts).
    // Compute in usize space, then narrow back to the field width.
    self.tb_bits.traceback_len = @intCast(@as(usize, idx) + TRACEBACK_ENTRY_LEN);
    td[idx + 0] = file;
    td[idx + 1] = line;
    td[idx + 2] = block;
}

export fn mp_obj_new_exception(exc_type: TypePtr) callconv(.c) Obj {
    return mp_obj_exception_make_new(exc_type, 0, 0, null);
}

export fn mp_obj_new_exception_args(exc_type: TypePtr, n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return mp_obj_exception_make_new(exc_type, n_args, 0, args);
}

// ── Exception type ROMs ───────────────────────────────────────────────
//
// `mp_type_BaseException` has no parent (make_new + print + attr only);
// derived types add `parent` pointing at their immediate base.
// All MP_DEFINE_EXCEPTION entries below follow the order in objexcept.c.

const MpObjTypeFull = extern struct {
    header: mirrors.MpObjType,
    slots: [11]?*const anyopaque,
};

// Type-flag value matches MP_TYPE_FLAG_NONE.
const TYPE_FLAG_NONE: u16 = 0x0000;

// Helper: build a "BaseException-shaped" type (no parent slot).
// slot order: make_new=1, print=2, attr=3.
fn rootExcType(name: u16) MpObjTypeFull {
    return .{
        .header = .{
            .base = .{ .type = &mp_type_type },
            .flags = TYPE_FLAG_NONE,
            .name = name,
            .slot_index_make_new = 1,
            .slot_index_print = 2,
            .slot_index_call = 0,
            .slot_index_unary_op = 0,
            .slot_index_binary_op = 0,
            .slot_index_attr = 3,
            .slot_index_subscr = 0,
            .slot_index_iter = 0,
            .slot_index_buffer = 0,
            .slot_index_protocol = 0,
            .slot_index_parent = 0,
            .slot_index_locals_dict = 0,
        },
        .slots = .{
            @ptrCast(&mp_obj_exception_make_new),
            @ptrCast(&mp_obj_exception_print),
            @ptrCast(&mp_obj_exception_attr),
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
}

// Helper: build a derived exception type (adds parent slot).
// slot order matches MP_DEFINE_EXCEPTION: make_new=1, print=2, attr=3, parent=4.
fn excType(name: u16, parent: *const anyopaque) MpObjTypeFull {
    return .{
        .header = .{
            .base = .{ .type = &mp_type_type },
            .flags = TYPE_FLAG_NONE,
            .name = name,
            .slot_index_make_new = 1,
            .slot_index_print = 2,
            .slot_index_call = 0,
            .slot_index_unary_op = 0,
            .slot_index_binary_op = 0,
            .slot_index_attr = 3,
            .slot_index_subscr = 0,
            .slot_index_iter = 0,
            .slot_index_buffer = 0,
            .slot_index_protocol = 0,
            .slot_index_parent = 4,
            .slot_index_locals_dict = 0,
        },
        .slots = .{
            @ptrCast(&mp_obj_exception_make_new),
            @ptrCast(&mp_obj_exception_print),
            @ptrCast(&mp_obj_exception_attr),
            parent,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
        },
    };
}

// Top of the hierarchy.
pub export const mp_type_BaseException: MpObjTypeFull = rootExcType(mp.MP_QSTR_BaseException);

// Direct children of BaseException.
pub export const mp_type_SystemExit: MpObjTypeFull = excType(mp.MP_QSTR_SystemExit, &mp_type_BaseException);
pub export const mp_type_KeyboardInterrupt: MpObjTypeFull = excType(mp.MP_QSTR_KeyboardInterrupt, &mp_type_BaseException);
pub export const mp_type_GeneratorExit: MpObjTypeFull = excType(mp.MP_QSTR_GeneratorExit, &mp_type_BaseException);
pub export const mp_type_Exception: MpObjTypeFull = excType(mp.MP_QSTR_Exception, &mp_type_BaseException);

// Children of Exception.
const ASYNC_AWAIT_ON: bool = configFlag("MICROPY_PY_ASYNC_AWAIT");
pub export const mp_type_StopAsyncIteration: MpObjTypeFull = if (ASYNC_AWAIT_ON)
    excType(mp.MP_QSTR_StopAsyncIteration, &mp_type_Exception)
else
    EMPTY_TYPE;
pub export const mp_type_StopIteration: MpObjTypeFull = excType(mp.MP_QSTR_StopIteration, &mp_type_Exception);
pub export const mp_type_ArithmeticError: MpObjTypeFull = excType(mp.MP_QSTR_ArithmeticError, &mp_type_Exception);
pub export const mp_type_OverflowError: MpObjTypeFull = excType(mp.MP_QSTR_OverflowError, &mp_type_ArithmeticError);
pub export const mp_type_ZeroDivisionError: MpObjTypeFull = excType(mp.MP_QSTR_ZeroDivisionError, &mp_type_ArithmeticError);
pub export const mp_type_AssertionError: MpObjTypeFull = excType(mp.MP_QSTR_AssertionError, &mp_type_Exception);
pub export const mp_type_AttributeError: MpObjTypeFull = excType(mp.MP_QSTR_AttributeError, &mp_type_Exception);
pub export const mp_type_EOFError: MpObjTypeFull = excType(mp.MP_QSTR_EOFError, &mp_type_Exception);
pub export const mp_type_ImportError: MpObjTypeFull = excType(mp.MP_QSTR_ImportError, &mp_type_Exception);
// CPython's, for a module that cannot be found (full).
pub export const mp_type_ModuleNotFoundError: MpObjTypeFull = excType(mp.MP_QSTR_ModuleNotFoundError, &mp_type_ImportError);
pub export const mp_type_LookupError: MpObjTypeFull = excType(mp.MP_QSTR_LookupError, &mp_type_Exception);
pub export const mp_type_IndexError: MpObjTypeFull = excType(mp.MP_QSTR_IndexError, &mp_type_LookupError);
pub export const mp_type_KeyError: MpObjTypeFull = excType(mp.MP_QSTR_KeyError, &mp_type_LookupError);
pub export const mp_type_MemoryError: MpObjTypeFull = excType(mp.MP_QSTR_MemoryError, &mp_type_Exception);
pub export const mp_type_NameError: MpObjTypeFull = excType(mp.MP_QSTR_NameError, &mp_type_Exception);
pub export const mp_type_OSError: MpObjTypeFull = excType(mp.MP_QSTR_OSError, &mp_type_Exception);
pub export const mp_type_RuntimeError: MpObjTypeFull = excType(mp.MP_QSTR_RuntimeError, &mp_type_Exception);
pub export const mp_type_NotImplementedError: MpObjTypeFull = excType(mp.MP_QSTR_NotImplementedError, &mp_type_RuntimeError);
pub export const mp_type_SyntaxError: MpObjTypeFull = excType(mp.MP_QSTR_SyntaxError, &mp_type_Exception);
pub export const mp_type_IndentationError: MpObjTypeFull = excType(mp.MP_QSTR_IndentationError, &mp_type_SyntaxError);
pub export const mp_type_TypeError: MpObjTypeFull = excType(mp.MP_QSTR_TypeError, &mp_type_Exception);

// MICROPY_EMIT_NATIVE = 0 in both configs → mp_type_ViperTypeError absent.

pub export const mp_type_ValueError: MpObjTypeFull = excType(mp.MP_QSTR_ValueError, &mp_type_Exception);

// MICROPY_PY_BUILTINS_STR_UNICODE: 0 in nano, 1 in full.
const STR_UNICODE_ON: bool = configFlag("MICROPY_PY_BUILTINS_STR_UNICODE");
pub export const mp_type_UnicodeError: MpObjTypeFull = if (STR_UNICODE_ON)
    excType(mp.MP_QSTR_UnicodeError, &mp_type_ValueError)
else
    EMPTY_TYPE;

// Placeholder for config-off types: zero-filled (never referenced because
// gating macros prevent any ROM_PTR(&mp_type_X) from being included).
const EMPTY_TYPE: MpObjTypeFull = std.mem.zeroes(MpObjTypeFull);

comptime {
    _ = &mp_obj_is_native_exception_instance;
    _ = &mp_obj_is_exception_type;
    _ = &mp_obj_is_exception_instance;
    _ = &mp_obj_exception_match;
    _ = &mp_obj_exception_clear_traceback;
    _ = &mp_obj_exception_get_value;
    _ = &mp_obj_exception_get_traceback;
    _ = &mp_obj_new_exception;
    _ = &mp_obj_new_exception_args;
    _ = &mp_obj_exception_attr;
    _ = &mp_obj_exception_print;
    _ = &mp_obj_exception_make_new;
    _ = &mp_obj_new_exception_msg;
    // mp_obj_new_exception_msg_varg / _vlist live in va_ops.c.
    _ = &mp_obj_exception_add_traceback;
    _ = &mp_type_BaseException;
}
