//! petitpy — Zig-native `socket` module (BSD sockets subset).
//!
//! Full-native only. MVP surface for
//! `hop3-rootd`'s AF_UNIX RPC listener:
//!
//!   Class:      socket.socket(family, type[, proto]) → sock
//!   Methods:    sock.bind(path_or_addr)
//!               sock.listen(backlog)
//!               sock.accept() → (sock, addr)
//!               sock.recv(bufsize) → bytes
//!               sock.sendall(bytes) → None
//!               sock.setblocking(bool)
//!               sock.getsockopt(level, opt, buflen) → bytes (raw)
//!               sock.fileno() → int
//!               sock.close() → None
//!   Constants:  AF_UNIX, AF_INET, AF_INET6, SOCK_STREAM, SOCK_DGRAM,
//!               SOL_SOCKET, SO_REUSEADDR, SO_PEERCRED (Linux only)
//!   Factory:    socket.fromfd(fd, family, type[, proto]) → sock
//!
//! Not shipped (add when a caller needs it): connect, sendto, recvfrom,
//! setsockopt, makefile, gethostname, gethostbyname, IPv4/6 address
//! tuple encoding. TCP support is untested — the driving use case is
//! AF_UNIX + SO_PEERCRED. TCP callers will need address-tuple support.
//!
//! Gated on build_options.feature_socket. wasm target coerced off
//! (no BSD sockets under WASI).
//!
//! __qstr_shadow_begin__
//! #if MICROPY_PY_SOCKET
//! MP_QSTR_socket
//! MP_QSTR_bind
//! MP_QSTR_listen
//! MP_QSTR_accept
//! MP_QSTR_recv
//! MP_QSTR_sendall
//! MP_QSTR_setblocking
//! MP_QSTR_getsockopt
//! MP_QSTR_fileno
//! MP_QSTR_close
//! MP_QSTR_fromfd
//! MP_QSTR_AF_UNIX
//! MP_QSTR_AF_INET
//! MP_QSTR_AF_INET6
//! MP_QSTR_SOCK_STREAM
//! MP_QSTR_SOCK_DGRAM
//! MP_QSTR_SOL_SOCKET
//! MP_QSTR_SO_REUSEADDR
//! MP_QSTR_SO_PEERCRED
//! MP_REGISTER_MODULE(MP_QSTR_socket, mp_module_socket);
//! #endif
//! __qstr_shadow_end__

const build_options = @import("build_options");
const mirrors = @import("../mp_mirrors.zig");
const pyerr = @import("../pyerr.zig");
const errno_compat = @import("../support/errno_compat.zig");

const Obj = mirrors.Obj;
const Qstr = usize;

const enabled = build_options.feature_socket;

const Body = if (enabled) struct {
    const mp = @cImport({
        @cInclude("py/qstr.h");
    });
    const errno_h = @cImport({
        @cInclude("errno.h");
    });
    const sys_socket_h = @cImport({
        @cInclude("sys/socket.h");
        @cInclude("sys/un.h");
        @cInclude("netinet/in.h");
    });
    const string_h = @cImport({
        @cInclude("string.h");
    });
    const fcntl_h = @cImport({
        @cInclude("fcntl.h");
    });

    extern const mp_type_module: anyopaque;
    extern const mp_type_dict: anyopaque;
    extern const mp_type_tuple: anyopaque;
    extern const mp_type_type: anyopaque;
    extern const mp_type_fun_builtin_0: anyopaque;
    extern const mp_type_fun_builtin_1: anyopaque;
    extern const mp_type_fun_builtin_2: anyopaque;
    extern const mp_type_fun_builtin_3: anyopaque;
    extern const mp_type_fun_builtin_var: anyopaque;

    extern fn mp_obj_new_bytes(data: [*c]const u8, len: usize) callconv(.c) Obj;
    extern fn mp_obj_new_str_from_cstr(s: [*:0]const u8) callconv(.c) Obj;
    extern fn mp_obj_new_tuple(n: usize, items: [*c]const Obj) callconv(.c) Obj;
    extern fn mp_obj_get_int(o: Obj) callconv(.c) isize;
    extern fn mp_obj_str_get_str(o: Obj) callconv(.c) ?[*:0]const u8;
    extern fn mp_obj_str_get_data(o: Obj, len_out: *usize) callconv(.c) [*]const u8;
    extern fn m_malloc_with_finaliser(n: usize) callconv(.c) ?*anyopaque;
    extern fn mp_raise_OSError_polled(errno_: c_int) callconv(.c) void;

    // libc socket API.
    extern fn socket(domain: c_int, type_: c_int, protocol: c_int) callconv(.c) c_int;
    extern fn bind(fd: c_int, addr: *const anyopaque, addrlen: sys_socket_h.socklen_t) callconv(.c) c_int;
    extern fn listen(fd: c_int, backlog: c_int) callconv(.c) c_int;
    extern fn accept(fd: c_int, addr: ?*anyopaque, addrlen: ?*sys_socket_h.socklen_t) callconv(.c) c_int;
    extern fn recv(fd: c_int, buf: [*]u8, len: usize, flags: c_int) callconv(.c) isize;
    extern fn send(fd: c_int, buf: [*]const u8, len: usize, flags: c_int) callconv(.c) isize;
    extern fn close(fd: c_int) callconv(.c) c_int;
    extern fn getsockopt(fd: c_int, level: c_int, optname: c_int, optval: [*]u8, optlen: *sys_socket_h.socklen_t) callconv(.c) c_int;
    extern fn fcntl(fd: c_int, cmd: c_int, ...) callconv(.c) c_int;

    // Under MICROPY_OBJ_REPR_A: mp_const_none = 6.
    const MP_CONST_NONE: Obj = 0x06;
    fn returnNone() Obj {
        return MP_CONST_NONE;
    }

    fn raiseOSError(err: c_int) Obj {
        mp_raise_OSError_polled(err);
        return mirrors.OBJ_NULL;
    }

    // Socket object: opaque wrapper around a file descriptor.
    // Extern struct so pointer-cast from Obj → *NpySocket works cleanly.
    const NpySocket = extern struct {
        base: mirrors.MpObjBase,
        fd: c_int,
        family: c_int,
        type_: c_int,
        proto: c_int,
    };

    fn allocSocket(fd: c_int, family: c_int, type_: c_int, proto: c_int) Obj {
        // With a finaliser: a dropped socket is closed by the collector (`__del__`).
        const p: *NpySocket = @ptrCast(@alignCast(m_malloc_with_finaliser(@sizeOf(NpySocket)).?));
        p.base.type = &mp_type_socket;
        p.fd = fd;
        p.family = family;
        p.type_ = type_;
        p.proto = proto;
        return @intFromPtr(p);
    }

    // ── Methods (self = args[0] via type-method dispatch) ────────────

    // socket.socket(family, type[, proto=0]) — variadic 2..3.
    fn py_socket_ctor(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
        const family: c_int = @intCast(mp_obj_get_int(args[0]));
        const type_: c_int = @intCast(mp_obj_get_int(args[1]));
        const proto: c_int = if (n_args >= 3) @intCast(mp_obj_get_int(args[2])) else 0;
        const fd = socket(family, type_, proto);
        if (fd < 0) return raiseOSError(errno_compat.errnoRef().*);
        return allocSocket(fd, family, type_, proto);
    }

    // socket.fromfd(fd, family, type[, proto=0]) — variadic 3..4.
    fn py_socket_fromfd(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
        const fd: c_int = @intCast(mp_obj_get_int(args[0]));
        const family: c_int = @intCast(mp_obj_get_int(args[1]));
        const type_: c_int = @intCast(mp_obj_get_int(args[2]));
        const proto: c_int = if (n_args >= 4) @intCast(mp_obj_get_int(args[3])) else 0;
        return allocSocket(fd, family, type_, proto);
    }

    // sock.bind(path_or_addr). For AF_UNIX, arg is a str path. For
    // AF_INET, arg is a (host, port) tuple — NOT yet supported.
    fn py_sock_bind(self_in: Obj, addr_obj: Obj) callconv(.c) Obj {
        const self: *NpySocket = @ptrFromInt(self_in);
        if (self.family != sys_socket_h.AF_UNIX) {
            // TCP address-tuple encoding not implemented yet.
            return raiseOSError(errno_h.EAFNOSUPPORT);
        }
        const path = mp_obj_str_get_str(addr_obj) orelse return raiseOSError(errno_h.EINVAL);
        var sun: sys_socket_h.sockaddr_un = std.mem.zeroes(sys_socket_h.sockaddr_un);
        sun.sun_family = sys_socket_h.AF_UNIX;
        var plen: usize = 0;
        while (path[plen] != 0) : (plen += 1) {}
        if (plen >= sun.sun_path.len) return raiseOSError(errno_h.ENAMETOOLONG);
        @memcpy(sun.sun_path[0..plen], path[0..plen]);
        // Actual addrlen = offsetof(sockaddr_un, sun_path) + plen; for
        // AF_UNIX the whole sizeof is accepted on both Linux and macOS.
        if (bind(self.fd, @ptrCast(&sun), @sizeOf(sys_socket_h.sockaddr_un)) < 0) {
            return raiseOSError(errno_compat.errnoRef().*);
        }
        return returnNone();
    }

    fn py_sock_listen(self_in: Obj, backlog_obj: Obj) callconv(.c) Obj {
        const self: *NpySocket = @ptrFromInt(self_in);
        const backlog: c_int = @intCast(mp_obj_get_int(backlog_obj));
        if (listen(self.fd, backlog) < 0) return raiseOSError(errno_compat.errnoRef().*);
        return returnNone();
    }

    // sock.accept() → (client_sock, addr). For AF_UNIX, addr is the
    // empty bytes; caller uses getsockopt(SO_PEERCRED) for identity.
    fn py_sock_accept(self_in: Obj) callconv(.c) Obj {
        const self: *NpySocket = @ptrFromInt(self_in);
        const client_fd = accept(self.fd, null, null);
        if (client_fd < 0) return raiseOSError(errno_compat.errnoRef().*);
        const client_obj = allocSocket(client_fd, self.family, self.type_, self.proto);
        // Placeholder addr — real address extraction is untested.
        const empty_addr = mp_obj_new_bytes(null, 0);
        const items = [_]Obj{ client_obj, empty_addr };
        return mp_obj_new_tuple(2, &items);
    }

    fn py_sock_recv(self_in: Obj, n_obj: Obj) callconv(.c) Obj {
        const self: *NpySocket = @ptrFromInt(self_in);
        const n_signed = mp_obj_get_int(n_obj);
        if (n_signed < 0) return raiseOSError(errno_h.EINVAL);
        const n: usize = @intCast(n_signed);
        // Stack buffer for small reads (typical RPC frames ≤4 KB).
        var buf: [4096]u8 = undefined;
        if (n > buf.len) return raiseOSError(errno_h.EFBIG);
        const got = recv(self.fd, &buf, n, 0);
        if (got < 0) return raiseOSError(errno_compat.errnoRef().*);
        return mp_obj_new_bytes(&buf, @intCast(got));
    }

    fn py_sock_sendall(self_in: Obj, data_obj: Obj) callconv(.c) Obj {
        const self: *NpySocket = @ptrFromInt(self_in);
        var len: usize = 0;
        const data = mp_obj_str_get_data(data_obj, &len);
        var offset: usize = 0;
        while (offset < len) {
            const sent = send(self.fd, data + offset, len - offset, 0);
            if (sent < 0) {
                if (errno_compat.errnoRef().* == errno_h.EINTR) continue;
                return raiseOSError(errno_compat.errnoRef().*);
            }
            if (sent == 0) return raiseOSError(errno_h.EPIPE);
            offset += @intCast(sent);
        }
        return returnNone();
    }

    fn py_sock_setblocking(self_in: Obj, flag_obj: Obj) callconv(.c) Obj {
        const self: *NpySocket = @ptrFromInt(self_in);
        const blocking = mp_obj_get_int(flag_obj) != 0;
        const cur = fcntl(self.fd, fcntl_h.F_GETFL);
        if (cur < 0) return raiseOSError(errno_compat.errnoRef().*);
        const new_flags: c_int = if (blocking) cur & ~fcntl_h.O_NONBLOCK else cur | fcntl_h.O_NONBLOCK;
        if (fcntl(self.fd, fcntl_h.F_SETFL, new_flags) < 0) return raiseOSError(errno_compat.errnoRef().*);
        return returnNone();
    }

    // sock.getsockopt(level, opt, buflen) → bytes.
    // hop3-rootd's SO_PEERCRED path needs the raw-bytes form (12 bytes
    // on Linux: struct ucred). Vendor CPython also supports an int
    // form when buflen isn't provided; MVP omits it.
    fn py_sock_getsockopt(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
        if (n_args < 3) return raiseOSError(errno_h.EINVAL);
        const self: *NpySocket = @ptrFromInt(args[0]);
        const level: c_int = @intCast(mp_obj_get_int(args[1]));
        const opt: c_int = @intCast(mp_obj_get_int(args[2]));
        const buflen_signed = mp_obj_get_int(args[3]);
        if (buflen_signed <= 0 or buflen_signed > 4096) return raiseOSError(errno_h.EINVAL);
        var buflen: sys_socket_h.socklen_t = @intCast(buflen_signed);
        var buf: [4096]u8 = undefined;
        if (getsockopt(self.fd, level, opt, &buf, &buflen) < 0) return raiseOSError(errno_compat.errnoRef().*);
        return mp_obj_new_bytes(&buf, @intCast(buflen));
    }

    fn py_sock_fileno(self_in: Obj) callconv(.c) Obj {
        const self: *NpySocket = @ptrFromInt(self_in);
        return mirrors.newSmallInt(@intCast(self.fd));
    }

    fn py_sock_close(self_in: Obj) callconv(.c) Obj {
        const self: *NpySocket = @ptrFromInt(self_in);
        if (self.fd >= 0) {
            _ = close(self.fd);
            self.fd = -1;
        }
        return returnNone();
    }

    // ── Method fn-obj exports ────────────────────────────────────────

    pub export const mp_socket_ctor_obj: mirrors.MpObjFunBuiltinVar = .{ .base = .{ .type = &mp_type_fun_builtin_var }, .sig = mirrors.makeFunSig(2, 3, false), .fun = @ptrCast(&py_socket_ctor) };
    pub export const mp_socket_fromfd_obj: mirrors.MpObjFunBuiltinVar = .{ .base = .{ .type = &mp_type_fun_builtin_var }, .sig = mirrors.makeFunSig(3, 4, false), .fun = @ptrCast(&py_socket_fromfd) };
    pub export const mp_sock_bind_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_2 }, .fun = @ptrCast(&py_sock_bind) };
    pub export const mp_sock_listen_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_2 }, .fun = @ptrCast(&py_sock_listen) };
    pub export const mp_sock_accept_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_sock_accept) };
    pub export const mp_sock_recv_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_2 }, .fun = @ptrCast(&py_sock_recv) };
    pub export const mp_sock_sendall_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_2 }, .fun = @ptrCast(&py_sock_sendall) };
    pub export const mp_sock_setblocking_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_2 }, .fun = @ptrCast(&py_sock_setblocking) };
    pub export const mp_sock_getsockopt_obj: mirrors.MpObjFunBuiltinVar = .{ .base = .{ .type = &mp_type_fun_builtin_var }, .sig = mirrors.makeFunSig(4, 4, false), .fun = @ptrCast(&py_sock_getsockopt) };
    pub export const mp_sock_fileno_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_sock_fileno) };
    pub export const mp_sock_close_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_sock_close) };

    // ── Socket type (with locals_dict for methods) ───────────────────

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

    const mp_socket_locals_dict_table = [_]RomEntry{
        .{ .key = qKey(mp.MP_QSTR_bind), .value = &mp_sock_bind_obj },
        .{ .key = qKey(mp.MP_QSTR_listen), .value = &mp_sock_listen_obj },
        .{ .key = qKey(mp.MP_QSTR_accept), .value = &mp_sock_accept_obj },
        .{ .key = qKey(mp.MP_QSTR_recv), .value = &mp_sock_recv_obj },
        .{ .key = qKey(mp.MP_QSTR_sendall), .value = &mp_sock_sendall_obj },
        .{ .key = qKey(mp.MP_QSTR_setblocking), .value = &mp_sock_setblocking_obj },
        .{ .key = qKey(mp.MP_QSTR_getsockopt), .value = &mp_sock_getsockopt_obj },
        .{ .key = qKey(mp.MP_QSTR_fileno), .value = &mp_sock_fileno_obj },
        .{ .key = qKey(mp.MP_QSTR_close), .value = &mp_sock_close_obj },
        .{ .key = qKey(mp.MP_QSTR___del__), .value = &mp_sock_close_obj },
    };

    pub export const mp_socket_locals_dict: mirrors.MpObjDict = .{
        .base = .{ .type = &mp_type_dict },
        .map = .{
            .bits = .{
                .all_keys_are_qstrs = 1,
                .is_fixed = 1,
                .is_ordered = 1,
                .used = mp_socket_locals_dict_table.len,
            },
            .alloc = mp_socket_locals_dict_table.len,
            .table = @ptrCast(@constCast(&mp_socket_locals_dict_table)),
        },
    };

    // MpObjTypeFull layout mirrors src/mp_type_roms.zig — header + 11 slots.
    // Only slot in use here: locals_dict at index 1.
    const MpObjTypeFull = extern struct {
        header: mirrors.MpObjType,
        slots: [11]?*const anyopaque,
    };

    pub export const mp_type_socket: MpObjTypeFull = .{
        .header = .{
            .base = .{ .type = &mp_type_type },
            .flags = 0x0000,
            .name = mp.MP_QSTR_socket,
            .slot_index_make_new = 0,
            .slot_index_print = 0,
            .slot_index_call = 0,
            .slot_index_unary_op = 0,
            .slot_index_binary_op = 0,
            .slot_index_attr = 0,
            .slot_index_subscr = 0,
            .slot_index_iter = 0,
            .slot_index_buffer = 0,
            .slot_index_protocol = 0,
            .slot_index_parent = 0,
            .slot_index_locals_dict = 1,
        },
        .slots = .{
            @ptrCast(&mp_socket_locals_dict),
            null, null, null, null, null, null, null, null, null, null,
        },
    };

    // ── Module globals ───────────────────────────────────────────────

    const mp_module_socket_globals_table = [_]RomEntry{
        .{ .key = qKey(mp.MP_QSTR___name__), .value = @ptrFromInt(qKey(mp.MP_QSTR_socket)) },
        // Callable: `socket.socket(family, type)` returns a new socket.
        // Since socket is a class, `sock.socket` as attr resolves to the
        // constructor. Here we expose it as a plain function.
        .{ .key = qKey(mp.MP_QSTR_socket), .value = &mp_socket_ctor_obj },
        .{ .key = qKey(mp.MP_QSTR_fromfd), .value = &mp_socket_fromfd_obj },

        // Constants — resolved via cImport so macOS/Linux/BSD values
        // match the running platform.
        .{ .key = qKey(mp.MP_QSTR_AF_UNIX), .value = intVal(@intCast(sys_socket_h.AF_UNIX)) },
        .{ .key = qKey(mp.MP_QSTR_AF_INET), .value = intVal(@intCast(sys_socket_h.AF_INET)) },
        .{ .key = qKey(mp.MP_QSTR_AF_INET6), .value = intVal(@intCast(sys_socket_h.AF_INET6)) },
        .{ .key = qKey(mp.MP_QSTR_SOCK_STREAM), .value = intVal(@intCast(sys_socket_h.SOCK_STREAM)) },
        .{ .key = qKey(mp.MP_QSTR_SOCK_DGRAM), .value = intVal(@intCast(sys_socket_h.SOCK_DGRAM)) },
        .{ .key = qKey(mp.MP_QSTR_SOL_SOCKET), .value = intVal(@intCast(sys_socket_h.SOL_SOCKET)) },
        .{ .key = qKey(mp.MP_QSTR_SO_REUSEADDR), .value = intVal(@intCast(sys_socket_h.SO_REUSEADDR)) },
        // SO_PEERCRED is Linux-only. Emit it as the Linux value (17)
        // regardless; hop3-rootd's code uses `getattr(socket, "SO_PEERCRED", None)`
        // — since we always expose it, that becomes the runtime path.
        // On macOS, calling getsockopt(SO_PEERCRED) will raise ENOPROTOOPT.
        .{ .key = qKey(mp.MP_QSTR_SO_PEERCRED), .value = intVal(17) },
    };

    pub export const mp_module_socket_globals: mirrors.MpObjDict = .{
        .base = .{ .type = &mp_type_dict },
        .map = .{
            .bits = .{
                .all_keys_are_qstrs = 1,
                .is_fixed = 1,
                .is_ordered = 1,
                .used = mp_module_socket_globals_table.len,
            },
            .alloc = mp_module_socket_globals_table.len,
            .table = @ptrCast(@constCast(&mp_module_socket_globals_table)),
        },
    };

    pub export const mp_module_socket: mirrors.MpObjModule = .{
        .base = .{ .type = &mp_type_module },
        .globals = @ptrCast(@constCast(&mp_module_socket_globals)),
    };

    const std = @import("std");
} else struct {};

comptime {
    if (enabled) {
        _ = &Body.mp_module_socket;
        _ = &Body.mp_module_socket_globals;
        _ = &Body.mp_type_socket;
        _ = &Body.mp_socket_locals_dict;
        _ = &Body.mp_socket_ctor_obj;
        _ = &Body.mp_socket_fromfd_obj;
        _ = &Body.mp_sock_bind_obj;
        _ = &Body.mp_sock_listen_obj;
        _ = &Body.mp_sock_accept_obj;
        _ = &Body.mp_sock_recv_obj;
        _ = &Body.mp_sock_sendall_obj;
        _ = &Body.mp_sock_setblocking_obj;
        _ = &Body.mp_sock_getsockopt_obj;
        _ = &Body.mp_sock_fileno_obj;
        _ = &Body.mp_sock_close_obj;
    }
}
