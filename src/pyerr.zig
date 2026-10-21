//! nanopython — the B0-pinned nlr→error-union transport convention.
//! Shared by every B1.5-converted module (the argcheck spike proved
//! it; notes/11). Internal Zig fns return `PyError!T` and propagate
//! a raise via `try` (real multi-frame error propagation, no
//! longjmp). At the C-ABI boundary `bridge(T, r)` either returns the
//! T (success) or — in B1 mode — calls the shared C trampoline
//! `npy_pyerr_nlr_jump(pending_exc)` so the still-C caller unwinds
//! via the existing setjmp infrastructure. At B2 the bridge body is
//! deleted and PyError propagates purely; `pending_exc` and the
//! shim are then dead and removed.

const std = @import("std");

pub const PyError = error{PyRaise};
// Not `threadlocal`: polled on every opcode, and on macOS each TLS access
// is a call to tlv_get_addr (1.2x on fibo/bubble, notes/15). No threads
// today; with real `_thread` this belongs in per-thread VM state.
pub var pending_exc: usize = 0;

/// B2 EXPERIMENT (polled sentinel): bridge no longer longjmps. On
/// raise, pending_exc has already been set by the impl. We return a
/// zeroed T as a sentinel. Callers MUST check pending_exc after every
/// bridge-wrapped call. C callers see MP_OBJ_NULL on Obj returns.
pub inline fn bridge(comptime T: type, r: PyError!T) T {
    return r catch {
        return std.mem.zeroes(T);
    };
}

/// B2 polled-sentinel: C-callable accessors so C shims can detect+
/// propagate a Zig-side raise. EXPERIMENTAL (deleted after B2 finalization).
export fn npy_pyerr_get_pending() callconv(.c) usize {
    return pending_exc;
}
export fn npy_pyerr_take_pending() callconv(.c) usize {
    const e = pending_exc;
    pending_exc = 0;
    return e;
}
/// B2 polled-sentinel: C callers (esp. ones converting from nlr_raise)
/// use this to mark a pending exception then return their sentinel.
export fn npy_pyerr_set_pending(exc: usize) callconv(.c) void {
    pending_exc = exc;
}
