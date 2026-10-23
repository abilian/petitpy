//! petitpy — Zig port of py/ringbuf.c (Axis-B B1 W6; TRUE-ZIG).
//! Pure ring buffer: 5 exported fns over `ringbuf_t` (a stable
//! non-config struct: u8* + 3×u16). No nlr/obj/MP_STATE/config —
//! the genuine-algorithm bar. The header's `static inline`
//! helpers (avail/free/memcpy_{get,put}_internal) are reimplemented
//! here faithfully (they are not symbols). Exact C int widths
//! mirrored: u16 fields, u32 temporaries, size_t lengths (lesson #6);
//! `@memcpy` for memcpy.

const ringbuf_t = extern struct {
    buf: [*c]u8,
    size: u16,
    iget: u16,
    iput: u16,
};

inline fn rb_free(r: *ringbuf_t) usize {
    return (@as(usize, r.size) + r.iget - r.iput - 1) % r.size;
}
inline fn rb_avail(r: *ringbuf_t) usize {
    return (@as(usize, r.size) + r.iput - r.iget) % r.size;
}
inline fn memcpy_get_internal(r: *ringbuf_t, data: [*c]u8, data_len: usize) void {
    var iget: u32 = r.iget;
    const iget_a: u32 = @intCast((iget + data_len) % r.size);
    var datap: [*c]u8 = data;
    if (iget_a < iget) {
        const tail = r.size - iget;
        @memcpy(datap[0..tail], (r.buf + iget)[0..tail]);
        datap += tail;
        iget = 0;
    }
    const n = iget_a - iget;
    @memcpy(datap[0..n], (r.buf + iget)[0..n]);
    r.iget = @intCast(iget_a);
}
inline fn memcpy_put_internal(r: *ringbuf_t, data: [*c]const u8, data_len: usize) void {
    var iput: u32 = r.iput;
    const iput_a: u32 = @intCast((iput + data_len) % r.size);
    var datap: [*c]const u8 = data;
    if (iput_a < iput) {
        const tail = r.size - iput;
        @memcpy((r.buf + iput)[0..tail], datap[0..tail]);
        datap += tail;
        iput = 0;
    }
    const n = iput_a - iput;
    @memcpy((r.buf + iput)[0..n], datap[0..n]);
    r.iput = @intCast(iput_a);
}

pub export fn ringbuf_peek16(r: *ringbuf_t) c_int {
    if (r.iget == r.iput) return -1;
    var iget_a: u32 = @as(u32, r.iget) + 1;
    if (iget_a == r.size) iget_a = 0;
    if (iget_a == r.iput) return -1;
    return (@as(c_int, r.buf[r.iget]) << 8) | @as(c_int, r.buf[iget_a]);
}

pub export fn ringbuf_get16(r: *ringbuf_t) c_int {
    const v = ringbuf_peek16(r);
    if (v == -1) return v;
    r.iget += 2;
    if (r.iget >= r.size) r.iget -= r.size;
    return v;
}

pub export fn ringbuf_put16(r: *ringbuf_t, v: u16) c_int {
    var iput_a: u32 = @as(u32, r.iput) + 1;
    if (iput_a == r.size) iput_a = 0;
    if (iput_a == r.iget) return -1;
    var iput_b: u32 = iput_a + 1;
    if (iput_b == r.size) iput_b = 0;
    if (iput_b == r.iget) return -1;
    r.buf[r.iput] = @intCast((v >> 8) & 0xff);
    r.buf[iput_a] = @intCast(v & 0xff);
    r.iput = @intCast(iput_b);
    return 0;
}

pub export fn ringbuf_get_bytes(r: *ringbuf_t, data: [*c]u8, data_len: usize) c_int {
    if (rb_avail(r) < data_len) {
        return if (r.size <= data_len) -2 else -1;
    }
    memcpy_get_internal(r, data, data_len);
    return 0;
}

pub export fn ringbuf_put_bytes(r: *ringbuf_t, data: [*c]const u8, data_len: usize) c_int {
    if (rb_free(r) < data_len) {
        return if (r.size <= data_len) -2 else -1;
    }
    memcpy_put_internal(r, data, data_len);
    return 0;
}

comptime {
    _ = &ringbuf_peek16;
    _ = &ringbuf_get16;
    _ = &ringbuf_put16;
    _ = &ringbuf_get_bytes;
    _ = &ringbuf_put_bytes;
}
