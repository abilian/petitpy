//! nanopython — Zig-native `pwd` module (getpwnam/getpwuid).
//!
//! Full-native only. Thin libc wrapper.
//!
//!   pwd.getpwnam(name) → struct_passwd
//!   pwd.getpwuid(uid)  → struct_passwd
//!
//! Returns an attrtuple with the CPython field names: pw_name, pw_passwd,
//! pw_uid, pw_gid, pw_gecos, pw_dir, pw_shell.
//!
//! Raises KeyError when the name/uid is not found (per CPython).
//!
//! Gated on build_options.feature_pwd_grp. Never on for wasm.
//!
//! __qstr_shadow_begin__
//! #if MICROPY_PY_PWD
//! MP_QSTR_pwd
//! MP_QSTR_getpwnam
//! MP_QSTR_getpwuid
//! MP_QSTR_pw_name
//! MP_QSTR_pw_passwd
//! MP_QSTR_pw_uid
//! MP_QSTR_pw_gid
//! MP_QSTR_pw_gecos
//! MP_QSTR_pw_dir
//! MP_QSTR_pw_shell
//! MP_REGISTER_MODULE(MP_QSTR_pwd, mp_module_pwd);
//! #endif
//! __qstr_shadow_end__

const build_options = @import("build_options");
const mirrors = @import("../mp_mirrors.zig");
const pyerr = @import("../pyerr.zig");
const errno_compat = @import("../support/errno_compat.zig");

const Obj = mirrors.Obj;
const Qstr = usize;

const enabled = build_options.feature_pwd_grp;

const Body = if (enabled) struct {
    const mp = @cImport({
        @cInclude("py/qstr.h");
    });
    const errno_h = @cImport({
        @cInclude("errno.h");
    });
    const pwd_h = @cImport({
        @cInclude("pwd.h");
    });

    extern const mp_type_module: anyopaque;
    extern const mp_type_dict: anyopaque;
    extern const mp_type_fun_builtin_1: anyopaque;
    extern const mp_type_KeyError: anyopaque;

    extern fn mp_obj_new_str_from_cstr(s: [*:0]const u8) callconv(.c) Obj;
    extern fn mp_obj_get_int(o: Obj) callconv(.c) isize;
    extern fn mp_obj_str_get_str(o: Obj) callconv(.c) ?[*:0]const u8;
    extern fn mp_obj_new_attrtuple(fields: [*]const Qstr, n: usize, items: [*c]const Obj) callconv(.c) Obj;
    extern fn mp_obj_new_exception_args(t: *const anyopaque, n_args: usize, args: [*c]const Obj) callconv(.c) Obj;
    extern fn getpwnam(name: [*:0]const u8) callconv(.c) ?*pwd_h.struct_passwd;
    extern fn getpwuid(uid: c_uint) callconv(.c) ?*pwd_h.struct_passwd;

    const passwd_fields: [7]Qstr = .{
        @intCast(mp.MP_QSTR_pw_name),
        @intCast(mp.MP_QSTR_pw_passwd),
        @intCast(mp.MP_QSTR_pw_uid),
        @intCast(mp.MP_QSTR_pw_gid),
        @intCast(mp.MP_QSTR_pw_gecos),
        @intCast(mp.MP_QSTR_pw_dir),
        @intCast(mp.MP_QSTR_pw_shell),
    };

    fn buildPasswdResult(p: *pwd_h.struct_passwd) Obj {
        const items = [7]Obj{
            mp_obj_new_str_from_cstr(p.pw_name),
            mp_obj_new_str_from_cstr(p.pw_passwd),
            mirrors.newSmallInt(@intCast(p.pw_uid)),
            mirrors.newSmallInt(@intCast(p.pw_gid)),
            // pw_gecos is optional on some platforms; fall back to
            // empty string.
            if (p.pw_gecos != null) mp_obj_new_str_from_cstr(p.pw_gecos) else mp_obj_new_str_from_cstr(""),
            mp_obj_new_str_from_cstr(p.pw_dir),
            mp_obj_new_str_from_cstr(p.pw_shell),
        };
        return mp_obj_new_attrtuple(&passwd_fields, 7, &items);
    }

    fn raiseKeyError(name_obj: Obj) Obj {
        const args = [_]Obj{name_obj};
        pyerr.pending_exc = mp_obj_new_exception_args(&mp_type_KeyError, 1, &args);
        return mirrors.OBJ_NULL;
    }

    fn py_getpwnam(name_obj: Obj) callconv(.c) Obj {
        const name = mp_obj_str_get_str(name_obj) orelse return raiseKeyError(name_obj);
        errno_compat.errnoRef().* = 0;
        const p = getpwnam(name) orelse return raiseKeyError(name_obj);
        return buildPasswdResult(p);
    }

    fn py_getpwuid(uid_obj: Obj) callconv(.c) Obj {
        const uid: c_uint = @intCast(mp_obj_get_int(uid_obj));
        errno_compat.errnoRef().* = 0;
        const p = getpwuid(uid) orelse return raiseKeyError(uid_obj);
        return buildPasswdResult(p);
    }

    pub export const mp_pwd_getpwnam_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_getpwnam) };
    pub export const mp_pwd_getpwuid_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_getpwuid) };

    const RomEntry = extern struct {
        key: Obj,
        value: *const anyopaque,
    };

    inline fn qKey(q: usize) Obj {
        return mirrors.objFromQstr(@as(Qstr, q));
    }

    const mp_module_pwd_globals_table = [_]RomEntry{
        .{ .key = qKey(mp.MP_QSTR___name__), .value = @ptrFromInt(qKey(mp.MP_QSTR_pwd)) },
        .{ .key = qKey(mp.MP_QSTR_getpwnam), .value = &mp_pwd_getpwnam_obj },
        .{ .key = qKey(mp.MP_QSTR_getpwuid), .value = &mp_pwd_getpwuid_obj },
    };

    pub export const mp_module_pwd_globals: mirrors.MpObjDict = .{
        .base = .{ .type = &mp_type_dict },
        .map = .{
            .bits = .{
                .all_keys_are_qstrs = 1,
                .is_fixed = 1,
                .is_ordered = 1,
                .used = mp_module_pwd_globals_table.len,
            },
            .alloc = mp_module_pwd_globals_table.len,
            .table = @ptrCast(@constCast(&mp_module_pwd_globals_table)),
        },
    };

    pub export const mp_module_pwd: mirrors.MpObjModule = .{
        .base = .{ .type = &mp_type_module },
        .globals = @ptrCast(@constCast(&mp_module_pwd_globals)),
    };
} else struct {};

comptime {
    if (enabled) {
        _ = &Body.mp_module_pwd;
        _ = &Body.mp_module_pwd_globals;
        _ = &Body.mp_pwd_getpwnam_obj;
        _ = &Body.mp_pwd_getpwuid_obj;
    }
}
