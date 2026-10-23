//! petitpy — Zig port of py/moderrno.c (the `errno` module).
//!
//! Nano + full: MICROPY_PY_ERRNO=1 and MICROPY_PY_ERRNO_ERRORCODE=1
//! (vendor default), so the live surface is:
//!   - `errorcode` dict (int → qstr) with 22 entries
//!   - module `globals` dict: __name__, errorcode, and 22 errno integer
//!     constants (EPERM..EINPROGRESS) — 24 entries
//!   - public C-callable `mp_errno_to_str(errno_val) → qstr` (used by
//!     objexcept.c to render OSError args).
//!
//! ADR-002 F2 — gated on build_options.feature_errno. When off:
//! - vendor py/moderrno.c becomes a no-op (#if MICROPY_PY_ERRNO).
//! - The Zig-side ROM objects + mp_errno_to_str are dropped.
//! - objexcept.zig already comptime-gates the mp_errno_to_str call on
//!   mp.MICROPY_PY_ERRNO, so the extern fn never becomes a live reference.
//!
//! The MP_REGISTER_EXTENSIBLE_MODULE marker stays in src/modules/moderrno.c
//! (a 4-line tombstone) — makemoduledefs.py scans only .c sources.

const build_options = @import("build_options");
const mirrors = @import("../mp_mirrors.zig");

const Obj = mirrors.Obj;
const Qstr = usize;

const RomEntry = extern struct {
    key: Obj,
    value: *const anyopaque,
};

const enabled = build_options.feature_errno;

const Body = if (enabled) struct {
    const mp = @cImport({
        @cInclude("py/qstr.h");
    });

    extern const mp_type_module: anyopaque;
    extern const mp_type_dict: anyopaque;

    // MP_E_* values from vendor/py/mperrno.h
    const EPERM: usize = 1;
    const ENOENT: usize = 2;
    const EIO: usize = 5;
    const EBADF: usize = 9;
    const EAGAIN: usize = 11;
    const ENOMEM: usize = 12;
    const EACCES: usize = 13;
    const EEXIST: usize = 17;
    const ENODEV: usize = 19;
    const EISDIR: usize = 21;
    const EINVAL: usize = 22;
    const EOPNOTSUPP: usize = 95;
    const EADDRINUSE: usize = 98;
    const ECONNABORTED: usize = 103;
    const ECONNRESET: usize = 104;
    const ENOBUFS: usize = 105;
    const ENOTCONN: usize = 107;
    const ETIMEDOUT: usize = 110;
    const ECONNREFUSED: usize = 111;
    const EHOSTUNREACH: usize = 113;
    const EALREADY: usize = 114;
    const EINPROGRESS: usize = 115;

    inline fn smallInt(n: usize) Obj {
        return (n << 1) | 1;
    }

    inline fn qstrObj(q: usize) Obj {
        return (q << 3) | 2;
    }

    // errorcode dict: int(errno) → qstr(name). 22 entries.
    const errorcode_table = [_]RomEntry{
        .{ .key = smallInt(EPERM), .value = @ptrFromInt(qstrObj(@as(Qstr, mp.MP_QSTR_EPERM))) },
        .{ .key = smallInt(ENOENT), .value = @ptrFromInt(qstrObj(@as(Qstr, mp.MP_QSTR_ENOENT))) },
        .{ .key = smallInt(EIO), .value = @ptrFromInt(qstrObj(@as(Qstr, mp.MP_QSTR_EIO))) },
        .{ .key = smallInt(EBADF), .value = @ptrFromInt(qstrObj(@as(Qstr, mp.MP_QSTR_EBADF))) },
        .{ .key = smallInt(EAGAIN), .value = @ptrFromInt(qstrObj(@as(Qstr, mp.MP_QSTR_EAGAIN))) },
        .{ .key = smallInt(ENOMEM), .value = @ptrFromInt(qstrObj(@as(Qstr, mp.MP_QSTR_ENOMEM))) },
        .{ .key = smallInt(EACCES), .value = @ptrFromInt(qstrObj(@as(Qstr, mp.MP_QSTR_EACCES))) },
        .{ .key = smallInt(EEXIST), .value = @ptrFromInt(qstrObj(@as(Qstr, mp.MP_QSTR_EEXIST))) },
        .{ .key = smallInt(ENODEV), .value = @ptrFromInt(qstrObj(@as(Qstr, mp.MP_QSTR_ENODEV))) },
        .{ .key = smallInt(EISDIR), .value = @ptrFromInt(qstrObj(@as(Qstr, mp.MP_QSTR_EISDIR))) },
        .{ .key = smallInt(EINVAL), .value = @ptrFromInt(qstrObj(@as(Qstr, mp.MP_QSTR_EINVAL))) },
        .{ .key = smallInt(EOPNOTSUPP), .value = @ptrFromInt(qstrObj(@as(Qstr, mp.MP_QSTR_EOPNOTSUPP))) },
        .{ .key = smallInt(EADDRINUSE), .value = @ptrFromInt(qstrObj(@as(Qstr, mp.MP_QSTR_EADDRINUSE))) },
        .{ .key = smallInt(ECONNABORTED), .value = @ptrFromInt(qstrObj(@as(Qstr, mp.MP_QSTR_ECONNABORTED))) },
        .{ .key = smallInt(ECONNRESET), .value = @ptrFromInt(qstrObj(@as(Qstr, mp.MP_QSTR_ECONNRESET))) },
        .{ .key = smallInt(ENOBUFS), .value = @ptrFromInt(qstrObj(@as(Qstr, mp.MP_QSTR_ENOBUFS))) },
        .{ .key = smallInt(ENOTCONN), .value = @ptrFromInt(qstrObj(@as(Qstr, mp.MP_QSTR_ENOTCONN))) },
        .{ .key = smallInt(ETIMEDOUT), .value = @ptrFromInt(qstrObj(@as(Qstr, mp.MP_QSTR_ETIMEDOUT))) },
        .{ .key = smallInt(ECONNREFUSED), .value = @ptrFromInt(qstrObj(@as(Qstr, mp.MP_QSTR_ECONNREFUSED))) },
        .{ .key = smallInt(EHOSTUNREACH), .value = @ptrFromInt(qstrObj(@as(Qstr, mp.MP_QSTR_EHOSTUNREACH))) },
        .{ .key = smallInt(EALREADY), .value = @ptrFromInt(qstrObj(@as(Qstr, mp.MP_QSTR_EALREADY))) },
        .{ .key = smallInt(EINPROGRESS), .value = @ptrFromInt(qstrObj(@as(Qstr, mp.MP_QSTR_EINPROGRESS))) },
    };

    pub export const errorcode_dict: mirrors.MpObjDict = .{
        .base = .{ .type = &mp_type_dict },
        .map = .{
            .bits = .{
                .all_keys_are_qstrs = 0, // keys are integers
                .is_fixed = 1,
                .is_ordered = 1,
                .used = errorcode_table.len,
            },
            .alloc = errorcode_table.len,
            .table = @ptrCast(@constCast(&errorcode_table)),
        },
    };

    const mp_module_errno_globals_table = [_]RomEntry{
        .{
            .key = qstrObj(@as(Qstr, mp.MP_QSTR___name__)),
            .value = @ptrFromInt(qstrObj(@as(Qstr, mp.MP_QSTR_errno))),
        },
        .{ .key = qstrObj(@as(Qstr, mp.MP_QSTR_errorcode)), .value = &errorcode_dict },
        .{ .key = qstrObj(@as(Qstr, mp.MP_QSTR_EPERM)), .value = @ptrFromInt(smallInt(EPERM)) },
        .{ .key = qstrObj(@as(Qstr, mp.MP_QSTR_ENOENT)), .value = @ptrFromInt(smallInt(ENOENT)) },
        .{ .key = qstrObj(@as(Qstr, mp.MP_QSTR_EIO)), .value = @ptrFromInt(smallInt(EIO)) },
        .{ .key = qstrObj(@as(Qstr, mp.MP_QSTR_EBADF)), .value = @ptrFromInt(smallInt(EBADF)) },
        .{ .key = qstrObj(@as(Qstr, mp.MP_QSTR_EAGAIN)), .value = @ptrFromInt(smallInt(EAGAIN)) },
        .{ .key = qstrObj(@as(Qstr, mp.MP_QSTR_ENOMEM)), .value = @ptrFromInt(smallInt(ENOMEM)) },
        .{ .key = qstrObj(@as(Qstr, mp.MP_QSTR_EACCES)), .value = @ptrFromInt(smallInt(EACCES)) },
        .{ .key = qstrObj(@as(Qstr, mp.MP_QSTR_EEXIST)), .value = @ptrFromInt(smallInt(EEXIST)) },
        .{ .key = qstrObj(@as(Qstr, mp.MP_QSTR_ENODEV)), .value = @ptrFromInt(smallInt(ENODEV)) },
        .{ .key = qstrObj(@as(Qstr, mp.MP_QSTR_EISDIR)), .value = @ptrFromInt(smallInt(EISDIR)) },
        .{ .key = qstrObj(@as(Qstr, mp.MP_QSTR_EINVAL)), .value = @ptrFromInt(smallInt(EINVAL)) },
        .{ .key = qstrObj(@as(Qstr, mp.MP_QSTR_EOPNOTSUPP)), .value = @ptrFromInt(smallInt(EOPNOTSUPP)) },
        .{ .key = qstrObj(@as(Qstr, mp.MP_QSTR_EADDRINUSE)), .value = @ptrFromInt(smallInt(EADDRINUSE)) },
        .{ .key = qstrObj(@as(Qstr, mp.MP_QSTR_ECONNABORTED)), .value = @ptrFromInt(smallInt(ECONNABORTED)) },
        .{ .key = qstrObj(@as(Qstr, mp.MP_QSTR_ECONNRESET)), .value = @ptrFromInt(smallInt(ECONNRESET)) },
        .{ .key = qstrObj(@as(Qstr, mp.MP_QSTR_ENOBUFS)), .value = @ptrFromInt(smallInt(ENOBUFS)) },
        .{ .key = qstrObj(@as(Qstr, mp.MP_QSTR_ENOTCONN)), .value = @ptrFromInt(smallInt(ENOTCONN)) },
        .{ .key = qstrObj(@as(Qstr, mp.MP_QSTR_ETIMEDOUT)), .value = @ptrFromInt(smallInt(ETIMEDOUT)) },
        .{ .key = qstrObj(@as(Qstr, mp.MP_QSTR_ECONNREFUSED)), .value = @ptrFromInt(smallInt(ECONNREFUSED)) },
        .{ .key = qstrObj(@as(Qstr, mp.MP_QSTR_EHOSTUNREACH)), .value = @ptrFromInt(smallInt(EHOSTUNREACH)) },
        .{ .key = qstrObj(@as(Qstr, mp.MP_QSTR_EALREADY)), .value = @ptrFromInt(smallInt(EALREADY)) },
        .{ .key = qstrObj(@as(Qstr, mp.MP_QSTR_EINPROGRESS)), .value = @ptrFromInt(smallInt(EINPROGRESS)) },
    };

    pub export const mp_module_errno_globals: mirrors.MpObjDict = .{
        .base = .{ .type = &mp_type_dict },
        .map = .{
            .bits = .{
                .all_keys_are_qstrs = 1,
                .is_fixed = 1,
                .is_ordered = 1,
                .used = mp_module_errno_globals_table.len,
            },
            .alloc = mp_module_errno_globals_table.len,
            .table = @ptrCast(@constCast(&mp_module_errno_globals_table)),
        },
    };

    pub export const mp_module_errno: mirrors.MpObjModule = .{
        .base = .{ .type = &mp_type_module },
        .globals = @ptrCast(@constCast(&mp_module_errno_globals)),
    };

    // `mp_errno_to_str(errno_val) → qstr` — called by objexcept.c when rendering
    // OSError args. Under ERRORCODE=1 we do a hash-map lookup against the
    // errorcode dict.
    pub export fn mp_errno_to_str(errno_val: Obj) callconv(.c) usize {
        const elem = mirrors.mp_map_lookup(
            @ptrCast(@constCast(&errorcode_dict.map)),
            errno_val,
            0, // MP_MAP_LOOKUP
        );
        if (elem) |e| {
            return mirrors.qstrValue(e.value);
        }
        return 0; // MP_QSTRnull
    }
} else struct {};

comptime {
    if (enabled) {
        _ = &Body.mp_module_errno;
        _ = &Body.mp_module_errno_globals;
        _ = &Body.errorcode_dict;
        _ = &Body.mp_errno_to_str;
    }
}
