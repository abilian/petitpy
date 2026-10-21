//! Out-buffer ownership: `*out_buf` is allocated via libc malloc
//! (not `std.heap.c_allocator`'s owned tracking) so the C caller
//! can free it with plain `free()`. The caller MUST free after the
//! loader has consumed the bytes. On non-zero return, `*out_buf`
//! is unspecified — gate on the return code, don't read out_buf.

const std = @import("std");
const lexer_mod = @import("lexer.zig");
const parser = @import("parser.zig");
const qstr_mod = @import("qstr.zig");
const compile_mod = @import("compile.zig");
const mpy = @import("mpy.zig");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("string.h");
});

/// Error codes returned by `npy_zig_compile_to_mpy`. Mirrored on the
/// C side as plain integers; the bridge translates them into
/// MicroPython exceptions before re-raising into the VM.
const ERR_OK: c_int = 0;
const ERR_OOM: c_int = 1;
const ERR_SYNTAX: c_int = 2;
const ERR_INDENT: c_int = 3;

/// Match MicroPython `mp_parse_input_kind_t` (py/parse.h:101-103).
const MP_PARSE_SINGLE_INPUT: c_int = 0;
const MP_PARSE_FILE_INPUT: c_int = 1;
const MP_PARSE_EVAL_INPUT: c_int = 2;

/// Compile a Python source string to .mpy bytes via the pure-Zig
/// pipeline (lexer + parser + compile + mpy.write).
///
/// On success: writes the malloc'd buffer pointer to `*out_buf`,
/// the length to `*out_len`, and returns 0. Caller MUST `free`
/// `*out_buf` after `mp_raw_code_load_mem` consumes it.
///
/// On failure: returns a non-zero ERR_* code; *out_buf is
/// unspecified.
export fn npy_zig_compile_to_mpy(
    src: [*]const u8,
    src_len: usize,
    src_name: [*:0]const u8,
    parse_input_kind: c_int,
    out_buf: *[*]u8,
    out_len: *usize,
) callconv(.c) c_int {
    out_len.* = 0;

    const input_kind: parser.InputKind = switch (parse_input_kind) {
        MP_PARSE_SINGLE_INPUT => .single_input,
        MP_PARSE_EVAL_INPUT => .eval_input,
        else => .file_input, // including MP_PARSE_FILE_INPUT
    };
    // Vendor `mp_compile(parse_tree, src, is_repl)`: is_repl is true
    // exactly when parse_input_kind == SINGLE_INPUT (the REPL case).
    const is_repl = parse_input_kind == MP_PARSE_SINGLE_INPUT;

    const gpa = std.heap.c_allocator;

    // Per-compilation qstr context — independent of the runtime's
    // qstr pool. The .mpy file the loader will read carries its
    // own qstr table; the runtime interns whatever it needs at
    // load time.
    var qctx = qstr_mod.QstrContext.init(gpa);
    defer qctx.deinit();

    // The lexer accepts a slice. We make an explicit copy that
    // lives for the lexer's lifetime so the C caller's buffer
    // can be transient.
    const src_slice = src[0..src_len];
    const src_copy = gpa.dupe(u8, src_slice) catch return ERR_OOM;
    // lexer takes ownership of the copy when free_len > 0 — but
    // our Zig lexer's lifecycle has lexerFree. The slice itself
    // is borrowed for the lexer's lifetime.
    defer gpa.free(src_copy);

    const lex = lexer_mod.lexerNewFromStr(gpa, 0, src_copy, false) catch return ERR_OOM;
    defer lexer_mod.lexerFree(lex);

    var tree = parser.parse(gpa, lex, &qctx, input_kind) catch |err| {
        return switch (err) {
            error.OutOfMemory => ERR_OOM,
            error.SyntaxError => ERR_SYNTAX,
            error.IndentationError => ERR_INDENT,
            error.DedentMismatch => ERR_INDENT,
        };
    };
    defer tree.deinit();

    // Source-name qstr: intern in our local qctx.
    const src_name_slice = std.mem.span(src_name);
    const source_file_qstr = qstr_mod.qstr_from_strn(&qctx, src_name_slice) catch return ERR_OOM;

    var module = compile_mod.compile(gpa, &qctx, tree, source_file_qstr, is_repl) catch |err| {
        return switch (err) {
            error.OutOfMemory => ERR_OOM,
            error.SyntaxError => ERR_SYNTAX,
            error.IndentationError => ERR_INDENT,
        };
    };
    defer module.deinit(gpa);

    // mpy.write returns a gpa-owned slice; we need to hand off to
    // libc malloc so the C side can free with plain free(). Copy
    // via c.malloc.
    const bytes = mpy.write(gpa, module) catch return ERR_OOM;
    defer gpa.free(bytes);

    const dst = c.malloc(bytes.len) orelse return ERR_OOM;
    _ = c.memcpy(dst, bytes.ptr, bytes.len);

    out_buf.* = @ptrCast(dst);
    out_len.* = bytes.len;
    return ERR_OK;
}

// Force export-fn analysis. Without this, Zig's dead-code elimination
// drops the symbol — same pattern as src/frontend/compile.zig.
comptime {
    _ = &npy_zig_compile_to_mpy;
}
