//! nanopython — Zig port of py/reader.c (Axis-B B1.5 W3; TRUE-ZIG).
//!
//! Under nano (MICROPY_READER_POSIX=0, MICROPY_HAS_FILE_READER=0)
//! only the in-memory reader is live: 4 fns, no raises, no MP_STATE.
//! `mp_reader_t` and `mp_reader_mem_t` are layout-stable (no config
//! gates → plain extern structs here, not lesson-#11 hazards).
//!
//! mp_reader_try_read_rom identifies a mem reader by its readbyte
//! function pointer being `mp_reader_mem_readbyte` — Zig's `&fn`
//! produces the same C-ABI symbol address, so the equality check
//! works across the C/Zig boundary (the test uses ONE definition
//! of the function exported here).

const Byte = u8;
const McUint = usize; // mp_uint_t

// m_new_obj / m_del_obj are macros; m_malloc / m_free are real externs
// (exported from src/memory/alloc.zig).
extern fn m_malloc(num_bytes: usize) callconv(.c) ?*anyopaque;
extern fn m_free(ptr: ?*anyopaque) callconv(.c) void;

const ReaderMem = extern struct {
    free_len: usize, // if > 0, mem is freed on close by m_del(byte, beg, free_len)
    beg: [*c]const Byte,
    cur: [*c]const Byte,
    end: [*c]const Byte,
};

const Reader = extern struct {
    data: ?*anyopaque,
    readbyte: ?*const fn (?*anyopaque) callconv(.c) McUint,
    close: ?*const fn (?*anyopaque) callconv(.c) void,
};

// MP_READER_EOF = (mp_uint_t)(-1)
const MP_READER_EOF: McUint = ~@as(McUint, 0);

export fn mp_reader_mem_readbyte(data: ?*anyopaque) callconv(.c) McUint {
    const reader: *ReaderMem = @ptrCast(@alignCast(data.?));
    if (@intFromPtr(reader.cur) < @intFromPtr(reader.end)) {
        const b: McUint = reader.cur[0];
        reader.cur += 1;
        return b;
    } else {
        return MP_READER_EOF;
    }
}

export fn mp_reader_mem_close(data: ?*anyopaque) callconv(.c) void {
    const reader: *ReaderMem = @ptrCast(@alignCast(data.?));
    if (reader.free_len > 0) {
        m_free(@ptrCast(@constCast(reader.beg)));
    }
    m_free(reader);
}

export fn mp_reader_new_mem(reader: *Reader, buf: [*c]const Byte, len: usize, free_len: usize) callconv(.c) void {
    const rm: *ReaderMem = @ptrCast(@alignCast(m_malloc(@sizeOf(ReaderMem)).?));
    rm.free_len = free_len;
    rm.beg = buf;
    rm.cur = buf;
    rm.end = buf + len;
    reader.data = rm;
    reader.readbyte = &mp_reader_mem_readbyte;
    reader.close = &mp_reader_mem_close;
}

export fn mp_reader_try_read_rom(reader: *Reader, len: usize) callconv(.c) [*c]const u8 {
    if (reader.readbyte != &mp_reader_mem_readbyte) return null;
    const rm: *ReaderMem = @ptrCast(@alignCast(reader.data.?));
    if (rm.free_len > 0) return null;
    const res = rm.cur;
    if (@intFromPtr(rm.end) - @intFromPtr(res) < len) return null;
    rm.cur += len;
    return res;
}

comptime {
    _ = &mp_reader_mem_readbyte;
    _ = &mp_reader_mem_close;
    _ = &mp_reader_new_mem;
    _ = &mp_reader_try_read_rom;
}
