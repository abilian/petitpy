//! petitpy — Zig-native `os` module for native POSIX.
//!
//! Full-native only. Ships enough surface for
//! stdlib-only privileged daemons like `hop3-rootd`:
//!
//!   Functions: urandom, open, close, read, write, lseek, fsync, chmod, chown,
//!              getpid, kill, getcwd, chdir, getenv, putenv, unsetenv,
//!              remove, unlink, rename, mkdir, rmdir, stat, lstat,
//!              listdir, readlink, symlink, access
//!   Ints:      O_RDONLY, O_WRONLY, O_RDWR, O_CREAT, O_TRUNC, O_APPEND,
//!              O_EXCL, F_OK, R_OK, W_OK, X_OK, SEEK_SET, SEEK_CUR, SEEK_END
//!   Strings:   sep, linesep, curdir, pardir, name, altsep, extsep
//!
//! Deferred to later slices (same feature gate): environ (dict proxy),
//! sysconf (hop3-rootd guards with hasattr), os.path submodule.
//!
//! Gated on `build_options.feature_os`; when off, the module body is
//! `else struct{}` and nothing compiles.
//!
//! __qstr_shadow_begin__
//! #if MICROPY_PY_OS
//! MP_QSTR_os
//! MP_QSTR_urandom
//! MP_QSTR_open
//! MP_QSTR_close
//! MP_QSTR_read
//! MP_QSTR_write
//! MP_QSTR_fsync
//! MP_QSTR_lseek
//! MP_QSTR_SEEK_SET
//! MP_QSTR_SEEK_CUR
//! MP_QSTR_SEEK_END
//! MP_QSTR_chmod
//! MP_QSTR_chown
//! MP_QSTR_getpid
//! MP_QSTR_kill
//! MP_QSTR_umask
//! MP_QSTR_getcwd
//! MP_QSTR_chdir
//! MP_QSTR_getenv
//! MP_QSTR_putenv
//! MP_QSTR_unsetenv
//! MP_QSTR_remove
//! MP_QSTR_unlink
//! MP_QSTR_rename
//! MP_QSTR_mkdir
//! MP_QSTR_rmdir
//! MP_QSTR_O_RDONLY
//! MP_QSTR_O_WRONLY
//! MP_QSTR_O_RDWR
//! MP_QSTR_O_CREAT
//! MP_QSTR_O_TRUNC
//! MP_QSTR_O_APPEND
//! MP_QSTR_O_EXCL
//! MP_QSTR_sep
//! MP_QSTR_altsep
//! MP_QSTR_extsep
//! MP_QSTR_linesep
//! MP_QSTR_curdir
//! MP_QSTR_pardir
//! MP_QSTR_name
//! MP_QSTR_stat
//! MP_QSTR_lstat
//! MP_QSTR_listdir
//! MP_QSTR_readlink
//! MP_QSTR_symlink
//! MP_QSTR_access
//! MP_QSTR_F_OK
//! MP_QSTR_R_OK
//! MP_QSTR_W_OK
//! MP_QSTR_X_OK
//! MP_QSTR_st_mode
//! MP_QSTR_st_ino
//! MP_QSTR_st_dev
//! MP_QSTR_st_nlink
//! MP_QSTR_st_uid
//! MP_QSTR_st_gid
//! MP_QSTR_st_size
//! MP_QSTR_st_atime
//! MP_QSTR_st_mtime
//! MP_QSTR_st_ctime
//! MP_QSTR_os_path
//! MP_QSTR_os_ext
//! MP_QSTR__environ
//! MP_QSTR___getattr__
//! MP_REGISTER_MODULE(MP_QSTR_os, mp_module_os);
//! #endif
//! __qstr_shadow_end__

const std = @import("std");
const build_options = @import("build_options");
const mirrors = @import("../mp_mirrors.zig");
const argcheck = @import("../runtime/argcheck.zig");
const pyerr = @import("../pyerr.zig");
const qstr_hash = @import("../support/qstr_hash.zig");
const errno_compat = @import("../support/errno_compat.zig");

const Obj = mirrors.Obj;
const Qstr = usize;

const enabled = build_options.feature_os;

const Body = if (enabled) struct {
    const mp = @cImport({
        @cInclude("py/qstr.h");
    });
    const errno_h = @cImport({
        @cInclude("errno.h");
    });
    const fcntl_h = @cImport({
        @cInclude("fcntl.h");
    });
    const sys_stat_h = @cImport({
        @cInclude("sys/stat.h");
    });
    const dirent_h = @cImport({
        @cInclude("dirent.h");
    });
    const unistd_h = @cImport({
        @cInclude("unistd.h");
    });
    const string_h = @cImport({
        @cInclude("string.h");
    });

    extern const mp_type_module: anyopaque;
    extern const mp_type_dict: anyopaque;
    extern const mp_type_str: anyopaque;
    extern const mp_type_fun_builtin_0: anyopaque;
    extern const mp_type_fun_builtin_1: anyopaque;
    extern const mp_type_fun_builtin_2: anyopaque;
    extern const mp_type_fun_builtin_3: anyopaque;
    extern const mp_type_fun_builtin_var: anyopaque;

    // ROM string constant helper. Hash is precomputed via the shimless
    // djb2 in support/qstr_hash.zig so `os.name == "posix"` etc.
    // succeed via the hash-check fast path in mp_obj_str_equal.
    inline fn romStr(comptime s: []const u8) mirrors.MpObjStr {
        return .{
            .base = .{ .type = &mp_type_str },
            .hash = qstr_hash.djb2Hash(s),
            .len = s.len,
            .data = s.ptr,
        };
    }

    const s_sep = "/";
    const s_altsep = "";
    const s_extsep = ".";
    const s_linesep = "\n";
    const s_curdir = ".";
    const s_pardir = "..";
    const s_name = "posix";

    pub export const mp_os_sep_str: mirrors.MpObjStr = romStr(s_sep);
    pub export const mp_os_altsep_str: mirrors.MpObjStr = romStr(s_altsep);
    pub export const mp_os_extsep_str: mirrors.MpObjStr = romStr(s_extsep);
    pub export const mp_os_linesep_str: mirrors.MpObjStr = romStr(s_linesep);
    pub export const mp_os_curdir_str: mirrors.MpObjStr = romStr(s_curdir);
    pub export const mp_os_pardir_str: mirrors.MpObjStr = romStr(s_pardir);
    pub export const mp_os_name_str: mirrors.MpObjStr = romStr(s_name);

    extern fn mp_obj_new_bytes(data: [*c]const u8, len: usize) callconv(.c) Obj;
    extern fn mp_obj_new_str_from_cstr(s: [*:0]const u8) callconv(.c) Obj;
    extern fn mp_obj_get_int(o: Obj) callconv(.c) isize;
    extern fn mp_obj_str_get_str(o: Obj) callconv(.c) ?[*:0]const u8;
    extern fn mp_obj_str_get_data(o: Obj, len_out: *usize) callconv(.c) [*]const u8;
    extern fn mp_call_function_1(fun: Obj, arg: Obj) callconv(.c) Obj;
    // Polled-sentinel raiser — sets pyerr.pending_exc + returns; caller
    // must return OBJ_NULL so the VM unwinds.
    extern fn mp_raise_OSError_polled(errno_: c_int) callconv(.c) void;

    extern fn open(pathname: [*:0]const u8, flags: c_int, ...) callconv(.c) c_int;
    extern fn close(fd: c_int) callconv(.c) c_int;
    extern fn read(fd: c_int, buf: [*]u8, count: usize) callconv(.c) isize;
    extern fn write(fd: c_int, buf: [*]const u8, count: usize) callconv(.c) isize;
    extern fn fsync(fd: c_int) callconv(.c) c_int;
    extern fn lseek(fd: c_int, offset: i64, whence: c_int) callconv(.c) i64;
    extern fn chmod(pathname: [*:0]const u8, mode: c_uint) callconv(.c) c_int;
    extern fn chown(pathname: [*:0]const u8, uid: c_uint, gid: c_uint) callconv(.c) c_int;
    extern fn getpid() callconv(.c) c_int;
    extern fn kill(pid: c_int, sig: c_int) callconv(.c) c_int;
    extern fn umask(mask: c_uint) callconv(.c) c_uint;
    extern fn getcwd(buf: [*]u8, size: usize) callconv(.c) ?[*:0]u8;
    extern fn chdir(path: [*:0]const u8) callconv(.c) c_int;
    extern fn getenv(name: [*:0]const u8) callconv(.c) ?[*:0]const u8;
    extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) callconv(.c) c_int;
    extern fn unsetenv(name: [*:0]const u8) callconv(.c) c_int;
    extern fn unlink(path: [*:0]const u8) callconv(.c) c_int;
    extern fn rename(old_: [*:0]const u8, new_: [*:0]const u8) callconv(.c) c_int;
    extern fn mkdir(path: [*:0]const u8, mode: c_uint) callconv(.c) c_int;
    extern fn rmdir(path: [*:0]const u8) callconv(.c) c_int;
    extern fn readlink(path: [*:0]const u8, buf: [*]u8, bufsiz: usize) callconv(.c) isize;
    extern fn symlink(target: [*:0]const u8, linkpath: [*:0]const u8) callconv(.c) c_int;
    extern fn access(path: [*:0]const u8, mode: c_int) callconv(.c) c_int;
    extern fn mp_obj_new_attrtuple(fields: [*]const Qstr, n: usize, items: [*c]const Obj) callconv(.c) Obj;
    extern fn mp_obj_new_list(n: usize, items: [*c]const Obj) callconv(.c) Obj;
    extern fn mp_obj_list_append(list: Obj, item: Obj) callconv(.c) Obj;

    extern fn mp_import_name(name: Qstr, fromlist: Obj, level: Obj) callconv(.c) Obj;
    extern fn mp_load_method_maybe(base: Obj, attr: Qstr, dest: *[2]Obj) callconv(.c) void;
    extern fn mp_obj_new_dict(n: usize) callconv(.c) Obj;
    extern fn mp_obj_dict_store(dict: Obj, key: Obj, value: Obj) callconv(.c) Obj;
    extern fn mp_obj_new_str(data: [*]const u8, len: usize) callconv(.c) Obj;
    extern fn mp_obj_new_exception_msg_varg(t: *const anyopaque, fmt: [*:0]const u8, ...) callconv(.c) Obj;
    extern const mp_type_AttributeError: anyopaque;

    // PEP 562 module __getattr__: `os.path` is petitpy-lib/os_path.py,
    // imported on first access, since the ROM globals dict cannot hold a
    // module loaded at run time. Anything else `os` lacks natively, such
    // as `environ` and `makedirs`, comes from petitpy-lib/os_ext.py.
    fn py_os_getattr(name: Obj) callconv(.c) Obj {
        const attr = mirrors.qstrValue(name);
        if (attr == mp.MP_QSTR_path) {
            return mp_import_name(mp.MP_QSTR_os_path, returnNone(), mirrors.newSmallInt(0));
        }
        const ext = mp_import_name(mp.MP_QSTR_os_ext, returnNone(), mirrors.newSmallInt(0));
        // Without os_ext on the path, the attribute is just missing.
        pyerr.pending_exc = 0;
        if (ext != mirrors.OBJ_NULL) {
            var dest: [2]Obj = .{ mirrors.OBJ_NULL, mirrors.OBJ_NULL };
            mp_load_method_maybe(ext, attr, &dest);
            if (dest[0] != mirrors.OBJ_NULL) return dest[0];
        }
        pyerr.pending_exc = mp_obj_new_exception_msg_varg(&mp_type_AttributeError, "no attribute '%q'", @as(usize, attr));
        return mirrors.OBJ_NULL;
    }

    // os._environ(): the process environment as a new dict, which
    // os_ext.environ starts from.
    fn py_os_environ() callconv(.c) Obj {
        const d = mp_obj_new_dict(0);
        var p = std.c.environ;
        while (p[0]) |entry| : (p += 1) {
            const s = std.mem.span(entry);
            const eq = std.mem.indexOfScalar(u8, s, '=') orelse continue;
            _ = mp_obj_dict_store(d, mp_obj_new_str(s.ptr, eq), mp_obj_new_str(s.ptr + eq + 1, s.len - eq - 1));
        }
        return d;
    }

    fn raiseOSError(err: c_int) Obj {
        mp_raise_OSError_polled(err);
        return mirrors.OBJ_NULL;
    }

    fn pathArg(o: Obj) ?[*:0]const u8 {
        // Fast path: real str/bytes object.
        if (mp_obj_str_get_str(o)) |s| return s;
        // Non-str fallback: petitpy doesn't ship the __fspath__
        // protocol, so anything with a meaningful __str__ (like our
        // pathlib.Path shim) needs a manual str() conversion here.
        // mp_obj_str_get_str set pyerr.pending_exc when it returned
        // null — clear it before the retry so a follow-up str() call
        // isn't tripped by the stale TypeError.
        pyerr.pending_exc = 0;
        const s_obj = mp_call_function_1(mirrors.objFromPtr(&mp_type_str), o);
        if (s_obj == mirrors.OBJ_NULL) return null;
        return mp_obj_str_get_str(s_obj);
    }

    // ── Functions ────────────────────────────────────────────────────

    // os.urandom(n) — n bytes from /dev/urandom.
    // ponytail: 4096-byte stack buffer, no heap. Covers uuid4 (16),
    // session tokens (32), keys (256). Larger → EFBIG; grow to a
    // vstr_t if a real caller ever needs it.
    fn py_os_urandom(n_obj: Obj) callconv(.c) Obj {
        const n_signed = mp_obj_get_int(n_obj);
        if (n_signed < 0) return raiseOSError(errno_h.EINVAL);
        const n: usize = @intCast(n_signed);
        if (n == 0) return mp_obj_new_bytes(null, 0);
        var buf: [4096]u8 = undefined;
        if (n > buf.len) return raiseOSError(errno_h.EFBIG);
        const fd = open("/dev/urandom", @intCast(fcntl_h.O_RDONLY));
        if (fd < 0) return raiseOSError(errno_compat.errnoRef().*);
        defer _ = close(fd);
        var offset: usize = 0;
        while (offset < n) {
            const got = read(fd, buf[offset..].ptr, n - offset);
            if (got < 0) return raiseOSError(errno_compat.errnoRef().*);
            if (got == 0) return raiseOSError(errno_h.EIO);
            offset += @intCast(got);
        }
        return mp_obj_new_bytes(&buf, n);
    }

    // os.open(path, flags[, mode]) — variadic 2..3 args. mode defaults
    // to 0o777 (masked by process umask, matching CPython).
    fn py_os_open(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
        const path = pathArg(args[0]) orelse return raiseOSError(errno_h.EINVAL);
        const flags: c_int = @intCast(mp_obj_get_int(args[1]));
        const mode: c_uint = if (n_args >= 3) @intCast(mp_obj_get_int(args[2])) else 0o777;
        const fd = open(path, flags, mode);
        if (fd < 0) return raiseOSError(errno_compat.errnoRef().*);
        return mirrors.newSmallInt(@intCast(fd));
    }

    // Under MICROPY_OBJ_REPR_A, mp_const_none is the immediate value
    // (0 << 3) | 6 = 6 — a vendor macro, not a linkable symbol.
    // See src/entry/embed_exec.zig for the same trick.
    const MP_CONST_NONE: Obj = 0x06;

    fn returnNone() Obj {
        return MP_CONST_NONE;
    }

    fn py_os_close(fd_obj: Obj) callconv(.c) Obj {
        const fd: c_int = @intCast(mp_obj_get_int(fd_obj));
        if (close(fd) < 0) return raiseOSError(errno_compat.errnoRef().*);
        return returnNone();
    }

    fn py_os_read(fd_obj: Obj, n_obj: Obj) callconv(.c) Obj {
        const fd: c_int = @intCast(mp_obj_get_int(fd_obj));
        const n_signed = mp_obj_get_int(n_obj);
        if (n_signed < 0) return raiseOSError(errno_h.EINVAL);
        const n: usize = @intCast(n_signed);
        if (n == 0) return mp_obj_new_bytes(null, 0);
        // ponytail: 4096-byte stack buffer, matches urandom. Bigger reads
        // → EFBIG; loop from Python or bump to a vstr later.
        var buf: [4096]u8 = undefined;
        if (n > buf.len) return raiseOSError(errno_h.EFBIG);
        const got = read(fd, &buf, n);
        if (got < 0) return raiseOSError(errno_compat.errnoRef().*);
        return mp_obj_new_bytes(&buf, @intCast(got));
    }

    fn py_os_write(fd_obj: Obj, data_obj: Obj) callconv(.c) Obj {
        const fd: c_int = @intCast(mp_obj_get_int(fd_obj));
        var len: usize = 0;
        const data = mp_obj_str_get_data(data_obj, &len);
        var offset: usize = 0;
        while (offset < len) {
            const got = write(fd, data + offset, len - offset);
            if (got < 0) return raiseOSError(errno_compat.errnoRef().*);
            if (got == 0) break;
            offset += @intCast(got);
        }
        return mirrors.newSmallInt(@intCast(offset));
    }

    fn py_os_lseek(fd_obj: Obj, pos_obj: Obj, how_obj: Obj) callconv(.c) Obj {
        const fd: c_int = @intCast(mp_obj_get_int(fd_obj));
        const at = lseek(fd, @intCast(mp_obj_get_int(pos_obj)), @intCast(mp_obj_get_int(how_obj)));
        if (at < 0) return raiseOSError(errno_compat.errnoRef().*);
        return mirrors.newSmallInt(@intCast(at));
    }

    fn py_os_fsync(fd_obj: Obj) callconv(.c) Obj {
        const fd: c_int = @intCast(mp_obj_get_int(fd_obj));
        if (fsync(fd) < 0) return raiseOSError(errno_compat.errnoRef().*);
        return returnNone();
    }

    fn py_os_chmod(path_obj: Obj, mode_obj: Obj) callconv(.c) Obj {
        const path = pathArg(path_obj) orelse return raiseOSError(errno_h.EINVAL);
        const mode: c_uint = @intCast(mp_obj_get_int(mode_obj));
        if (chmod(path, mode) < 0) return raiseOSError(errno_compat.errnoRef().*);
        return returnNone();
    }

    fn py_os_chown(path_obj: Obj, uid_obj: Obj, gid_obj: Obj) callconv(.c) Obj {
        const path = pathArg(path_obj) orelse return raiseOSError(errno_h.EINVAL);
        const uid: c_uint = @intCast(mp_obj_get_int(uid_obj));
        const gid: c_uint = @intCast(mp_obj_get_int(gid_obj));
        if (chown(path, uid, gid) < 0) return raiseOSError(errno_compat.errnoRef().*);
        return returnNone();
    }

    fn py_os_getpid() callconv(.c) Obj {
        return mirrors.newSmallInt(@intCast(getpid()));
    }

    fn py_os_kill(pid_obj: Obj, sig_obj: Obj) callconv(.c) Obj {
        const pid: c_int = @intCast(mp_obj_get_int(pid_obj));
        const sig: c_int = @intCast(mp_obj_get_int(sig_obj));
        if (kill(pid, sig) < 0) return raiseOSError(errno_compat.errnoRef().*);
        return returnNone();
    }

    // os.umask(mask) — set the process file-creation mask, return the
    // previous mask. `umask(2)` doesn't fail; no errno_compat.errnoRef().* propagation.
    fn py_os_umask(mask_obj: Obj) callconv(.c) Obj {
        const mask: c_uint = @intCast(mp_obj_get_int(mask_obj));
        const prev = umask(mask);
        return mirrors.newSmallInt(@intCast(prev));
    }

    // ponytail: PATH_MAX is 4096 on Linux, 1024 on macOS; use 4096 to
    // cover both. A path longer than that is ENAMETOOLONG anyway.
    fn py_os_getcwd() callconv(.c) Obj {
        var buf: [4096]u8 = undefined;
        const p = getcwd(&buf, buf.len) orelse return raiseOSError(errno_compat.errnoRef().*);
        return mp_obj_new_str_from_cstr(p);
    }

    fn py_os_chdir(path_obj: Obj) callconv(.c) Obj {
        const path = pathArg(path_obj) orelse return raiseOSError(errno_h.EINVAL);
        if (chdir(path) < 0) return raiseOSError(errno_compat.errnoRef().*);
        return returnNone();
    }

    // os.getenv(name[, default]) — returns str or default (None if missing).
    fn py_os_getenv(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
        const name = pathArg(args[0]) orelse return raiseOSError(errno_h.EINVAL);
        if (getenv(name)) |v| return mp_obj_new_str_from_cstr(v);
        if (n_args >= 2) return args[1];
        return returnNone();
    }

    fn py_os_putenv(name_obj: Obj, value_obj: Obj) callconv(.c) Obj {
        const name = pathArg(name_obj) orelse return raiseOSError(errno_h.EINVAL);
        const value = pathArg(value_obj) orelse return raiseOSError(errno_h.EINVAL);
        if (setenv(name, value, 1) < 0) return raiseOSError(errno_compat.errnoRef().*);
        return returnNone();
    }

    fn py_os_unsetenv(name_obj: Obj) callconv(.c) Obj {
        const name = pathArg(name_obj) orelse return raiseOSError(errno_h.EINVAL);
        if (unsetenv(name) < 0) return raiseOSError(errno_compat.errnoRef().*);
        return returnNone();
    }

    fn py_os_unlink(path_obj: Obj) callconv(.c) Obj {
        const path = pathArg(path_obj) orelse return raiseOSError(errno_h.EINVAL);
        if (unlink(path) < 0) return raiseOSError(errno_compat.errnoRef().*);
        return returnNone();
    }

    fn py_os_rename(src_obj: Obj, dst_obj: Obj) callconv(.c) Obj {
        const src = pathArg(src_obj) orelse return raiseOSError(errno_h.EINVAL);
        const dst = pathArg(dst_obj) orelse return raiseOSError(errno_h.EINVAL);
        if (rename(src, dst) < 0) return raiseOSError(errno_compat.errnoRef().*);
        return returnNone();
    }

    fn py_os_mkdir(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
        const path = pathArg(args[0]) orelse return raiseOSError(errno_h.EINVAL);
        const mode: c_uint = if (n_args >= 2) @intCast(mp_obj_get_int(args[1])) else 0o777;
        if (mkdir(path, mode) < 0) return raiseOSError(errno_compat.errnoRef().*);
        return returnNone();
    }

    fn py_os_rmdir(path_obj: Obj) callconv(.c) Obj {
        const path = pathArg(path_obj) orelse return raiseOSError(errno_h.EINVAL);
        if (rmdir(path) < 0) return raiseOSError(errno_compat.errnoRef().*);
        return returnNone();
    }

    // ── stat / lstat ─────────────────────────────────────────────────

    // stat_result attribute names, in the CPython-compatible order.
    // Also usable via integer index [0]..[9] because attrtuple IS a tuple.
    const stat_fields: [10]Qstr = .{
        @intCast(mp.MP_QSTR_st_mode),
        @intCast(mp.MP_QSTR_st_ino),
        @intCast(mp.MP_QSTR_st_dev),
        @intCast(mp.MP_QSTR_st_nlink),
        @intCast(mp.MP_QSTR_st_uid),
        @intCast(mp.MP_QSTR_st_gid),
        @intCast(mp.MP_QSTR_st_size),
        @intCast(mp.MP_QSTR_st_atime),
        @intCast(mp.MP_QSTR_st_mtime),
        @intCast(mp.MP_QSTR_st_ctime),
    };

    // Cast whatever integer fields libc gave us into Python smallints.
    // MicroPython uses ints for st_*time (not floats) matching the
    // upstream unix-port. That keeps things nano-compatible; nothing
    // in `hop3-rootd` needs sub-second precision.
    inline fn statInt(v: anytype) Obj {
        return mirrors.newSmallInt(@intCast(v));
    }

    // st_atime/st_mtime/st_ctime are C macros expanding to
    // st_atimespec.tv_sec (BSD/macOS) or st_atim.tv_sec (Linux/glibc).
    // Macros don't survive translate-c, so pick the right field name
    // at Zig comptime.
    inline fn atimeSec(st: *const sys_stat_h.struct_stat) c_long {
        if (@hasField(sys_stat_h.struct_stat, "st_atimespec")) return @intCast(st.st_atimespec.tv_sec);
        if (@hasField(sys_stat_h.struct_stat, "st_atim")) return @intCast(st.st_atim.tv_sec);
        @compileError("unsupported struct stat layout: no st_atimespec or st_atim");
    }
    inline fn mtimeSec(st: *const sys_stat_h.struct_stat) c_long {
        if (@hasField(sys_stat_h.struct_stat, "st_mtimespec")) return @intCast(st.st_mtimespec.tv_sec);
        if (@hasField(sys_stat_h.struct_stat, "st_mtim")) return @intCast(st.st_mtim.tv_sec);
        @compileError("unsupported struct stat layout: no st_mtimespec or st_mtim");
    }
    inline fn ctimeSec(st: *const sys_stat_h.struct_stat) c_long {
        if (@hasField(sys_stat_h.struct_stat, "st_ctimespec")) return @intCast(st.st_ctimespec.tv_sec);
        if (@hasField(sys_stat_h.struct_stat, "st_ctim")) return @intCast(st.st_ctim.tv_sec);
        @compileError("unsupported struct stat layout: no st_ctimespec or st_ctim");
    }

    fn buildStatResult(st: *const sys_stat_h.struct_stat) Obj {
        const items = [10]Obj{
            statInt(st.st_mode),
            statInt(st.st_ino),
            statInt(st.st_dev),
            statInt(st.st_nlink),
            statInt(st.st_uid),
            statInt(st.st_gid),
            statInt(st.st_size),
            statInt(atimeSec(st)),
            statInt(mtimeSec(st)),
            statInt(ctimeSec(st)),
        };
        return mp_obj_new_attrtuple(&stat_fields, 10, &items);
    }

    fn py_os_stat(path_obj: Obj) callconv(.c) Obj {
        const path = pathArg(path_obj) orelse return raiseOSError(errno_h.EINVAL);
        var st: sys_stat_h.struct_stat = undefined;
        if (sys_stat_h.stat(path, &st) < 0) return raiseOSError(errno_compat.errnoRef().*);
        return buildStatResult(&st);
    }

    fn py_os_lstat(path_obj: Obj) callconv(.c) Obj {
        const path = pathArg(path_obj) orelse return raiseOSError(errno_h.EINVAL);
        var st: sys_stat_h.struct_stat = undefined;
        if (sys_stat_h.lstat(path, &st) < 0) return raiseOSError(errno_compat.errnoRef().*);
        return buildStatResult(&st);
    }

    // ── listdir / readlink ───────────────────────────────────────────

    fn py_os_listdir(path_obj: Obj) callconv(.c) Obj {
        const path = pathArg(path_obj) orelse return raiseOSError(errno_h.EINVAL);
        const dir = dirent_h.opendir(path) orelse return raiseOSError(errno_compat.errnoRef().*);
        defer _ = dirent_h.closedir(dir);
        const list = mp_obj_new_list(0, null);
        while (true) {
            // Per POSIX: to distinguish EOF from error, clear errno_compat.errnoRef().*,
            // call readdir, then check errno_compat.errnoRef().* on null.
            errno_compat.errnoRef().* = 0;
            const entry = dirent_h.readdir(dir);
            if (entry == null) {
                if (errno_compat.errnoRef().* != 0) return raiseOSError(errno_compat.errnoRef().*);
                break;
            }
            const name_ptr: [*:0]const u8 = @ptrCast(&entry.*.d_name);
            // Skip "." and ".." — matches CPython + POSIX convention.
            const nlen = string_h.strlen(name_ptr);
            if ((nlen == 1 and name_ptr[0] == '.') or
                (nlen == 2 and name_ptr[0] == '.' and name_ptr[1] == '.')) continue;
            _ = mp_obj_list_append(list, mp_obj_new_str_from_cstr(name_ptr));
        }
        return list;
    }

    fn py_os_readlink(path_obj: Obj) callconv(.c) Obj {
        const path = pathArg(path_obj) orelse return raiseOSError(errno_h.EINVAL);
        // readlink() does NOT null-terminate. Read up to buflen-1 and
        // null-terminate manually. PATH_MAX is 4096 on Linux, 1024 on
        // macOS — 4096 covers both.
        var buf: [4096]u8 = undefined;
        const got = readlink(path, &buf, buf.len - 1);
        if (got < 0) return raiseOSError(errno_compat.errnoRef().*);
        buf[@intCast(got)] = 0;
        return mp_obj_new_str_from_cstr(@ptrCast(&buf));
    }

    fn py_os_symlink(target_obj: Obj, link_obj: Obj) callconv(.c) Obj {
        const target = pathArg(target_obj) orelse return raiseOSError(errno_h.EINVAL);
        const link = pathArg(link_obj) orelse return raiseOSError(errno_h.EINVAL);
        if (symlink(target, link) < 0) return raiseOSError(errno_compat.errnoRef().*);
        return returnNone();
    }

    // os.access(path, mode) — mode is a bitmask of F_OK|R_OK|W_OK|X_OK.
    // Returns bool. Does NOT raise: this is the CPython contract.
    fn py_os_access(path_obj: Obj, mode_obj: Obj) callconv(.c) Obj {
        const path = pathArg(path_obj) orelse return raiseOSError(errno_h.EINVAL);
        const mode: c_int = @intCast(mp_obj_get_int(mode_obj));
        const ok = access(path, mode) == 0;
        // Python True/False under REPR_A are immediate ptr constants.
        // Use mp_const_true/mp_const_false vendor symbols.
        return if (ok) mp_true_val else mp_false_val;
    }

    // MP_OBJ_NEW_IMMEDIATE_OBJ((val << 3) | 6). Index values from
    // vendor py/obj.h:915-917:
    //   None  = idx 0 → 6
    //   False = idx 1 → 14
    //   True  = idx 3 → 30  (idx 2 is skipped by upstream)
    const mp_false_val: Obj = 0x0E;
    const mp_true_val: Obj = 0x1E;

    // ── Function-object exports ──────────────────────────────────────

    pub export const mp_os_environ_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_0 }, .fun = @ptrCast(&py_os_environ) };
    pub export const mp_os_getattr_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_os_getattr) };
    pub export const mp_os_urandom_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_os_urandom) };
    pub export const mp_os_open_obj: mirrors.MpObjFunBuiltinVar = .{ .base = .{ .type = &mp_type_fun_builtin_var }, .sig = mirrors.makeFunSig(2, 3, false), .fun = @ptrCast(&py_os_open) };
    pub export const mp_os_close_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_os_close) };
    pub export const mp_os_read_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_2 }, .fun = @ptrCast(&py_os_read) };
    pub export const mp_os_write_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_2 }, .fun = @ptrCast(&py_os_write) };
    pub export const mp_os_lseek_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_3 }, .fun = @ptrCast(&py_os_lseek) };
    pub export const mp_os_fsync_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_os_fsync) };
    pub export const mp_os_chmod_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_2 }, .fun = @ptrCast(&py_os_chmod) };
    pub export const mp_os_chown_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_3 }, .fun = @ptrCast(&py_os_chown) };
    pub export const mp_os_getpid_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_0 }, .fun = @ptrCast(&py_os_getpid) };
    pub export const mp_os_kill_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_2 }, .fun = @ptrCast(&py_os_kill) };
    pub export const mp_os_umask_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_os_umask) };
    pub export const mp_os_getcwd_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_0 }, .fun = @ptrCast(&py_os_getcwd) };
    pub export const mp_os_chdir_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_os_chdir) };
    pub export const mp_os_getenv_obj = argcheck.kwVar(1, &.{ 0, mp.MP_QSTR_default }, .{ mirrors.OBJ_NULL, mirrors.OBJ_NONE }, &py_os_getenv);
    pub export const mp_os_putenv_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_2 }, .fun = @ptrCast(&py_os_putenv) };
    pub export const mp_os_unsetenv_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_os_unsetenv) };
    pub export const mp_os_unlink_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_os_unlink) };
    pub export const mp_os_rename_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_2 }, .fun = @ptrCast(&py_os_rename) };
    pub export const mp_os_mkdir_obj: mirrors.MpObjFunBuiltinVar = .{ .base = .{ .type = &mp_type_fun_builtin_var }, .sig = mirrors.makeFunSig(1, 2, false), .fun = @ptrCast(&py_os_mkdir) };
    pub export const mp_os_rmdir_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_os_rmdir) };
    pub export const mp_os_stat_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_os_stat) };
    pub export const mp_os_lstat_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_os_lstat) };
    pub export const mp_os_listdir_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_os_listdir) };
    pub export const mp_os_readlink_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_os_readlink) };
    pub export const mp_os_symlink_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_2 }, .fun = @ptrCast(&py_os_symlink) };
    pub export const mp_os_access_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_2 }, .fun = @ptrCast(&py_os_access) };

    // ── Module globals dict ──────────────────────────────────────────

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

    const mp_module_os_globals_table = [_]RomEntry{
        .{ .key = qKey(mp.MP_QSTR___name__), .value = @ptrFromInt(qKey(mp.MP_QSTR_os)) },

        // Functions.
        .{ .key = qKey(mp.MP_QSTR_urandom), .value = &mp_os_urandom_obj },
        .{ .key = qKey(mp.MP_QSTR_open), .value = &mp_os_open_obj },
        .{ .key = qKey(mp.MP_QSTR_close), .value = &mp_os_close_obj },
        .{ .key = qKey(mp.MP_QSTR_read), .value = &mp_os_read_obj },
        .{ .key = qKey(mp.MP_QSTR_write), .value = &mp_os_write_obj },
        .{ .key = qKey(mp.MP_QSTR_lseek), .value = &mp_os_lseek_obj },
        .{ .key = qKey(mp.MP_QSTR_fsync), .value = &mp_os_fsync_obj },
        .{ .key = qKey(mp.MP_QSTR_chmod), .value = &mp_os_chmod_obj },
        .{ .key = qKey(mp.MP_QSTR_chown), .value = &mp_os_chown_obj },
        .{ .key = qKey(mp.MP_QSTR_getpid), .value = &mp_os_getpid_obj },
        .{ .key = qKey(mp.MP_QSTR_kill), .value = &mp_os_kill_obj },
        .{ .key = qKey(mp.MP_QSTR_umask), .value = &mp_os_umask_obj },
        .{ .key = qKey(mp.MP_QSTR_getcwd), .value = &mp_os_getcwd_obj },
        .{ .key = qKey(mp.MP_QSTR_chdir), .value = &mp_os_chdir_obj },
        .{ .key = qKey(mp.MP_QSTR_getenv), .value = &mp_os_getenv_obj },
        .{ .key = qKey(mp.MP_QSTR__environ), .value = &mp_os_environ_obj },
        .{ .key = qKey(mp.MP_QSTR_putenv), .value = &mp_os_putenv_obj },
        .{ .key = qKey(mp.MP_QSTR_unsetenv), .value = &mp_os_unsetenv_obj },
        // remove is CPython's canonical name; unlink is the POSIX alias.
        // Both point to the same underlying unlink(2) wrapper.
        .{ .key = qKey(mp.MP_QSTR_remove), .value = &mp_os_unlink_obj },
        .{ .key = qKey(mp.MP_QSTR_unlink), .value = &mp_os_unlink_obj },
        .{ .key = qKey(mp.MP_QSTR_rename), .value = &mp_os_rename_obj },
        .{ .key = qKey(mp.MP_QSTR_mkdir), .value = &mp_os_mkdir_obj },
        .{ .key = qKey(mp.MP_QSTR_rmdir), .value = &mp_os_rmdir_obj },
        .{ .key = qKey(mp.MP_QSTR_stat), .value = &mp_os_stat_obj },
        .{ .key = qKey(mp.MP_QSTR_lstat), .value = &mp_os_lstat_obj },
        .{ .key = qKey(mp.MP_QSTR_listdir), .value = &mp_os_listdir_obj },
        .{ .key = qKey(mp.MP_QSTR_readlink), .value = &mp_os_readlink_obj },
        .{ .key = qKey(mp.MP_QSTR_symlink), .value = &mp_os_symlink_obj },
        .{ .key = qKey(mp.MP_QSTR_access), .value = &mp_os_access_obj },
        // access(2) mode constants — same values on Linux + macOS
        // (POSIX-defined: F_OK=0, X_OK=1, W_OK=2, R_OK=4).
        .{ .key = qKey(mp.MP_QSTR_F_OK), .value = intVal(@intCast(unistd_h.F_OK)) },
        .{ .key = qKey(mp.MP_QSTR_R_OK), .value = intVal(@intCast(unistd_h.R_OK)) },
        .{ .key = qKey(mp.MP_QSTR_W_OK), .value = intVal(@intCast(unistd_h.W_OK)) },
        .{ .key = qKey(mp.MP_QSTR_X_OK), .value = intVal(@intCast(unistd_h.X_OK)) },

        // open() flag constants — resolved from fcntl.h (Linux/macOS values differ).
        .{ .key = qKey(mp.MP_QSTR_O_RDONLY), .value = intVal(@intCast(fcntl_h.O_RDONLY)) },
        .{ .key = qKey(mp.MP_QSTR_O_WRONLY), .value = intVal(@intCast(fcntl_h.O_WRONLY)) },
        .{ .key = qKey(mp.MP_QSTR_O_RDWR), .value = intVal(@intCast(fcntl_h.O_RDWR)) },
        .{ .key = qKey(mp.MP_QSTR_O_CREAT), .value = intVal(@intCast(fcntl_h.O_CREAT)) },
        .{ .key = qKey(mp.MP_QSTR_O_TRUNC), .value = intVal(@intCast(fcntl_h.O_TRUNC)) },
        .{ .key = qKey(mp.MP_QSTR_O_APPEND), .value = intVal(@intCast(fcntl_h.O_APPEND)) },
        .{ .key = qKey(mp.MP_QSTR_O_EXCL), .value = intVal(@intCast(fcntl_h.O_EXCL)) },

        // lseek() whence values, POSIX-defined.
        .{ .key = qKey(mp.MP_QSTR_SEEK_SET), .value = intVal(0) },
        .{ .key = qKey(mp.MP_QSTR_SEEK_CUR), .value = intVal(1) },
        .{ .key = qKey(mp.MP_QSTR_SEEK_END), .value = intVal(2) },

        // String constants (ROM). Match CPython on POSIX: sep='/', altsep=None
        // (we ship an empty str — CPython uses None, but None isn't a ROM
        // constant we can point at from a table cell; if hop3-rootd cares it
        // can compare against "" or use `os.name == 'posix'`).
        .{ .key = qKey(mp.MP_QSTR_sep), .value = &mp_os_sep_str },
        .{ .key = qKey(mp.MP_QSTR_altsep), .value = &mp_os_altsep_str },
        .{ .key = qKey(mp.MP_QSTR_extsep), .value = &mp_os_extsep_str },
        .{ .key = qKey(mp.MP_QSTR_linesep), .value = &mp_os_linesep_str },
        .{ .key = qKey(mp.MP_QSTR_curdir), .value = &mp_os_curdir_str },
        .{ .key = qKey(mp.MP_QSTR_pardir), .value = &mp_os_pardir_str },
        .{ .key = qKey(mp.MP_QSTR_name), .value = &mp_os_name_str },
        .{ .key = qKey(mp.MP_QSTR___getattr__), .value = &mp_os_getattr_obj },
    };

    pub export const mp_module_os_globals: mirrors.MpObjDict = .{
        .base = .{ .type = &mp_type_dict },
        .map = .{
            .bits = .{
                .all_keys_are_qstrs = 1,
                .is_fixed = 1,
                .is_ordered = 1,
                .used = mp_module_os_globals_table.len,
            },
            .alloc = mp_module_os_globals_table.len,
            .table = @ptrCast(@constCast(&mp_module_os_globals_table)),
        },
    };

    pub export const mp_module_os: mirrors.MpObjModule = .{
        .base = .{ .type = &mp_type_module },
        .globals = @ptrCast(@constCast(&mp_module_os_globals)),
    };
} else struct {};

comptime {
    if (enabled) {
        _ = &Body.mp_module_os;
        _ = &Body.mp_module_os_globals;
        _ = &Body.mp_os_getattr_obj;
        _ = &Body.mp_os_urandom_obj;
        _ = &Body.mp_os_open_obj;
        _ = &Body.mp_os_close_obj;
        _ = &Body.mp_os_read_obj;
        _ = &Body.mp_os_write_obj;
        _ = &Body.mp_os_lseek_obj;
        _ = &Body.mp_os_fsync_obj;
        _ = &Body.mp_os_chmod_obj;
        _ = &Body.mp_os_chown_obj;
        _ = &Body.mp_os_getpid_obj;
        _ = &Body.mp_os_kill_obj;
        _ = &Body.mp_os_getcwd_obj;
        _ = &Body.mp_os_chdir_obj;
        _ = &Body.mp_os_getenv_obj;
        _ = &Body.mp_os_environ_obj;
        _ = &Body.mp_os_putenv_obj;
        _ = &Body.mp_os_unsetenv_obj;
        _ = &Body.mp_os_unlink_obj;
        _ = &Body.mp_os_rename_obj;
        _ = &Body.mp_os_mkdir_obj;
        _ = &Body.mp_os_rmdir_obj;
        _ = &Body.mp_os_sep_str;
        _ = &Body.mp_os_altsep_str;
        _ = &Body.mp_os_extsep_str;
        _ = &Body.mp_os_linesep_str;
        _ = &Body.mp_os_curdir_str;
        _ = &Body.mp_os_pardir_str;
        _ = &Body.mp_os_name_str;
        _ = &Body.mp_os_stat_obj;
        _ = &Body.mp_os_lstat_obj;
        _ = &Body.mp_os_listdir_obj;
        _ = &Body.mp_os_readlink_obj;
        _ = &Body.mp_os_symlink_obj;
        _ = &Body.mp_os_access_obj;
    }
}
