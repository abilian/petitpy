//! nanopython — Zig-native `select` module (select(2) wrapper).
//!
//! Full-native only. Minimal surface for the
//! accept loop pattern hop3-rootd uses:
//!
//!   select.select(rlist, wlist, xlist, timeout=None)
//!       -> (ready_r, ready_w, ready_x)
//!
//! Args are Python lists of file descriptors (ints). Objects with
//! `.fileno()` are NOT yet accepted — vendor CPython does; add when a
//! caller needs it. Timeout is a float in seconds; `None` means block
//! indefinitely. Returned lists share fd values with the input lists
//! (no fd → object mapping).
//!
//! Not shipped: `poll()`, `epoll()`, `kqueue()`, `select.PIPE_BUF`,
//! `select.select` on non-fd sequences. Add when a caller needs them.
//!
//! Gated on build_options.feature_select. wasm coerced off (no select(2)
//! under WASI — poll_oneoff exists but has a different shape).
//!
//! __qstr_shadow_begin__
//! #if MICROPY_PY_SELECT
//! MP_QSTR_select
//! MP_REGISTER_MODULE(MP_QSTR_select, mp_module_select);
//! #endif
//! __qstr_shadow_end__

const build_options = @import("build_options");
const mirrors = @import("../mp_mirrors.zig");
const pyerr = @import("../pyerr.zig");
const errno_compat = @import("../support/errno_compat.zig");

const Obj = mirrors.Obj;
const Qstr = usize;

const enabled = build_options.feature_select;

const Body = if (enabled) struct {
    const mp = @cImport({
        @cInclude("py/qstr.h");
    });
    const errno_h = @cImport({
        @cInclude("errno.h");
    });
    const sys_select_h = @cImport({
        @cInclude("sys/select.h");
    });

    extern const mp_type_module: anyopaque;
    extern const mp_type_dict: anyopaque;
    extern const mp_type_fun_builtin_var: anyopaque;

    extern fn mp_obj_new_list(n: usize, items: [*c]const Obj) callconv(.c) Obj;
    extern fn mp_obj_new_tuple(n: usize, items: [*c]const Obj) callconv(.c) Obj;
    extern fn mp_obj_list_append(list: Obj, item: Obj) callconv(.c) Obj;
    extern fn mp_obj_get_int(o: Obj) callconv(.c) isize;
    extern fn mp_obj_get_float(o: Obj) callconv(.c) f64;
    extern fn mp_raise_OSError_polled(errno_: c_int) callconv(.c) void;

    // POSIX select(2).
    extern fn select(nfds: c_int, readfds: ?*sys_select_h.fd_set, writefds: ?*sys_select_h.fd_set, exceptfds: ?*sys_select_h.fd_set, timeout: ?*sys_select_h.struct_timeval) callconv(.c) c_int;

    // Under MICROPY_OBJ_REPR_A: mp_const_none = 6.
    const MP_CONST_NONE: Obj = 0x06;

    fn raiseOSError(err: c_int) Obj {
        mp_raise_OSError_polled(err);
        return mirrors.OBJ_NULL;
    }

    // FD_ZERO/FD_SET/FD_ISSET via inline manipulation of fd_bits.
    // fd_set layout is platform-dependent — access via cImport'd
    // FD_ZERO/FD_SET macros wouldn't survive translate-c, so do it
    // by hand: fd_bits is an array of longs; bit `fd` is at
    // fd_bits[fd / bits_per_long] bit (fd % bits_per_long).
    const bits_per_long = @bitSizeOf(c_long);

    inline fn fdZero(set: *sys_select_h.fd_set) void {
        @memset(std.mem.asBytes(set), 0);
    }

    inline fn fdSet(fd: c_int, set: *sys_select_h.fd_set) void {
        const ufd: usize = @intCast(fd);
        const bits = std.mem.bytesAsSlice(c_long, std.mem.asBytes(set));
        bits[ufd / bits_per_long] |= @as(c_long, 1) << @intCast(ufd % bits_per_long);
    }

    inline fn fdIsSet(fd: c_int, set: *const sys_select_h.fd_set) bool {
        const ufd: usize = @intCast(fd);
        const bits = std.mem.bytesAsSlice(c_long, std.mem.asBytes(@constCast(set)));
        return (bits[ufd / bits_per_long] & (@as(c_long, 1) << @intCast(ufd % bits_per_long))) != 0;
    }

    // Iterate a Python list, extract fd ints, populate the fd_set,
    // track the max fd seen. Returns the max fd found (or -1 if empty).
    fn populateSet(list_obj: Obj, set: *sys_select_h.fd_set) c_int {
        fdZero(set);
        var maxfd: c_int = -1;
        const list: *mirrors.MpObjList = mirrors.MpObjList.fromObj(list_obj);
        var i: usize = 0;
        while (i < list.len) : (i += 1) {
            const fd: c_int = @intCast(mp_obj_get_int(list.items[i]));
            if (fd < 0 or fd >= sys_select_h.FD_SETSIZE) continue;
            fdSet(fd, set);
            if (fd > maxfd) maxfd = fd;
        }
        return maxfd;
    }

    // Build a result list of fd ints, keeping order from the input list.
    // Only ints ready per fd_set are included.
    fn filterReady(list_obj: Obj, set: *const sys_select_h.fd_set) Obj {
        const list: *mirrors.MpObjList = mirrors.MpObjList.fromObj(list_obj);
        const result = mp_obj_new_list(0, null);
        var i: usize = 0;
        while (i < list.len) : (i += 1) {
            const fd: c_int = @intCast(mp_obj_get_int(list.items[i]));
            if (fd < 0 or fd >= sys_select_h.FD_SETSIZE) continue;
            if (fdIsSet(fd, set)) _ = mp_obj_list_append(result, list.items[i]);
        }
        return result;
    }

    // select(rlist, wlist, xlist[, timeout]) → (rready, wready, xready)
    fn py_select(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
        if (n_args < 3) return raiseOSError(errno_h.EINVAL);

        var rset: sys_select_h.fd_set = undefined;
        var wset: sys_select_h.fd_set = undefined;
        var xset: sys_select_h.fd_set = undefined;

        const maxr = populateSet(args[0], &rset);
        const maxw = populateSet(args[1], &wset);
        const maxx = populateSet(args[2], &xset);
        var nfds: c_int = maxr;
        if (maxw > nfds) nfds = maxw;
        if (maxx > nfds) nfds = maxx;
        nfds += 1; // select wants highest fd + 1

        // timeout arg. None (or absent) → NULL → block indefinitely.
        // Number → struct timeval seconds+microseconds.
        var tv: sys_select_h.struct_timeval = undefined;
        var tv_ptr: ?*sys_select_h.struct_timeval = null;
        if (n_args >= 4 and args[3] != MP_CONST_NONE) {
            const secs = mp_obj_get_float(args[3]);
            if (secs < 0) return raiseOSError(errno_h.EINVAL);
            const whole: f64 = @trunc(secs);
            tv.tv_sec = @intFromFloat(whole);
            tv.tv_usec = @intFromFloat((secs - whole) * 1_000_000.0);
            tv_ptr = &tv;
        }

        const n = select(nfds, &rset, &wset, &xset, tv_ptr);
        if (n < 0) return raiseOSError(errno_compat.errnoRef().*);

        const items = [_]Obj{
            filterReady(args[0], &rset),
            filterReady(args[1], &wset),
            filterReady(args[2], &xset),
        };
        return mp_obj_new_tuple(3, &items);
    }

    // ── Function-object export ───────────────────────────────────────

    pub export const mp_select_select_obj: mirrors.MpObjFunBuiltinVar = .{
        .base = .{ .type = &mp_type_fun_builtin_var },
        .sig = mirrors.makeFunSig(3, 4, false),
        .fun = @ptrCast(&py_select),
    };

    // ── Module globals ───────────────────────────────────────────────

    const RomEntry = extern struct {
        key: Obj,
        value: *const anyopaque,
    };

    inline fn qKey(q: usize) Obj {
        return mirrors.objFromQstr(@as(Qstr, q));
    }

    const mp_module_select_globals_table = [_]RomEntry{
        .{ .key = qKey(mp.MP_QSTR___name__), .value = @ptrFromInt(qKey(mp.MP_QSTR_select)) },
        .{ .key = qKey(mp.MP_QSTR_select), .value = &mp_select_select_obj },
    };

    pub export const mp_module_select_globals: mirrors.MpObjDict = .{
        .base = .{ .type = &mp_type_dict },
        .map = .{
            .bits = .{
                .all_keys_are_qstrs = 1,
                .is_fixed = 1,
                .is_ordered = 1,
                .used = mp_module_select_globals_table.len,
            },
            .alloc = mp_module_select_globals_table.len,
            .table = @ptrCast(@constCast(&mp_module_select_globals_table)),
        },
    };

    pub export const mp_module_select: mirrors.MpObjModule = .{
        .base = .{ .type = &mp_type_module },
        .globals = @ptrCast(@constCast(&mp_module_select_globals)),
    };

    const std = @import("std");
} else struct {};

comptime {
    if (enabled) {
        _ = &Body.mp_module_select;
        _ = &Body.mp_module_select_globals;
        _ = &Body.mp_select_select_obj;
    }
}
