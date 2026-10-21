// zigpy-compile — the user-facing pure-Zig .py → .mpy compiler.
//
// CLI shape mirrors `mpy-cross` so users coming from the vendor tool
// feel at home:
//
//   zigpy-compile [opts] <input.py> [<input2.py> ...]
//
//   -o <file>      explicit output (only valid with exactly one input)
//   -s <name>      override embedded source-file name (default: "")
//   -O3            optimisation level (default and only supported;
//                  -O0/-O1/-O2 accepted but map to -O3 in nano)
//   -v, --version  print version
//   -h, --help     print usage
//
// Exit codes (match mpy-cross convention):
//   0 — all inputs compiled and written cleanly
//   1 — compile error (SyntaxError / IndentationError / ImportError)
//   2 — infrastructure error (cannot read input, cannot write output,
//                             OOM, bad flag, -o with multiple inputs)

const std = @import("std");

// NOTE: we deliberately do NOT @import("build_options") here. compile.zig
// already addOptions("build_options", ...) on its own module; when
// zigpy-compile's module also adds it directly, Zig 0.16 sees the same
// options.zig file under two distinct module names ("build_options" and
// "build_options0") and rejects the build. The version string is small
// enough to inline; refresh it at release time.
const VERSION: []const u8 = "0.1.0-dev";

const qstr_mod = @import("qstr.zig");
const lexer_mod = @import("lexer.zig");
const parser = @import("parser.zig");
const compile_mod = @import("compile.zig");
const mpy = @import("mpy.zig");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
    @cInclude("string.h");
});

// ---------------------------------------------------------------------------
// I/O helpers (libc-backed; same convention as the other compiler CLIs).
// ---------------------------------------------------------------------------

fn write_stdout(bytes: []const u8) void {
    _ = c.write(1, bytes.ptr, bytes.len);
}

fn write_stderr(bytes: []const u8) void {
    _ = c.write(2, bytes.ptr, bytes.len);
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

fn die_infra(msg: []const u8) noreturn {
    write_stderr("zigpy-compile: error: ");
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
    if (fsz == 0) return buf;
    const got = c.fread(buf.ptr, 1, fsz, fp);
    if (got != fsz) return error.FreadShort;
    return buf;
}

fn write_file_libc(path_z: [*:0]const u8, bytes: []const u8) !void {
    const fp = c.fopen(path_z, "wb");
    if (fp == null) return error.FopenFailed;
    defer _ = c.fclose(fp);
    if (bytes.len == 0) return;
    const wr = c.fwrite(bytes.ptr, 1, bytes.len, fp);
    if (wr != bytes.len) return error.FwriteShort;
}

/// Copy `path` into a stack-allocated NUL-terminated buffer.
/// Returns error.PathTooLong if path won't fit (with room for the NUL).
fn nul_terminate(buf: *[4096]u8, path: []const u8) ![*:0]const u8 {
    if (path.len + 1 > buf.len) return error.PathTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return @ptrCast(buf);
}

// ---------------------------------------------------------------------------
// CLI parsing.
// ---------------------------------------------------------------------------

const Args = struct {
    inputs: std.ArrayList([]const u8),
    output: ?[]const u8 = null,
    source_name: ?[]const u8 = null, // null → default "" (matches mpy-cross -s '')
    opt_level: u8 = 3,

    fn deinit(self: *Args, gpa: std.mem.Allocator) void {
        self.inputs.deinit(gpa);
    }
};

fn print_usage() void {
    const usage =
        "usage: zigpy-compile [opts] <input.py> [<input2.py> ...]\n" ++
        "\n" ++
        "options:\n" ++
        "  -o <file>      explicit output path (only valid with one input)\n" ++
        "  -s <name>      override embedded source-file name (default: \"\")\n" ++
        "  -O<n>          optimisation level (only -O3 is meaningful; default 3)\n" ++
        "  -v, --version  print version and exit\n" ++
        "  -h, --help     print this help and exit\n" ++
        "\n" ++
        "Default output: <input>.mpy alongside <input>.py.\n";
    write_stdout(usage);
}

fn print_version() void {
    print_line("zigpy-compile (nanopython {s}) -- emitting mpy v6\n", .{VERSION});
}

/// Parse argv[1..]. Exits with code 2 on bad flags.
/// On --help/--version, prints and exits 0.
fn parse_args(gpa: std.mem.Allocator, argv: []const [:0]const u8) !Args {
    var args = Args{ .inputs = .empty };
    errdefer args.deinit(gpa);

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            print_usage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "--version")) {
            print_version();
            std.process.exit(0);
        } else if (std.mem.eql(u8, a, "-o")) {
            i += 1;
            if (i >= argv.len) die_infra("-o requires an argument");
            if (args.output != null) die_infra("-o specified twice");
            args.output = argv[i];
        } else if (std.mem.eql(u8, a, "-s")) {
            i += 1;
            if (i >= argv.len) die_infra("-s requires an argument");
            args.source_name = argv[i];
        } else if (a.len >= 2 and a[0] == '-' and a[1] == 'O') {
            // -O, -O0, -O1, -O2, -O3 — all accepted, but only -O3 affects
            // codegen in nano. We record the level for completeness.
            if (a.len == 2) {
                args.opt_level = 3;
            } else if (a.len == 3 and a[2] >= '0' and a[2] <= '3') {
                args.opt_level = a[2] - '0';
            } else {
                print_err_line("zigpy-compile: error: unknown option: {s}\n", .{a});
                std.process.exit(2);
            }
        } else if (a.len > 0 and a[0] == '-') {
            print_err_line("zigpy-compile: error: unknown option: {s}\n", .{a});
            std.process.exit(2);
        } else {
            try args.inputs.append(gpa, a);
        }
    }

    if (args.inputs.items.len == 0) {
        print_usage();
        std.process.exit(2);
    }
    if (args.output != null and args.inputs.items.len != 1) {
        die_infra("-o is only valid with exactly one input file");
    }
    return args;
}

// ---------------------------------------------------------------------------
// Output path derivation: input.py → input.mpy.
// ---------------------------------------------------------------------------

fn default_output_path(gpa: std.mem.Allocator, input: []const u8) ![]u8 {
    // Strip trailing ".py" if present; append ".mpy".
    const stem_len: usize = if (std.mem.endsWith(u8, input, ".py"))
        input.len - 3
    else
        input.len;
    const out = try gpa.alloc(u8, stem_len + 4);
    @memcpy(out[0..stem_len], input[0..stem_len]);
    @memcpy(out[stem_len..], ".mpy");
    return out;
}

// ---------------------------------------------------------------------------
// Compile a single file. Returns true on success, false on compile error.
// Infrastructure errors call die_infra and don't return.
// ---------------------------------------------------------------------------

fn compile_one(
    gpa: std.mem.Allocator,
    input_path: []const u8,
    output_path: []const u8,
    source_name: []const u8,
) bool {
    // NUL-terminate the input path and read source bytes.
    var in_buf: [4096]u8 = undefined;
    const in_z = nul_terminate(&in_buf, input_path) catch {
        print_err_line("zigpy-compile: {s}: input path too long\n", .{input_path});
        std.process.exit(2);
    };
    const py_src = read_file_libc(gpa, in_z) catch |err| {
        print_err_line("zigpy-compile: {s}: cannot read: {}\n", .{ input_path, err });
        std.process.exit(2);
    };
    defer gpa.free(py_src);

    // Pipeline: qstr ctx → lex → parse → compile → mpy.write.
    var qctx = qstr_mod.QstrContext.init(gpa);
    defer qctx.deinit();

    const lex = lexer_mod.lexerNewFromStr(gpa, 0, py_src, true) catch |err| {
        print_err_line("zigpy-compile: {s}: lexer init failed: {}\n", .{ input_path, err });
        return false;
    };
    defer lexer_mod.lexerFree(lex);

    var tree = parser.parse(gpa, lex, &qctx, .file_input) catch |err| {
        print_err_line("zigpy-compile: {s}: parse error: {}\n", .{ input_path, err });
        return false;
    };
    defer tree.deinit();

    const source_file_qstr = qstr_mod.qstr_from_strn(&qctx, source_name) catch {
        print_err_line("zigpy-compile: {s}: out of memory interning source name\n", .{input_path});
        std.process.exit(2);
    };

    var module = compile_mod.compile(gpa, &qctx, tree, source_file_qstr, false) catch |err| {
        switch (err) {
            error.OutOfMemory => {
                print_err_line("zigpy-compile: {s}: out of memory during compile\n", .{input_path});
                std.process.exit(2);
            },
            error.SyntaxError => {
                print_err_line("zigpy-compile: {s}: SyntaxError\n", .{input_path});
                return false;
            },
            error.IndentationError => {
                print_err_line("zigpy-compile: {s}: IndentationError\n", .{input_path});
                return false;
            },
        }
    };
    defer module.deinit(gpa);

    const bytes = mpy.write(gpa, module) catch {
        print_err_line("zigpy-compile: {s}: out of memory serialising .mpy\n", .{input_path});
        std.process.exit(2);
    };
    defer gpa.free(bytes);

    // NUL-terminate the output path and write.
    var out_buf: [4096]u8 = undefined;
    const out_z = nul_terminate(&out_buf, output_path) catch {
        print_err_line("zigpy-compile: {s}: output path too long\n", .{output_path});
        std.process.exit(2);
    };
    write_file_libc(out_z, bytes) catch |err| {
        print_err_line("zigpy-compile: {s}: cannot write: {}\n", .{ output_path, err });
        std.process.exit(2);
    };
    return true;
}

// ---------------------------------------------------------------------------
// Entry.
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.c_allocator;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var args = try parse_args(gpa, argv);
    defer args.deinit(gpa);

    // Default source name = "" (matches mpy-cross -s '' so byte-diffs
    // against compile_test stay clean even when invoking zigpy-compile
    // directly). Users can override with -s.
    const source_name: []const u8 = args.source_name orelse "";

    var any_failed = false;
    for (args.inputs.items) |input| {
        const output_owned: ?[]u8 = if (args.output == null)
            default_output_path(gpa, input) catch die_infra("out of memory")
        else
            null;
        defer if (output_owned) |p| gpa.free(p);

        const output_path: []const u8 = args.output orelse output_owned.?;
        const ok = compile_one(gpa, input, output_path, source_name);
        if (!ok) any_failed = true;
    }

    if (any_failed) std.process.exit(1);
    std.process.exit(0);
}
