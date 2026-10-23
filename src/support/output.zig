//! Where Python's stdout (fd 1) and stderr (fd 2) go: the file
//! descriptors, or the function an embedding host gives in its
//! configuration (ADR 022), which then receives every write in order.

const unistd = @cImport(@cInclude("unistd.h"));

pub const Sink = struct {
    write: *const fn (userdata: ?*anyopaque, fd: c_int, data: [*]const u8, len: usize) callconv(.c) void,
    userdata: ?*anyopaque,
};

/// Interpreter state (set by ppy_new, cleared by ppy_free): one of the
/// globals ADR 022's second step moves into each interpreter.
pub var sink: ?Sink = null;

pub fn write(fd: c_int, data: [*]const u8, len: usize) void {
    if (sink) |s| return s.write(s.userdata, fd, data, len);
    _ = unistd.write(fd, data, len);
}
