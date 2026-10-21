// Round-trip a .mpy file: read it, write it back, compare bytes.
// CLI: zigpy-mpy-roundtrip <input.mpy>
// Exit 0 on match, 1 on mismatch, 2 on read error.
//
// This is the C1 milestone: proves our .mpy format Zig structs match
// vendor's on-disk layout. After this, the compiler can serialize and
// the differential test against mpy-cross has a foundation.

const std = @import("std");
const mpy = @import("mpy.zig");

const cwrite = @cImport({ @cInclude("unistd.h"); });
fn posix_write(fd: c_int, bytes: []const u8) !usize {
    const n = cwrite.write(fd, bytes.ptr, bytes.len);
    return @intCast(@max(n, 0));
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.c_allocator;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len < 2) {
        _ = posix_write(2, "usage: mpy-roundtrip <input.mpy>\n") catch {};
        std.process.exit(2);
    }
    // Need NUL-terminated for fopen — copy.
    const path = argv[1];
    var path_z_buf: [4096]u8 = undefined;
    if (path.len + 1 > path_z_buf.len) std.process.exit(2);
    @memcpy(path_z_buf[0..path.len], path);
    path_z_buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_z_buf);

    // Read entire file via libc to keep this dependency-light
    const c = @cImport({
        @cInclude("stdio.h");
        @cInclude("stdlib.h");
    });
    const fp = c.fopen(path_z, "rb");
    if (fp == null) {
        const msg = "fopen failed\n";
        _ = posix_write(2, msg) catch {};
        std.process.exit(2);
    }
    defer _ = c.fclose(fp);

    _ = c.fseek(fp, 0, c.SEEK_END);
    const fsz: usize = @intCast(c.ftell(fp));
    _ = c.fseek(fp, 0, c.SEEK_SET);

    const buf = try gpa.alloc(u8, fsz);
    defer gpa.free(buf);
    const got = c.fread(buf.ptr, 1, fsz, fp);
    if (got != fsz) {
        const msg = "fread short\n";
        _ = posix_write(2, msg) catch {};
        std.process.exit(2);
    }

    // Read .mpy → Module
    const mod = mpy.read(gpa, buf) catch |err| {
        var ebuf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&ebuf, "mpy.read failed: {}\n", .{err}) catch "(error)\n";
        _ = posix_write(2, msg) catch {};
        std.process.exit(2);
    };
    defer mod.deinit(gpa);

    // Module → bytes
    const out = try mpy.write(gpa, mod);
    defer gpa.free(out);

    // Compare
    if (std.mem.eql(u8, buf, out)) {
        var sbuf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&sbuf, "OK round-trip: {} bytes, {s}\n", .{ buf.len, path }) catch "OK\n";
        _ = posix_write(1, msg) catch {};
        std.process.exit(0);
    } else {
        var sbuf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&sbuf, "MISMATCH: in={} bytes, out={} bytes, {s}\n", .{ buf.len, out.len, path }) catch "MISMATCH\n";
        _ = posix_write(2, msg) catch {};

        // Find first diff for debugging
        var i: usize = 0;
        const min_len = @min(buf.len, out.len);
        while (i < min_len) : (i += 1) {
            if (buf[i] != out[i]) {
                var dbuf: [128]u8 = undefined;
                const dmsg = std.fmt.bufPrint(&dbuf, "  first byte diff at offset {}: in=0x{x:0>2} out=0x{x:0>2}\n", .{ i, buf[i], out[i] }) catch "(diff)\n";
                _ = posix_write(2, dmsg) catch {};
                break;
            }
        }
        std.process.exit(1);
    }
}
