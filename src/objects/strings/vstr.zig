//! nanopython — full Zig port of py/vstr.c (drops vstr_shim).
//! `vstr_t` layout mirrored directly (was via accessor shim — verified
//! plain bool, no bitfield → size 32 on 64-bit).
//! MICROPY_PY_BUILTINS_STR_UNICODE=0 ⇒ nano-corpus vstr_add_char is the
//! 1-byte truncate branch (full builds the UTF-8 ladder).
//!
//! Raise path on shared PyError transport (notes/11): every fn that
//! can raise RuntimeError returns `PyError!T`; C-ABI exports are thin
//! `pyerr.bridge` wrappers. The `m_*` C-side MemoryError raises still
//! originate in C — they longjmp past Zig frames harmlessly.

const std = @import("std");
const pyerr = @import("../../pyerr.zig");
const PyError = pyerr.PyError;
const build_options = @import("build_options");

// vstr_printf / vstr_vprintf are in src/objects/strings/va_ops.c —
// see that file for why the va_list-touching code can't stay in Zig
// on aarch64-Linux under the LLVM backend.

// vstr_t layout (misc.h): { size_t alloc; size_t len; char *buf; bool
// fixed_buf; } — plain bool, not bitfield. sizeof = 32 bytes on 64-bit.
const VstrT = extern struct {
    alloc: usize,
    len: usize,
    buf: [*c]u8,
    fixed_buf: bool,
};

const Vs = ?*VstrT;
const Buf = [*c]u8;

extern fn m_malloc(num_bytes: usize) callconv(.c) ?*anyopaque;
extern fn m_realloc(ptr: ?*anyopaque, new_num_bytes: usize) callconv(.c) ?*anyopaque;
extern fn m_free(ptr: ?*anyopaque) callconv(.c) void;
extern fn mp_obj_new_exception_msg(t: *const anyopaque, msg: ?[*:0]const u8) callconv(.c) usize;
extern const mp_type_RuntimeError: anyopaque;

const PrintStrnFn = *const fn (?*anyopaque, [*c]const u8, usize) callconv(.c) void;
const PrintT = extern struct {
    data: ?*anyopaque,
    print_strn: PrintStrnFn,
};

inline fn roundAlloc(a: usize) usize {
    // ROUND_ALLOC(a) = (a & ((~0U) - 7)) + 8 — ~0U is `unsigned int`
    // (32-bit), so the mask zero-extends to 0x00000000FFFFFFF8 (bits
    // >31 are cleared too — a C quirk we preserve exactly).
    return (a & @as(usize, ~@as(c_uint, 0) -% 7)) +% 8;
}

fn raiseRuntime() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_RuntimeError, null);
    return error.PyRaise;
}

export fn vstr_init(vstr: Vs, alloc_in: usize) void {
    var alloc = alloc_in;
    if (alloc < 1) alloc = 1;
    vstr.?.alloc = alloc;
    vstr.?.len = 0;
    vstr.?.buf = @ptrCast(m_malloc(alloc));
    vstr.?.fixed_buf = false;
}
export fn vstr_init_len(vstr: Vs, len: usize) void {
    vstr_init(vstr, len +% 1);
    vstr.?.len = len;
}
export fn vstr_init_fixed_buf(vstr: Vs, alloc: usize, buf: Buf) void {
    vstr.?.alloc = alloc;
    vstr.?.len = 0;
    vstr.?.buf = buf;
    vstr.?.fixed_buf = true;
}
export fn vstr_init_print(vstr: Vs, alloc: usize, print: ?*PrintT) void {
    vstr_init(vstr, alloc);
    print.?.data = vstr;
    print.?.print_strn = @ptrCast(&vstr_add_strn);
}
export fn vstr_clear(vstr: Vs) void {
    if (!vstr.?.fixed_buf) m_free(vstr.?.buf);
    vstr.?.buf = null;
}
export fn vstr_new(alloc: usize) Vs {
    const vstr: Vs = @ptrCast(@alignCast(m_malloc(@sizeOf(VstrT))));
    vstr_init(vstr, alloc);
    return vstr;
}
export fn vstr_free(vstr: Vs) void {
    if (vstr) |v| {
        if (!v.fixed_buf) m_free(v.buf);
        m_free(v);
    }
}

fn vstrExtendImpl(vstr: Vs, size: usize) PyError!Buf {
    if (vstr.?.fixed_buf) try raiseRuntime();
    const a = vstr.?.alloc;
    const new_buf: Buf = @ptrCast(m_realloc(vstr.?.buf, a +% size));
    const p = new_buf + a;
    vstr.?.alloc = a +% size;
    vstr.?.buf = new_buf;
    return p;
}
export fn vstr_extend(vstr: Vs, size: usize) Buf {
    return pyerr.bridge(Buf, vstrExtendImpl(vstr, size));
}

fn vstrEnsureExtraImpl(vstr: Vs, size: usize) PyError!void {
    if (vstr.?.len + size > vstr.?.alloc) {
        if (vstr.?.fixed_buf) try raiseRuntime();
        const new_alloc = roundAlloc((vstr.?.len + size) +% 16);
        vstr.?.buf = @ptrCast(m_realloc(vstr.?.buf, new_alloc));
        vstr.?.alloc = new_alloc;
    }
}
export fn vstr_hint_size(vstr: Vs, size: usize) void {
    pyerr.bridge(void, vstrEnsureExtraImpl(vstr, size));
}

fn vstrAddLenImpl(vstr: Vs, len: usize) PyError!Buf {
    try vstrEnsureExtraImpl(vstr, len);
    const buf = vstr.?.buf + vstr.?.len;
    vstr.?.len +%= len;
    return buf;
}
export fn vstr_add_len(vstr: Vs, len: usize) Buf {
    return pyerr.bridge(Buf, vstrAddLenImpl(vstr, len));
}

fn vstrNullTerminatedStrImpl(vstr: Vs) PyError!Buf {
    if (vstr.?.alloc == vstr.?.len) {
        _ = try vstrExtendImpl(vstr, 1);
    }
    const b = vstr.?.buf;
    b[vstr.?.len] = 0;
    return b;
}
export fn vstr_null_terminated_str(vstr: Vs) Buf {
    return pyerr.bridge(Buf, vstrNullTerminatedStrImpl(vstr));
}

fn vstrAddByteImpl(vstr: Vs, b: u8) PyError!void {
    const buf = try vstrAddLenImpl(vstr, 1);
    buf[0] = b;
}
export fn vstr_add_byte(vstr: Vs, b: u8) void {
    pyerr.bridge(void, vstrAddByteImpl(vstr, b));
}

fn vstrAddCharImpl(vstr: Vs, ch: u32) PyError!void {
    if (build_options.str_unicode) {
        if (ch < 0x80) {
            try vstrAddByteImpl(vstr, @truncate(ch));
        } else if (ch < 0x800) {
            try vstrAddByteImpl(vstr, @as(u8, @truncate(ch >> 6)) | 0xC0);
            try vstrAddByteImpl(vstr, @as(u8, @truncate(ch & 0x3F)) | 0x80);
        } else if (ch < 0x10000) {
            try vstrAddByteImpl(vstr, @as(u8, @truncate(ch >> 12)) | 0xE0);
            try vstrAddByteImpl(vstr, @as(u8, @truncate((ch >> 6) & 0x3F)) | 0x80);
            try vstrAddByteImpl(vstr, @as(u8, @truncate(ch & 0x3F)) | 0x80);
        } else {
            try vstrAddByteImpl(vstr, @as(u8, @truncate(ch >> 18)) | 0xF0);
            try vstrAddByteImpl(vstr, @as(u8, @truncate((ch >> 12) & 0x3F)) | 0x80);
            try vstrAddByteImpl(vstr, @as(u8, @truncate((ch >> 6) & 0x3F)) | 0x80);
            try vstrAddByteImpl(vstr, @as(u8, @truncate(ch & 0x3F)) | 0x80);
        }
        return;
    }
    try vstrAddByteImpl(vstr, @truncate(ch));
}
export fn vstr_add_char(vstr: Vs, ch: u32) void {
    pyerr.bridge(void, vstrAddCharImpl(vstr, ch));
}

fn vstrAddStrnImpl(vstr: Vs, str: [*c]const u8, len: usize) PyError!void {
    try vstrEnsureExtraImpl(vstr, len);
    const dst = vstr.?.buf + vstr.?.len;
    if (len != 0) @memmove(dst[0..len], str[0..len]);
    vstr.?.len +%= len;
}
export fn vstr_add_strn(vstr: Vs, str: [*c]const u8, len: usize) void {
    pyerr.bridge(void, vstrAddStrnImpl(vstr, str, len));
}

fn vstrAddStrImpl(vstr: Vs, str: [*c]const u8) PyError!void {
    try vstrAddStrnImpl(vstr, str, std.mem.span(@as([*:0]const u8, @ptrCast(str))).len);
}
export fn vstr_add_str(vstr: Vs, str: [*c]const u8) void {
    pyerr.bridge(void, vstrAddStrImpl(vstr, str));
}

fn vstrInsBlankBytesImpl(vstr: Vs, byte_pos_in: usize, byte_len: usize) PyError!Buf {
    const l = vstr.?.len;
    var byte_pos = byte_pos_in;
    if (byte_pos > l) byte_pos = l;
    if (byte_len > 0) {
        try vstrEnsureExtraImpl(vstr, byte_len);
        const base = vstr.?.buf;
        const n = l - byte_pos;
        if (n != 0) @memmove((base + byte_pos + byte_len)[0..n], (base + byte_pos)[0..n]);
        vstr.?.len +%= byte_len;
    }
    return vstr.?.buf + byte_pos;
}

fn vstrInsByteImpl(vstr: Vs, byte_pos: usize, b: u8) PyError!void {
    const s = try vstrInsBlankBytesImpl(vstr, byte_pos, 1);
    s[0] = b;
}
export fn vstr_ins_byte(vstr: Vs, byte_pos: usize, b: u8) void {
    pyerr.bridge(void, vstrInsByteImpl(vstr, byte_pos, b));
}

fn vstrInsCharImpl(vstr: Vs, char_pos: usize, chr: u32) PyError!void {
    const s = try vstrInsBlankBytesImpl(vstr, char_pos, 1);
    s[0] = @truncate(chr);
}
export fn vstr_ins_char(vstr: Vs, char_pos: usize, chr: u32) void {
    pyerr.bridge(void, vstrInsCharImpl(vstr, char_pos, chr));
}

export fn vstr_cut_head_bytes(vstr: Vs, bytes_to_cut: usize) void {
    vstr_cut_out_bytes(vstr, 0, bytes_to_cut);
}
export fn vstr_cut_tail_bytes(vstr: Vs, len: usize) void {
    if (len > vstr.?.len) {
        vstr.?.len = 0;
    } else {
        vstr.?.len -%= len;
    }
}
export fn vstr_cut_out_bytes(vstr: Vs, byte_pos: usize, bytes_to_cut: usize) void {
    const l = vstr.?.len;
    if (byte_pos >= l) {
        return;
    } else if (byte_pos + bytes_to_cut >= l) {
        vstr.?.len = byte_pos;
    } else {
        const base = vstr.?.buf;
        const n = l - byte_pos - bytes_to_cut;
        @memmove((base + byte_pos)[0..n], (base + byte_pos + bytes_to_cut)[0..n]);
        vstr.?.len -%= bytes_to_cut;
    }
}

// vstr_printf / vstr_vprintf: see va_ops.c.

// Legacy accessors kept as exports for callers (objstr.zig) that still
// route through the old npy_vstr_* surface. New code should use VstrT
// directly via the struct fields.
export fn npy_vstr_get_alloc(v: *const VstrT) callconv(.c) usize { return v.alloc; }
export fn npy_vstr_get_len(v: *const VstrT) callconv(.c) usize { return v.len; }
export fn npy_vstr_get_buf(v: *const VstrT) callconv(.c) Buf { return v.buf; }
export fn npy_vstr_set_alloc(v: *VstrT, a: usize) callconv(.c) void { v.alloc = a; }
export fn npy_vstr_set_buf(v: *VstrT, b: Buf) callconv(.c) void { v.buf = b; }

comptime {
    _ = &npy_vstr_get_alloc;
    _ = &npy_vstr_get_len;
    _ = &npy_vstr_get_buf;
    _ = &npy_vstr_set_alloc;
    _ = &npy_vstr_set_buf;
    // vstr_printf / vstr_vprintf omitted: they're defined in
    // src/objects/strings/va_ops.c, so the C compile guarantees
    // their export.
    for (.{
        &vstr_init,           &vstr_init_len,            &vstr_init_fixed_buf,
        &vstr_init_print,     &vstr_clear,               &vstr_new,
        &vstr_free,           &vstr_extend,              &vstr_hint_size,
        &vstr_add_len,        &vstr_null_terminated_str, &vstr_add_byte,
        &vstr_add_char,       &vstr_add_str,             &vstr_add_strn,
        &vstr_ins_byte,       &vstr_ins_char,            &vstr_cut_head_bytes,
        &vstr_cut_tail_bytes, &vstr_cut_out_bytes,
    }) |f| {
        _ = f;
    }
}
