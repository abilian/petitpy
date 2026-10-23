//! petitpy — Zig port of py/stream.c (drops support/stream_shim.c).
//!
//! VERBATIM-B2DEBT relocation: the stream protocol (read/write/readinto/
//! readline/seek via MP_OBJ_TYPE_GET_SLOT stream-slot dispatch) + ioctl/
//! errno + const-fun-obj glue, no isolable algorithm, no nlr host.
//!
//! Config gating:
//!   - nano: MICROPY_PY_BUILTINS_STR_UNICODE=0 → no UTF-8 read branch.
//!   - full: MICROPY_PY_BUILTINS_STR_UNICODE=1 → UTF-8 read branch active.
//!   - MICROPY_STREAMS_POSIX_API=0 everywhere → mp_stream_posix_* not emitted.
//!   - MICROPY_STREAMS_NON_BLOCK depends on ROM_LEVEL ≥ EXTRA_FEATURES:
//!     under MINIMUM it's 0; treat mp_is_nonblocking_error() as constant
//!     false. (Both nano and full sit at MINIMUM today.)

const build_options = @import("build_options");
const mp = @cImport({
    @cInclude("py/qstr.h");
});
const mirrors = @import("../mp_mirrors.zig");

const Obj = mirrors.Obj;

// ── stream.h constants (mirrored to avoid pulling py/stream.h via cImport) ──
const MP_STREAM_ERROR: usize = ~@as(usize, 0);
const MP_STREAM_FLUSH: usize = 1;
const MP_STREAM_SEEK: usize = 2;
const MP_STREAM_CLOSE: usize = 4;

const MP_STREAM_OP_READ: c_int = 1;
const MP_STREAM_OP_WRITE: c_int = 2;
const MP_STREAM_OP_IOCTL: c_int = 4;

const MP_STREAM_RW_READ: u8 = 0;
const MP_STREAM_RW_WRITE: u8 = 2;
const MP_STREAM_RW_ONCE: u8 = 1;

// SEEK_SET / SEEK_CUR from libc (unistd.h / stdio.h)
const SEEK_SET: c_int = 0;
const SEEK_CUR: c_int = 1;

const MP_EINVAL: c_int = 22;

const DEFAULT_BUFFER_SIZE: usize = 256;

// ── mp_stream_p_t mirror (py/stream.h:70) ──────────────────────────────
// `is_text` is a 1-bit bitfield in C; mirror as a usize-sized slot since
// the three preceding fields are pointers (their own width) so layout
// position of is_text is at +24 bytes on 64-bit.
const StreamP = extern struct {
    read: ?*const fn (obj: Obj, buf: ?*anyopaque, size: usize, errcode: *c_int) callconv(.c) usize,
    write: ?*const fn (obj: Obj, buf: ?*const anyopaque, size: usize, errcode: *c_int) callconv(.c) usize,
    ioctl: ?*const fn (obj: Obj, request: usize, arg: usize, errcode: *c_int) callconv(.c) usize,
    is_text: usize, // bitfield :1 in C
};

// mp_stream_seek_t (py/stream.h:56). `mp_off_t` is a signed 64-bit on
// 64-bit hosts.
const MpStreamSeek = extern struct {
    offset: i64,
    whence: c_int,
};

// vstr_t (misc.h). Layout mirrored from src/objects/strings/vstr.zig.
const VstrT = extern struct {
    alloc: usize,
    len: usize,
    buf: [*c]u8,
    fixed_buf: bool,
};

// ── extern declarations ────────────────────────────────────────────────
extern fn mp_obj_get_type(o: Obj) callconv(.c) ?*const anyopaque;
extern fn mp_obj_get_int(arg: Obj) callconv(.c) isize;
extern fn mp_obj_get_int_truncated(arg: Obj) callconv(.c) isize;
extern fn mp_obj_is_true(arg: Obj) callconv(.c) bool;
extern fn mp_obj_new_int(value: isize) callconv(.c) Obj;
extern fn mp_obj_new_int_from_uint(value: usize) callconv(.c) Obj;
extern fn mp_obj_new_list(n: usize, items: [*c]const Obj) callconv(.c) Obj;
extern fn mp_obj_list_append(list: Obj, v: Obj) callconv(.c) Obj;
extern fn mp_obj_new_str_from_vstr(vstr: ?*anyopaque) callconv(.c) Obj;
extern fn mp_obj_new_bytes_from_vstr(vstr: ?*anyopaque) callconv(.c) Obj;
extern fn mp_get_buffer(obj: Obj, bufinfo: *MpBufferInfo, flags: c_uint) callconv(.c) bool;
extern fn mp_raise_OSError(errno_: c_int) callconv(.c) noreturn;

extern fn vstr_init(vstr: *VstrT, alloc: usize) callconv(.c) void;
extern fn vstr_init_len(vstr: *VstrT, len: usize) callconv(.c) void;
extern fn vstr_clear(vstr: *VstrT) callconv(.c) void;
extern fn vstr_extend(vstr: *VstrT, size: usize) callconv(.c) [*c]u8;
extern fn vstr_add_len(vstr: *VstrT, len: usize) callconv(.c) [*c]u8;
extern fn vstr_cut_tail_bytes(vstr: *VstrT, len: usize) callconv(.c) void;

extern const mp_type_fun_builtin_var: anyopaque;
extern const mp_type_fun_builtin_1: anyopaque;

const MpBufferInfo = extern struct {
    buf: ?*anyopaque,
    len: usize,
    typecode: c_int,
};

const MP_BUFFER_READ: c_uint = 1;
const MP_BUFFER_WRITE: c_uint = 2;
const MP_BUFFER_RAISE_IF_UNSUPPORTED: c_uint = 4;

inline fn getBufferRaise(obj: Obj, bufinfo: *MpBufferInfo, flags: c_uint) void {
    _ = mp_get_buffer(obj, bufinfo, flags | MP_BUFFER_RAISE_IF_UNSUPPORTED);
}

// `mp_is_nonblocking_error()` is hard-coded to `(0)` everywhere we build
// today (MICROPY_STREAMS_NON_BLOCK=0 under MINIMUM ROM level). Keep as
// an inline so future flips just edit one place.
inline fn isNonblockingError(_: c_int) bool {
    return false;
}

// ── stream-slot access ─────────────────────────────────────────────────
// Mirror of static inline mp_get_stream (py/stream.h:100).
inline fn getStream(self_in: Obj) *const StreamP {
    const base: *const mirrors.MpObjBase = @ptrFromInt(self_in);
    const t = mirrors.MpObjType.fromPtr(base.type);
    const slot = t.getSlot(.protocol).?;
    return @ptrCast(@alignCast(slot));
}

// ── stream protocol helpers (public C ABI) ─────────────────────────────

/// `mp_get_stream_raise` (py/stream.c:75).
export fn mp_get_stream_raise(self_in: Obj, flags: c_int) callconv(.c) *const StreamP {
    const type_p = mp_obj_get_type(self_in);
    const t = mirrors.MpObjType.fromPtr(type_p);
    if (t.hasSlot(.protocol)) {
        const stream_p: *const StreamP = @ptrCast(@alignCast(t.getSlot(.protocol).?));
        const need_read = (flags & MP_STREAM_OP_READ) != 0;
        const need_write = (flags & MP_STREAM_OP_WRITE) != 0;
        const need_ioctl = (flags & MP_STREAM_OP_IOCTL) != 0;
        const lacks_read = need_read and stream_p.read == null;
        const lacks_write = need_write and stream_p.write == null;
        const lacks_ioctl = need_ioctl and stream_p.ioctl == null;
        if (!lacks_read and !lacks_write and !lacks_ioctl) {
            return stream_p;
        }
    }
    // NX-3 N4: stream.zig is whole-module dead under nano (no Zig
    // importer reaches this body at runtime). @panic preserves the
    // noreturn fall-through after the conditional return above.
    @panic("mp_get_stream_raise: stream operation not supported (unreachable under nano)");
}

/// `mp_stream_rw` (py/stream.c:24).
export fn mp_stream_rw(
    stream: Obj,
    buf_in: ?*anyopaque,
    size_in: usize,
    errcode: *c_int,
    flags: u8,
) callconv(.c) usize {
    var buf: [*c]u8 = @ptrCast(buf_in);
    const stream_p = getStream(stream);

    errcode.* = 0;
    var size = size_in;
    var done: usize = 0;
    while (size > 0) {
        const out_sz = if ((flags & MP_STREAM_RW_WRITE) != 0)
            stream_p.write.?(stream, @as(*const anyopaque, @ptrCast(buf)), size, errcode)
        else
            stream_p.read.?(stream, @as(*anyopaque, @ptrCast(buf)), size, errcode);

        // For read, out_sz == 0 means EOF. For write, it's unspecified
        // what it means, but we don't make any progress, so returning is
        // still the best option.
        if (out_sz == 0) {
            return done;
        }
        if (out_sz == MP_STREAM_ERROR) {
            if (isNonblockingError(errcode.*) and done != 0) {
                errcode.* = 0;
            }
            return done;
        }
        if ((flags & MP_STREAM_RW_ONCE) != 0) {
            return out_sz;
        }

        buf += out_sz;
        size -= out_sz;
        done += out_sz;
    }
    return done;
}

/// `mp_stream_seek` (py/stream.c:63).
export fn mp_stream_seek(stream: Obj, offset: i64, whence: c_int, errcode: *c_int) callconv(.c) i64 {
    var seek_s: MpStreamSeek = .{ .offset = offset, .whence = whence };
    const stream_p = getStream(stream);
    const res = stream_p.ioctl.?(stream, MP_STREAM_SEEK, @intFromPtr(&seek_s), errcode);
    if (res == MP_STREAM_ERROR) {
        return -1;
    }
    return seek_s.offset;
}

/// `mp_stream_write` (py/stream.c:221).
export fn mp_stream_write(self_in: Obj, buf: ?*const anyopaque, len: usize, flags: u8) callconv(.c) Obj {
    var error_: c_int = 0;
    const out_sz = mp_stream_rw(self_in, @constCast(buf), len, &error_, flags);
    if (error_ != 0) {
        if (isNonblockingError(error_)) {
            return mirrors.OBJ_NONE;
        }
        mp_raise_OSError(error_);
    }
    return mirrors.newSmallInt(@intCast(out_sz));
}

/// `mp_stream_write_adaptor` (py/stream.c:238). Used to adapt a stream
/// object to an mp_print_t interface.
export fn mp_stream_write_adaptor(self: ?*anyopaque, buf: [*c]const u8, len: usize) callconv(.c) void {
    _ = mp_stream_write(@intFromPtr(self), @as(?*const anyopaque, @ptrCast(buf)), len, MP_STREAM_RW_WRITE);
}

/// `mp_stream_close` (py/stream.c:411).
export fn mp_stream_close(stream: Obj) callconv(.c) Obj {
    const stream_p = getStream(stream);
    var error_: c_int = 0;
    const res = stream_p.ioctl.?(stream, MP_STREAM_CLOSE, 0, &error_);
    if (res == MP_STREAM_ERROR) {
        mp_raise_OSError(error_);
    }
    return mirrors.OBJ_NONE;
}

// ── readall + read helpers ─────────────────────────────────────────────

fn streamReadall(self_in: Obj) Obj {
    const stream_p = getStream(self_in);

    var total_size: usize = 0;
    var vstr: VstrT = undefined;
    vstr_init(&vstr, DEFAULT_BUFFER_SIZE);
    var p: [*c]u8 = vstr.buf;
    var current_read: usize = DEFAULT_BUFFER_SIZE;
    while (true) {
        var error_: c_int = 0;
        const out_sz = stream_p.read.?(self_in, @as(*anyopaque, @ptrCast(p)), current_read, &error_);
        if (out_sz == MP_STREAM_ERROR) {
            if (isNonblockingError(error_)) {
                if (total_size == 0) {
                    return mirrors.OBJ_NONE;
                }
                break;
            }
            mp_raise_OSError(error_);
        }
        if (out_sz == 0) {
            break;
        }
        total_size += out_sz;
        if (out_sz < current_read) {
            current_read -= out_sz;
            p += out_sz;
        } else {
            p = vstr_extend(&vstr, DEFAULT_BUFFER_SIZE);
            current_read = DEFAULT_BUFFER_SIZE;
        }
    }

    vstr.len = total_size;
    if (stream_p.is_text != 0) {
        return mp_obj_new_str_from_vstr(@ptrCast(&vstr));
    } else {
        return mp_obj_new_bytes_from_vstr(@ptrCast(&vstr));
    }
}

// UTF-8 helper for is_text branch under full.
inline fn utf8IsNonAscii(b: u8) bool {
    return (b & 0x80) != 0;
}

fn streamReadGeneric(n_args: usize, args: [*c]const Obj, flags: u8) Obj {
    // What to do if sz < -1?  Python docs don't specify this case.
    // CPython does a readall, but here we silently let negatives through,
    // and they will cause a MemoryError.
    var sz: isize = 0;
    if (n_args == 1) {
        return streamReadall(args[0]);
    }
    sz = mp_obj_get_int(args[1]);
    if (sz == -1) {
        return streamReadall(args[0]);
    }

    const stream_p = getStream(args[0]);

    if (comptime build_options.str_unicode) {
        if (stream_p.is_text != 0) {
            // We need to read sz number of unicode characters. Because we
            // don't have any buffering, and because the stream API can only
            // read bytes, we must read here in units of bytes and must
            // never over-read.
            var vstr: VstrT = undefined;
            vstr_init(&vstr, @intCast(sz));
            var more_bytes: usize = @intCast(sz);
            var last_buf_offset: usize = 0;
            outer: while (more_bytes > 0) {
                const p = vstr_add_len(&vstr, more_bytes);
                var error_: c_int = 0;
                const out_sz = mp_stream_rw(args[0], @as(*anyopaque, @ptrCast(p)), more_bytes, &error_, MP_STREAM_RW_READ);
                if (error_ != 0) {
                    vstr_cut_tail_bytes(&vstr, more_bytes);
                    if (isNonblockingError(error_)) {
                        if (vstr.len == 0) {
                            vstr_clear(&vstr);
                            return mirrors.OBJ_NONE;
                        }
                        break :outer;
                    }
                    mp_raise_OSError(error_);
                }

                if (out_sz < more_bytes) {
                    vstr_cut_tail_bytes(&vstr, more_bytes - out_sz);
                    if (out_sz == 0) {
                        break :outer;
                    }
                }

                // count chars from bytes just read
                var off = last_buf_offset;
                while (true) {
                    const b = vstr.buf[off];
                    var n: usize = 0;
                    if (!utf8IsNonAscii(b)) {
                        n = 1;
                    } else if ((b & 0xe0) == 0xc0) {
                        n = 2;
                    } else if ((b & 0xf0) == 0xe0) {
                        n = 3;
                    } else if ((b & 0xf8) == 0xf0) {
                        n = 4;
                    } else {
                        n = 5;
                    }
                    if (off + n <= vstr.len) {
                        off += n;
                        sz -= 1;
                        last_buf_offset = off;
                        if (off >= vstr.len) {
                            more_bytes = @intCast(sz);
                            break;
                        }
                    } else {
                        more_bytes = (off + n - vstr.len) + @as(usize, @intCast(sz - 1));
                        break;
                    }
                }
            }
            return mp_obj_new_str_from_vstr(@ptrCast(&vstr));
        }
    }

    var vstr: VstrT = undefined;
    vstr_init_len(&vstr, @intCast(sz));
    var error_: c_int = 0;
    const out_sz = mp_stream_rw(args[0], @as(*anyopaque, @ptrCast(vstr.buf)), @intCast(sz), &error_, flags);
    if (error_ != 0) {
        vstr_clear(&vstr);
        if (isNonblockingError(error_)) {
            return mirrors.OBJ_NONE;
        }
        mp_raise_OSError(error_);
    }
    vstr.len = out_sz;
    if (stream_p.is_text != 0) {
        return mp_obj_new_str_from_vstr(@ptrCast(&vstr));
    } else {
        return mp_obj_new_bytes_from_vstr(@ptrCast(&vstr));
    }
}

// ── fun-obj implementations ────────────────────────────────────────────

fn streamRead(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return streamReadGeneric(n_args, args, MP_STREAM_RW_READ);
}
fn streamRead1(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return streamReadGeneric(n_args, args, MP_STREAM_RW_READ | MP_STREAM_RW_ONCE);
}

fn streamReadintoWriteGeneric(n_args: usize, args: [*c]const Obj, flags: u8) Obj {
    var bufinfo: MpBufferInfo = undefined;
    const buf_flags: c_uint = if ((flags & MP_STREAM_RW_WRITE) != 0) MP_BUFFER_READ else MP_BUFFER_WRITE;
    getBufferRaise(args[1], &bufinfo, buf_flags);

    // CPython extension, allow optional maximum length and offset:
    //   stream.operation(buf, max_len)
    //   stream.operation(buf, off, max_len)
    var max_len: usize = ~@as(usize, 0);
    var off: usize = 0;
    if (n_args == 3) {
        max_len = @intCast(mp_obj_get_int_truncated(args[2]));
    } else if (n_args == 4) {
        off = @intCast(mp_obj_get_int_truncated(args[2]));
        max_len = @intCast(mp_obj_get_int_truncated(args[3]));
        if (off > bufinfo.len) {
            off = bufinfo.len;
        }
    }
    bufinfo.len -= off;

    const p_buf: [*c]u8 = @as([*c]u8, @ptrCast(bufinfo.buf)) + off;
    const n = if (bufinfo.len < max_len) bufinfo.len else max_len;
    return mp_stream_write(args[0], @as(?*const anyopaque, @ptrCast(p_buf)), n, flags);
}

fn streamWriteMethod(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return streamReadintoWriteGeneric(n_args, args, MP_STREAM_RW_WRITE);
}
fn streamWrite1Method(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return streamReadintoWriteGeneric(n_args, args, MP_STREAM_RW_WRITE | MP_STREAM_RW_ONCE);
}
fn streamReadinto(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return streamReadintoWriteGeneric(n_args, args, MP_STREAM_RW_READ);
}
fn streamReadinto1(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return streamReadintoWriteGeneric(n_args, args, MP_STREAM_RW_READ | MP_STREAM_RW_ONCE);
}

fn streamUnbufferedReadline(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    const stream_p = getStream(args[0]);

    var max_size: isize = -1;
    if (n_args > 1) {
        max_size = mirrors.smallIntValue(args[1]);
    }

    var vstr: VstrT = undefined;
    if (max_size != -1) {
        vstr_init(&vstr, @intCast(max_size));
    } else {
        vstr_init(&vstr, 16);
    }

    while (max_size == -1 or max_size != 0) {
        if (max_size != -1) max_size -= 1;
        const p = vstr_add_len(&vstr, 1);
        var error_: c_int = 0;
        const out_sz = stream_p.read.?(args[0], @as(*anyopaque, @ptrCast(p)), 1, &error_);
        if (out_sz == MP_STREAM_ERROR) {
            if (isNonblockingError(error_)) {
                if (vstr.len == 1) {
                    vstr_clear(&vstr);
                    return mirrors.OBJ_NONE;
                } else {
                    // Back out previously added byte (goto done).
                    vstr_cut_tail_bytes(&vstr, 1);
                    break;
                }
            }
            mp_raise_OSError(error_);
        }
        if (out_sz == 0) {
            // Back out previously added byte (label `done` in C).
            vstr_cut_tail_bytes(&vstr, 1);
            break;
        }
        if (p[0] == '\n') {
            break;
        }
    }

    if (stream_p.is_text != 0) {
        return mp_obj_new_str_from_vstr(@ptrCast(&vstr));
    } else {
        return mp_obj_new_bytes_from_vstr(@ptrCast(&vstr));
    }
}

fn streamUnbufferedReadlines(self: Obj) callconv(.c) Obj {
    const lines = mp_obj_new_list(0, null);
    while (true) {
        var arg_self = self;
        const line = streamUnbufferedReadline(1, @ptrCast(&arg_self));
        if (!mp_obj_is_true(line)) break;
        _ = mp_obj_list_append(lines, line);
    }
    return lines;
}

/// `mp_stream_unbuffered_iter` (py/stream.c:403). Iterator helper used
/// by file-IO types (callconv-compat re-export).
export fn mp_stream_unbuffered_iter(self: Obj) callconv(.c) Obj {
    var arg_self = self;
    const l_in = streamUnbufferedReadline(1, @ptrCast(&arg_self));
    if (mp_obj_is_true(l_in)) {
        return l_in;
    }
    return mirrors.OBJ_STOP_ITERATION;
}

fn streamExit(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    _ = n_args;
    return mp_stream_close(args[0]);
}

fn streamSeek(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    const offset: i64 = @intCast(mp_obj_get_int(args[1]));
    var whence: c_int = SEEK_SET;
    if (n_args == 3) {
        whence = @intCast(mp_obj_get_int(args[2]));
    }

    // In POSIX, it's an error to seek before end of stream — enforce here.
    if (whence == SEEK_SET and offset < 0) {
        mp_raise_OSError(MP_EINVAL);
    }

    var error_: c_int = 0;
    const res = mp_stream_seek(args[0], offset, whence, &error_);
    if (res == -1) {
        mp_raise_OSError(error_);
    }

    return mp_obj_new_int_from_uint(@intCast(res));
}

fn streamTell(self: Obj) callconv(.c) Obj {
    var a: [3]Obj = .{ self, mirrors.newSmallInt(0), mirrors.newSmallInt(SEEK_CUR) };
    return streamSeek(3, &a);
}

fn streamFlush(self: Obj) callconv(.c) Obj {
    const stream_p = getStream(self);
    var error_: c_int = 0;
    const res = stream_p.ioctl.?(self, MP_STREAM_FLUSH, 0, &error_);
    if (res == MP_STREAM_ERROR) {
        mp_raise_OSError(error_);
    }
    return mirrors.OBJ_NONE;
}

fn streamIoctl(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    var bufinfo: MpBufferInfo = undefined;
    var val: usize = 0;
    if (n_args > 2) {
        if (mp_get_buffer(args[2], &bufinfo, MP_BUFFER_WRITE)) {
            val = @intFromPtr(bufinfo.buf);
        } else {
            val = @intCast(mp_obj_get_int_truncated(args[2]));
        }
    }

    const stream_p = getStream(args[0]);
    var error_: c_int = 0;
    const res = stream_p.ioctl.?(args[0], @intCast(mp_obj_get_int(args[1])), val, &error_);
    if (res == MP_STREAM_ERROR) {
        mp_raise_OSError(error_);
    }

    return mp_obj_new_int(@intCast(res));
}

// ── ROM fun-obj exports ────────────────────────────────────────────────

pub export const mp_stream_read_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(1, 2, false),
    .fun = @ptrCast(&streamRead),
};
pub export const mp_stream_read1_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(1, 2, false),
    .fun = @ptrCast(&streamRead1),
};
pub export const mp_stream_write_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(2, 4, false),
    .fun = @ptrCast(&streamWriteMethod),
};
pub export const mp_stream_write1_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(2, 4, false),
    .fun = @ptrCast(&streamWrite1Method),
};
pub export const mp_stream_readinto_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(2, 3, false),
    .fun = @ptrCast(&streamReadinto),
};
pub export const mp_stream_readinto1_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(2, 3, false),
    .fun = @ptrCast(&streamReadinto1),
};
pub export const mp_stream_unbuffered_readline_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(1, 2, false),
    .fun = @ptrCast(&streamUnbufferedReadline),
};
pub export const mp_stream_unbuffered_readlines_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_1 },
    .fun = @ptrCast(&streamUnbufferedReadlines),
};
pub export const mp_stream_close_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_1 },
    .fun = @ptrCast(&mp_stream_close),
};
pub export const mp_stream___exit___obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(4, 4, false),
    .fun = @ptrCast(&streamExit),
};
pub export const mp_stream_seek_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(2, 3, false),
    .fun = @ptrCast(&streamSeek),
};
pub export const mp_stream_tell_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_1 },
    .fun = @ptrCast(&streamTell),
};
pub export const mp_stream_flush_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_1 },
    .fun = @ptrCast(&streamFlush),
};
pub export const mp_stream_ioctl_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(2, 3, false),
    .fun = @ptrCast(&streamIoctl),
};

comptime {
    _ = mp;
    _ = &mp_get_stream_raise;
    _ = &mp_stream_rw;
    _ = &mp_stream_seek;
    _ = &mp_stream_write;
    _ = &mp_stream_write_adaptor;
    _ = &mp_stream_close;
    _ = &mp_stream_unbuffered_iter;
}
