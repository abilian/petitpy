//! petitpy — Zig port of py/modarray.c (the `array` builtin module).
//!
//! Tiny module: just two entries (`__name__`, `array`). The
//! MP_REGISTER_EXTENSIBLE_MODULE marker stays in modarray.c (a 4-line
//! tombstone) for the qstr-gen scanner.
//!
//! ADR-002 F2 — gated on build_options.feature_array. When off, the
//! module export disappears and the reference to vendor's `mp_type_array`
//! (which itself becomes undefined under MICROPY_PY_ARRAY=0) is dropped.

const build_options = @import("build_options");
const mirrors = @import("../mp_mirrors.zig");

const Obj = mirrors.Obj;
const Qstr = usize;

const RomEntry = extern struct {
    key: Obj,
    value: *const anyopaque,
};

const enabled = build_options.feature_array;

const Body = if (enabled) struct {
    const mp = @cImport({
        @cInclude("py/qstr.h");
    });

    extern const mp_type_module: anyopaque;
    extern const mp_type_dict: anyopaque;
    extern const mp_type_array: anyopaque;

    const mp_module_array_globals_table = [_]RomEntry{
        .{
            .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR___name__)),
            .value = @ptrFromInt(mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_array))),
        },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_array)), .value = &mp_type_array },
    };

    pub export const mp_module_array_globals: mirrors.MpObjDict = .{
        .base = .{ .type = &mp_type_dict },
        .map = .{
            .bits = .{
                .all_keys_are_qstrs = 1,
                .is_fixed = 1,
                .is_ordered = 1,
                .used = mp_module_array_globals_table.len,
            },
            .alloc = mp_module_array_globals_table.len,
            .table = @ptrCast(@constCast(&mp_module_array_globals_table)),
        },
    };

    pub export const mp_module_array: mirrors.MpObjModule = .{
        .base = .{ .type = &mp_type_module },
        .globals = @ptrCast(@constCast(&mp_module_array_globals)),
    };
} else struct {};

comptime {
    if (enabled) {
        _ = &Body.mp_module_array;
        _ = &Body.mp_module_array_globals;
    }
}
