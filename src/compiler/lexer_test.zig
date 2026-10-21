// Differential test: vendor py/lexer.c vs. src/compiler/lexer.zig.
//
// CLI:
//   zigpy-lexer-test <input.py>         # single file
//   zigpy-lexer-test --corpus <dir>     # iterate every *.py recursively under <dir>
//   zigpy-lexer-test                    # default: tests/qstr_fixture.py
//
// Flow (per fixture):
//   1. Spawn `token_dump <fixture>` (the vendor-linked C harness at
//      vendor/micropython/mpy-cross/build/tools/token_dump or anywhere
//      on PATH). Capture stdout — one line per token in the format:
//
//          idx<TAB>kind<TAB>line<TAB>column<TAB>len<TAB>hexbytes\n
//
//   2. Read the same fixture, construct our pure-Zig Lexer via
//      `lexer.lexerNewFromStr(...)`, loop `lexer.lexerToNext(...)`,
//      format each emitted token in the exact same wire format.
//   3. Diff the two streams line-by-line. First diverging line is
//      reported with context (3 lines before, the mismatch marked
//      with '*', and 3 lines after on the vendor side for orientation).
//
// Exit codes:
//   0 — every fixture's token stream matched byte-identically
//   1 — at least one fixture diverged
//   2 — infrastructure error (token_dump missing, file unreadable, etc.)
//
// This is the C3 acceptance criterion. The strong form ("552/552
// byte-identical") is what unlocks promoting src/compiler/lexer.zig
// out of test-only status.
//
// NOTE: This file imports src/compiler/lexer.zig, which the C3 task
// generates alongside this harness. The build wiring (`zig build
// lexer-test`) is added in the same patch; until lexer.zig exists the
// test target is intentionally absent from build.zig so `make check`
// is not affected.

const std = @import("std");
const libc = @cImport({ @cInclude("unistd.h"); @cInclude("stdlib.h"); });
const lexer = @import("lexer.zig");

const DEFAULT_FIXTURE = "tests/qstr_fixture.py";

// Resolution order for the vendor token-dump helper:
//   1. NPY_TOKEN_DUMP env var (absolute path; useful in CI)
//   2. vendor/micropython/mpy-cross/build/tools/token_dump (canonical local build)
//   3. `token_dump` on PATH
const TOKEN_DUMP_DEFAULT =
    "vendor/micropython/mpy-cross/build/tools/token_dump";

// ── tiny logging helpers ─────────────────────────────────────────────────────

fn eprint(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = libc.write(2, out.ptr, out.len);
}

fn oprint(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = libc.write(1, out.ptr, out.len);
}

fn dieInfra(msg: []const u8) noreturn {
    eprint("ERROR (infra): {s}\n", .{msg});
    std.process.exit(2);
}

// ── vendor token-dump invocation ─────────────────────────────────────────────

fn resolveTokenDump(gpa: std.mem.Allocator) ![]const u8 {
    // Skip env lookup (Zig 0.16 API change); always use default path.

    // Probe the canonical build path. std.fs.cwd().access doesn't
    // distinguish "missing" from "permission denied", but for this
    // helper either failure means "fall back to PATH".
    std.fs.cwd().access(TOKEN_DUMP_DEFAULT, .{}) catch {
        return try gpa.dupe(u8, "token_dump");
    };
    return try gpa.dupe(u8, TOKEN_DUMP_DEFAULT);
}

/// Spawn `<exe> <fixture>` and capture its stdout. Returns owned bytes.
fn captureVendor(gpa: std.mem.Allocator, exe: []const u8, fixture: []const u8) ![]u8 {
    var child = std.process.Child.init(&.{ exe, fixture }, gpa);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;

    try child.spawn();

    var out = std.ArrayList(u8){};
    defer out.deinit(gpa);

    var stdout = child.stdout.?;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try stdout.read(&buf);
        if (n == 0) break;
        try out.appendSlice(gpa, buf[0..n]);
    }

    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                eprint("token_dump exited with code {d} on {s}\n", .{ code, fixture });
                return error.VendorFailed;
            }
        },
        else => {
            eprint("token_dump terminated abnormally on {s}\n", .{fixture});
            return error.VendorFailed;
        },
    }

    return try out.toOwnedSlice(gpa);
}

// ── pure-Zig token-dump (same wire format) ───────────────────────────────────

fn readFile(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const stat = try f.stat();
    const buf = try gpa.alloc(u8, stat.size);
    errdefer gpa.free(buf);
    const n = try f.readAll(buf);
    if (n != stat.size) return error.ShortRead;
    return buf;
}

fn writeHex(w: anytype, bytes: []const u8) !void {
    const hex = "0123456789abcdef";
    for (bytes) |b| {
        try w.writeByte(hex[b >> 4]);
        try w.writeByte(hex[b & 0x0f]);
    }
}

fn dumpZig(gpa: std.mem.Allocator, fixture: []const u8) ![]u8 {
    const src = try readFile(gpa, fixture);
    defer gpa.free(src);

    var out = std.ArrayList(u8){};
    defer out.deinit(gpa);
    var w = out.writer(gpa);

    // Source-name interning is the parser's job; the lexer just stores
    // an opaque qstr id. Pass 0 (MP_QSTRnull) — this matches what the
    // C harness does after vendor's qstr_from_str(path) only for the
    // purposes of the lexer's internal bookkeeping; the source-name
    // field is never emitted in the token wire format, so the actual
    // id is don't-care.
    const src_name: lexer.qstr = 0;

    const lex = lexer.lexerNewFromStr(
        gpa,
        src_name,
        src,
        true, // debug_mode = true matches mp_optimise_value default (0)
    ) catch |e| {
        eprint("zig lexerNewFromStr failed on {s}: {s}\n", .{ fixture, @errorName(e) });
        return error.ZigLexFailed;
    };
    defer lexer.lexerFree(lex);

    var idx: usize = 0;
    while (true) : (idx += 1) {
        try w.print("{d}\t{d}\t{d}\t{d}\t{d}\t", .{
            idx,
            @intFromEnum(lex.tok_kind),
            lex.tok_line,
            lex.tok_column,
            lex.vstr.items.len,
        });
        try writeHex(&w, lex.vstr.items);
        try w.writeByte('\n');

        const kind = lex.tok_kind;
        if (kind == .END or kind == .INVALID) break;

        lexer.lexerToNext(lex) catch |e| {
            eprint("zig lexerToNext failed on {s}: {s}\n", .{ fixture, @errorName(e) });
            return error.ZigLexFailed;
        };
    }

    return try out.toOwnedSlice(gpa);
}

// ── diff reporting ───────────────────────────────────────────────────────────

/// Print the first divergence with 3-line context on each side.
/// Returns true if streams matched.
fn diffAndReport(
    gpa: std.mem.Allocator,
    fixture: []const u8,
    vendor: []const u8,
    ours: []const u8,
) !bool {
    _ = gpa;
    if (std.mem.eql(u8, vendor, ours)) return true;

    // Walk both streams line-by-line.
    var v_lines = std.mem.splitScalar(u8, vendor, '\n');
    var z_lines = std.mem.splitScalar(u8, ours, '\n');

    // Ring buffer of last 3 vendor lines for context.
    var ctx: [3][]const u8 = .{ "", "", "" };
    var ctx_w: usize = 0;
    var line_no: usize = 0;

    while (true) : (line_no += 1) {
        const v = v_lines.next();
        const z = z_lines.next();
        if (v == null and z == null) {
            // Both ended cleanly and bytes were unequal: must be trailing
            // whitespace divergence; report at synthetic position.
            eprint("FAIL {s}: streams differ only in trailing bytes\n", .{fixture});
            return false;
        }
        const vs = v orelse "";
        const zs = z orelse "";

        if (!std.mem.eql(u8, vs, zs)) {
            eprint("FAIL {s}: divergence at line {d}\n", .{ fixture, line_no });
            // Print up to 3 prior vendor lines for context.
            var n_ctx: usize = 0;
            while (n_ctx < 3) : (n_ctx += 1) {
                const slot = (ctx_w + n_ctx) % 3;
                if (ctx[slot].len != 0) {
                    eprint("    ctx |  {s}\n", .{ctx[slot]});
                }
            }
            eprint("  vendor *| {s}\n", .{vs});
            eprint("  zig    *| {s}\n", .{zs});
            return false;
        }

        ctx[ctx_w] = vs;
        ctx_w = (ctx_w + 1) % 3;
    }
}

// ── fixture enumeration ──────────────────────────────────────────────────────

fn collectCorpus(gpa: std.mem.Allocator, root: []const u8) !std.ArrayList([]u8) {
    var list = std.ArrayList([]u8){};
    errdefer {
        for (list.items) |p| gpa.free(p);
        list.deinit(gpa);
    }

    var dir = try std.fs.cwd().openDir(root, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".py")) continue;
        const full = try std.fs.path.join(gpa, &.{ root, entry.path });
        try list.append(gpa, full);
    }

    // Stable order: lexicographic by full path. Helps reproducible diffs.
    std.mem.sort([]u8, list.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    return list;
}

// ── main ─────────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.c_allocator;
    const raw_argv = try init.minimal.args.toSlice(init.arena.allocator());

    // ── arg parsing ──────────────────────────────────────────────────────
    var corpus_dir: ?[]const u8 = null;
    var single: ?[]const u8 = null;
    var i: usize = 1;
    while (i < raw_argv.len) : (i += 1) {
        const a = raw_argv[i];
        if (std.mem.eql(u8, a, "--corpus")) {
            if (i + 1 >= raw_argv.len) dieInfra("--corpus needs a directory");
            corpus_dir = raw_argv[i + 1];
            i += 1;
        } else if (a.len > 0 and a[0] == '-') {
            eprint("unknown flag: {s}\n", .{a});
            std.process.exit(2);
        } else {
            single = a;
        }
    }

    const exe = resolveTokenDump(gpa) catch |e| {
        eprint("could not resolve token_dump: {s}\n", .{@errorName(e)});
        std.process.exit(2);
    };
    defer gpa.free(exe);

    oprint("lexer_test: using vendor harness `{s}`\n", .{exe});

    // ── fixture list ─────────────────────────────────────────────────────
    var fixtures = std.ArrayList([]u8){};
    defer {
        for (fixtures.items) |p| gpa.free(p);
        fixtures.deinit(gpa);
    }

    if (corpus_dir) |dir| {
        fixtures = try collectCorpus(gpa, dir);
        oprint("lexer_test: corpus {s} -> {d} fixtures\n", .{ dir, fixtures.items.len });
    } else {
        const f = single orelse DEFAULT_FIXTURE;
        try fixtures.append(gpa, try gpa.dupe(u8, f));
    }

    if (fixtures.items.len == 0) dieInfra("no fixtures to test");

    // ── differential loop ────────────────────────────────────────────────
    var n_pass: usize = 0;
    var n_fail: usize = 0;
    var first_fail: ?[]const u8 = null;

    for (fixtures.items) |fx| {
        const vendor = captureVendor(gpa, exe, fx) catch |e| {
            eprint("FAIL {s}: vendor capture: {s}\n", .{ fx, @errorName(e) });
            n_fail += 1;
            if (first_fail == null) first_fail = fx;
            continue;
        };
        defer gpa.free(vendor);

        const ours = dumpZig(gpa, fx) catch |e| {
            eprint("FAIL {s}: zig dump: {s}\n", .{ fx, @errorName(e) });
            n_fail += 1;
            if (first_fail == null) first_fail = fx;
            continue;
        };
        defer gpa.free(ours);

        const ok = diffAndReport(gpa, fx, vendor, ours) catch |e| {
            eprint("FAIL {s}: diff: {s}\n", .{ fx, @errorName(e) });
            n_fail += 1;
            if (first_fail == null) first_fail = fx;
            continue;
        };

        if (ok) {
            n_pass += 1;
        } else {
            n_fail += 1;
            if (first_fail == null) first_fail = fx;
        }
    }

    oprint("lexer_test: {d} passed, {d} failed (of {d})\n", .{
        n_pass, n_fail, fixtures.items.len,
    });

    if (n_fail == 0) {
        oprint("PASS\n", .{});
        std.process.exit(0);
    } else {
        if (first_fail) |f| eprint("first failure: {s}\n", .{f});
        std.process.exit(1);
    }
}
