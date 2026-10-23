//! petitpy — Zig port of support/readline_shim.c.
//! Simple line reader for input() + REPL line reader for main.zig.

const builtin = @import("builtin");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("string.h");
});

const CHAR_CTRL_D: c_int = 0x04;

// macOS/BSD libc names FILE* globals __stdinp/__stdoutp/__stderrp; Linux
// and wasi-libc use stdin/stdout/stderr. Resolve the right pair at
// comptime so the wasi build (wasm32-wasi) and macOS native build both
// translate cleanly.
// Under wasi-libc, c.stdin / c.stdout / c.stderr are typed as ?*FILE.
// fputs/fflush/fgets accept the optional directly, so we keep the return
// type matched to whichever form the cimport surfaces.
inline fn stdinFp() @TypeOf(if (@hasDecl(c, "__stdinp")) c.__stdinp else c.stdin) {
    return if (@hasDecl(c, "__stdinp")) c.__stdinp else c.stdin;
}
inline fn stdoutFp() @TypeOf(if (@hasDecl(c, "__stdoutp")) c.__stdoutp else c.stdout) {
    return if (@hasDecl(c, "__stdoutp")) c.__stdoutp else c.stdout;
}
inline fn stderrFp() @TypeOf(if (@hasDecl(c, "__stderrp")) c.__stderrp else c.stderr) {
    return if (@hasDecl(c, "__stderrp")) c.__stderrp else c.stderr;
}

extern fn vstr_add_strn(vstr: ?*anyopaque, str: [*c]const u8, len: usize) callconv(.c) void;
extern fn mp_repl_continue_with_input(input: [*:0]const u8) callconv(.c) bool;

// Reads one line from stdin into the vstr (strips trailing \n).
// Returns 0 on success, CHAR_CTRL_D on EOF.
export fn readline(line: ?*anyopaque, prompt: ?[*:0]const u8) callconv(.c) c_int {
    if (prompt) |p| {
        if (p[0] != 0) {
            _ = c.fputs(p, stdoutFp());
            _ = c.fflush(stdoutFp());
        }
    }
    var buf: [256]u8 = undefined;
    while (c.fgets(&buf, buf.len, stdinFp()) != null) {
        const n = c.strlen(&buf);
        if (n > 0 and buf[n - 1] == '\n') {
            vstr_add_strn(line, &buf, n - 1);
            return 0;
        }
        vstr_add_strn(line, &buf, n);
    }
    return CHAR_CTRL_D;
}

// REPL line-reader (used by main.zig). Returns bytes read, or 0 on EOF
// (line_buf[0]=0). Trailing \n is stripped.
export fn npy_repl_read_line(line_buf: [*:0]u8, buf_max: c_int, prompt: ?[*:0]const u8) callconv(.c) c_int {
    if (prompt) |p| {
        if (p[0] != 0) {
            _ = c.fputs(p, stderrFp());
            _ = c.fflush(stderrFp());
        }
    }
    if (c.fgets(line_buf, buf_max, stdinFp()) == null) {
        line_buf[0] = 0;
        return 0;
    }
    const n: c_int = @intCast(c.strlen(line_buf));
    if (n > 0 and line_buf[@intCast(n - 1)] == '\n') line_buf[@intCast(n - 1)] = 0;
    return n;
}

// Returns 1 if more input expected (unmatched bracket, compound stmt,
// line continuation), else 0.
export fn npy_repl_continue(input: [*:0]const u8) callconv(.c) c_int {
    return if (mp_repl_continue_with_input(input)) 1 else 0;
}

comptime {
    _ = &readline;
    _ = &npy_repl_read_line;
    _ = &npy_repl_continue;
}
