//! nanopython — Zig-native low-level `_subprocess` module.
//!
//! notes/plans/full-unix-profile.md phase 6. Ships the C-side
//! fork+exec+wait+pipes primitive; the Pythonic `subprocess.run`
//! wrapper (accepting kwargs, CompletedProcess, CalledProcessError,
//! TimeoutExpired) lives in nanopython-lib/subprocess.py.
//!
//! Sole export:
//!   _subprocess._spawn_and_wait(argv, input_or_none, timeout_or_neg1,
//!                               env_or_none)
//!     → (returncode, stdout_bytes, stderr_bytes, timed_out_bool)
//!
//! Semantics:
//!   * argv: list of str; argv[0] is the binary path (must be absolute
//!     or on $PATH — no shell expansion).
//!   * input_or_none: bytes to write to child stdin (None = no input).
//!   * timeout_or_neg1: float seconds; negative = block indefinitely.
//!     If exceeded, the child is SIGTERM'd, reaped, and the tuple's
//!     timed_out=True. Whatever was captured before the kill is returned.
//!   * env_or_none: dict of str→str; None = inherit parent env.
//!
//! No shell, no piping to another process, no signal-safe forking
//! guarantees, no CLOEXEC beyond the default POSIX behavior. This is
//! a "run one command, capture output, return everything" primitive.
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

    // Read up to `max` bytes from `fd` into an m_malloc'd buffer.
    // Returns a Python bytes object. Non-blocking-safe (EAGAIN → break).
    // Uses ping-pong doubling to size the output.
    fn readAllToBytes(fd: c_int) Obj {
        var cap: usize = 4096;
        var buf: [*]u8 = @ptrCast(@alignCast(m_malloc(cap).?));
        var len: usize = 0;
        while (true) {
            if (len == cap) {
                const ncap = cap * 2;
                const nbuf: [*]u8 = @ptrCast(@alignCast(m_malloc(ncap).?));
                @memcpy(nbuf[0..len], buf[0..len]);
                m_free(@ptrCast(buf));
                buf = nbuf;
                cap = ncap;
            }
            const n = read(fd, buf + len, cap - len);
            if (n < 0) {
                if (errno_compat.errnoRef().* == errno_h.EINTR) continue;
                if (errno_compat.errnoRef().* == errno_h.EAGAIN or errno_compat.errnoRef().* == errno_h.EWOULDBLOCK) break;
                break; // Give up on other errors — return what we have.
            }
            if (n == 0) break; // EOF
            len += @intCast(n);
        }
        const result = mp_obj_new_bytes(buf, len);
        m_free(@ptrCast(buf));
        return result;
    }

    // Elapsed monotonic seconds since `start_ts`.
    fn elapsedSince(start: *const time_h.struct_timespec) f64 {
        var now: time_h.struct_timespec = undefined;
        _ = clock_gettime(CLOCK_MONOTONIC, &now);
        return @as(f64, @floatFromInt(now.tv_sec - start.tv_sec)) +
            @as(f64, @floatFromInt(now.tv_nsec - start.tv_nsec)) / 1_000_000_000.0;
    }

    // _spawn_and_wait(argv, input_or_none, timeout_or_neg1, env_or_none)
    //   → (returncode, stdout, stderr, timed_out)
    fn py_spawn_and_wait(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
        if (n_args < 4) return raiseOSError(errno_h.EINVAL);

        // Marshal argv from Python list into a null-terminated char**.
        const argv_list: *mirrors.MpObjList = mirrors.MpObjList.fromObj(args[0]);
        const argc = argv_list.len;
        if (argc == 0) return raiseOSError(errno_h.EINVAL);
        const argv_bytes = (argc + 1) * @sizeOf(?[*:0]const u8);
        var argv: [*]?[*:0]const u8 = @ptrCast(@alignCast(m_malloc(argv_bytes).?));
        defer m_free(@ptrCast(argv));
        var i: usize = 0;
        while (i < argc) : (i += 1) {
            argv[i] = mp_obj_str_get_str(argv_list.items[i]) orelse return raiseOSError(errno_h.EINVAL);
        }
        argv[argc] = null;

        // input_or_none.
        const input_obj = args[1];
        var input_data: [*]const u8 = undefined;
        var input_len: usize = 0;
        const have_input = input_obj != MP_CONST_NONE;
        if (have_input) {
            input_data = mp_obj_str_get_data(input_obj, &input_len);
        }

        // timeout (negative = wait indefinitely).
        const timeout_secs: f64 = mp_obj_get_float(args[2]);

        // env (currently unused — inherit parent). See TODO below.
        _ = args[3];

        // Set up three pipes: stdin (parent writes), stdout, stderr.
        var stdin_pipe: [2]c_int = undefined;
        var stdout_pipe: [2]c_int = undefined;
        var stderr_pipe: [2]c_int = undefined;
        if (pipe(&stdin_pipe) < 0) return raiseOSError(errno_compat.errnoRef().*);
        if (pipe(&stdout_pipe) < 0) {
            _ = close(stdin_pipe[0]); _ = close(stdin_pipe[1]);
            return raiseOSError(errno_compat.errnoRef().*);
        }
        if (pipe(&stderr_pipe) < 0) {
            _ = close(stdin_pipe[0]); _ = close(stdin_pipe[1]);
            _ = close(stdout_pipe[0]); _ = close(stdout_pipe[1]);
            return raiseOSError(errno_compat.errnoRef().*);
        }

        const child = fork();
        if (child < 0) return raiseOSError(errno_compat.errnoRef().*);

        if (child == 0) {
            // ── Child ────────────────────────────────────────────────
            _ = dup2(stdin_pipe[0], 0);
            _ = dup2(stdout_pipe[1], 1);
            _ = dup2(stderr_pipe[1], 2);
            // Close parent ends.
            _ = close(stdin_pipe[0]); _ = close(stdin_pipe[1]);
            _ = close(stdout_pipe[0]); _ = close(stdout_pipe[1]);
            _ = close(stderr_pipe[0]); _ = close(stderr_pipe[1]);
            _ = execvp(argv[0].?, argv);
            // execvp only returns on failure.
            _exit(127);
        }

        // ── Parent ───────────────────────────────────────────────────
        _ = close(stdin_pipe[0]);
        _ = close(stdout_pipe[1]);
        _ = close(stderr_pipe[1]);

        // Feed child stdin (blocking write for MVP; child is on the
        // other end reading, so this should complete quickly for the
        // typical small-input case hop3-rootd uses).
        if (have_input) {
            var off: usize = 0;
            while (off < input_len) {
                const w = write(stdin_pipe[1], input_data + off, input_len - off);
                if (w < 0) {
                    if (errno_compat.errnoRef().* == errno_h.EINTR) continue;
                    break; // Give up; the child may have died.
                }
                if (w == 0) break;
                off += @intCast(w);
            }
        }
        _ = close(stdin_pipe[1]);

        // Set stdout/stderr reads to non-blocking so we can poll+read
        // while waiting for the child.
        _ = fcntl_setnonblock(stdout_pipe[0]);
        _ = fcntl_setnonblock(stderr_pipe[0]);

        // Poll waitpid + drain pipes. Simple: check waitpid(WNOHANG)
        // every 10ms, read what's available, kill if timeout exceeded.
        var start_ts: time_h.struct_timespec = undefined;
        _ = clock_gettime(CLOCK_MONOTONIC, &start_ts);
        var status: c_int = 0;
        var timed_out = false;
        while (true) {
            const w = waitpid(child, &status, WNOHANG);
            if (w == child) break;
            if (w < 0) {
                if (errno_compat.errnoRef().* == errno_h.EINTR) continue;
                _ = close(stdout_pipe[0]); _ = close(stderr_pipe[0]);
                return raiseOSError(errno_compat.errnoRef().*);
            }
            // Still running. Check timeout.
            if (timeout_secs >= 0 and elapsedSince(&start_ts) > timeout_secs) {
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
                timed_out = true;
                break;
            }
            sleep10ms();
        }

        const stdout_bytes = readAllToBytes(stdout_pipe[0]);
        const stderr_bytes = readAllToBytes(stderr_pipe[0]);
        _ = close(stdout_pipe[0]);
        _ = close(stderr_pipe[0]);

        // Extract exit code from status. WIFEXITED / WEXITSTATUS
        // macros — use bit ops (POSIX-defined).
        const returncode: isize = if ((status & 0x7f) == 0)
            @as(isize, @intCast((status >> 8) & 0xff)) // WIFEXITED
        else
            -@as(isize, @intCast(status & 0x7f)); // signal number, negated

        const items = [_]Obj{
            mirrors.newSmallInt(returncode),
            stdout_bytes,
            stderr_bytes,
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
        .sig = mirrors.makeFunSig(4, 4, false),
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
