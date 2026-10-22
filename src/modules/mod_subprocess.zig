//! nanopython — Zig-native low-level `_subprocess` module.
//!
//! Full-native only. Ships the C-side
//! fork+exec+wait+pipes primitive; the Pythonic `subprocess.run`
//! wrapper (accepting kwargs, CompletedProcess, CalledProcessError,
//! TimeoutExpired) lives in nanopython-lib/subprocess.py.
//!
//! Sole export: `_subprocess._spawn_and_wait`, documented at its
//! definition. No shell, no CLOEXEC beyond the default POSIX behaviour:
//! a "run one command, wait, return its output" primitive.
//!
//! Gated on build_options.feature_subprocess. wasm coerced off.
//!
//! __qstr_shadow_begin__
//! #if MICROPY_PY__SUBPROCESS
//! MP_QSTR__subprocess
//! MP_QSTR__spawn_and_wait
//! MP_REGISTER_MODULE(MP_QSTR__subprocess, mp_module__subprocess);
//! #endif
//! __qstr_shadow_end__

const std = @import("std");
const build_options = @import("build_options");
const mirrors = @import("../mp_mirrors.zig");
const pyerr = @import("../pyerr.zig");
const errno_compat = @import("../support/errno_compat.zig");

const Obj = mirrors.Obj;
const Qstr = usize;

const enabled = build_options.feature_subprocess;

const Body = if (enabled) struct {
    const mp = @cImport({
        @cInclude("py/qstr.h");
    });
    const errno_h = @cImport({
        @cInclude("errno.h");
    });
    const sys_wait_h = @cImport({
        @cInclude("sys/wait.h");
    });
    const unistd_h = @cImport({
        @cInclude("unistd.h");
    });
    const signal_h = @cImport({
        @cInclude("signal.h");
    });
    const time_h = @cImport({
        @cInclude("time.h");
    });
    const fcntl_h = @cImport({
        @cInclude("fcntl.h");
    });

    extern const mp_type_module: anyopaque;
    extern const mp_type_dict: anyopaque;
    extern const mp_type_fun_builtin_var: anyopaque;

    extern fn mp_obj_new_bytes(data: [*c]const u8, len: usize) callconv(.c) Obj;
    extern fn mp_obj_new_tuple(n: usize, items: [*c]const Obj) callconv(.c) Obj;
    extern fn mp_obj_get_int(o: Obj) callconv(.c) isize;
    extern fn mp_obj_get_float(o: Obj) callconv(.c) f64;
    extern fn mp_obj_str_get_str(o: Obj) callconv(.c) ?[*:0]const u8;
    extern fn mp_obj_str_get_data(o: Obj, len_out: *usize) callconv(.c) [*]const u8;
    extern fn mp_raise_OSError_polled(errno_: c_int) callconv(.c) void;
    extern fn m_malloc(n: usize) callconv(.c) ?*anyopaque;
    extern fn m_free(p: ?*anyopaque) callconv(.c) void;

    // libc.
    extern fn pipe(fds: *[2]c_int) callconv(.c) c_int;
    extern fn fork() callconv(.c) c_int;
    extern fn dup2(oldfd: c_int, newfd: c_int) callconv(.c) c_int;
    extern fn execvp(file: [*:0]const u8, argv: [*]const ?[*:0]const u8) callconv(.c) c_int;
    extern fn execvpe(file: [*:0]const u8, argv: [*]const ?[*:0]const u8, envp: [*]const ?[*:0]const u8) callconv(.c) c_int;
    extern fn read(fd: c_int, buf: [*]u8, count: usize) callconv(.c) isize;
    extern fn write(fd: c_int, buf: [*]const u8, count: usize) callconv(.c) isize;
    extern fn close(fd: c_int) callconv(.c) c_int;
    extern fn waitpid(pid: c_int, status: *c_int, options: c_int) callconv(.c) c_int;
    extern fn kill(pid: c_int, sig: c_int) callconv(.c) c_int;
    extern fn nanosleep(req: *const time_h.struct_timespec, rem: ?*time_h.struct_timespec) callconv(.c) c_int;
    extern fn clock_gettime(clk: c_int, ts: *time_h.struct_timespec) callconv(.c) c_int;
    extern fn _exit(status: c_int) callconv(.c) noreturn;

    const CLOCK_MONOTONIC: c_int = @intCast(time_h.CLOCK_MONOTONIC);
    // WNOHANG value differs per platform — use cImport'd value.
    const WNOHANG: c_int = @intCast(sys_wait_h.WNOHANG);

    // Under MICROPY_OBJ_REPR_A: mp_const_none = 6.
    const MP_CONST_NONE: Obj = 0x06;
    const MP_CONST_FALSE: Obj = 0x0E;
    const MP_CONST_TRUE: Obj = 0x1E;

    fn raiseOSError(err: c_int) Obj {
        mp_raise_OSError_polled(err);
        return mirrors.OBJ_NULL;
    }

    // Elapsed monotonic seconds since `start_ts`.
    fn elapsedSince(start: *const time_h.struct_timespec) f64 {
        var now: time_h.struct_timespec = undefined;
        _ = clock_gettime(CLOCK_MONOTONIC, &now);
        return @as(f64, @floatFromInt(now.tv_sec - start.tv_sec)) +
            @as(f64, @floatFromInt(now.tv_nsec - start.tv_nsec)) / 1_000_000_000.0;
    }

    // Where each of the child's stdin, stdout and stderr goes: the
    // parent's (INHERIT), a pipe to the parent, the child's stdout
    // (stderr only), /dev/null, or a file descriptor (>= 0). PIPE,
    // STDOUT and DEVNULL are subprocess's own values.
    const INHERIT: isize = -4;
    const PIPE: isize = -1;
    const STDOUT: isize = -2;
    const DEVNULL: isize = -3;

    const Pollfd = extern struct { fd: c_int, events: c_short, revents: c_short = 0 };
    const POLLIN: c_short = 0x1;
    const POLLOUT: c_short = 0x4;
    extern fn poll(fds: [*]Pollfd, n: c_uint, timeout_ms: c_int) callconv(.c) c_int;
    extern fn open(path: [*:0]const u8, flags: c_int, ...) callconv(.c) c_int;
    extern fn chdir(path: [*:0]const u8) callconv(.c) c_int;
    extern fn signal(sig: c_int, handler: ?*const anyopaque) callconv(.c) ?*const anyopaque;
    const SIG_IGN: ?*const anyopaque = @ptrFromInt(1);

    fn errno() c_int {
        return errno_compat.errnoRef().*;
    }

    fn closeFd(fd: *c_int) void {
        if (fd.* >= 0) _ = close(fd.*);
        fd.* = -1;
    }

    // A null-terminated char** over a list of str, in m_malloc'd memory.
    fn cStrArray(list_obj: Obj) ?[*:null]?[*:0]const u8 {
        const list = mirrors.MpObjList.fromObj(list_obj);
        const arr: [*]?[*:0]const u8 = @ptrCast(@alignCast(m_malloc((list.len + 1) * @sizeOf(usize)).?));
        for (0..list.len) |i| {
            arr[i] = mp_obj_str_get_str(list.items[i]) orelse {
                m_free(@ptrCast(arr));
                return null;
            };
        }
        arr[list.len] = null;
        return @ptrCast(arr);
    }

    // _spawn_and_wait(argv, input, timeout, env, cwd, stdin, stdout, stderr)
    //   → (returncode, stdout bytes or None, stderr bytes or None, timed_out)
    // `env` is None or a list of "NAME=value" strings; the three streams
    // take the modes above. Output is read while the child runs, so a
    // child that writes more than a pipe holds does not block.
    fn py_spawn_and_wait(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
        _ = n_args;
        const argv = cStrArray(args[0]) orelse return raiseOSError(errno_h.EINVAL);
        defer m_free(@ptrCast(argv));
        if (argv[0] == null) return raiseOSError(errno_h.EINVAL);
        const envp: ?[*:null]?[*:0]const u8 = if (args[3] == MP_CONST_NONE) null else cStrArray(args[3]) orelse return raiseOSError(errno_h.EINVAL);
        defer if (envp) |e| m_free(@ptrCast(e));
        const cwd: ?[*:0]const u8 = if (args[4] == MP_CONST_NONE) null else mp_obj_str_get_str(args[4]) orelse return raiseOSError(errno_h.EINVAL);
        var input: []const u8 = &.{};
        if (args[1] != MP_CONST_NONE) {
            var len: usize = 0;
            input = mp_obj_str_get_data(args[1], &len)[0..len];
        }
        const timeout_secs: f64 = mp_obj_get_float(args[2]);
        const modes = [3]isize{ mp_obj_get_int(args[5]), mp_obj_get_int(args[6]), mp_obj_get_int(args[7]) };

        // pipes[i] carries stream i; the parent writes pipes[0] and reads
        // the other two.
        var pipes: [3][2]c_int = @splat(.{ -1, -1 });
        defer for (&pipes) |*pp| {
            closeFd(&pp[0]);
            closeFd(&pp[1]);
        };
        for (modes, 0..) |m, i| {
            if (m == PIPE and pipe(&pipes[i]) < 0) return raiseOSError(errno());
        }

        const child = fork();
        if (child < 0) return raiseOSError(errno());
        if (child == 0) {
            for (modes, 0..) |m, i| {
                const fd: c_int = @intCast(i);
                switch (m) {
                    INHERIT => {},
                    PIPE => _ = dup2(pipes[i][if (i == 0) 0 else 1], fd),
                    STDOUT => _ = dup2(1, fd),
                    DEVNULL => _ = dup2(open("/dev/null", if (i == 0) fcntl_h.O_RDONLY else fcntl_h.O_WRONLY), fd),
                    else => _ = dup2(@intCast(m), fd),
                }
            }
            for (&pipes) |*pp| {
                closeFd(&pp[0]);
                closeFd(&pp[1]);
            }
            if (cwd) |d| if (chdir(d) < 0) _exit(127);
            if (envp) |e| std.c.environ = @ptrCast(@constCast(e));
            _ = execvp(argv[0].?, argv);
            // execvp only returns on failure.
            _exit(127);
        }

        // ── Parent ───────────────────────────────────────────────────
        closeFd(&pipes[0][0]);
        closeFd(&pipes[1][1]);
        closeFd(&pipes[2][1]);
        if (input.len == 0) closeFd(&pipes[0][1]);
        for ([_]c_int{ pipes[0][1], pipes[1][0], pipes[2][0] }) |fd| {
            if (fd >= 0) _ = fcntl_setnonblock(fd);
        }
        // A child that exits without reading its input must not kill
        // the parent with SIGPIPE; the write fails with EPIPE instead.
        const old_sigpipe = signal(signal_h.SIGPIPE, SIG_IGN);
        defer _ = signal(signal_h.SIGPIPE, old_sigpipe);

        const gpa = std.heap.c_allocator;
        var out: [3]std.ArrayList(u8) = @splat(.empty);
        defer for (&out) |*o| o.deinit(gpa);
        var written: usize = 0;
        var start_ts: time_h.struct_timespec = undefined;
        _ = clock_gettime(CLOCK_MONOTONIC, &start_ts);
        var timed_out = false;

        // Feed stdin and drain stdout/stderr until all three are closed.
        while (true) {
            var fds: [3]Pollfd = undefined;
            var stream: [3]usize = undefined;
            var n: usize = 0;
            for (0..3) |i| {
                const fd = pipes[i][if (i == 0) 1 else 0];
                if (fd < 0) continue;
                fds[n] = .{ .fd = fd, .events = if (i == 0) POLLOUT else POLLIN };
                stream[n] = i;
                n += 1;
            }
            if (n == 0) break;
            var wait_ms: c_int = -1;
            if (timeout_secs >= 0) {
                const left = timeout_secs - elapsedSince(&start_ts);
                if (left <= 0) {
                    timed_out = true;
                    break;
                }
                wait_ms = @intFromFloat(@ceil(left * 1000.0));
            }
            if (poll(&fds, @intCast(n), wait_ms) < 0) {
                if (errno() == errno_h.EINTR) continue;
                return raiseOSError(errno());
            }
            for (fds[0..n], stream[0..n]) |f, i| {
                if (f.revents == 0) continue;
                if (i == 0) {
                    const w = write(f.fd, input.ptr + written, input.len - written);
                    if (w > 0) written += @intCast(w);
                    if (written == input.len or (w < 0 and errno() != errno_h.EAGAIN and errno() != errno_h.EINTR)) closeFd(&pipes[0][1]);
                } else {
                    out[i].ensureUnusedCapacity(gpa, 16384) catch return raiseOSError(errno_h.ENOMEM);
                    const buf = out[i].unusedCapacitySlice();
                    const got = read(f.fd, buf.ptr, buf.len);
                    if (got > 0) {
                        out[i].items.len += @intCast(got);
                    } else if (got == 0 or (errno() != errno_h.EAGAIN and errno() != errno_h.EINTR)) {
                        closeFd(&pipes[i][0]);
                    }
                }
            }
        }

        // The streams are closed; wait for the child to exit.
        var status: c_int = 0;
        while (!timed_out) {
            const w = waitpid(child, &status, WNOHANG);
            if (w == child) break;
            if (w < 0 and errno() != errno_h.EINTR) return raiseOSError(errno());
            if (timeout_secs >= 0 and elapsedSince(&start_ts) > timeout_secs) {
                timed_out = true;
                break;
            }
            sleep10ms();
        }
        if (timed_out) {
            _ = kill(child, signal_h.SIGTERM);
            // Give it a moment to die.
            var give_up_at: time_h.struct_timespec = undefined;
            _ = clock_gettime(CLOCK_MONOTONIC, &give_up_at);
            while (waitpid(child, &status, WNOHANG) != child) {
                if (elapsedSince(&give_up_at) > 1.0) {
                    _ = kill(child, signal_h.SIGKILL);
                    _ = waitpid(child, &status, 0); // blocking reap
                    break;
                }
                sleep10ms();
            }
        }

        // Extract exit code from status. WIFEXITED / WEXITSTATUS
        // macros — use bit ops (POSIX-defined).
        const returncode: isize = if ((status & 0x7f) == 0)
            @as(isize, @intCast((status >> 8) & 0xff)) // WIFEXITED
        else
            -@as(isize, @intCast(status & 0x7f)); // signal number, negated

        const items = [_]Obj{
            mirrors.newSmallInt(returncode),
            if (modes[1] == PIPE) mp_obj_new_bytes(out[1].items.ptr, out[1].items.len) else MP_CONST_NONE,
            if (modes[2] == PIPE) mp_obj_new_bytes(out[2].items.ptr, out[2].items.len) else MP_CONST_NONE,
            if (timed_out) MP_CONST_TRUE else MP_CONST_FALSE,
        };
        return mp_obj_new_tuple(4, &items);
    }

    fn sleep10ms() void {
        var ts: time_h.struct_timespec = .{ .tv_sec = 0, .tv_nsec = 10_000_000 };
        _ = nanosleep(&ts, null);
    }

    extern fn fcntl(fd: c_int, cmd: c_int, ...) callconv(.c) c_int;
    fn fcntl_setnonblock(fd: c_int) c_int {
        const cur = fcntl(fd, fcntl_h.F_GETFL);
        if (cur < 0) return -1;
        return fcntl(fd, fcntl_h.F_SETFL, cur | fcntl_h.O_NONBLOCK);
    }

    // ── Module exports ───────────────────────────────────────────────

    pub export const mp_subprocess_spawn_obj: mirrors.MpObjFunBuiltinVar = .{
        .base = .{ .type = &mp_type_fun_builtin_var },
        .sig = mirrors.makeFunSig(8, 8, false),
        .fun = @ptrCast(&py_spawn_and_wait),
    };

    const RomEntry = extern struct {
        key: Obj,
        value: *const anyopaque,
    };

    inline fn qKey(q: usize) Obj {
        return mirrors.objFromQstr(@as(Qstr, q));
    }

    const mp_module__subprocess_globals_table = [_]RomEntry{
        .{ .key = qKey(mp.MP_QSTR___name__), .value = @ptrFromInt(qKey(mp.MP_QSTR__subprocess)) },
        .{ .key = qKey(mp.MP_QSTR__spawn_and_wait), .value = &mp_subprocess_spawn_obj },
    };

    pub export const mp_module__subprocess_globals: mirrors.MpObjDict = .{
        .base = .{ .type = &mp_type_dict },
        .map = .{
            .bits = .{
                .all_keys_are_qstrs = 1,
                .is_fixed = 1,
                .is_ordered = 1,
                .used = mp_module__subprocess_globals_table.len,
            },
            .alloc = mp_module__subprocess_globals_table.len,
            .table = @ptrCast(@constCast(&mp_module__subprocess_globals_table)),
        },
    };

    pub export const mp_module__subprocess: mirrors.MpObjModule = .{
        .base = .{ .type = &mp_type_module },
        .globals = @ptrCast(@constCast(&mp_module__subprocess_globals)),
    };
} else struct {};

comptime {
    if (enabled) {
        _ = &Body.mp_module__subprocess;
        _ = &Body.mp_module__subprocess_globals;
        _ = &Body.mp_subprocess_spawn_obj;
    }
}
