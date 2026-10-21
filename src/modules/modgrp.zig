//! nanopython — Zig-native `grp` module (getgrnam/getgrgid).
//!
//! notes/plans/full-unix-profile.md phase 7. Thin libc wrapper.
//!
//!   grp.getgrnam(name) → struct_group
//!   grp.getgrgid(gid)  → struct_group
//!
//! Fields: gr_name, gr_passwd, gr_gid, gr_mem (list of member names).
//!
//! Raises KeyError when the name/gid is not found (per CPython).
//!
//! Gated on build_options.feature_pwd_grp. Never on for wasm.
//!
//! __qstr_shadow_begin__
//! #if MICROPY_PY_GRP
//! MP_QSTR_grp
//! MP_QSTR_getgrnam
//! MP_QSTR_getgrgid
//! MP_QSTR_gr_name
//! MP_QSTR_gr_passwd
//! MP_QSTR_gr_gid
//! MP_QSTR_gr_mem
//! MP_REGISTER_MODULE(MP_QSTR_grp, mp_module_grp);
//! #endif
//! __qstr_shadow_end__

const build_options = @import("build_options");
const mirrors = @import("../mp_mirrors.zig");
const pyerr = @import("../pyerr.zig");

const Obj = mirrors.Obj;
const Qstr = usize;

const enabled = build_options.feature_pwd_grp;

const Body = if (enabled) struct {
    const mp = @cImport({
        @cInclude("py/qstr.h");
    });
    const grp_h = @cImport({
        @cInclude("grp.h");
    });

    extern const mp_type_module: anyopaque;
    extern const mp_type_dict: anyopaque;
    extern const mp_type_fun_builtin_1: anyopaque;
    extern const mp_type_KeyError: anyopaque;

    extern fn mp_obj_new_str_from_cstr(s: [*:0]const u8) callconv(.c) Obj;
    extern fn mp_obj_new_list(n: usize, items: [*c]const Obj) callconv(.c) Obj;
    extern fn mp_obj_list_append(list: Obj, item: Obj) callconv(.c) Obj;
    extern fn mp_obj_get_int(o: Obj) callconv(.c) isize;
    extern fn mp_obj_str_get_str(o: Obj) callconv(.c) ?[*:0]const u8;
    extern fn mp_obj_new_attrtuple(fields: [*]const Qstr, n: usize, items: [*c]const Obj) callconv(.c) Obj;
    extern fn mp_obj_new_exception_args(t: *const anyopaque, n_args: usize, args: [*c]const Obj) callconv(.c) Obj;
    extern fn getgrnam(name: [*:0]const u8) callconv(.c) ?*grp_h.struct_group;
    extern fn getgrgid(gid: c_uint) callconv(.c) ?*grp_h.struct_group;

    const group_fields: [4]Qstr = .{
        @intCast(mp.MP_QSTR_gr_name),
        @intCast(mp.MP_QSTR_gr_passwd),
        @intCast(mp.MP_QSTR_gr_gid),
        @intCast(mp.MP_QSTR_gr_mem),
    };

    fn buildGroupResult(g: *grp_h.struct_group) Obj {
        // Build gr_mem — g.gr_mem is a null-terminated array of C strings.
        const members = mp_obj_new_list(0, null);
        if (g.gr_mem != null) {
            var i: usize = 0;
            while (g.gr_mem[i] != null) : (i += 1) {
                _ = mp_obj_list_append(members, mp_obj_new_str_from_cstr(g.gr_mem[i].?));
            }
        }
        const items = [4]Obj{
            mp_obj_new_str_from_cstr(g.gr_name),
            mp_obj_new_str_from_cstr(g.gr_passwd),
            mirrors.newSmallInt(@intCast(g.gr_gid)),
            members,
        };
        return mp_obj_new_attrtuple(&group_fields, 4, &items);
    }

    fn raiseKeyError(name_obj: Obj) Obj {
        const args = [_]Obj{name_obj};
        pyerr.pending_exc = mp_obj_new_exception_args(&mp_type_KeyError, 1, &args);
        return mirrors.OBJ_NULL;
    }

    fn py_getgrnam(name_obj: Obj) callconv(.c) Obj {
        const name = mp_obj_str_get_str(name_obj) orelse return raiseKeyError(name_obj);
        const g = getgrnam(name) orelse return raiseKeyError(name_obj);
        return buildGroupResult(g);
    }

    fn py_getgrgid(gid_obj: Obj) callconv(.c) Obj {
        const gid: c_uint = @intCast(mp_obj_get_int(gid_obj));
        const g = getgrgid(gid) orelse return raiseKeyError(gid_obj);
        return buildGroupResult(g);
    }

    pub export const mp_grp_getgrnam_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_getgrnam) };
    pub export const mp_grp_getgrgid_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_getgrgid) };

    const RomEntry = extern struct {
        key: Obj,
        value: *const anyopaque,
    };

    inline fn qKey(q: usize) Obj {
        return mirrors.objFromQstr(@as(Qstr, q));
    }

    const mp_module_grp_globals_table = [_]RomEntry{
        .{ .key = qKey(mp.MP_QSTR___name__), .value = @ptrFromInt(qKey(mp.MP_QSTR_grp)) },
        .{ .key = qKey(mp.MP_QSTR_getgrnam), .value = &mp_grp_getgrnam_obj },
        .{ .key = qKey(mp.MP_QSTR_getgrgid), .value = &mp_grp_getgrgid_obj },
    };

    pub export const mp_module_grp_globals: mirrors.MpObjDict = .{
        .base = .{ .type = &mp_type_dict },
        .map = .{
            .bits = .{
                .all_keys_are_qstrs = 1,
                .is_fixed = 1,
                .is_ordered = 1,
                .used = mp_module_grp_globals_table.len,
            },
            .alloc = mp_module_grp_globals_table.len,
            .table = @ptrCast(@constCast(&mp_module_grp_globals_table)),
        },
    };

    pub export const mp_module_grp: mirrors.MpObjModule = .{
        .base = .{ .type = &mp_type_module },
        .globals = @ptrCast(@constCast(&mp_module_grp_globals)),
    };
} else struct {};

comptime {
    if (enabled) {
        _ = &Body.mp_module_grp;
        _ = &Body.mp_module_grp_globals;
        _ = &Body.mp_grp_getgrnam_obj;
        _ = &Body.mp_grp_getgrgid_obj;
    }
}
