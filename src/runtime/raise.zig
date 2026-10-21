//! nanopython — surviving mp_raise_* helpers + m_malloc_fail.
//!
//! NX-3 N4 (2026-06-05): m_malloc_fail is now polled — sets
//! pyerr.pending_exc + returns instead of longjmping via nlr_raise.
//! Allocators (`memory/alloc.zig`, `memory/gc.zig`) propagate the
//! libc-null result up to callers. The memoryerror.py path:
//! allocator-caller sees null → returns OBJ_NULL (slot-fn ABI) →
//! mp_binary_op's polled-sentinel check (runtime.zig:576) lifts
//! pending_exc into PyError → exception_handler catches.
//!
//! This eliminates the last Zig-originated nlr_jump call site under
//! nano. The C trampoline + nlrsetjmp.c stay only because the 5
//! npy_nlr_run host sites (vm.zig, runtime.zig×2, runtime_utils.zig×2,
//! objgetitemiter.zig) still defensively wrap their bodies — their
//! `if (exc_c != null)` branches are now effectively dead under nano;
//! only the polled-sentinel path fires. A follow-up session can
//! strangle them.
//!
//! NX-3 N4b (2026-06-05): mp_raise_TypeError and mp_raise_OSError are
//! @panic stubs — their callers (`support/stream.zig` +
//! `modules/file_io.zig`) are dead under nano so the panics never
//! fire.
//!
//! NX-3 N3b (2026-06-05): hub conversion. The vendor-noreturn parade
//! (mp_raise_ValueError, _NotImplementedError, _StopIteration,
//! _OSError_with_filename, _TypeError_int_conversion) and the broad
//! polled-extern sibling family (mp_raise_msg_polled / _ValueError_polled
//! / …) all had zero callers in the nano compile graph — they were
//! vendor-public ABI that nothing in the zigonly build actually used.
//! Deleted.

const mirrors = @import("../mp_mirrors.zig");
const pyerr = @import("../pyerr.zig");
const build_options = @import("build_options");

const Obj = mirrors.Obj;

// Exception constructors used by mp_raise_OSError_polled.
extern fn mp_obj_new_exception_args(t: *const anyopaque, n: usize, args: [*c]const Obj) callconv(.c) Obj;

// Exception constructors used by m_malloc_fail.
extern fn mp_obj_new_exception_msg(t: *const anyopaque, msg: [*:0]const u8) callconv(.c) Obj;

// Exception type singletons used by surviving raisers.
extern const mp_type_OSError: anyopaque;
extern const mp_type_MemoryError: anyopaque;

inline fn newExcArg1(t: *const anyopaque, arg: Obj) Obj {
    const args = [_]Obj{arg};
    return mp_obj_new_exception_args(t, 1, &args);
}

// ── polled (Phase B-3): set pyerr.pending_exc + return ────────────
// Only `mp_raise_OSError_polled` survives — `zig_compile_bridge.zig`
// calls it on the OOM path during compile/exec.

pub export fn mp_raise_OSError_polled(errno_: c_int) callconv(.c) void {
    pyerr.pending_exc = newExcArg1(&mp_type_OSError, mirrors.newSmallInt(errno_));
}

// ── NORETURN: vendor C raise helpers. Dead under nano (no caller in
// the active runtime) but reachable under full via vendor MPZ
// (objint_mpz.c mp_obj_int_pow3 type-check), modre, file_io. ADR 012
// Phase 3.5 step 6 — liberated from @panic so vendor C raises set
// pending_exc + print + exit (same shape as the other nano_mp_raise_*
// helpers below).

pub export fn mp_raise_TypeError(msg: ?[*:0]const u8) callconv(.c) noreturn {
    const exc = if (msg) |m| mp_obj_new_exception_msg(&mp_type_TypeError, m) else mp_obj_new_exception(&mp_type_TypeError);
    longlongRaiseDie(exc);
}

pub export fn mp_raise_OSError(errno_: c_int) callconv(.c) noreturn {
    longlongRaiseDie(newExcArg1(&mp_type_OSError, mirrors.newSmallInt(errno_)));
}

// ── m_malloc_fail — MemoryError raise (polled) ────────────────────
// Called from C-ABI allocator paths in `memory/alloc.zig` +
// `memory/gc.zig`. NX-3 N4: no longer noreturn — sets the polled
// sentinel and returns. The allocator returns the libc-null result;
// callers must propagate (return OBJ_NULL from slot fn, or
// `return error.PyRaise` from PyError fn).
//
// Signature keeps `num_bytes: usize` for ABI back-compat (alloc.zig
// + gc.zig pass it but the arg is unused; TERSE error reporting has
// no format-string formatting anyway).
pub export fn m_malloc_fail(num_bytes: usize) callconv(.c) void {
    _ = num_bytes;
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_MemoryError, "memory allocation failed");
}

comptime {
    _ = &m_malloc_fail;
    _ = &mp_raise_TypeError;
    _ = &mp_raise_OSError;
    _ = &mp_raise_OSError_polled;
}

// ── Vendor-C raise bridge (nano arm) ──────────────────────────────────
//
// Vendor py/objint_longlong.c (wasm32-nano LONGLONG carveout) and
// vendor py/objfloat.c + py/formatfloat.c (FLOAT carveout — both nano
// arms) call mp_raise_msg / mp_raise_ValueError on edge cases —
// overflow, divide-by-zero, negative shift, NaN/Inf-to-int, etc.
// Under main's strangled runtime (py/runtime.c gone) those symbols
// don't exist on nano. Provide thin bridges that:
//
//   1. Allocate the exception (so the type + msg are preserved).
//   2. Stash it in pyerr.pending_exc.
//   3. Print a clean Python-style traceback to stderr.
//   4. exit(1).
//
// We can't do the polled-sentinel propagation here because vendor C
// expects MP_NORETURN — caller doesn't check pending_exc. Cleanly
// exiting is the right UX (matches what slim-wasm's wasm_setjmp.c
// nlr_jump override did before main's polled-sentinel arc obviated
// it for the Zig-side raise paths).
//
// Gated to nano builds — under full, a subset is overridden by stubs
// in full_stubs.zig that use @panic (full's float/int arms are wired
// differently). The handful that don't have full-side replacements
// (mp_raise_NotImplementedError, mp_raise_type_arg) are exported
// unconditionally — see the second comptime block below.
const nano_raise_active = !build_options.is_full;
const longlong_raise_active = nano_raise_active; // back-compat alias

extern const mp_plat_print: anyopaque;
extern fn mp_obj_print_exception(print: *const anyopaque, exc: Obj) callconv(.c) void;
extern fn mp_obj_new_exception(t: *const anyopaque) callconv(.c) Obj;
extern fn mp_print_str(print: *const anyopaque, str: [*:0]const u8) callconv(.c) void;
extern fn exit(code: c_int) callconv(.c) noreturn;

fn longlongRaiseDie(exc: Obj) noreturn {
    // Use mp_print_str (which writes via fwrite on a real FILE*) instead
    // of fprintf(NULL, ...) — wasi-libc dereferences the FILE*'s vtable
    // for the formatter, and a NULL FILE* puts that lookup in the wasm
    // function-table region (which traps "uninitialized element"). The
    // body already routes through mp_plat_print; route the prefix there
    // too. fflush(NULL) had the same trap shape — dropping it is fine,
    // mp_plat_print's fwrite is already line-buffered to stderr.
    pyerr.pending_exc = exc;

    // ADR 013 — if a wrap-call trampoline registered an nlr_buf_t,
    // longjmp to it instead of exiting. The trampoline converts the
    // longjmp back into the polled-sentinel pattern, restoring
    // try/except over vendor-C raises. Native + full only; under nano
    // and under wasm32 full, exception_unwind is false and we fall
    // through to print + exit (status quo).
    const nlr_trampoline = @import("nlr_trampoline.zig");
    if (nlr_trampoline.hasActiveHandler()) {
        nlr_trampoline.raiseViaLongjmp(exc);
    }

    mp_print_str(&mp_plat_print, "Traceback (most recent call last):\n");
    mp_obj_print_exception(&mp_plat_print, exc);
    exit(1);
}

fn nano_mp_raise_msg(t: *const anyopaque, msg: ?[*:0]const u8) callconv(.c) noreturn {
    const exc = if (msg) |m| mp_obj_new_exception_msg(t, m) else mp_obj_new_exception(t);
    longlongRaiseDie(exc);
}

fn nano_mp_raise_msg_varg(t: *const anyopaque, fmt: ?[*:0]const u8, ...) callconv(.c) noreturn {
    // varg formatting deferred — raise with the literal format string.
    const exc = if (fmt) |m| mp_obj_new_exception_msg(t, m) else mp_obj_new_exception(t);
    longlongRaiseDie(exc);
}

extern const mp_type_ValueError: anyopaque;
extern const mp_type_NotImplementedError: anyopaque;
extern const mp_type_TypeError: anyopaque;

fn nano_mp_raise_ValueError(msg: ?[*:0]const u8) callconv(.c) noreturn {
    const exc = if (msg) |m| mp_obj_new_exception_msg(&mp_type_ValueError, m) else mp_obj_new_exception(&mp_type_ValueError);
    longlongRaiseDie(exc);
}

fn nano_mp_raise_NotImplementedError(msg: ?[*:0]const u8) callconv(.c) noreturn {
    const exc = if (msg) |m| mp_obj_new_exception_msg(&mp_type_NotImplementedError, m) else mp_obj_new_exception(&mp_type_NotImplementedError);
    longlongRaiseDie(exc);
}

// mp_raise_TypeError_int_conversion(arg) — called by vendor objint.c
// when int() receives a non-coercible object. The arg's type isn't
// formatted into the message (ERROR_REPORTING=NORMAL omits it for the
// terse path); raise TypeError with a generic message.
fn nano_mp_raise_TypeError_int_conversion(arg: Obj) callconv(.c) noreturn {
    _ = arg;
    longlongRaiseDie(mp_obj_new_exception_msg(&mp_type_TypeError, "can't convert to int"));
}

// mp_raise_type_arg(type, arg) — vendor extmod/modre.c (and a few py/
// callers) raise an exception of a given type with a single arg (e.g.
// raise TypeError(arg)). Used by modre.c when the regex compile/match
// fails. Mirrors the vendor noreturn ABI; allocates the exception
// with the arg, sets pyerr.pending_exc, prints traceback + exits.
fn nano_mp_raise_type_arg(t: *const anyopaque, arg: Obj) callconv(.c) noreturn {
    longlongRaiseDie(newExcArg1(t, arg));
}

comptime {
    // All raise helpers are exported on BOTH arms — vendor MPZ code
    // (objint_mpz.c "divide by zero" / "negative shift count" /
    // "buffer too small"; objint.c int_to_bytes; modre.c regex errors)
    // calls them under full. The implementations don't depend on
    // anything nano-specific (just pyerr.pending_exc + print + exit).
    // full_stubs.zig used to provide @panic-on-call stubs for the first
    // four — removed in ADR 012 Phase 3.5 step 4.
    @export(&nano_mp_raise_msg, .{ .name = "mp_raise_msg" });
    @export(&nano_mp_raise_msg_varg, .{ .name = "mp_raise_msg_varg" });
    @export(&nano_mp_raise_ValueError, .{ .name = "mp_raise_ValueError" });
    @export(&nano_mp_raise_TypeError_int_conversion, .{ .name = "mp_raise_TypeError_int_conversion" });
    @export(&nano_mp_raise_NotImplementedError, .{ .name = "mp_raise_NotImplementedError" });
    @export(&nano_mp_raise_type_arg, .{ .name = "mp_raise_type_arg" });
}

