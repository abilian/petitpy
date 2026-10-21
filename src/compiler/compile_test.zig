// Differential test: our compile() vs vendor mpy-cross at the .mpy
// byte level. The proof point for C7b's compiler track: any .py source
// our pipeline accepts must produce byte-identical .mpy output to
// mpy-cross.
//
// CLI: zigpy-compile-test <input.py>
//   (Default: /tmp/zigpy_compile_test_tiny.py — a one-line `x = 1`.)
//
// Flow:
//   1. Invoke `mpy-cross <input.py> -o /tmp/...golden.mpy`.
//   2. Read the golden .mpy via libc fopen/fread.
//   3. Lex + parse + compile <input.py> via our pipeline.
//   4. Serialise via mpy.write -> our bytes.
//   5. Byte-compare. On first divergence: hex-print 32 bytes around
//      the diff site so the failure tells you what changed.
//
// Exit 0 on PASS (bytes identical), 1 on FAIL (any byte differs),
// 2 on infrastructure error (missing mpy-cross, parse/compile error).
//
// We currently pass source_file=0 (the empty qstr) to compile() and
// invoke mpy-cross WITHOUT the `-s` source-file flag so the embedded
// path doesn't drive divergence on its own. If the byte streams differ
// in the qstr-table region, that's the FIRST thing to look at.

const std = @import("std");
const mpy = @import("mpy.zig");
const qstr_mod = @import("qstr.zig");
const lexer_mod = @import("lexer.zig");
const parser = @import("parser.zig");
const compile_mod = @import("compile.zig");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
    @cInclude("string.h");
});

const DEFAULT_FIXTURE = "/tmp/zigpy_compile_test_tiny.py";
const MPY_CROSS = "mpy-cross";

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

fn run_mpy_cross(input_py: []const u8, output_mpy: []const u8) !bool {
    var buf: [4096]u8 = undefined;
    // -s '' -- override the embedded source-file path so byte-diff on
    //          path strings doesn't mask real codegen divergences.
    // -O3   -- strip source-line emission (MICROPY_ENABLE_SOURCE_LINE
    //          equivalent off; matches our nano config).
    const cmd = try std.fmt.bufPrintZ(
        &buf,
        "{s} -O3 -s '' -o '{s}' '{s}'",
        .{ MPY_CROSS, output_mpy, input_py },
    );
    const rc = c.system(cmd.ptr);
    return rc == 0;
}

fn hex_print_window(label: []const u8, bytes: []const u8, center: usize) void {
    print_line("  {s} (window centered at offset {d}):\n", .{ label, center });
    const start = if (center > 16) center - 16 else 0;
    const end = @min(bytes.len, center + 16);
    var line: [256]u8 = undefined;
    var lp: usize = 0;
    var off = start;
    while (off < end) : (off += 1) {
        const w = std.fmt.bufPrint(line[lp..], "{x:0>2} ", .{bytes[off]}) catch break;
        lp += w.len;
        if (off - start == 15) {
            line[lp] = ' ';
            lp += 1;
            line[lp] = '|';
            lp += 1;
            line[lp] = ' ';
            lp += 1;
        }
    }
    line[lp] = '\n';
    lp += 1;
    write_stdout(line[0..lp]);
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.c_allocator;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    const input_py: []const u8 = if (argv.len >= 2) argv[1] else DEFAULT_FIXTURE;

    // For the default fixture, materialise a tiny one-line program so
    // CI doesn't need a pre-staged file.
    if (std.mem.eql(u8, input_py, DEFAULT_FIXTURE)) {
        const fp = c.fopen(DEFAULT_FIXTURE.ptr, "wb");
        if (fp == null) die_infra("could not write default fixture");
        defer _ = c.fclose(fp);
        const body = "x = 1\n";
        const wr = c.fwrite(body.ptr, 1, body.len, fp);
        if (wr != body.len) die_infra("short write to fixture");
    }

    const out_mpy = "/tmp/zigpy_compile_test_golden.mpy";

    print_line("compile_test: input={s}\n", .{input_py});

    // Step 1: mpy-cross → golden bytes.
    const ok = run_mpy_cross(input_py, out_mpy) catch |err| {
        print_err_line("mpy-cross spawn failed: {}\n", .{err});
        die_infra("could not invoke mpy-cross (is it on PATH?)");
    };
    if (!ok) die_infra("mpy-cross exited non-zero");

    var path_buf: [1024]u8 = undefined;
    if (out_mpy.len + 1 > path_buf.len) die_infra("path too long");
    @memcpy(path_buf[0..out_mpy.len], out_mpy);
    path_buf[out_mpy.len] = 0;
    const golden = read_file_libc(gpa, @ptrCast(&path_buf)) catch |err| {
        print_err_line("read golden .mpy failed: {}\n", .{err});
        die_infra("could not read golden .mpy");
    };
    defer gpa.free(golden);

    // Step 2: read the input .py.
    var in_buf: [1024]u8 = undefined;
    if (input_py.len + 1 > in_buf.len) die_infra("input path too long");
    @memcpy(in_buf[0..input_py.len], input_py);
    in_buf[input_py.len] = 0;
    const py_src = read_file_libc(gpa, @ptrCast(&in_buf)) catch |err| {
        print_err_line("read .py failed: {}\n", .{err});
        die_infra("could not read input .py");
    };
    defer gpa.free(py_src);

    // Step 3: our pipeline (lex → parse → compile).
    var qctx = qstr_mod.QstrContext.init(gpa);
    defer qctx.deinit();

    const lex = lexer_mod.lexerNewFromStr(gpa, 0, py_src, true) catch |err| {
        print_err_line("lexer init failed: {}\n", .{err});
        die_infra("could not start lexer");
    };
    defer lexer_mod.lexerFree(lex);

    var tree = parser.parse(gpa, lex, &qctx, .file_input) catch |err| {
        print_err_line("parse failed: {}\n", .{err});
        die_infra("could not parse input");
    };
    defer tree.deinit();

    // mpy-cross with `-s ''` interns "" as MP_QSTR_ (id 1, not the
    // MP_QSTRnull sentinel at id 0). Match that.
    const source_file_qstr = qstr_mod.qstr_from_strn(&qctx, "") catch {
        die_infra("could not intern empty source file qstr");
    };

    var module = compile_mod.compile(gpa, &qctx, tree, source_file_qstr, false) catch |err| {
        print_err_line("compile failed: {}\n", .{err});
        die_infra("could not compile input");
    };
    defer module.deinit(gpa);

    // Step 4: serialise.
    const ours = mpy.write(gpa, module) catch |err| {
        print_err_line("mpy.write failed: {}\n", .{err});
        die_infra("could not serialise our Module");
    };
    defer gpa.free(ours);

    print_line(
        "compile_test: golden={d} bytes, ours={d} bytes\n",
        .{ golden.len, ours.len },
    );

    // Always dump ours to a fixed path so we can hex-diff vs golden out
    // of band when triaging divergence patterns.
    const ours_path = "/tmp/zigpy_compile_test_ours.mpy";
    {
        const fp_out = c.fopen(ours_path.ptr, "wb");
        if (fp_out != null) {
            _ = c.fwrite(ours.ptr, 1, ours.len, fp_out);
            _ = c.fclose(fp_out);
        }
    }

    // Step 5: byte-compare.
    if (golden.len == ours.len and std.mem.eql(u8, golden, ours)) {
        write_stdout("PASS — byte-identical to mpy-cross\n");
        std.process.exit(0);
    }

    write_stdout("FAIL — bytes differ\n");
    const min_len = @min(golden.len, ours.len);
    var diff_at: usize = min_len;
    var i: usize = 0;
    while (i < min_len) : (i += 1) {
        if (golden[i] != ours[i]) {
            diff_at = i;
            break;
        }
    }
    print_line("  first divergence at offset {d}\n", .{diff_at});
    hex_print_window("golden", golden, diff_at);
    hex_print_window("ours  ", ours, diff_at);
    std.process.exit(1);
}
