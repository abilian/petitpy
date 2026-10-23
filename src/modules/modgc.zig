//! petitpy — full Zig port of py/modgc.c (the `gc` builtin module).
//!
//! Builds the ROM data (fn-obj defs + globals dict + module struct) in
//! Zig. The `MP_REGISTER_MODULE(MP_QSTR_gc, mp_module_gc)` marker stays
//! in a 4-line modgc_shim.c tombstone — qstr-gen scans only .c sources.
//!
//! Config (under nano + full):
//!   PY_GC_COLLECT_RETVAL=1: collect() returns int(gc_collected). The
//!     bumping gc.zig allocator never sets gc_collected; always 0.
//!   GC_SPLIT_HEAP_AUTO=0: mem_free reads info.free only.
//!   GC_ALLOC_THRESHOLD=ROM_LEVEL≥CORE_FEATURES: nano (MINIMUM) → 0;
//!     full (CORE_FEATURES) → 1. gc_threshold is full-only.
//!
//! ADR-002 F2 — gated on build_options.feature_gc_module. Independent
//! of MICROPY_ENABLE_GC (the underlying GC subsystem stays on either way).
//! When off, the entire Python-facing gc module + its 7 fn-obj wrappers
//! around gc_collect/gc_info/state-poke drop out.

const build_options = @import("build_options");
const mirrors = @import("../mp_mirrors.zig");

const Obj = mirrors.Obj;
const Qstr = usize;

const RomEntry = extern struct {
    key: Obj,
    value: *const anyopaque,
};

const enabled = build_options.feature_gc_module;

const Body = if (enabled) struct {
    const mp = @cImport({
        @cInclude("py/qstr.h");
    });
    const mp_cfg = @cImport({
        @cInclude("py/mpconfig.h");
    });
    const state = @import("../runtime/mpstate.zig");

    // Gate the threshold ROM entry on the *C* macro the rest of the runtime
    // uses (defaults to `ROM_LEVEL_AT_LEAST_CORE_FEATURES`, i.e. 0 under our
    // MINIMUM-by-default config). Keying off `build_options.is_full` instead
    // would diverge from vendor's `#if MICROPY_GC_ALLOC_THRESHOLD` and
    // reference a qstr the scanner never emits.
    const HAS_GC_THRESHOLD: bool = mp_cfg.MICROPY_GC_ALLOC_THRESHOLD;

    extern const mp_type_module: anyopaque;
    extern const mp_type_dict: anyopaque;
    extern const mp_type_fun_builtin_0: anyopaque;
    extern const mp_type_fun_builtin_var: anyopaque;
    extern fn gc_collect() callconv(.c) void;
    extern fn mp_obj_get_int(arg: Obj) callconv(.c) isize;
    extern fn mp_obj_new_int(v: isize) callconv(.c) Obj;

    const GcInfo = extern struct {
        total: usize,
        used: usize,
        free: usize,
        max_free: usize,
        num_1block: usize,
        num_2block: usize,
        max_block: usize,
    };
    extern fn gc_info(info: *GcInfo) callconv(.c) void;

    fn py_gc_collect() callconv(.c) Obj {
        gc_collect();
        return mirrors.newSmallInt(0);
    }

    fn py_gc_disable() callconv(.c) Obj {
        state.memState().gc_auto_collect_enabled = 0;
        return mirrors.OBJ_NONE;
    }

    fn py_gc_enable() callconv(.c) Obj {
        state.memState().gc_auto_collect_enabled = 1;
        return mirrors.OBJ_NONE;
    }

    fn py_gc_isenabled() callconv(.c) Obj {
        return mirrors.newBool(state.memState().gc_auto_collect_enabled != 0);
    }

    fn py_gc_mem_free() callconv(.c) Obj {
        var info: GcInfo = undefined;
        gc_info(&info);
        return mirrors.newSmallInt(@bitCast(info.free));
    }

    fn py_gc_mem_alloc() callconv(.c) Obj {
        var info: GcInfo = undefined;
        gc_info(&info);
        return mirrors.newSmallInt(@bitCast(info.used));
    }

    fn py_gc_threshold(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
        _ = n_args;
        _ = args;
        return mirrors.OBJ_NONE;
    }

    pub export const gc_collect_obj: mirrors.MpObjFunBuiltinFixed = .{
        .base = .{ .type = &mp_type_fun_builtin_0 },
        .fun = @ptrCast(&py_gc_collect),
    };
    pub export const gc_disable_obj: mirrors.MpObjFunBuiltinFixed = .{
        .base = .{ .type = &mp_type_fun_builtin_0 },
        .fun = @ptrCast(&py_gc_disable),
    };
    pub export const gc_enable_obj: mirrors.MpObjFunBuiltinFixed = .{
        .base = .{ .type = &mp_type_fun_builtin_0 },
        .fun = @ptrCast(&py_gc_enable),
    };
    pub export const gc_isenabled_obj: mirrors.MpObjFunBuiltinFixed = .{
        .base = .{ .type = &mp_type_fun_builtin_0 },
        .fun = @ptrCast(&py_gc_isenabled),
    };
    pub export const gc_mem_free_obj: mirrors.MpObjFunBuiltinFixed = .{
        .base = .{ .type = &mp_type_fun_builtin_0 },
        .fun = @ptrCast(&py_gc_mem_free),
    };
    pub export const gc_mem_alloc_obj: mirrors.MpObjFunBuiltinFixed = .{
        .base = .{ .type = &mp_type_fun_builtin_0 },
        .fun = @ptrCast(&py_gc_mem_alloc),
    };
    pub export const gc_threshold_obj: mirrors.MpObjFunBuiltinVar = .{
        .base = .{ .type = &mp_type_fun_builtin_var },
        .sig = mirrors.makeFunSig(0, 1, false),
        .fun = @ptrCast(&py_gc_threshold),
    };

    const N_ENTRIES: usize = if (HAS_GC_THRESHOLD) 8 else 7;

    const mp_module_gc_globals_table: [N_ENTRIES]RomEntry = if (HAS_GC_THRESHOLD) .{
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR___name__)), .value = @ptrFromInt(mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_gc))) },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_collect)), .value = &gc_collect_obj },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_disable)), .value = &gc_disable_obj },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_enable)), .value = &gc_enable_obj },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_isenabled)), .value = &gc_isenabled_obj },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_mem_free)), .value = &gc_mem_free_obj },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_mem_alloc)), .value = &gc_mem_alloc_obj },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_threshold)), .value = &gc_threshold_obj },
    } else .{
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR___name__)), .value = @ptrFromInt(mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_gc))) },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_collect)), .value = &gc_collect_obj },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_disable)), .value = &gc_disable_obj },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_enable)), .value = &gc_enable_obj },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_isenabled)), .value = &gc_isenabled_obj },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_mem_free)), .value = &gc_mem_free_obj },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_mem_alloc)), .value = &gc_mem_alloc_obj },
    };

    pub export const mp_module_gc_globals: mirrors.MpObjDict = .{
        .base = .{ .type = &mp_type_dict },
        .map = .{
            .bits = .{ .all_keys_are_qstrs = 1, .is_fixed = 1, .is_ordered = 1, .used = N_ENTRIES },
            .alloc = N_ENTRIES,
            .table = @ptrCast(@constCast(&mp_module_gc_globals_table)),
        },
    };

    pub export const mp_module_gc: mirrors.MpObjModule = .{
        .base = .{ .type = &mp_type_module },
        .globals = @ptrCast(@constCast(&mp_module_gc_globals)),
    };
} else struct {};

comptime {
    if (enabled) {
        _ = &Body.mp_module_gc;
        _ = &Body.mp_module_gc_globals;
        _ = &Body.gc_collect_obj;
        _ = &Body.gc_disable_obj;
        _ = &Body.gc_enable_obj;
        _ = &Body.gc_isenabled_obj;
        _ = &Body.gc_mem_free_obj;
        _ = &Body.gc_mem_alloc_obj;
        _ = &Body.gc_threshold_obj;
    }
}
