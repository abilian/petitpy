//! nanopython — Zig-native `signal` module MVP.
//!
//! notes/plans/full-unix-profile.md phase 5 (MVP). Ships the surface
//! `hop3-rootd`'s `__main__.py` calls at boot (`signal.signal(SIGTERM,
//! handler)` etc.) plus the common signal-number constants. Does NOT
//! actually dispatch the handler on signal delivery — proper delivery
//! needs bytecode-loop safepoint integration (deferred). Under this
//! MVP:
//!
//!   * `signal.signal(SIGTERM, handler)` records `handler` in a Zig-
//!     side table and returns `SIG_DFL` as the "previous handler". No
//!     libc `sigaction(2)` call is made — the process behaves per
//!     libc defaults (SIGTERM/SIGINT kill; SIGUSR1/2 kill on Linux,
//!     ignored on macOS).
//!   * hop3-rootd's daemon will therefore die on SIGTERM instead of
//!     shutting down gracefully. Everything ELSE at import + startup
//!     time works.
//!
//! When a downstream needs real delivery: add a safepoint dispatcher
//! in `src/runtime/vm.zig`'s main opcode loop, register a libc trampoline
//! that sets a `pending_signal` flag, and drain the flag at every
//! safepoint. Not this session.
//!
//! Gated on build_options.feature_signal. Never on for wasm.
//!
//! __qstr_shadow_begin__
//! #if MICROPY_PY_SIGNAL
//! MP_QSTR_signal
//! MP_QSTR_getsignal
//! MP_QSTR_SIGHUP
//! MP_QSTR_SIGINT
//! MP_QSTR_SIGQUIT
//! MP_QSTR_SIGKILL
//! MP_QSTR_SIGUSR1
//! MP_QSTR_SIGUSR2
//! MP_QSTR_SIGPIPE
//! MP_QSTR_SIGTERM
//! MP_QSTR_SIGCHLD
//! MP_QSTR_SIG_DFL
//! MP_QSTR_SIG_IGN
//! MP_REGISTER_MODULE(MP_QSTR_signal, mp_module_signal);
//! #endif
//! __qstr_shadow_end__

const build_options = @import("build_options");
const mirrors = @import("../mp_mirrors.zig");
const pyerr = @import("../pyerr.zig");

const Obj = mirrors.Obj;
const Qstr = usize;

const enabled = build_options.feature_signal;

const Body = if (enabled) struct {
    const mp = @cImport({
        @cInclude("py/qstr.h");
    });
    const signal_h = @cImport({
        @cInclude("signal.h");
    });

    extern const mp_type_module: anyopaque;
    extern const mp_type_dict: anyopaque;
    extern const mp_type_fun_builtin_1: anyopaque;
    extern const mp_type_fun_builtin_2: anyopaque;

    extern fn mp_obj_get_int(o: Obj) callconv(.c) isize;

    // Under MICROPY_OBJ_REPR_A: mp_const_none = 6.
    const MP_CONST_NONE: Obj = 0x06;
    fn returnNone() Obj {
        return MP_CONST_NONE;
    }

    // Handler registry — up to NSIG entries. Stores the handler that
    // was last set for each signum. NEVER called (MVP limitation).
    const NSIG: usize = 64;
    var handlers: [NSIG]Obj = @splat(MP_CONST_NONE);

    // signal.signal(signum, handler) → previous handler (always SIG_DFL
    // under MVP since we don't actually dispatch).
    fn py_signal(signum_obj: Obj, handler_obj: Obj) callconv(.c) Obj {
        const signum = mp_obj_get_int(signum_obj);
        if (signum < 0 or signum >= NSIG) return mirrors.newSmallInt(0);  // SIG_DFL
        const prev = handlers[@intCast(signum)];
        handlers[@intCast(signum)] = handler_obj;
        // Return the previous handler — SIG_DFL (0) if none set.
        if (prev == MP_CONST_NONE) return mirrors.newSmallInt(0);
        return prev;
    }

    // signal.getsignal(signum) → current handler or SIG_DFL.
    fn py_getsignal(signum_obj: Obj) callconv(.c) Obj {
        const signum = mp_obj_get_int(signum_obj);
        if (signum < 0 or signum >= NSIG) return mirrors.newSmallInt(0);
        const h = handlers[@intCast(signum)];
        if (h == MP_CONST_NONE) return mirrors.newSmallInt(0);
        return h;
    }

    pub export const mp_signal_signal_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_2 }, .fun = @ptrCast(&py_signal) };
    pub export const mp_signal_getsignal_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_getsignal) };

    const RomEntry = extern struct {
        key: Obj,
        value: *const anyopaque,
    };

    inline fn qKey(q: usize) Obj {
        return mirrors.objFromQstr(@as(Qstr, q));
    }
    inline fn intVal(v: isize) *const anyopaque {
        return @ptrFromInt(mirrors.newSmallInt(v));
    }

    const mp_module_signal_globals_table = [_]RomEntry{
        .{ .key = qKey(mp.MP_QSTR___name__), .value = @ptrFromInt(qKey(mp.MP_QSTR_signal)) },
        .{ .key = qKey(mp.MP_QSTR_signal), .value = &mp_signal_signal_obj },
        .{ .key = qKey(mp.MP_QSTR_getsignal), .value = &mp_signal_getsignal_obj },
        // Constants. Values from signal.h — differ macOS vs Linux only
        // for USR1/USR2 (macOS: 30/31; Linux: 10/12). We take whatever
        // the cImport gives us for the running platform.
        .{ .key = qKey(mp.MP_QSTR_SIGHUP), .value = intVal(@intCast(signal_h.SIGHUP)) },
        .{ .key = qKey(mp.MP_QSTR_SIGINT), .value = intVal(@intCast(signal_h.SIGINT)) },
        .{ .key = qKey(mp.MP_QSTR_SIGQUIT), .value = intVal(@intCast(signal_h.SIGQUIT)) },
        .{ .key = qKey(mp.MP_QSTR_SIGKILL), .value = intVal(@intCast(signal_h.SIGKILL)) },
        .{ .key = qKey(mp.MP_QSTR_SIGUSR1), .value = intVal(@intCast(signal_h.SIGUSR1)) },
        .{ .key = qKey(mp.MP_QSTR_SIGUSR2), .value = intVal(@intCast(signal_h.SIGUSR2)) },
        .{ .key = qKey(mp.MP_QSTR_SIGPIPE), .value = intVal(@intCast(signal_h.SIGPIPE)) },
        .{ .key = qKey(mp.MP_QSTR_SIGTERM), .value = intVal(@intCast(signal_h.SIGTERM)) },
        .{ .key = qKey(mp.MP_QSTR_SIGCHLD), .value = intVal(@intCast(signal_h.SIGCHLD)) },
        // SIG_DFL / SIG_IGN — CPython represents them as ints 0 / 1
        // rather than the void-fn ptrs from libc. Match CPython.
        .{ .key = qKey(mp.MP_QSTR_SIG_DFL), .value = intVal(0) },
        .{ .key = qKey(mp.MP_QSTR_SIG_IGN), .value = intVal(1) },
    };

    pub export const mp_module_signal_globals: mirrors.MpObjDict = .{
        .base = .{ .type = &mp_type_dict },
        .map = .{
            .bits = .{
                .all_keys_are_qstrs = 1,
                .is_fixed = 1,
                .is_ordered = 1,
                .used = mp_module_signal_globals_table.len,
            },
            .alloc = mp_module_signal_globals_table.len,
            .table = @ptrCast(@constCast(&mp_module_signal_globals_table)),
        },
    };

    pub export const mp_module_signal: mirrors.MpObjModule = .{
        .base = .{ .type = &mp_type_module },
        .globals = @ptrCast(@constCast(&mp_module_signal_globals)),
    };
} else struct {};

comptime {
    if (enabled) {
        _ = &Body.mp_module_signal;
        _ = &Body.mp_module_signal_globals;
        _ = &Body.mp_signal_signal_obj;
        _ = &Body.mp_signal_getsignal_obj;
    }
}
