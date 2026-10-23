//! petitpy — Zig port of py/modcollections.c (the `collections` module).
//! Nano: DEQUE=1, ORDEREDDICT=1 → 4-entry globals dict.
//!
//! ADR-002 F2 — gated on build_options.feature_collections so
//! -Dfeature-collections=false drops the entire module body (and its
//! references to mp_namedtuple_obj / mp_type_deque / mp_type_ordereddict,
//! which become undefined symbols under MICROPY_PY_COLLECTIONS=0).

const build_options = @import("build_options");
const mirrors = @import("../mp_mirrors.zig");

const Obj = mirrors.Obj;
const Qstr = usize;

const RomEntry = extern struct {
    key: Obj,
    value: *const anyopaque,
};

const enabled = build_options.feature_collections;

const Body = if (enabled) struct {
    const mp = @cImport({
        @cInclude("py/qstr.h");
    });

    extern const mp_type_module: anyopaque;
    extern const mp_type_dict: anyopaque;
    extern const mp_type_deque: anyopaque;
    extern const mp_namedtuple_obj: anyopaque;
    extern const mp_type_ordereddict: anyopaque;

    const mp_module_collections_globals_table = [_]RomEntry{
        .{
            .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR___name__)),
            .value = @ptrFromInt(mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_collections))),
        },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_deque)), .value = &mp_type_deque },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_namedtuple)), .value = &mp_namedtuple_obj },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_OrderedDict)), .value = &mp_type_ordereddict },
    };

    pub export const mp_module_collections_globals: mirrors.MpObjDict = .{
        .base = .{ .type = &mp_type_dict },
        .map = .{
            .bits = .{
                .all_keys_are_qstrs = 1,
                .is_fixed = 1,
                .is_ordered = 1,
                .used = mp_module_collections_globals_table.len,
            },
            .alloc = mp_module_collections_globals_table.len,
            .table = @ptrCast(@constCast(&mp_module_collections_globals_table)),
        },
    };

    pub export const mp_module_collections: mirrors.MpObjModule = .{
        .base = .{ .type = &mp_type_module },
        .globals = @ptrCast(@constCast(&mp_module_collections_globals)),
    };
} else struct {};

comptime {
    if (enabled) {
        _ = &Body.mp_module_collections;
        _ = &Body.mp_module_collections_globals;
    }
}
