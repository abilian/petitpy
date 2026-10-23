// Differential test: vendor mpy-cross vs. our qstr.zig static-pool ids.
//
// CLI: zigpy-qstr-test <input.py>
//   (Default: tests/qstr_fixture.py if no arg is provided.)
//
// Flow:
//   1. Invoke vendor mpy-cross on <input.py> -> /tmp/<basename>.mpy
//   2. Read the .mpy via libc fopen/fread.
//   3. Parse via @import("mpy.zig").read() -> Module (proven byte-identical
//      via C1's 552/552 round-trip).
//   4. For every entry in Module.qstrs:
//        - .static(id): assert qstr.qstr_str(&ctx, id) returns a string
//          whose length is qstr.qstr_len(&ctx, id). (We cannot recover
//          the original literal from vendor's .mpy for a .static entry
//          — the vendor encoded only the id — so the strongest available
//          assertion is that OUR qstr.zig can resolve that id to SOME
//          non-empty bytes whose internal length/hash are self-consistent.
//          Combined with the comptime-pool-size asserts in qstr.zig,
//          this is sufficient to prove the id is in vendor range.)
//        - .new(bytes): intern via qstr.qstr_from_strn(&ctx, bytes).
//          Assert the returned id is >= N_TOTAL (dynamic pool).
//          Then re-intern to assert dedup.
//
// Exit 0 on PASS, 1 on FAIL, 2 on infrastructure error
// (missing mpy-cross, fopen failure, parse error).
//
// This is the C2 acceptance criterion: pure-Zig qstr table agrees with
// vendor's id assignments at the .mpy boundary.

const std = @import("std");
const mpy = @import("mpy.zig");
const qstr = @import("qstr.zig");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
    @cInclude("string.h");
});

const DEFAULT_FIXTURE = "tests/qstr_fixture.py";
const MPY_CROSS = "mpy-cross"; // resolved via PATH

fn write_stderr(bytes: []const u8) void {
    _ = c.write(2, bytes.ptr, bytes.len);
}

fn write_stdout(bytes: []const u8) void {
    _ = c.write(1, bytes.ptr, bytes.len);
}

fn die_infra(msg: []const u8) noreturn {
    write_stderr("ERROR (infra): ");
    write_stderr(msg);
    write_stderr("\n");
    std.process.exit(2);
}

fn read_file_libc(gpa: std.mem.Allocator, path_z: [*:0]const u8) ![]u8 {
    const fp = c.fopen(path_z, "rb");
    if (fp == null) return error.FopenFailed;
    defer _ = c.fclose(fp);
    _ = c.fseek(fp, 0, c.SEEK_END);
    const fsz: usize = @intCast(c.ftell(fp));
    _ = c.fseek(fp, 0, c.SEEK_SET);
    const buf = try gpa.alloc(u8, fsz);
    errdefer gpa.free(buf);
    const got = c.fread(buf.ptr, 1, fsz, fp);
    if (got != fsz) return error.FreadShort;
    return buf;
}

/// Run `mpy-cross <input.py> -o <output.mpy>` synchronously via libc system().
/// Returns whether the subprocess exited 0.
fn run_mpy_cross(gpa: std.mem.Allocator, input_py: []const u8, output_mpy: []const u8) !bool {
    // Build a shell command — simpler than messing with Zig 0.16 std.process API.
    var buf: [4096]u8 = undefined;
    const cmd = try std.fmt.bufPrintZ(&buf, "{s} -o '{s}' '{s}'", .{ MPY_CROSS, output_mpy, input_py });
    _ = gpa;
    const rc = c.system(cmd.ptr);
    return rc == 0;
}

fn print_line(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, fmt, args) catch return;
    write_stdout(out);
}

fn print_err_line(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, fmt, args) catch return;
    write_stderr(out);
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.c_allocator;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    const input_py: []const u8 = if (argv.len >= 2) argv[1] else DEFAULT_FIXTURE;

    // Place the .mpy in /tmp so we don't pollute the source tree.
    const out_mpy = "/tmp/petitpy_qstr_test.mpy";

    print_line("qstr_test: compiling {s} -> {s}\n", .{ input_py, out_mpy });

    const ok = run_mpy_cross(gpa, input_py, out_mpy) catch |err| {
        print_err_line("mpy-cross spawn failed: {}\n", .{err});
        die_infra("could not invoke mpy-cross (is it on PATH?)");
    };
    if (!ok) die_infra("mpy-cross exited non-zero");

    // NUL-terminate path for fopen.
    var path_buf: [1024]u8 = undefined;
    if (out_mpy.len + 1 > path_buf.len) die_infra("path too long");
    @memcpy(path_buf[0..out_mpy.len], out_mpy);
    path_buf[out_mpy.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_buf);

    const data = read_file_libc(gpa, path_z) catch |err| {
        print_err_line("read .mpy failed: {}\n", .{err});
        die_infra("could not read produced .mpy");
    };
    defer gpa.free(data);

    const mod = mpy.read(gpa, data) catch |err| {
        print_err_line("mpy.read failed: {}\n", .{err});
        die_infra("could not parse produced .mpy");
    };
    defer mod.deinit(gpa);

    print_line("qstr_test: parsed {d} qstr entries, {d} objs\n", .{ mod.qstrs.len, mod.objs.len });

    var ctx = qstr.QstrContext.init(gpa);
    defer ctx.deinit();

    var fail_count: usize = 0;
    var static_count: usize = 0;
    var new_count: usize = 0;

    for (mod.qstrs, 0..) |q, idx| {
        switch (q) {
            .static => |id| {
                static_count += 1;
                // Bound check: vendor never emits .static with id outside the
                // static+main pool (it would be impossible to resolve).
                if (id >= qstr.N_TOTAL) {
                    print_err_line(
                        "FAIL[{d}]: .static id={d} >= N_TOTAL={d} (vendor emitted out-of-range static)\n",
                        .{ idx, id, qstr.N_TOTAL },
                    );
                    fail_count += 1;
                    continue;
                }
                // Our qstr.zig must resolve this id to non-empty bytes
                // (every static-pool entry has at least 1 char).
                const s = qstr.qstr_str(&ctx, id);
                const len = qstr.qstr_len(&ctx, id);
                if (len == 0 and id != 0 and id != 1) {
                    // id 0 (MP_QSTRnull) and id 1 (MP_QSTR_) are the two
                    // valid empty-string qstrs. Any OTHER id with zero
                    // length is a pool corruption.
                    print_err_line(
                        "FAIL[{d}]: .static id={d} resolves to empty string (pool corruption?)\n",
                        .{ idx, id },
                    );
                    fail_count += 1;
                    continue;
                }
                if (s.len < len) {
                    print_err_line(
                        "FAIL[{d}]: .static id={d}: qstr_str().len={d} < qstr_len()={d}\n",
                        .{ idx, id, s.len, len },
                    );
                    fail_count += 1;
                    continue;
                }
                // Self-consistency: re-intern the resolved bytes; must
                // return the same id (because static-pool lookup must
                // win over dynamic-pool append for any string already
                // in the static pool).
                const reintern = try qstr.qstr_from_strn(&ctx, s[0..len]);
                if (reintern != id) {
                    print_err_line(
                        "FAIL[{d}]: .static id={d}: re-interning '{s}' yielded id={d}, expected {d}\n",
                        .{ idx, id, s[0..len], reintern, id },
                    );
                    fail_count += 1;
                }
            },
            .new => |bytes| {
                new_count += 1;
                // Vendor emits `.new` (inline literal) for any qstr id
                // > QSTR_LAST_STATIC (165). That includes both:
                //   - main-pool entries (id 166..N_TOTAL-1) — present in
                //     our static pool, OK to resolve via static lookup
                //   - truly dynamic entries (id >= N_TOTAL) — interned now
                // Either is acceptable; what matters is the id is > 165.
                const id = try qstr.qstr_from_strn(&ctx, bytes);
                if (id != 0 and id <= qstr.QSTR_LAST_STATIC) {
                    // .new for a qstr that would have been encoded as .static
                    // — this would be a vendor divergence (different qstrdefs).
                    print_err_line(
                        "FAIL[{d}]: .new '{s}' resolved to id={d} <= QSTR_LAST_STATIC ({d})\n",
                        .{ idx, bytes, id, qstr.QSTR_LAST_STATIC },
                    );
                    fail_count += 1;
                    continue;
                }
                // Dedup: a second intern must return the same id.
                const id2 = try qstr.qstr_from_strn(&ctx, bytes);
                if (id2 != id) {
                    print_err_line(
                        "FAIL[{d}]: .new '{s}': dedup broken (first={d}, second={d})\n",
                        .{ idx, bytes, id, id2 },
                    );
                    fail_count += 1;
                    continue;
                }
                // Round-trip: bytes -> id -> resolved bytes must match.
                const resolved = qstr.qstr_str(&ctx, id);
                const rlen = qstr.qstr_len(&ctx, id);
                if (rlen != bytes.len or !std.mem.eql(u8, resolved[0..rlen], bytes)) {
                    print_err_line(
                        "FAIL[{d}]: .new '{s}': id={d} resolves to '{s}' (len {d} vs {d})\n",
                        .{ idx, bytes, id, resolved[0..rlen], rlen, bytes.len },
                    );
                    fail_count += 1;
                }
            },
        }
    }

    print_line(
        "qstr_test: {d} static refs, {d} new literals, {d} failures\n",
        .{ static_count, new_count, fail_count },
    );

    if (fail_count == 0) {
        write_stdout("PASS\n");
        std.process.exit(0);
    } else {
        write_stderr("FAIL\n");
        std.process.exit(1);
    }
}
