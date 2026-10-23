//! petitpy — Zig port of py/scheduler.c.
//!
//! Under nano (probed): SCHEDULER=0, KBD_EXCEPTION=0, VM_ABORT=0,
//! PY_THREAD=0, the SCHEDULER_STATIC_NODES + EVENT_POLL_HOOK families
//! are all #if-dead. The live remainder is ~30 LOC:
//!   - mp_sched_exception(exc): set pending exception (no raise)
//!   - mp_handle_pending_internal(behavior): check + optionally raise
//!     the pending exception (the ONLY raise path in the file)
//!   - mp_event_handle_nowait / _wait_indefinite / _wait_ms: thin
//!     wrappers around mp_handle_pending under nano (the
//!     MICROPY_INTERNAL_WFE macro is (void)0).
//!
//! The raise is via the shared PyError bridge. The
//! MICROPY_BEGIN/END_ATOMIC_SECTION macros under nano are no-ops so
//! the `atomic_state` local is faithfully kept as a dead var (kept
//! so the line-by-line correspondence to C is unambiguous; the
//! compiler optimises it out).
//!
//! Pending-exception slot: under nano (PY_THREAD=0) the MicroPython C
//! code resolves MP_STATE_THREAD(mp_pending_exception) to a single
//! global slot. We implement that slot here as a module-level `var`
//! and expose the three npy_sch_* accessors the C shim API declares.

const mp = @cImport({
    @cInclude("py/runtime.h");
});
const mirrors = @import("../mp_mirrors.zig");
const pyerr = @import("../pyerr.zig");
const PyError = pyerr.PyError;

const Obj = mirrors.Obj;

// MP_OBJ_NULL (sentinel for "no pending exc") = (mp_obj_t)0
const MP_OBJ_NULL: Obj = 0;

// Backing storage for MP_STATE_THREAD(mp_pending_exception) under nano
// (PY_THREAD=0 collapses the per-thread slot to a single global).
var pending_exception: Obj = MP_OBJ_NULL;

export fn npy_sch_get_pending() callconv(.c) Obj {
    return pending_exception;
}

export fn npy_sch_set_pending(exc: Obj) callconv(.c) void {
    pending_exception = exc;
}

export fn npy_sch_clear_pending() callconv(.c) void {
    pending_exception = MP_OBJ_NULL;
}

export fn mp_sched_exception(exc: Obj) callconv(.c) void {
    npy_sch_set_pending(exc);
    // SCHEDULER=0 + PY_THREAD=0 → the sched_state optimisation block is dead.
}

fn mpHandlePendingInternalImpl(behavior: c_int) PyError!void {
    const handle_exceptions = behavior != mp.MP_HANDLE_PENDING_CALLBACKS_ONLY;
    const raise_exceptions = behavior == mp.MP_HANDLE_PENDING_CALLBACKS_AND_EXCEPTIONS;

    // VM_ABORT=0 → vm-abort block dead.

    // Handle any pending exception.
    if (handle_exceptions and npy_sch_get_pending() != MP_OBJ_NULL) {
        // BEGIN_ATOMIC: nano = no-op; atomic_state kept for faithfulness.
        const obj = npy_sch_get_pending();
        if (obj != MP_OBJ_NULL) {
            npy_sch_clear_pending();
            if (raise_exceptions) {
                // END_ATOMIC (no-op), then nlr_raise(obj) → PyError convention
                pyerr.pending_exc = obj;
                return error.PyRaise;
            }
        }
        // END_ATOMIC (no-op)
    }
    // SCHEDULER=0 → pending-callbacks block dead.
}

export fn mp_handle_pending_internal(behavior: c_int) callconv(.c) void {
    pyerr.bridge(void, mpHandlePendingInternalImpl(behavior));
}

// EVENT_POLL_HOOK_FAST=0 + PREVIEW_VERSION_2=0 → only the #else
// branch lives: MICROPY_INTERNAL_EVENT_HOOK; mp_handle_pending(true).
// Both expand to a single mp_handle_pending(true) call under nano.
export fn mp_event_handle_nowait() callconv(.c) void {
    mp_handle_pending_internal(mp.MP_HANDLE_PENDING_CALLBACKS_AND_EXCEPTIONS);
}

// EVENT_POLL_HOOK=0 + PREVIEW_VERSION_2=0 → only the #else branch lives:
// mp_event_handle_nowait(); MICROPY_INTERNAL_WFE(-1)=(void)0.
export fn mp_event_wait_indefinite() callconv(.c) void {
    mp_event_handle_nowait();
}

export fn mp_event_wait_ms(_: usize) callconv(.c) void {
    mp_event_handle_nowait();
}

comptime {
    _ = &npy_sch_get_pending;
    _ = &npy_sch_set_pending;
    _ = &npy_sch_clear_pending;
    _ = &mp_sched_exception;
    _ = &mp_handle_pending_internal;
    _ = &mp_event_handle_nowait;
    _ = &mp_event_wait_indefinite;
    _ = &mp_event_wait_ms;
}
