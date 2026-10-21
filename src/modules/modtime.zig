//! nanopython — Zig-native `time` module for native POSIX.
//!
//! notes/plans/full-unix-profile.md phase 2. Ships the subset stdlib-
//! only daemons like `hop3-rootd` actually reach for:
//!
//!   Functions: time, monotonic, sleep, time_ns, monotonic_ns,
//!              perf_counter, sleep_ms, ticks_ms
//!
//! All wall-clock / monotonic time comes from clock_gettime(2); sleep
//! from nanosleep(2). Floats used when nanopython's float type is on
//! (MICROPY_PY_BUILTINS_FLOAT=1 — enabled on both nano and full arms
//! per port/mpconfigport.h:134), so the `time.monotonic() - started`
//! subtraction hop3-rootd's server.py depends on works correctly.
//!
//! Gated on `build_options.feature_time`; when off, the module body
//! is `else struct{}` and nothing compiles. Not built on wasm — WASI
//! has clock_time_get and poll_oneoff but the polled-sentinel + sleep
//! shape doesn't map cleanly.
//!
//! __qstr_shadow_begin__
//! #if MICROPY_PY_TIME
//! MP_QSTR_time
//! MP_QSTR_monotonic
//! MP_QSTR_sleep
//! MP_QSTR_time_ns
//! MP_QSTR_monotonic_ns
//! MP_QSTR_perf_counter
//! MP_QSTR_sleep_ms
//! MP_QSTR_ticks_ms
//! MP_QSTR_ticks_diff
//! MP_REGISTER_MODULE(MP_QSTR_time, mp_module_time);
//! #endif
//! __qstr_shadow_end__

const build_options = @import("build_options");
const mirrors = @import("../mp_mirrors.zig");
const pyerr = @import("../pyerr.zig");
const errno_compat = @import("../support/errno_compat.zig");

const Obj = mirrors.Obj;
const Qstr = usize;

const enabled = build_options.feature_time;

const Body = if (enabled) struct {
    const mp = @cImport({
        @cInclude("py/qstr.h");
    });
    const errno_h = @cImport({
        @cInclude("errno.h");
    });
    const time_h = @cImport({
        @cInclude("time.h");
    });

    extern const mp_type_module: anyopaque;
    extern const mp_type_dict: anyopaque;
    extern const mp_type_fun_builtin_0: anyopaque;
    extern const mp_type_fun_builtin_1: anyopaque;
    extern const mp_type_fun_builtin_2: anyopaque;

    extern fn mp_obj_new_float(v: f64) callconv(.c) Obj;
    extern fn mp_obj_get_int(o: Obj) callconv(.c) isize;
    extern fn mp_obj_get_float(o: Obj) callconv(.c) f64;
    extern fn mp_raise_OSError_polled(errno_: c_int) callconv(.c) void;

    // clock_gettime(2) — CLOCK_REALTIME for time.time, CLOCK_MONOTONIC
    // for time.monotonic. Both universal on Linux + macOS.
    extern fn clock_gettime(clk_id: c_int, ts: *time_h.struct_timespec) callconv(.c) c_int;
    // nanosleep(2) — usable-anywhere sleep primitive.
    extern fn nanosleep(req: *const time_h.struct_timespec, rem: ?*time_h.struct_timespec) callconv(.c) c_int;

    const CLOCK_REALTIME: c_int = 0;
    // CLOCK_MONOTONIC values differ across platforms — resolve via cImport
    // (macOS uses 6, Linux uses 1). Wrap in a compile-time fetch.
    const CLOCK_MONOTONIC: c_int = @intCast(time_h.CLOCK_MONOTONIC);

    // Under MICROPY_OBJ_REPR_A, mp_const_none is the immediate value
    // (0 << 3) | 6 = 6. Same trick as modos.zig.
    const MP_CONST_NONE: Obj = 0x06;
    fn returnNone() Obj {
        return MP_CONST_NONE;
    }

    fn raiseOSError(err: c_int) Obj {
        mp_raise_OSError_polled(err);
        return mirrors.OBJ_NULL;
    }

    inline fn now(clk: c_int) f64 {
        var ts: time_h.struct_timespec = undefined;
        _ = clock_gettime(clk, &ts);
        return @as(f64, @floatFromInt(ts.tv_sec)) + @as(f64, @floatFromInt(ts.tv_nsec)) / 1_000_000_000.0;
    }

    inline fn nowNs(clk: c_int) i64 {
        var ts: time_h.struct_timespec = undefined;
        _ = clock_gettime(clk, &ts);
        return @as(i64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(i64, @intCast(ts.tv_nsec));
    }

    // ── Functions ────────────────────────────────────────────────────

    fn py_time() callconv(.c) Obj {
        return mp_obj_new_float(now(CLOCK_REALTIME));
    }

    fn py_monotonic() callconv(.c) Obj {
        return mp_obj_new_float(now(CLOCK_MONOTONIC));
    }

    // Sleep the given number of seconds. Accepts float or int.
    fn py_sleep(secs_obj: Obj) callconv(.c) Obj {
        // mp_obj_get_float works for both int and float inputs.
        const secs = mp_obj_get_float(secs_obj);
        if (secs < 0) return raiseOSError(errno_h.EINVAL);
        var req: time_h.struct_timespec = undefined;
        const whole: f64 = @trunc(secs);
        req.tv_sec = @intFromFloat(whole);
        req.tv_nsec = @intFromFloat((secs - whole) * 1_000_000_000.0);
        // Retry on EINTR — vendor CPython and MicroPython do the same.
        while (nanosleep(&req, &req) < 0) {
            if (errno_compat.errnoRef().* != errno_h.EINTR) return raiseOSError(errno_compat.errnoRef().*);
        }
        return returnNone();
    }

    // Integer-nanosecond variants — CPython adds these to avoid the
    // float precision loss for high-resolution monotonic reads.
    fn py_time_ns() callconv(.c) Obj {
        return mirrors.newSmallInt(@intCast(nowNs(CLOCK_REALTIME)));
    }

    fn py_monotonic_ns() callconv(.c) Obj {
        return mirrors.newSmallInt(@intCast(nowNs(CLOCK_MONOTONIC)));
    }

    // MicroPython aliases — some existing MP-shaped code uses these.
    // sleep_ms(n) — sleep n milliseconds. Never negative.
    fn py_sleep_ms(n_obj: Obj) callconv(.c) Obj {
        const n = mp_obj_get_int(n_obj);
        if (n <= 0) return returnNone();
        var req: time_h.struct_timespec = undefined;
        req.tv_sec = @divTrunc(n, 1000);
        req.tv_nsec = @rem(n, 1000) * 1_000_000;
        while (nanosleep(&req, &req) < 0) {
            if (errno_compat.errnoRef().* != errno_h.EINTR) return raiseOSError(errno_compat.errnoRef().*);
        }
        return returnNone();
    }

    // ticks_ms — monotonic clock in milliseconds. Wraps like MicroPython,
    // but we return the full 64-bit value so wrap-arithmetic isn't
    // strictly needed for realistic uptimes.
    fn py_ticks_ms() callconv(.c) Obj {
        const ns = nowNs(CLOCK_MONOTONIC);
        return mirrors.newSmallInt(@intCast(@divTrunc(ns, 1_000_000)));
    }

    // ticks_diff(a, b) — a-b, matching MicroPython convention.
    fn py_ticks_diff(a_obj: Obj, b_obj: Obj) callconv(.c) Obj {
        const a = mp_obj_get_int(a_obj);
        const b = mp_obj_get_int(b_obj);
        return mirrors.newSmallInt(a - b);
    }

    // ── Function-object exports ──────────────────────────────────────

    pub export const mp_time_time_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_0 }, .fun = @ptrCast(&py_time) };
    pub export const mp_time_monotonic_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_0 }, .fun = @ptrCast(&py_monotonic) };
    pub export const mp_time_sleep_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_sleep) };
    pub export const mp_time_time_ns_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_0 }, .fun = @ptrCast(&py_time_ns) };
    pub export const mp_time_monotonic_ns_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_0 }, .fun = @ptrCast(&py_monotonic_ns) };
    pub export const mp_time_sleep_ms_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_sleep_ms) };
    pub export const mp_time_ticks_ms_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_0 }, .fun = @ptrCast(&py_ticks_ms) };
    pub export const mp_time_ticks_diff_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_2 }, .fun = @ptrCast(&py_ticks_diff) };

    // ── Module globals dict ──────────────────────────────────────────

    const RomEntry = extern struct {
        key: Obj,
        value: *const anyopaque,
    };

    inline fn qKey(q: usize) Obj {
        return mirrors.objFromQstr(@as(Qstr, q));
    }

    const mp_module_time_globals_table = [_]RomEntry{
        .{ .key = qKey(mp.MP_QSTR___name__), .value = @ptrFromInt(qKey(mp.MP_QSTR_time)) },
        .{ .key = qKey(mp.MP_QSTR_time), .value = &mp_time_time_obj },
        .{ .key = qKey(mp.MP_QSTR_monotonic), .value = &mp_time_monotonic_obj },
        .{ .key = qKey(mp.MP_QSTR_sleep), .value = &mp_time_sleep_obj },
        .{ .key = qKey(mp.MP_QSTR_time_ns), .value = &mp_time_time_ns_obj },
        .{ .key = qKey(mp.MP_QSTR_monotonic_ns), .value = &mp_time_monotonic_ns_obj },
        // perf_counter aliases monotonic (CPython says so).
        .{ .key = qKey(mp.MP_QSTR_perf_counter), .value = &mp_time_monotonic_obj },
        .{ .key = qKey(mp.MP_QSTR_sleep_ms), .value = &mp_time_sleep_ms_obj },
        .{ .key = qKey(mp.MP_QSTR_ticks_ms), .value = &mp_time_ticks_ms_obj },
        .{ .key = qKey(mp.MP_QSTR_ticks_diff), .value = &mp_time_ticks_diff_obj },
    };

    pub export const mp_module_time_globals: mirrors.MpObjDict = .{
        .base = .{ .type = &mp_type_dict },
        .map = .{
            .bits = .{
                .all_keys_are_qstrs = 1,
                .is_fixed = 1,
                .is_ordered = 1,
                .used = mp_module_time_globals_table.len,
            },
            .alloc = mp_module_time_globals_table.len,
            .table = @ptrCast(@constCast(&mp_module_time_globals_table)),
        },
    };

    pub export const mp_module_time: mirrors.MpObjModule = .{
        .base = .{ .type = &mp_type_module },
        .globals = @ptrCast(@constCast(&mp_module_time_globals)),
    };
} else struct {};

comptime {
    if (enabled) {
        _ = &Body.mp_module_time;
        _ = &Body.mp_module_time_globals;
        _ = &Body.mp_time_time_obj;
        _ = &Body.mp_time_monotonic_obj;
        _ = &Body.mp_time_sleep_obj;
        _ = &Body.mp_time_time_ns_obj;
        _ = &Body.mp_time_monotonic_ns_obj;
        _ = &Body.mp_time_sleep_ms_obj;
        _ = &Body.mp_time_ticks_ms_obj;
        _ = &Body.mp_time_ticks_diff_obj;
    }
}
