//! Phase F0 — full-arm rehab stubs.
//!
//! When `CONFIG=full` enables features that nano doesn't ship, the linker
//! needs concrete definitions for the symbols referenced by full-only
//! branches. This module supplies the minimal set so that `CONFIG=full make
//! build` LINKS — functions panic at runtime with descriptive messages, and
//! ROM consts are zero-initialised sentinels.
//!
//! Most stubs are gated on `build_options.is_full` because under nano the
//! same symbol names are already exported from other modules (objint.zig,
//! objstr.zig, modsys.zig, …) as the live polled implementations. Gating
//! avoids exported-symbol collisions while satisfying the linker under full.
//!
//! Each stub is grouped by subsystem so triage panic messages tell you which
//! subsystem to port next.

const std = @import("std");
const build_options = @import("build_options");
const mirrors = @import("../mp_mirrors.zig");

const Obj = mirrors.Obj;

// ── Long-int / mpz — PORTED ───────────────────────────────────────────
// The 14 long-int stubs that lived here have been replaced by the real
// vendor implementations (py/objint.c + py/objint_mpz.c + py/mpz.c),
// re-added to the compile graph under `is_full` in build.zig. The
// trade-off: zero-vendor-C is preserved under nano;
// full accepts ~2.8k LOC of vendor C compiled-back-in here.

// ── Complex (4) — full-only ───────────────────────────────────────────
// vendor py/objcomplex.c. Pure data type. F4 target.

fn stub_mp_obj_complex_binary_op(op: c_int, lhs_real: f64, lhs_imag: f64, rhs_in: Obj) callconv(.c) Obj {
    _ = .{ op, lhs_real, lhs_imag, rhs_in };
    @panic("full-arm stub: mp_obj_complex_binary_op — port objcomplex.c");
}
fn stub_mp_obj_complex_get(self_in: Obj, real: *f64, imag: *f64) callconv(.c) void {
    _ = .{ self_in, real, imag };
    @panic("full-arm stub: mp_obj_complex_get — port objcomplex.c");
}
fn stub_mp_obj_new_complex(real: f64, imag: f64) callconv(.c) Obj {
    _ = .{ real, imag };
    @panic("full-arm stub: mp_obj_new_complex — port objcomplex.c");
}
// ROM type singleton. Zero-init; reads of `&mp_type_complex` for identity
// compares succeed; any slot-dispatch would crash, but we never get there
// because mp_obj_new_complex / mp_obj_complex_get panic first.
var stub_mp_type_complex_storage: [256]u8 align(8) = [_]u8{0} ** 256;

// ── Sys (3) — full-only ───────────────────────────────────────────────
// F3 target. modsys.zig already mostly ported.

// mp_sys_maxsize_obj — PORTED (F2a): now provided by vendor py/objint_mpz.c
// as a side-effect of the long-int re-add; no longer needs a stub.

// mp_sys_stdout_print — vendor py/mpprint.h: extern const mp_print_t.
// Vendor py/modsys.c initialises it as
//   const mp_print_t mp_sys_stdout_print = {&mp_sys_stdout_obj, mp_stream_write_adaptor};
// so MP_PYTHON_PRINTER (= &mp_sys_stdout_print) lets vendor builtin_help
// route through the stream adaptor onto our nano stdout. Initialised at
// runtime in init_full_stubs() because Zig comptime can't take the address
// of these C externs.
const MpPrintT = extern struct {
    data: ?*anyopaque,
    print_strn: ?*const fn (data: ?*anyopaque, str: [*]const u8, len: usize) callconv(.c) void,
};
extern const mp_sys_stdout_obj: anyopaque;
extern fn mp_stream_write_adaptor(data: ?*anyopaque, str: [*]const u8, len: usize) callconv(.c) void;
var stub_mp_sys_stdout_print_storage: MpPrintT = .{ .data = null, .print_strn = null };

fn _init_full_stubs_impl() callconv(.c) void {
    stub_mp_sys_stdout_print_storage = .{
        .data = @constCast(@ptrCast(&mp_sys_stdout_obj)),
        .print_strn = &mp_stream_write_adaptor,
    };
}
fn _init_full_stubs_noop() callconv(.c) void {}

// cur_exception — MP_STATE_VM root pointer slot (mp_obj_base_t *).
// Read/written by vm.c when MICROPY_PY_SYS_EXC_INFO=1.
var stub_cur_exception_storage: ?*anyopaque = null;

// ── Modules + singletons (4) — full-only ─────────────────────────────

// mp_module_io — PORTED: now provided by vendor py/modio.c
// re-added to the compile graph under is_full in build.zig. Depends on
// stream.zig's ROM exports + file_io.zig's mp_builtin_open_obj.

// mp_const_notimplemented_obj — vendor objsingleton.c: {{&mp_type_singleton}, MP_QSTR_NotImplemented}.
// F-rehab Fix: zero-init crashed print() because base.type read as NULL. Init to
// real singleton fields so the print slot (singleton_print → %q name) works.
const MpObjSingletonStub = extern struct {
    base_type: ?*const anyopaque,
    name: u16,
    _pad: [6]u8 = .{0} ** 6,
};
const mp_qstr = @cImport({
    @cInclude("py/qstr.h");
});
extern const mp_type_singleton: anyopaque;
var stub_mp_const_notimplemented_obj_storage: MpObjSingletonStub = .{
    .base_type = &mp_type_singleton,
    .name = mp_qstr.MP_QSTR_NotImplemented,
};

// mp_type_code — vendor py/objfun.c: const mp_obj_type_t mp_type_code.
var stub_mp_type_code_storage: [256]u8 align(8) = [_]u8{0} ** 256;

// mp_warning — PORTED: real impl now provided
// by vendor py/warning.c re-added to the compile graph under is_full in
// build.zig. Routes via &mp_stderr_print (defined in mpprint.zig).

// ── String/sequence helpers (3) — full-only ──────────────────────────

extern const mp_type_str: anyopaque;

inline fn isQstr(o: Obj) bool {
    // mp_obj_is_qstr: REPR_A — low 3 bits == 010 → qstr.
    return (o & 7) == 2;
}
inline fn objBaseType(o: Obj) ?*const anyopaque {
    const base: *const mirrors.MpObjBase = @ptrFromInt(o);
    return base.type;
}

// mp_obj_is_str(o) — vendor macro. Some full-only Zig call sites expect
// it as a function symbol (`@extern fn`).
fn stub_mp_obj_is_str(o: Obj) callconv(.c) bool {
    if (isQstr(o)) return true;
    if (o == 0) return false;
    if ((o & 7) != 0) return false;
    return objBaseType(o) == @as(?*const anyopaque, &mp_type_str);
}

// mp_obj_is_tuple_compatible(o) — vendor macro (objtuple.h:65):
//   MP_OBJ_TYPE_GET_SLOT_OR_NULL(mp_obj_get_type(o), iter) == mp_obj_tuple_getiter
// True for plain tuple AND namedtuple (both share the same iter slot).
extern fn mp_obj_get_type(o: Obj) callconv(.c) ?*const anyopaque;
extern fn mp_obj_tuple_getiter(o_in: Obj, iter_buf: ?*anyopaque) callconv(.c) Obj;
fn stub_mp_obj_is_tuple_compatible(o: Obj) callconv(.c) bool {
    const tp = mp_obj_get_type(o);
    if (tp == null) return false;
    const t = mirrors.MpObjType.fromPtr(tp);
    const iter_slot = t.getSlot(.iter) orelse return false;
    return iter_slot == @as(*const anyopaque, @ptrCast(&mp_obj_tuple_getiter));
}

// str_index_to_ptr — PORTED (F-rehab Fix 2) by src/objects/strings/objstr.zig
// as `_full_str_index_to_ptr` (UTF-8-walking version for str; mp_get_index
// fast path for bytes/bytearray). Conditionally exported there.

// ── NLR residual — removed (F-rehab) ─────────────────────────────────
// npy_pyerr_nlr_jump was deleted in NX-3. obj.zig:133 + objstr.zig:613
// converted to polled-sentinel under full (no jump; pending_exc stays
// set). The full_stubs.zig export is gone.

// ── NX-3-deleted vendor raise helpers, re-stubbed for F2a ─────────────
// Vendor py/objint.c + py/objint_mpz.c (re-added under full in F2a)
// call these noreturn helpers on error paths (divide-by-zero, NaN→int,
// negative-shift, non-numeric ctor arg, etc.). NX-3 deleted the Zig
// definitions because their nano callers were strangled. Under full
// the vendor call sites are live again.
//
// Set pyerr.pending_exc before @panic. The
// noreturn ABI is preserved; the test still dies, but if any caller
// path manages to poll pending_exc before the panic propagates, it
// sees a useful exception object. This is best-effort — full unwinding
// across vendor C still needs NLR (deleted) or signature-changing
// porting (out of F-rehab scope).
const pyerr = @import("../pyerr.zig");
extern fn mp_obj_new_exception_msg(t: *const anyopaque, msg: [*:0]const u8) callconv(.c) Obj;
extern const mp_type_TypeError: anyopaque;
extern const mp_type_ValueError: anyopaque;

fn stub_mp_raise_msg(t: ?*const anyopaque, msg: ?[*:0]const u8) callconv(.c) noreturn {
    if (t) |tp| {
        if (msg) |m| {
            pyerr.pending_exc = mp_obj_new_exception_msg(tp, m);
        }
    }
    @panic("full-arm stub: mp_raise_msg — NX-3 deleted");
}

fn stub_mp_raise_msg_varg(t: ?*const anyopaque, fmt: ?[*:0]const u8, ...) callconv(.c) noreturn {
    if (t) |tp| {
        if (fmt) |m| {
            // varg formatting deferred — raise with literal format string.
            pyerr.pending_exc = mp_obj_new_exception_msg(tp, m);
        }
    }
    @panic("full-arm stub: mp_raise_msg_varg — NX-3 deleted");
}

fn stub_mp_raise_ValueError(msg: ?[*:0]const u8) callconv(.c) noreturn {
    if (msg) |m| {
        pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_ValueError, m);
    }
    @panic("full-arm stub: mp_raise_ValueError — NX-3 deleted");
}

fn stub_mp_raise_TypeError_int_conversion(arg: Obj) callconv(.c) noreturn {
    _ = arg;
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_TypeError, "can't convert to int");
    @panic("full-arm stub: mp_raise_TypeError_int_conversion — NX-3 deleted");
}

// ── Comptime export gate ─────────────────────────────────────────────
// All symbols above are exported to their C ABI names ONLY when running
// under `CONFIG=full`. Under nano the existing live exports in objint.zig,
// objstr.zig, modsys.zig, etc. take precedence at link time.

comptime {
    // npy_init_full_stubs is always exported (called from embed.zig);
    // it's a no-op under nano.
    if (build_options.is_full) {
        @export(&_init_full_stubs_impl, .{ .name = "npy_init_full_stubs" });
    } else {
        @export(&_init_full_stubs_noop, .{ .name = "npy_init_full_stubs" });
    }
    // mp_const_notimplemented_obj is exported on BOTH arms — it's a
    // 1-word singleton used by NotImplemented in modbuiltins.zig:1022,
    // and the comparison check in objtype.zig:303 (binary-op chain).
    // The storage struct and its initialization are identical across
    // configs; gating it on is_full was a leftover from when only full
    // had the modbuiltins entry. ADR 009 Lane A3a — gate-removal.
    @export(&stub_mp_const_notimplemented_obj_storage, .{ .name = "mp_const_notimplemented_obj" });
    if (build_options.is_full) {
        // Long-int — PORTED (F2a): the 14 export entries that lived here
        // are now provided by vendor py/objint.c + py/objint_mpz.c + py/mpz.c
        // (see build.zig is_full carveout).

        // Complex (4)
        @export(&stub_mp_obj_complex_binary_op, .{ .name = "mp_obj_complex_binary_op" });
        @export(&stub_mp_obj_complex_get, .{ .name = "mp_obj_complex_get" });
        @export(&stub_mp_obj_new_complex, .{ .name = "mp_obj_new_complex" });
        @export(&stub_mp_type_complex_storage, .{ .name = "mp_type_complex" });

        // Sys (2) — mp_sys_maxsize_obj now comes from vendor objint_mpz.c (F2a)
        @export(&stub_mp_sys_stdout_print_storage, .{ .name = "mp_sys_stdout_print" });
        @export(&stub_cur_exception_storage, .{ .name = "cur_exception" });

        // Modules + singletons (3) — mp_module_io now comes from vendor py/modio.c (F5)
        // mp_warning now comes from vendor py/warning.c (finishing touches)
        @export(&stub_mp_type_code_storage, .{ .name = "mp_type_code" });

        // String/sequence helpers (2; str_index_to_ptr now ported in objstr.zig)
        @export(&stub_mp_obj_is_str, .{ .name = "mp_obj_is_str" });
        @export(&stub_mp_obj_is_tuple_compatible, .{ .name = "mp_obj_is_tuple_compatible" });

        // NLR residual — removed in F-rehab (was npy_pyerr_nlr_jump).

        // NX-3-deleted vendor raise helpers — ADR 012 Phase 3.5 step 4
        // moved these to unconditional exports in src/runtime/raise.zig
        // (real impls, not @panic stubs) because vendor MPZ code under
        // full calls mp_raise_msg / mp_raise_ValueError for "divide by
        // zero", "negative shift count", "buffer too small", etc.
    }
}
