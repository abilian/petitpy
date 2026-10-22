//! nanopython — Zig port of src/modules/file_io.c (file IO + sys.std{in,out,err})
//! for the full config. Under nano (MICROPY_PY_IO=0), this file emits nothing:
//! all symbols live behind `if (build_options.is_full)` so dead-code elimination
//! drops them, and main.zig's `npy_file_io_init()` call site is itself comptime-
//! gated, so the linker never needs the symbol under nano.
//!
//! Provides under full:
//!   - `mp_type_textio` (qstr TextIOWrapper) + `mp_type_fileio` (qstr FileIO)
//!   - `mp_builtin_open_obj`: open(path, mode) → file via libc fopen
//!   - `mp_sys_std{in,out,err}_obj` and `.buffer` siblings
//!   - `npy_file_io_init()`: binds the static FILE*s at mp_init time
//!     (stdin/stdout/stderr aren't constants on Darwin).
//!
//! __qstr_shadow_begin__
//! #if MICROPY_PY_IO
//! MP_QSTR_FileIO
//! MP_QSTR_TextIOWrapper
//! MP_QSTR_buffer
//! MP_QSTR_readlines
//! MP_QSTR_fileno
//! #endif
//! __qstr_shadow_end__

const build_options = @import("build_options");
const mp = @cImport({
    @cInclude("py/qstr.h");
});
// Pulled in via @cImport so that platform-specific decls (FILE* stdio globals
// on macOS = __stdinp/__stdoutp/__stderrp; on Linux/wasi = stdin/stdout/stderr)
// and errno accessor (Darwin = __error; glibc/musl/wasi = __errno_location)
// can be resolved at comptime via @hasDecl. Same approach as src/support/readline.zig.
const libc = @cImport({
    @cInclude("stdio.h");
    @cInclude("errno.h");
});
const mirrors = @import("../mp_mirrors.zig");

const Obj = mirrors.Obj;
const Qstr = usize;

// ── libc externs (avoid std.c platform-specific surface) ───────────────
const FILE = opaque {};
extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) callconv(.c) ?*FILE;
extern fn fclose(stream: *FILE) callconv(.c) c_int;
extern fn fread(ptr: *anyopaque, size: usize, nmemb: usize, stream: *FILE) callconv(.c) usize;
extern fn fwrite(ptr: *const anyopaque, size: usize, nmemb: usize, stream: *FILE) callconv(.c) usize;
extern fn fseek(stream: *FILE, offset: c_long, whence: c_int) callconv(.c) c_int;
extern fn ftell(stream: *FILE) callconv(.c) c_long;
extern fn fflush(stream: *FILE) callconv(.c) c_int;
extern fn ferror(stream: *FILE) callconv(.c) c_int;
extern fn clearerr(stream: *FILE) callconv(.c) void;
extern fn fileno(stream: *FILE) callconv(.c) c_int;
extern fn strchr(s: [*:0]const u8, c: c_int) callconv(.c) ?[*:0]const u8;

// Comptime-pick the stdio FILE* globals (Darwin vs POSIX) and the errno
// accessor (Darwin __error vs Linux/wasi __errno_location). The FILE pointers
// are stored into the NpyFile objects at init time and only read/written via
// the libc functions above, so we cast through *FILE.
inline fn stdinFp() ?*FILE {
    if (@hasDecl(libc, "__stdinp")) return @ptrCast(libc.__stdinp);
    return @ptrCast(libc.stdin);
}
inline fn stdoutFp() ?*FILE {
    if (@hasDecl(libc, "__stdoutp")) return @ptrCast(libc.__stdoutp);
    return @ptrCast(libc.stdout);
}
inline fn stderrFp() ?*FILE {
    if (@hasDecl(libc, "__stderrp")) return @ptrCast(libc.__stderrp);
    return @ptrCast(libc.stderr);
}

// ── extern type & fn-obj references ────────────────────────────────────
extern const mp_type_fun_builtin_var: anyopaque;
extern const mp_type_str: anyopaque;
extern const mp_type_type: anyopaque;

// Stream builtin fn-obj symbols (defined in vendor py/stream.c).
extern const mp_stream_read_obj: anyopaque;
extern const mp_stream_readinto_obj: anyopaque;
extern const mp_stream_unbuffered_readline_obj: anyopaque;
extern const mp_stream_unbuffered_readlines_obj: anyopaque;
extern const mp_stream_write_obj: anyopaque;
extern const mp_stream_seek_obj: anyopaque;
extern const mp_stream_tell_obj: anyopaque;
extern const mp_stream_flush_obj: anyopaque;
extern const mp_stream_close_obj: anyopaque;
extern const mp_stream___exit___obj: anyopaque;
extern const mp_identity_obj: anyopaque;

// Runtime helpers (vendor py/runtime.h).
extern fn mp_printf(print: ?*const anyopaque, fmt: [*:0]const u8, ...) callconv(.c) c_int;
extern fn qstr_str(q: usize) callconv(.c) [*:0]const u8;
// NX-3 N4a: polled-sentinel. Returns null + sets pyerr.pending_exc on bad input.
extern fn mp_obj_str_get_str(self_in: Obj) callconv(.c) ?[*:0]const u8;
extern fn mp_raise_TypeError(msg: ?*const anyopaque) callconv(.c) noreturn;
extern fn mp_raise_OSError(errno_: c_int) callconv(.c) noreturn;
extern fn m_malloc_with_finaliser(num_bytes: usize) callconv(.c) *anyopaque;

inline fn errnoVal() c_int {
    if (@hasDecl(libc, "__error")) return libc.__error().*;
    if (@hasDecl(libc, "__errno_location")) return libc.__errno_location().*;
    return libc.errno;
}

// ── stream.h constants (mirrors py/stream.h) ───────────────────────────
const MP_STREAM_ERROR: usize = ~@as(usize, 0);
const MP_STREAM_FLUSH: usize = 1;
const MP_STREAM_SEEK: usize = 2;
const MP_STREAM_CLOSE: usize = 4;
const MP_SEEK_SET: c_int = 0;
const MP_SEEK_CUR: c_int = 1;
const MP_SEEK_END: c_int = 2;

const EBADF: c_int = 9;
const EINVAL: c_int = 22;

// ── mp_obj_npy_file_t ──────────────────────────────────────────────────
// Lays out as: { type, FILE*, bool, padding } — same as the C struct.
const NpyFile = extern struct {
    base: mirrors.MpObjBase,
    fp: ?*FILE,
    is_stdio: bool,
};

// vendor's struct mp_stream_seek_t (py/stream.h:56). `mp_off_t` is the
// vendor's off_t — under nano/full it's a signed 64-bit on 64-bit hosts.
const MpStreamSeek = extern struct {
    offset: i64,
    whence: c_int,
};

// vendor's mp_stream_p_t (py/stream.h:70). `is_text` is a 1-bit bitfield;
// we mirror as a full mp_uint_t (usize) field — works because read/write/
// ioctl are pointers (their own width) so layout-position of is_text after
// them just needs to be a single word.
const StreamP = extern struct {
    read: ?*const fn (obj: Obj, buf: ?*anyopaque, size: usize, errcode: *c_int) callconv(.c) usize,
    write: ?*const fn (obj: Obj, buf: ?*const anyopaque, size: usize, errcode: *c_int) callconv(.c) usize,
    ioctl: ?*const fn (obj: Obj, request: usize, arg: usize, errcode: *c_int) callconv(.c) usize,
    is_text: usize, // bitfield :1 in C → store in a usize-sized slot
};

// ── stream-protocol implementations ────────────────────────────────────
fn npyFileRead(self_in: Obj, buf: ?*anyopaque, size: usize, errcode: *c_int) callconv(.c) usize {
    const self: *NpyFile = @ptrFromInt(self_in);
    const fp = self.fp orelse {
        errcode.* = EBADF;
        return MP_STREAM_ERROR;
    };
    const n = fread(buf.?, 1, size, fp);
    if (n == 0 and ferror(fp) != 0) {
        errcode.* = errnoVal();
        clearerr(fp);
        return MP_STREAM_ERROR;
    }
    return n;
}

fn npyFileWrite(self_in: Obj, buf: ?*const anyopaque, size: usize, errcode: *c_int) callconv(.c) usize {
    const self: *NpyFile = @ptrFromInt(self_in);
    const fp = self.fp orelse {
        errcode.* = EBADF;
        return MP_STREAM_ERROR;
    };
    const n = fwrite(buf.?, 1, size, fp);
    if (n < size) {
        errcode.* = errnoVal();
        return MP_STREAM_ERROR;
    }
    return n;
}

fn npyFileIoctl(self_in: Obj, request: usize, arg: usize, errcode: *c_int) callconv(.c) usize {
    const self: *NpyFile = @ptrFromInt(self_in);
    switch (request) {
        MP_STREAM_SEEK => {
            const fp = self.fp orelse {
                errcode.* = EBADF;
                return MP_STREAM_ERROR;
            };
            const s: *MpStreamSeek = @ptrFromInt(arg);
            const whence: c_int = switch (s.whence) {
                MP_SEEK_SET => MP_SEEK_SET,
                MP_SEEK_CUR => MP_SEEK_CUR,
                MP_SEEK_END => MP_SEEK_END,
                else => {
                    errcode.* = EINVAL;
                    return MP_STREAM_ERROR;
                },
            };
            if (fseek(fp, @intCast(s.offset), whence) != 0) {
                errcode.* = errnoVal();
                return MP_STREAM_ERROR;
            }
            const pos = ftell(fp);
            if (pos < 0) {
                errcode.* = errnoVal();
                return MP_STREAM_ERROR;
            }
            s.offset = pos;
            return 0;
        },
        MP_STREAM_FLUSH => {
            const fp = self.fp orelse {
                errcode.* = EBADF;
                return MP_STREAM_ERROR;
            };
            if (fflush(fp) != 0) {
                errcode.* = errnoVal();
                return MP_STREAM_ERROR;
            }
            return 0;
        },
        MP_STREAM_CLOSE => {
            if (self.fp) |fp| {
                if (!self.is_stdio) _ = fclose(fp);
            }
            self.fp = null;
            return 0;
        },
        else => {
            errcode.* = EINVAL;
            return MP_STREAM_ERROR;
        },
    }
}

// ── npy_file_print ─────────────────────────────────────────────────────
fn npyFilePrint(print: ?*const anyopaque, self_in: Obj, kind: c_int) callconv(.c) void {
    _ = kind;
    const self: *NpyFile = @ptrFromInt(self_in);
    const fd: c_int = if (self.fp) |fp| fileno(fp) else -1;
    const t = mirrors.MpObjType.fromPtr(self.base.type);
    _ = mp_printf(print, "<io.%s %d>", qstr_str(@intCast(t.name)), fd);
}

// ── fileno() ───────────────────────────────────────────────────────────
extern const mp_type_fun_builtin_1: anyopaque;
extern fn mp_raise_OSError_polled(errno_: c_int) callconv(.c) void;

fn npyFileFileno(self_in: Obj) callconv(.c) Obj {
    const self: *NpyFile = @ptrFromInt(self_in);
    const fp = self.fp orelse {
        mp_raise_OSError_polled(EBADF);
        return mirrors.OBJ_NULL;
    };
    return mirrors.newSmallInt(fileno(fp));
}

const npy_file_fileno_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&npyFileFileno) };

// ── locals_dict for FileIO/TextIOWrapper ───────────────────────────────
const RomEntry = extern struct {
    key: Obj,
    value: *const anyopaque,
};

const npy_file_locals_dict_table = [_]RomEntry{
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_read)), .value = &mp_stream_read_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_readinto)), .value = &mp_stream_readinto_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_readline)), .value = &mp_stream_unbuffered_readline_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_readlines)), .value = &mp_stream_unbuffered_readlines_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_write)), .value = &mp_stream_write_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_seek)), .value = &mp_stream_seek_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_tell)), .value = &mp_stream_tell_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_flush)), .value = &mp_stream_flush_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_fileno)), .value = &npy_file_fileno_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_close)), .value = &mp_stream_close_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR___del__)), .value = &mp_stream_close_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR___enter__)), .value = &mp_identity_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR___exit__)), .value = &mp_stream___exit___obj },
};

extern const mp_type_dict: anyopaque;

pub export const npy_file_locals_dict: mirrors.MpObjDict = .{
    .base = .{ .type = &mp_type_dict },
    .map = .{
        .bits = .{
            .all_keys_are_qstrs = 1,
            .is_fixed = 1,
            .is_ordered = 1,
            .used = npy_file_locals_dict_table.len,
        },
        .alloc = npy_file_locals_dict_table.len,
        .table = @ptrCast(@constCast(&npy_file_locals_dict_table)),
    },
};

// ── stream-protocol structs (one per textio/fileio for is_text bit) ────
const npy_fileio_stream_p: StreamP = .{
    .read = &npyFileRead,
    .write = &npyFileWrite,
    .ioctl = &npyFileIoctl,
    .is_text = 0,
};
const npy_textio_stream_p: StreamP = .{
    .read = &npyFileRead,
    .write = &npyFileWrite,
    .ioctl = &npyFileIoctl,
    .is_text = 1,
};

// ── attr slot for textio (only under SYS_STDIO_BUFFER) ─────────────────
const has_buffer = build_options.is_full; // SYS_STDIO_BUFFER tracks full

fn npyTextioAttr(self_in: Obj, attr: u16, dest: [*c]Obj) callconv(.c) void {
    if (dest[0] != mirrors.OBJ_NULL) return; // read-only
    if (attr == @as(u16, mp.MP_QSTR_buffer)) {
        if (self_in == mirrors.objFromPtr(&mp_sys_stdin_obj)) {
            dest[0] = mirrors.objFromPtr(&mp_sys_stdin_buffer_obj);
            return;
        }
        if (self_in == mirrors.objFromPtr(&mp_sys_stdout_obj)) {
            dest[0] = mirrors.objFromPtr(&mp_sys_stdout_buffer_obj);
            return;
        }
        if (self_in == mirrors.objFromPtr(&mp_sys_stderr_obj)) {
            dest[0] = mirrors.objFromPtr(&mp_sys_stderr_buffer_obj);
            return;
        }
    }
    dest[1] = mirrors.OBJ_SENTINEL; // forward to locals dict
}

// ── type definitions ───────────────────────────────────────────────────
// MP_TYPE_FLAG_ITER_IS_STREAM = ITERNEXT(0x0100) | CUSTOM(0x0080) = 0x0180.
const FLAG_ITER_IS_STREAM: u16 = 0x0180;

// MpObjTypeFull layout (header + 11 slots) — must match mp_type_roms.zig.
const MpObjTypeFull = extern struct {
    header: mirrors.MpObjType,
    slots: [11]?*const anyopaque,
};

// mp_type_fileio:
//   MP_DEFINE_CONST_OBJ_TYPE(mp_type_fileio, MP_QSTR_FileIO,
//       MP_TYPE_FLAG_ITER_IS_STREAM,
//       print, npy_file_print,
//       protocol, &npy_fileio_stream_p,
//       locals_dict, &npy_file_locals_dict);
// 3 named slots in order: print=1, protocol=2, locals_dict=3.
pub export const mp_type_fileio: MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = FLAG_ITER_IS_STREAM,
        .name = mp.MP_QSTR_FileIO,
        .slot_index_make_new = 0,
        .slot_index_print = 1,
        .slot_index_call = 0,
        .slot_index_unary_op = 0,
        .slot_index_binary_op = 0,
        .slot_index_attr = 0,
        .slot_index_subscr = 0,
        .slot_index_iter = 0,
        .slot_index_buffer = 0,
        .slot_index_protocol = 2,
        .slot_index_parent = 0,
        .slot_index_locals_dict = 3,
    },
    .slots = .{
        @ptrCast(&npyFilePrint),
        @ptrCast(&npy_fileio_stream_p),
        @ptrCast(&npy_file_locals_dict),
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
    },
};

// mp_type_textio: same as fileio, but text stream + attr slot under
// SYS_STDIO_BUFFER. With attr, the 4 named slots are:
//   print=1, protocol=2, attr=3, locals_dict=4.
pub export const mp_type_textio: MpObjTypeFull = if (has_buffer) .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = FLAG_ITER_IS_STREAM,
        .name = mp.MP_QSTR_TextIOWrapper,
        .slot_index_make_new = 0,
        .slot_index_print = 1,
        .slot_index_call = 0,
        .slot_index_unary_op = 0,
        .slot_index_binary_op = 0,
        .slot_index_attr = 3,
        .slot_index_subscr = 0,
        .slot_index_iter = 0,
        .slot_index_buffer = 0,
        .slot_index_protocol = 2,
        .slot_index_parent = 0,
        .slot_index_locals_dict = 4,
    },
    .slots = .{
        @ptrCast(&npyFilePrint),
        @ptrCast(&npy_textio_stream_p),
        @ptrCast(&npyTextioAttr),
        @ptrCast(&npy_file_locals_dict),
        null,
        null,
        null,
        null,
        null,
        null,
        null,
    },
} else .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = FLAG_ITER_IS_STREAM,
        .name = mp.MP_QSTR_TextIOWrapper,
        .slot_index_make_new = 0,
        .slot_index_print = 1,
        .slot_index_call = 0,
        .slot_index_unary_op = 0,
        .slot_index_binary_op = 0,
        .slot_index_attr = 0,
        .slot_index_subscr = 0,
        .slot_index_iter = 0,
        .slot_index_buffer = 0,
        .slot_index_protocol = 2,
        .slot_index_parent = 0,
        .slot_index_locals_dict = 3,
    },
    .slots = .{
        @ptrCast(&npyFilePrint),
        @ptrCast(&npy_textio_stream_p),
        @ptrCast(&npy_file_locals_dict),
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
    },
};

// ── stdio file objects ─────────────────────────────────────────────────
// FILE*s for stdin/stdout/stderr are bound at init time (npy_file_io_init);
// they're not constants on Darwin. We initialize fp=null here.
pub export var mp_sys_stdin_obj: NpyFile = .{
    .base = .{ .type = &mp_type_textio },
    .fp = null,
    .is_stdio = true,
};
pub export var mp_sys_stdout_obj: NpyFile = .{
    .base = .{ .type = &mp_type_textio },
    .fp = null,
    .is_stdio = true,
};
pub export var mp_sys_stderr_obj: NpyFile = .{
    .base = .{ .type = &mp_type_textio },
    .fp = null,
    .is_stdio = true,
};
pub export var mp_sys_stdin_buffer_obj: NpyFile = .{
    .base = .{ .type = &mp_type_fileio },
    .fp = null,
    .is_stdio = true,
};
pub export var mp_sys_stdout_buffer_obj: NpyFile = .{
    .base = .{ .type = &mp_type_fileio },
    .fp = null,
    .is_stdio = true,
};
pub export var mp_sys_stderr_buffer_obj: NpyFile = .{
    .base = .{ .type = &mp_type_fileio },
    .fp = null,
    .is_stdio = true,
};

export fn npy_file_io_init() callconv(.c) void {
    mp_sys_stdin_obj.fp = stdinFp();
    mp_sys_stdout_obj.fp = stdoutFp();
    mp_sys_stderr_obj.fp = stderrFp();
    if (has_buffer) {
        mp_sys_stdin_buffer_obj.fp = stdinFp();
        mp_sys_stdout_buffer_obj.fp = stdoutFp();
        mp_sys_stderr_buffer_obj.fp = stderrFp();
    }
}

// ── open(path, mode) ───────────────────────────────────────────────────
fn mpBuiltinOpen(n_args: usize, args: [*c]const Obj, kwargs: ?*anyopaque) callconv(.c) Obj {
    _ = kwargs;
    if (n_args < 1) mp_raise_TypeError(null);
    // NX-3 N4a: mp_obj_str_get_str polled-sentinel. On bad input → null +
    // pending_exc set; surface as TypeError via mp_raise_TypeError (legacy
    // noreturn path; file_io is dead under nano, lives only under full).
    const path = mp_obj_str_get_str(args[0]) orelse mp_raise_TypeError(null);
    var mode: [*:0]const u8 = "r";
    if (n_args >= 2 and (mirrors.isQstr(args[1]) or mirrors.isExactType(args[1], &mp_type_str))) {
        mode = mp_obj_str_get_str(args[1]) orelse mp_raise_TypeError(null);
    }
    const text = strchr(mode, 'b') == null;
    const fp = fopen(path, mode);
    if (fp == null) mp_raise_OSError(errnoVal());
    // With a finaliser: a dropped file is closed by the collector (`__del__`).
    const o: *NpyFile = @ptrCast(@alignCast(m_malloc_with_finaliser(@sizeOf(NpyFile))));
    o.base.type = if (text) &mp_type_textio else &mp_type_fileio;
    o.fp = fp;
    o.is_stdio = false;
    return mirrors.objFromPtr(o);
}

// MP_DEFINE_CONST_FUN_OBJ_KW(mp_builtin_open_obj, 1, mp_builtin_open):
// min=1, max=MP_OBJ_FUN_ARGS_MAX (0xffff), kw=true.
pub export const mp_builtin_open_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(1, 0xffff, true),
    .fun = @ptrCast(&mpBuiltinOpen),
};

comptime {
    _ = &mp_type_fileio;
    _ = &mp_type_textio;
    _ = &mp_builtin_open_obj;
    _ = &npy_file_locals_dict;
    _ = &mp_sys_stdin_obj;
    _ = &mp_sys_stdout_obj;
    _ = &mp_sys_stderr_obj;
    _ = &mp_sys_stdin_buffer_obj;
    _ = &mp_sys_stdout_buffer_obj;
    _ = &mp_sys_stderr_buffer_obj;
    _ = &npy_file_io_init;
}
