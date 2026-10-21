//! nanopython — Zig port of py/modmicropython.c (the `micropython`
//! builtin module).
//!
//! Under nano + full the live surface is the same 5 entries:
//!   __name__, const, opt_level, heap_lock, heap_unlock
//!
//! Disabled-by-config (nano = full = OFF):
//!   MEM_INFO, STACK_USE, EMERGENCY_EXCEPTION_BUF, PYSTACK, KBD_EXCEPTION,
//!   RINGIO, SCHEDULER, MICROPY_PY_MICROPYTHON_HEAP_LOCKED.
//!
//! GC_LOCK_DEPTH_SHIFT = 0 (FINALISER=0), so the `gc_lock_depth >> SHIFT`
//! in heap_unlock collapses to a raw read.
//!
//! ADR-002 F2 — gated on build_options.feature_micropython. When off the
//! module export disappears; the 3 helper fn objs become dead and the
//! linker DCEs the bodies + `gc_lock`/`gc_unlock`/state-read refs.
//!
//! The MP_REGISTER_MODULE marker stays in src/modules/modmicropython.c
//! (a 4-line tombstone) — makemoduledefs.py scans only .c sources.

const build_options = @import("build_options");
const mirrors = @import("../mp_mirrors.zig");

const Obj = mirrors.Obj;
const Qstr = usize;

const RomEntry = extern struct {
    key: Obj,
    value: *const anyopaque,
};

const enabled = build_options.feature_micropython;

const Body = if (enabled) struct {
    const mp = @cImport({
        @cInclude("py/qstr.h");
    });
    const state = @import("../runtime/mpstate.zig");

    extern const mp_type_module: anyopaque;
    extern const mp_type_dict: anyopaque;
    extern const mp_type_fun_builtin_0: anyopaque;
    extern const mp_type_fun_builtin_var: anyopaque;
    extern const mp_identity_obj: anyopaque;

    extern fn gc_lock() callconv(.c) void;
    extern fn gc_unlock() callconv(.c) void;
    extern fn mp_obj_get_int(arg: Obj) callconv(.c) isize;

    fn py_micropython_opt_level(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
        if (n_args == 0) {
            return mirrors.newSmallInt(@bitCast(state.vmState().mp_optimise_value));
        }
        state.vmState().mp_optimise_value = @bitCast(mp_obj_get_int(args[0]));
        return mirrors.OBJ_NONE;
    }

    fn py_micropython_heap_lock() callconv(.c) Obj {
        gc_lock();
        return mirrors.OBJ_NONE;
    }

    fn py_micropython_heap_unlock() callconv(.c) Obj {
        gc_unlock();
        // GC_LOCK_DEPTH_SHIFT = 0 under nano (FINALISER=0), so >> 0 is identity.
        return mirrors.newSmallInt(@as(isize, @intCast(state.threadState().gc_lock_depth)));
    }

    pub export const mp_micropython_opt_level_obj: mirrors.MpObjFunBuiltinVar = .{
        .base = .{ .type = &mp_type_fun_builtin_var },
        .sig = mirrors.makeFunSig(0, 1, false),
        .fun = @ptrCast(&py_micropython_opt_level),
    };
    pub export const mp_micropython_heap_lock_obj: mirrors.MpObjFunBuiltinFixed = .{
        .base = .{ .type = &mp_type_fun_builtin_0 },
        .fun = @ptrCast(&py_micropython_heap_lock),
    };
    pub export const mp_micropython_heap_unlock_obj: mirrors.MpObjFunBuiltinFixed = .{
        .base = .{ .type = &mp_type_fun_builtin_0 },
        .fun = @ptrCast(&py_micropython_heap_unlock),
    };

    const mp_module_micropython_globals_table = [_]RomEntry{
        .{
            .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR___name__)),
            .value = @ptrFromInt(mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_micropython))),
        },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_const)), .value = &mp_identity_obj },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_opt_level)), .value = &mp_micropython_opt_level_obj },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_heap_lock)), .value = &mp_micropython_heap_lock_obj },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_heap_unlock)), .value = &mp_micropython_heap_unlock_obj },
    };

    pub export const mp_module_micropython_globals: mirrors.MpObjDict = .{
        .base = .{ .type = &mp_type_dict },
        .map = .{
            .bits = .{
                .all_keys_are_qstrs = 1,
                .is_fixed = 1,
                .is_ordered = 1,
                .used = mp_module_micropython_globals_table.len,
            },
            .alloc = mp_module_micropython_globals_table.len,
            .table = @ptrCast(@constCast(&mp_module_micropython_globals_table)),
        },
    };

    pub export const mp_module_micropython: mirrors.MpObjModule = .{
        .base = .{ .type = &mp_type_module },
        .globals = @ptrCast(@constCast(&mp_module_micropython_globals)),
    };
} else struct {};

comptime {
    if (enabled) {
        _ = &Body.mp_module_micropython;
        _ = &Body.mp_module_micropython_globals;
        _ = &Body.mp_micropython_opt_level_obj;
        _ = &Body.mp_micropython_heap_lock_obj;
        _ = &Body.mp_micropython_heap_unlock_obj;
    }
}
