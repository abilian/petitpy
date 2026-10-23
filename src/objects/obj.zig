//! petitpy — Zig port of py/obj.c.
//!
//! Raise-path C frames were ported to Zig so that, once the nlr
//! longjmp transport was removed, PyError can propagate naturally via Zig
//! `try` chains. This file now fully replaces the obj_shim.c bridge; all
//! type-slot dispatch + identity/length/equality/print/get-buffer helpers
//! live here directly, using `mp_mirrors` instead of C accessor wrappers.
//!
//! Under nano LONGINT=NONE, FLOAT=0:
//!   - mp_obj_get_int_maybe: arg=bool → 0/1; arg=small_int → value;
//!     arg=int → checked-value; else → mp_unary_op(INT_MAYBE) and check.
//!   - mp_obj_get_int: get_int_maybe or raise TypeError_int_conversion.
//!   - mp_obj_get_int_truncated: is_int ? truncated : get_int.
//!
//! Under full (LONGINT_IMPL=MPZ, BUILTINS_COMPLEX=1):
//!   - mp_obj_get_uint / mp_obj_get_ll: bignum-aware int extractors.
//!   - mp_obj_get_complex{,_maybe}: complex extractors.

const mp = @cImport({
    @cInclude("py/obj.h");
    @cInclude("py/runtime.h");
});
const pyerr = @import("../pyerr.zig");
const PyError = pyerr.PyError;
const mirrors = @import("../mp_mirrors.zig");
const build_options = @import("build_options");

const Obj = mirrors.Obj;
const MP_OBJ_NULL: Obj = mirrors.OBJ_NULL;

// ── External symbols ────────────────────────────────────────────────
extern fn mp_unary_op(op: c_int, arg: Obj) callconv(.c) Obj;
extern fn mp_obj_int_get_checked(self_in: Obj) callconv(.c) isize;
extern fn mp_obj_int_get_truncated(self_in: Obj) callconv(.c) isize;
extern fn mp_obj_is_exception_instance(o: Obj) callconv(.c) bool;
extern fn mp_obj_new_int(v: isize) callconv(.c) Obj;
extern fn mp_obj_new_int_from_uint(v: usize) callconv(.c) Obj;
extern fn npy_pyerr_get_pending() callconv(.c) usize;
extern fn mp_obj_str_equal(o1: Obj, o2: Obj) callconv(.c) bool;
extern fn mp_obj_exception_get_traceback(o: Obj, n_out: *usize, values_out: *[*c]const usize) callconv(.c) void;
extern fn mp_obj_instance_is_callable(o: Obj) callconv(.c) bool;
extern fn mp_obj_instance_call(self_in: Obj, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj;
extern fn m_malloc(num_bytes: usize) callconv(.c) ?*anyopaque;
extern fn mp_obj_new_exception_msg(t: *const anyopaque, msg: [*:0]const u8) callconv(.c) Obj;
extern fn mp_print_str(print: ?*const anyopaque, str: [*c]const u8) c_int;
extern fn mp_printf(print: ?*const anyopaque, fmt: [*c]const u8, ...) c_int;
extern fn qstr_str(q: usize) callconv(.c) [*:0]const u8;
extern fn mp_warning(category: ?[*:0]const u8, msg: [*:0]const u8, ...) callconv(.c) void;
// LONGINT-only externs (defined in objint_mpz.c / objint_longlong.c, gated
// under MICROPY_LONGINT_IMPL != NONE → full only). The wrappers below are
// gated identically; under nano these declarations stay unreferenced.
extern fn mp_obj_int_to_bytes_impl(self_in: Obj, big_endian: bool, len: usize, buf: [*c]u8) callconv(.c) bool;
extern fn mp_obj_int_get_uint_checked(self_in: Obj) callconv(.c) usize;

// Type ROMs.
extern const mp_type_int: anyopaque;
extern const mp_type_str: anyopaque;
extern const mp_type_bytes: anyopaque;
extern const mp_type_bool: anyopaque;
extern const mp_type_NoneType: anyopaque;
extern const mp_type_tuple: anyopaque;
extern const mp_type_list: anyopaque;
extern const mp_type_type: anyopaque;
extern const mp_type_TypeError: anyopaque;
extern const mp_type_IndexError: anyopaque;
extern const mp_type_fun_builtin_1: anyopaque;

// `MP_PYTHON_PRINTER` — resolves to &mp_sys_stdout_print under full
// (IO+SYS_STDFILES) and &mp_plat_print under nano (mpprint.h:42-45).
extern const mp_plat_print: anyopaque;
extern const mp_sys_stdout_print: anyopaque;
inline fn pythonPrinter() *const anyopaque {
    return if (comptime build_options.is_full) &mp_sys_stdout_print else &mp_plat_print;
}

// `mp_cstack_check` is static-inline (cstack.h); under MICROPY_STACK_CHECK=0
// (true under both nano and full at MICROPY_CONFIG_ROM_LEVEL_MINIMUM) the
// vendor body is empty. No-op port.
inline fn cstackCheck() void {}

// ── Inline helpers (replacing the npy_objz_* shim accessors) ────────
inline fn typeOf(o: Obj) ?*const anyopaque {
    return mp_obj_get_type(o);
}

inline fn isStr(o: Obj) bool {
    // mp_obj_is_str (macro): qstr-immediate OR exact-type-str.
    return mirrors.isQstr(o) or mirrors.isExactType(o, &mp_type_str);
}

inline fn isBytes(o: Obj) bool {
    return mirrors.isExactType(o, &mp_type_bytes);
}

inline fn isFloat(o: Obj) bool {
    // mp_obj_is_float (macro): under REPR_A the only float representation
    // is heap-allocated → exact-type-float check. FLOAT is on under both
    // nano and full configs.
    return mirrors.isExactType(o, &mp_type_float);
}

extern const mp_type_float: anyopaque;
extern fn mp_obj_float_get(self_in: Obj) callconv(.c) f64;
extern fn mp_obj_int_as_float_impl(self_in: Obj) callconv(.c) f64;

inline fn isStrOrBytesForLen(o: Obj) bool {
    // !UNICODE && is_str → str fast-path; bytes fast-path always.
    // Under MICROPY_PY_BUILTINS_STR_UNICODE=1 (full), is_str gives the
    // unicode-len fast path through the unary_op slot, not the byte fast
    // path here.
    if (comptime !build_options.str_unicode) {
        if (isStr(o)) return true;
    }
    return isBytes(o);
}

inline fn getStrLen(o: Obj) usize {
    // GET_STR_LEN (objstr.h): if qstr → qstr_len, else mp_obj_str_t.len.
    if (mirrors.isQstr(o)) {
        var len_out: usize = 0;
        _ = qstr_data(mirrors.qstrValue(o), &len_out);
        return len_out;
    }
    return mirrors.MpObjStr.fromObj(o).len;
}

extern fn qstr_data(q: usize, len: *usize) callconv(.c) [*c]const u8;

// ── nlr bridge (full only) — NX-3 polled ────────────────────────────
// Was: `if (pending_exc) npy_pyerr_nlr_jump(exc)`. NX-3 deleted
// npy_pyerr_nlr_jump (no NLR), so under full this is now a no-op:
// pending_exc stays set, callers MUST poll. Vendor C callers that
// expected noreturn semantics may misbehave; for
// the best-effort full-arm gate this is preferable to a hard panic.
inline fn longjmpIfPending() void {}

// ── Raise helpers (PyError convention). ─────────────────────────────
// Each sets pyerr.pending_exc + returns error.PyRaise. The C-ABI export
// wraps the impl with pyerr.bridge which catches and returns the zero
// sentinel (callers poll pending_exc). Under TERSE error reporting
// (ROM_LEVEL_MINIMUM), the int-conversion message is the literal
// "can't convert to int" — see runtime.c:1744.
fn raiseIntConversion() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_TypeError, "can't convert to int");
    return error.PyRaise;
}
fn raiseNoLen() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_TypeError, "object has no len");
    return error.PyRaise;
}
fn raiseExpectedTupleList() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_TypeError, "expected tuple/list");
    return error.PyRaise;
}
fn raiseWrongLength() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_ValueError, "tuple/list has wrong length");
    return error.PyRaise;
}
fn raiseIndicesMustBeInts() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_TypeError, "indices must be integers");
    return error.PyRaise;
}
fn raiseIndexOutOfRange() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_IndexError, "index out of range");
    return error.PyRaise;
}
fn raiseNoItemDeletion() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_TypeError, "object doesn't support item deletion");
    return error.PyRaise;
}
fn raiseNotSubscriptable() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_TypeError, "object isn't subscriptable");
    return error.PyRaise;
}
fn raiseNoItemAssignment() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_TypeError, "object doesn't support item assignment");
    return error.PyRaise;
}
fn raiseBufferProtocol() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_TypeError, "object with buffer protocol required");
    return error.PyRaise;
}
fn raiseFloatConversion() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_TypeError, "can't convert to float");
    return error.PyRaise;
}
fn raiseComplexConversion() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_TypeError, "can't convert to complex");
    return error.PyRaise;
}

// ValueError type ROM for the wrong-length helper above.
extern const mp_type_ValueError: anyopaque;

// ── mp_obj_get_int{_maybe,_truncated} (W6) ──────────────────────────

export fn mp_obj_get_int_maybe(arg: Obj, value: *isize) callconv(.c) bool {
    // B2 polled-sentinel: defensive — caller may pass sentinel 0
    // (MP_OBJ_NULL) when an earlier bridge raise propagated through them
    // unchecked. Treat as "not an int".
    if (arg == MP_OBJ_NULL or pyerr.pending_exc != 0) return false;
    if (arg == mirrors.OBJ_FALSE) {
        value.* = 0;
    } else if (arg == mirrors.OBJ_TRUE) {
        value.* = 1;
    } else if (mirrors.isSmallInt(arg)) {
        value.* = mirrors.smallIntValue(arg);
    } else if (mirrors.isExactType(arg, &mp_type_int)) {
        return intGetChecked(arg, value);
    } else {
        const maybe_int = mp_unary_op(mp.MP_UNARY_OP_INT_MAYBE, arg);
        if (maybe_int != MP_OBJ_NULL) {
            return intGetChecked(maybe_int, value);
        } else {
            return false;
        }
    }
    return true;
}

extern fn mpz_as_int_checked(z: *const anyopaque, value: *isize) callconv(.c) bool;
extern const mp_type_OverflowError: anyopaque;

/// An int's machine-word value. A bignum that does not fit raises
/// OverflowError polled, where vendor mp_obj_int_get_checked raises
/// through the vendor-C path that a plain subscript cannot catch.
fn intGetChecked(o: Obj, value: *isize) bool {
    if (build_options.longint_none or mirrors.isSmallInt(o)) {
        value.* = mp_obj_int_get_checked(o);
        return true;
    }
    // mp_obj_int_t: the object header, then the mpz.
    if (mpz_as_int_checked(@ptrFromInt(o + @sizeOf(mirrors.MpObjBase)), value)) return true;
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_OverflowError, "overflow converting long int to machine word");
    return false;
}

fn mpObjGetIntImpl(arg: Obj) PyError!isize {
    var val: isize = 0;
    if (!mp_obj_get_int_maybe(arg, &val)) {
        // If mp_obj_get_int_maybe already set pending_exc, preserve it;
        // otherwise raise our own TypeError.
        if (pyerr.pending_exc == 0) {
            try raiseIntConversion();
        }
        return error.PyRaise;
    }
    return val;
}

export fn mp_obj_get_int(arg: Obj) callconv(.c) isize {
    const r = pyerr.bridge(isize, mpObjGetIntImpl(arg));
    longjmpIfPending(); // full only: bridge to longjmp at export boundary
    return r;
}

export fn mp_obj_get_int_truncated(arg: Obj) callconv(.c) isize {
    // is_int = is_small_int || is_exact(int)
    if (mirrors.isSmallInt(arg) or mirrors.isExactType(arg, &mp_type_int)) {
        return mp_obj_int_get_truncated(arg);
    } else {
        return mp_obj_get_int(arg);
    }
}

// ── mp_obj_equal{,_not_equal} (W6 #2) ───────────────────────────────

fn equalNotEqualImpl(op: c_int, o1_in: Obj, o2_in: Obj) Obj {
    var o1 = o1_in;
    var o2 = o2_in;
    const local_true: Obj = if (op == mp.MP_BINARY_OP_NOT_EQUAL)
        mirrors.OBJ_FALSE
    else
        mirrors.OBJ_TRUE;
    const local_false: Obj = if (op == mp.MP_BINARY_OP_NOT_EQUAL)
        mirrors.OBJ_TRUE
    else
        mirrors.OBJ_FALSE;

    // Reflexive shortcut.
    if (o1 == o2) {
        if (mirrors.isSmallInt(o1)) {
            return local_true;
        }
        const type_o1 = mirrors.MpObjType.fromPtr(typeOf(o1));
        if ((type_o1.flags & mirrors.FLAG_EQ_NOT_REFLEXIVE) == 0) {
            return local_true;
        }
    }

    // Decide whether to skip the first generic-pass (C: goto skip_one_pass).
    var skip_first: bool = false;
    if (isStr(o1)) {
        if (isStr(o2)) {
            return if (mp_obj_str_equal(o1, o2)) local_true else local_false;
        }
        // MICROPY_PY_STR_BYTES_CMP_WARN (full + feature-warning only): str vs bytes → False + warn.
        // ADR-002 F1: the mp_warning call is also gated on feature_warning so
        // disabling -Dfeature-warning=false under full does not leave an
        // undefined symbol (vendor py/warning.c is empty when MICROPY_WARNINGS=0).
        if (comptime build_options.is_full and build_options.feature_warning) {
            if (isBytes(o2)) {
                mp_warning(null, "Comparison between bytes and str");
                return local_false;
            }
        }
        skip_first = true;
    } else if (comptime build_options.is_full) {
        if (comptime build_options.feature_warning) {
            if (isBytes(o1) and isStr(o2)) {
                mp_warning(null, "Comparison between bytes and str");
                return local_false;
            }
        }
        if (mirrors.isSmallInt(o1)) {
            if (mirrors.isSmallInt(o2)) return local_false;
            skip_first = true;
        }
    } else if (mirrors.isSmallInt(o1)) {
        if (mirrors.isSmallInt(o2)) {
            // both small ints, equal would have returned already
            return local_false;
        }
        skip_first = true;
    }

    // Generic 2-pass loop: try o1's type, then swap and try o2's type.
    var pass: u32 = 0;
    while (pass < 2) : ({
        pass += 1;
        const tmp = o1;
        o1 = o2;
        o2 = tmp;
    }) {
        if (skip_first) {
            skip_first = false;
            continue;
        }
        const t = mirrors.MpObjType.fromPtr(typeOf(o1));
        if (!t.hasSlot(.binary_op)) continue;

        // Skip if the type doesn't permit cross-type eq AND types differ.
        if (!t.flagEqChecksOtherType() and typeOf(o2) != @as(?*const anyopaque, @ptrCast(t))) {
            continue;
        }

        // CPython asymmetry: try __ne__ first if eq has neq test (op==NOT_EQUAL).
        if (op == mp.MP_BINARY_OP_NOT_EQUAL and (t.flags & mirrors.FLAG_EQ_HAS_NEQ_TEST) != 0) {
            const r = t.callBinaryOp(mp.MP_BINARY_OP_NOT_EQUAL, o1, o2);
            if (r != MP_OBJ_NULL) return r;
        }

        // Try __eq__.
        const r = t.callBinaryOp(mp.MP_BINARY_OP_EQUAL, o1, o2);
        if (r != MP_OBJ_NULL) {
            if (op == mp.MP_BINARY_OP_EQUAL) return r;
            return if (mp_obj_is_true(r)) local_true else local_false;
        }
    }

    // Equality not implemented: fall back to pointer comparison.
    return if (o1 == o2) local_true else local_false;
}

export fn mp_obj_equal_not_equal(op: c_int, o1: Obj, o2: Obj) callconv(.c) Obj {
    return equalNotEqualImpl(op, o1, o2);
}

export fn mp_obj_equal(o1: Obj, o2: Obj) callconv(.c) bool {
    return mp_obj_is_true(equalNotEqualImpl(mp.MP_BINARY_OP_EQUAL, o1, o2));
}

// ── mp_obj_print_exception ──────────────────────────────────────────

extern fn npy_exception_get_cause(exc: Obj) callconv(.c) Obj;

export fn mp_obj_print_exception(print: ?*const anyopaque, exc: Obj) void {
    printExceptionChain(print, exc, 16);
}

// The cause first, as CPython prints a `raise ... from` chain; `depth`
// bounds a cycle (`a.__cause__ = b; b.__cause__ = a`).
fn printExceptionChain(print: ?*const anyopaque, exc: Obj, depth: u8) void {
    if (depth > 0 and mp_obj_is_exception_instance(exc)) {
        const cause = npy_exception_get_cause(exc);
        if (cause != 0 and cause != mirrors.OBJ_NONE) {
            printExceptionChain(print, cause, depth - 1);
            _ = mp_print_str(print, "\nThe above exception was the direct cause of the following exception:\n\n");
        }
    }
    if (mp_obj_is_exception_instance(exc)) {
        var n: usize = 0;
        var values: [*c]const usize = undefined;
        mp_obj_exception_get_traceback(exc, &n, &values);
        if (n > 0) {
            // n is always a multiple of 3 (file, line, block triples).
            _ = mp_print_str(print, "Traceback (most recent call last):\n");
            var i: isize = @as(isize, @intCast(n)) - 3;
            while (i >= 0) : (i -= 3) {
                const idx: usize = @intCast(i);
                if (comptime @hasDecl(mp, "MICROPY_ENABLE_SOURCE_LINE") and mp.MICROPY_ENABLE_SOURCE_LINE) {
                    _ = mp_printf(print, "  File \"%q\", line %d", @as(c_uint, @intCast(values[idx])), @as(c_int, @intCast(values[idx + 1])));
                } else {
                    _ = mp_printf(print, "  File \"%q\"", @as(c_uint, @intCast(values[idx])));
                }
                const block = values[idx + 2];
                if (block == @as(usize, mp.MP_QSTRnull)) {
                    _ = mp_print_str(print, "\n");
                } else {
                    _ = mp_printf(print, ", in %q\n", @as(c_uint, @intCast(block)));
                }
            }
        }
    }
    mp_obj_print_helper(print, exc, mp.PRINT_EXC);
    _ = mp_print_str(print, "\n");
}

// ── mp_obj_len{,_maybe} ─────────────────────────────────────────────

export fn mp_obj_len_maybe(o_in: Obj) Obj {
    if (isStrOrBytesForLen(o_in)) {
        return mirrors.newSmallInt(@intCast(getStrLen(o_in)));
    }
    const t = mirrors.MpObjType.fromPtr(typeOf(o_in));
    if (t.hasSlot(.unary_op)) {
        const fn_ptr: mirrors.MpUnaryOpFun = @ptrCast(@alignCast(t.getSlot(.unary_op).?));
        return fn_ptr(mp.MP_UNARY_OP_LEN, o_in);
    }
    return MP_OBJ_NULL;
}

fn mpObjLenImpl(o_in: Obj) PyError!Obj {
    const len = mp_obj_len_maybe(o_in);
    if (len == MP_OBJ_NULL) {
        try raiseNoLen();
    }
    return len;
}

export fn mp_obj_len(o_in: Obj) Obj {
    return pyerr.bridge(Obj, mpObjLenImpl(o_in));
}

// ── mp_obj_get_type_str, mp_obj_print[_helper], _is_callable, _is_true, _id ──

export fn mp_obj_get_type_str(o_in: Obj) [*c]const u8 {
    const t = mirrors.MpObjType.fromPtr(typeOf(o_in));
    return qstr_str(t.name);
}

export fn mp_obj_print_helper(print: ?*const anyopaque, o_in: Obj, kind: c_int) void {
    cstackCheck();
    // NDEBUG is set under nano → skip the "(nil)" defensive print.
    const t = mirrors.MpObjType.fromPtr(typeOf(o_in));
    if (t.hasSlot(.print)) {
        const fn_ptr: mirrors.MpPrintFun = @ptrCast(@alignCast(t.getSlot(.print).?));
        fn_ptr(print.?, o_in, kind);
    } else {
        _ = mp_printf(print, "<%q>", @as(c_uint, @intCast(t.name)));
    }
}

export fn mp_obj_print(o_in: Obj, kind: c_int) void {
    mp_obj_print_helper(pythonPrinter(), o_in, kind);
}

export fn mp_obj_is_true(arg: Obj) bool {
    // B2 defensive: arg may be MP_OBJ_NULL when called with a bridge sentinel.
    if (arg == MP_OBJ_NULL or npy_pyerr_get_pending() != 0) return false;
    if (arg == mirrors.OBJ_FALSE) return false;
    if (arg == mirrors.OBJ_TRUE) return true;
    if (arg == mirrors.OBJ_NONE) return false;
    if (mirrors.isSmallInt(arg)) {
        return arg != mirrors.newSmallInt(0);
    }
    const t = mirrors.MpObjType.fromPtr(typeOf(arg));
    if (t.hasSlot(.unary_op)) {
        const fn_ptr: mirrors.MpUnaryOpFun = @ptrCast(@alignCast(t.getSlot(.unary_op).?));
        const result = fn_ptr(mp.MP_UNARY_OP_BOOL, arg);
        if (result != MP_OBJ_NULL) {
            return result == mirrors.OBJ_TRUE;
        }
    }
    const len = mp_obj_len_maybe(arg);
    if (len != MP_OBJ_NULL) {
        return len != mirrors.newSmallInt(0);
    }
    return true; // anything else is truthy per Python
}

export fn mp_obj_is_callable(o_in: Obj) bool {
    const t = mirrors.MpObjType.fromPtr(typeOf(o_in));
    const call_slot = t.getSlot(.call);
    const instance_call: *const anyopaque = @ptrCast(&mp_obj_instance_call);
    if (call_slot) |slot| {
        if (slot != instance_call) return true;
        return mp_obj_instance_is_callable(o_in);
    }
    return false;
}

export fn mp_obj_id(o_in: Obj) Obj {
    const id: isize = @bitCast(o_in);
    if (!mirrors.isObj(o_in)) {
        return mp_obj_new_int(id);
    }
    if (id >= 0) {
        // Affinity for "user" memory in low half of address space → small int.
        return mirrors.newSmallInt(id);
    }
    // Negative → return a (large) positive long int so it doesn't clash.
    return mp_obj_new_int_from_uint(@bitCast(id));
}

// ── mp_obj_get_type (REPR_A + IMMEDIATE_OBJS live branch) ───────────

export fn mp_obj_get_type(o_in: Obj) ?*const anyopaque {
    // B2 defensive: MP_OBJ_NULL (sentinel = 0) has tag bits 0 so is_obj() is
    // true — but dereferencing it segfaults. Bail to a NULL type pointer.
    if (o_in == MP_OBJ_NULL) return null;
    if (mirrors.isObj(o_in)) {
        // Note: empirically the read needs to go through a `*align(1)` deref
        // (mirrors.objBaseType) to match the C call sequence — but obj.zig
        // historically used a C shim hop that sequenced the same deref and
        // somehow avoided a follow-on bus error in enumerate(). Investigated
        // 2026-05-22; the difference is benign. Use the mirror.
        return mirrors.objBaseType(o_in);
    }
    // Immediate-obj table — see file header for tag layout.
    const table = [16]?*const anyopaque{
        null, &mp_type_int, &mp_type_str,      &mp_type_int,
        null, &mp_type_int, &mp_type_NoneType, &mp_type_int,
        null, &mp_type_int, &mp_type_str,      &mp_type_int,
        null, &mp_type_int, &mp_type_bool,     &mp_type_int,
    };
    return table[o_in & 0xf];
}

// ── mp_obj_get_array, _fixed_n, mp_get_index, mp_obj_subscr, _identity, get_buffer ──

fn mpObjGetArrayImpl(o: Obj, len_out: *usize, items_out: *[*c]Obj) PyError!void {
    if (mirrors.isExactType(o, &mp_type_tuple)) {
        const t = mirrors.MpObjTuple.fromObj(o);
        len_out.* = t.len;
        items_out.* = @ptrCast(t.itemsPtr());
    } else if (mirrors.isExactType(o, &mp_type_list)) {
        const l = mirrors.MpObjList.fromObj(o);
        len_out.* = l.len;
        items_out.* = @ptrCast(l.items);
    } else {
        try raiseExpectedTupleList();
    }
}

export fn mp_obj_get_array(o: Obj, len_out: *usize, items_out: *[*c]Obj) void {
    pyerr.bridge(void, mpObjGetArrayImpl(o, len_out, items_out));
}

fn mpObjGetArrayFixedNImpl(o: Obj, len: usize, items_out: *[*c]Obj) PyError!void {
    var seq_len: usize = 0;
    try mpObjGetArrayImpl(o, &seq_len, items_out);
    if (seq_len != len) {
        try raiseWrongLength();
    }
}

export fn mp_obj_get_array_fixed_n(o: Obj, len: usize, items_out: *[*c]Obj) void {
    pyerr.bridge(void, mpObjGetArrayFixedNImpl(o, len, items_out));
}

fn mpGetIndexImpl(_type: ?*const anyopaque, len: usize, index: Obj, is_slice: bool) PyError!usize {
    _ = _type;
    var i: isize = 0;
    if (mirrors.isSmallInt(index)) {
        i = mirrors.smallIntValue(index);
    } else if (!mp_obj_get_int_maybe(index, &i)) {
        if (pyerr.pending_exc != 0) return error.PyRaise;
        try raiseIndicesMustBeInts();
    }
    const ilen: isize = @bitCast(len);
    if (i < 0) i += ilen;
    if (is_slice) {
        if (i < 0) i = 0 else if (i > ilen) i = ilen;
    } else {
        if (i < 0 or i >= ilen) {
            try raiseIndexOutOfRange();
        }
    }
    return @bitCast(i);
}

export fn mp_get_index(_type: ?*const anyopaque, len: usize, index: Obj, is_slice: bool) usize {
    // B2 defensive: don't overwrite a prior pending raise.
    if (pyerr.pending_exc != 0) return 0;
    return pyerr.bridge(usize, mpGetIndexImpl(_type, len, index, is_slice));
}

fn mpObjSubscrImpl(base: Obj, index: Obj, value: Obj) PyError!Obj {
    const t = mirrors.MpObjType.fromPtr(typeOf(base));
    if (t.hasSlot(.subscr)) {
        const fn_ptr: mirrors.MpSubscrFun = @ptrCast(@alignCast(t.getSlot(.subscr).?));
        const ret = fn_ptr(base, index, value);
        if (ret != MP_OBJ_NULL) return ret;
        if (pyerr.pending_exc != 0) return error.PyRaise;
        // TODO: call base classes here?
    }
    // `list[str]` and a class's `__class_getitem__`, on full.
    if (build_options.is_full and value == mirrors.OBJ_SENTINEL and typeOf(base) == @as(?*const anyopaque, &mp_type_type)) {
        return @import("../runtime/runtime.zig").typingCall(mp.MP_QSTR__class_getitem, base, index);
    }
    if (value == MP_OBJ_NULL) {
        try raiseNoItemDeletion();
    } else if (value == mirrors.OBJ_SENTINEL) {
        try raiseNotSubscriptable();
    } else {
        try raiseNoItemAssignment();
    }
    return MP_OBJ_NULL;
}

export fn mp_obj_subscr(base: Obj, index: Obj, value: Obj) Obj {
    return pyerr.bridge(Obj, mpObjSubscrImpl(base, index, value));
}

pub export fn mp_identity(self: Obj) Obj {
    return self;
}

// `mp_identity_obj` (MP_DEFINE_CONST_FUN_OBJ_1) — vendor callers
// (modmicropython, objstringio) reference this symbol via MP_ROM_PTR.
pub export const mp_identity_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_1 },
    .fun = @ptrCast(&mp_identity),
};

fn mpGetBufferImpl(obj: Obj, bufinfo: ?*anyopaque, flags: c_uint) PyError!bool {
    const t = mirrors.MpObjType.fromPtr(typeOf(obj));
    if (t.hasSlot(.buffer)) {
        const fn_ptr: mirrors.MpBufferFun = @ptrCast(@alignCast(t.getSlot(.buffer).?));
        if (fn_ptr(obj, bufinfo.?, flags & mp.MP_BUFFER_RW) == 0) {
            return true;
        }
    }
    if ((flags & mp.MP_BUFFER_RAISE_IF_UNSUPPORTED) != 0) {
        try raiseBufferProtocol();
    }
    return false;
}

export fn mp_get_buffer(obj: Obj, bufinfo: ?*anyopaque, flags: c_uint) bool {
    const r = pyerr.bridge(bool, mpGetBufferImpl(obj, bufinfo, flags));
    // Lesson #34: vendor C callers (objarray.c::array_binary_op, etc.)
    // assume mp_get_buffer_raise is noreturn; without the longjmp they
    // read uninitialized bufinfo and crash with a huge alloc.
    longjmpIfPending();
    return r;
}

// ── mp_obj_get_float / _maybe (TRUE-ZIG-PORT) ───────────────────────

export fn mp_obj_get_float_maybe(arg_in: Obj, value: *f64) callconv(.c) bool {
    var val: f64 = 0;
    if (arg_in == mirrors.OBJ_FALSE) {
        val = 0;
    } else if (arg_in == mirrors.OBJ_TRUE) {
        val = 1;
    } else if (mirrors.isSmallInt(arg_in)) {
        val = @floatFromInt(mirrors.smallIntValue(arg_in));
    } else if (!build_options.longint_none and mirrors.isExactType(arg_in, &mp_type_int)) {
        // A heap int (vendor obj.c's LONGINT branch).
        val = mp_obj_int_as_float_impl(arg_in);
    } else if (isFloat(arg_in)) {
        val = mp_obj_float_get(arg_in);
    } else {
        const converted = mp_unary_op(mp.MP_UNARY_OP_FLOAT_MAYBE, arg_in);
        if (converted != 0 and isFloat(converted)) {
            val = mp_obj_float_get(converted);
        } else if (build_options.is_full and isFloat(@import("../runtime/opmethods.zig").nativeBase(arg_in))) {
            // A float subclass without its own __float__.
            val = mp_obj_float_get(@import("../runtime/opmethods.zig").nativeBase(arg_in));
        } else {
            return false;
        }
    }
    value.* = val;
    return true;
}

fn mpObjGetFloatImpl(arg_in: Obj) PyError!f64 {
    var val: f64 = 0;
    if (!mp_obj_get_float_maybe(arg_in, &val)) {
        try raiseFloatConversion();
    }
    return val;
}

export fn mp_obj_get_float(arg_in: Obj) callconv(.c) f64 {
    return pyerr.bridge(f64, mpObjGetFloatImpl(arg_in));
}

// ── mp_obj_malloc_helper ────────────────────────────────────────────
// Used pervasively across the Zig object ports + a few C shims.
// MICROPY_ENABLE_FINALISER is off in both nano and full → the
// _with_finaliser_helper variant has no callers and is omitted.
pub export fn mp_obj_malloc_helper(num_bytes: usize, type_in: *const anyopaque) callconv(.c) ?*anyopaque {
    const raw = m_malloc(num_bytes) orelse return null;
    const base: *mirrors.MpObjBase = @ptrCast(@alignCast(raw));
    base.type = type_in;
    return raw;
}

// ── Full-only: mp_obj_get_uint / mp_obj_get_ll (LONGINT_IMPL != NONE) ──
// Vendor obj.c wraps these under `#if MICROPY_LONGINT_IMPL != NONE`. We
// match exactly: under nano (LONGINT_IMPL=NONE) the symbols are absent
// from vendor, no callers exist, and we omit the Zig export so the
// referenced LONGINT-only externs stay un-linked.
const longInt = struct {
    fn getUintImpl(arg_in: Obj) PyError!usize {
        var arg = arg_in;
        if (!mirrors.isExactType(arg, &mp_type_int)) {
            const as_int = mp_unary_op(mp.MP_UNARY_OP_INT_MAYBE, arg);
            if (as_int == MP_OBJ_NULL) {
                try raiseIntConversion();
            }
            arg = as_int;
        }
        return mp_obj_int_get_uint_checked(arg);
    }

    pub export fn mp_obj_get_uint(arg_in: Obj) callconv(.c) usize {
        return pyerr.bridge(usize, getUintImpl(arg_in));
    }

    fn getLlImpl(arg_in: Obj) PyError!c_longlong {
        var arg = arg_in;
        if (!mirrors.isExactType(arg, &mp_type_int)) {
            const as_int = mp_unary_op(mp.MP_UNARY_OP_INT_MAYBE, arg);
            if (as_int == MP_OBJ_NULL) {
                try raiseIntConversion();
            }
            arg = as_int;
        }
        if (mirrors.isSmallInt(arg)) {
            return @intCast(mirrors.smallIntValue(arg));
        }
        var res: c_longlong = 0;
        const buf: [*c]u8 = @ptrCast(&res);
        // MP_ENDIANNESS_BIG — vendor uses big-endian here.
        _ = mp_obj_int_to_bytes_impl(arg, true, @sizeOf(c_longlong), buf);
        return res;
    }

    pub export fn mp_obj_get_ll(arg_in: Obj) callconv(.c) c_longlong {
        return pyerr.bridge(c_longlong, getLlImpl(arg_in));
    }
};

comptime {
    if (build_options.is_full) {
        _ = &longInt.mp_obj_get_uint;
        _ = &longInt.mp_obj_get_ll;
    }
}

// ── Full-only: mp_obj_get_complex{,_maybe} (FLOAT + COMPLEX) ─────────
// Vendor obj.c wraps these under `#if MICROPY_PY_BUILTINS_COMPLEX`.
extern const mp_type_complex: anyopaque;
extern fn mp_obj_complex_get(self_in: Obj, real: *f64, imag: *f64) callconv(.c) void;

const complex = struct {
    pub export fn mp_obj_get_complex_maybe(arg_in: Obj, real: *f64, imag: *f64) callconv(.c) bool {
        var arg = arg_in;
        if (mp_obj_get_float_maybe(arg, real)) {
            imag.* = 0;
        } else if (mirrors.isExactType(arg, &mp_type_complex)) {
            mp_obj_complex_get(arg, real, imag);
        } else {
            arg = mp_unary_op(mp.MP_UNARY_OP_COMPLEX_MAYBE, arg);
            if (arg != MP_OBJ_NULL and mirrors.isExactType(arg, &mp_type_complex)) {
                mp_obj_complex_get(arg, real, imag);
            } else {
                return false;
            }
        }
        return true;
    }

    fn getComplexImpl(arg_in: Obj, real: *f64, imag: *f64) PyError!void {
        if (!mp_obj_get_complex_maybe(arg_in, real, imag)) {
            // Under MICROPY_ERROR_REPORTING_TERSE (the default) the message is
            // the literal "can't convert to complex"; we follow that here.
            try raiseComplexConversion();
        }
    }

    pub export fn mp_obj_get_complex(arg_in: Obj, real: *f64, imag: *f64) callconv(.c) void {
        pyerr.bridge(void, getComplexImpl(arg_in, real, imag));
    }
};

comptime {
    if (build_options.is_full) {
        _ = &complex.mp_obj_get_complex_maybe;
        _ = &complex.mp_obj_get_complex;
    }
}

comptime {
    _ = &mp_obj_get_int_maybe;
    _ = &mp_obj_get_int;
    _ = &mp_obj_get_int_truncated;
    _ = &mp_obj_equal_not_equal;
    _ = &mp_obj_equal;
    _ = &mp_obj_print_exception;
    _ = &mp_obj_len_maybe;
    _ = &mp_obj_len;
    _ = &mp_obj_get_type_str;
    _ = &mp_obj_print_helper;
    _ = &mp_obj_print;
    _ = &mp_obj_is_true;
    _ = &mp_obj_is_callable;
    _ = &mp_obj_id;
    _ = &mp_obj_get_array;
    _ = &mp_obj_get_array_fixed_n;
    _ = &mp_get_index;
    _ = &mp_obj_subscr;
    _ = &mp_identity;
    _ = &mp_identity_obj;
    _ = &mp_get_buffer;
    _ = &mp_obj_get_type;
    _ = &mp_obj_get_float_maybe;
    _ = &mp_obj_get_float;
    _ = &mp_obj_malloc_helper;
}
