//! petitpy — Zig port of `src/runtime/zig_compile_bridge.c`.
//!
//! This is the architectural pivot of NX-3: replaces the
//! `nlr_push_jump_callback` globals/locals swap (which fired on NLR
//! unwind) with Zig `defer`. After this lands, the only consumer of
//! the `nlr_jump_callback_*` infrastructure is gone — N4 can delete
//! `nlr.c`, `nlrsetjmp.c`, `nlr_trampoline.c`, `runtime_shim.c`, and
//! the mirror types in `mp_mirrors.zig` that backed the callback
//! chain.
//!
//! Five entry points (matches the C file):
//!   - raise_from_code        (private helper)  → raiseFromCode
//!   - compile_and_load       (private helper)  → compileAndLoad
//!   - npy_zig_compile_source (script/REPL)    → exported as before
//!   - npy_zig_eval_exec      (eval/exec)      → exported as before;
//!     the globals-swap now uses `defer mp_globals_set(saved)` instead
//!     of `nlr_push_jump_callback`
//!   - npy_zig_compile_to_code (compile() builtin) — exported when
//!     MICROPY_PY_BUILTINS_COMPILE; under nano this is set, so the
//!     export is emitted unconditionally (the FUN_OBJ that references
//!     it stays #if-gated shim-side).

const std = @import("std");
const mirrors = @import("../mp_mirrors.zig");
const pyerr = @import("../pyerr.zig");
const build_options = @import("build_options");
const PyError = pyerr.PyError;

const Obj = mirrors.Obj;
const Qstr = usize;

// ── extern surface ───────────────────────────────────────────────────

// Provided by src/compiler/bridge.zig (Zig export). Returns one of the
// NPY_ZIG_* codes below.
extern fn npy_zig_compile_to_mpy(
    src: [*]const u8,
    src_len: usize,
    src_name: [*:0]const u8,
    parse_input_kind: c_int,
    out_buf: *?[*]u8,
    out_len: *usize,
) callconv(.c) c_int;

// Error codes — must match src/compiler/bridge.zig.
const NPY_ZIG_OK: c_int = 0;
const NPY_ZIG_OOM: c_int = 1;
const NPY_ZIG_SYNTAX: c_int = 2;
const NPY_ZIG_INDENT: c_int = 3;

// MP_ENOMEM (mperrno.h:47). nano uses the bare numeric mperrno table.
const MP_ENOMEM: c_int = 12;

// Persistent-code loader — Zig-side as of NX-1 (persistentcode.zig).
extern fn mp_raw_code_load_mem(buf: [*]const u8, len: usize, cm: *mirrors.MpCompiledModule) callconv(.c) void;

// Vendor / Zig-runtime helpers.
extern fn mp_make_function_from_proto_fun(proto: usize, ctx: ?*const anyopaque, defargs: [*c]const Obj) callconv(.c) Obj;
extern fn mp_call_function_0(fun: Obj) callconv(.c) Obj;
extern fn mp_obj_new_exception_msg(t: *const anyopaque, msg: [*:0]const u8) callconv(.c) Obj;
extern fn mp_obj_exception_add_traceback(exc: Obj, source_file: Qstr, source_line: usize, block_name: Qstr) callconv(.c) void;
extern fn m_malloc(num_bytes: usize) callconv(.c) ?*anyopaque;

// Globals/locals swap (Zig-side: jcb_glue.zig).
extern fn mp_globals_get() callconv(.c) ?*anyopaque;
extern fn mp_locals_get() callconv(.c) ?*anyopaque;
extern fn mp_globals_set(d: ?*anyopaque) callconv(.c) void;
extern fn mp_locals_set(d: ?*anyopaque) callconv(.c) void;

// qstr_str — needed to obtain the C-string source-file name for the
// compiler bridge. Static-inline in qstr.h; the underlying symbol is
// `qstr_str` (real extern in nano + full).
extern fn qstr_str(q: Qstr) callconv(.c) [*:0]const u8;

// Polled raise for the OOM short-circuit.
extern fn mp_raise_OSError_polled(errno_: c_int) callconv(.c) void;

// Exception type singletons.
extern const mp_type_SyntaxError: anyopaque;
extern const mp_type_IndentationError: anyopaque;
extern const mp_type_RuntimeError: anyopaque;
// `mp_type_module` is Zig-exported (mp_type_roms.zig:285). Linker
// resolves the same symbol regardless of source language.
extern const mp_type_module: anyopaque;
// `mp_type_code` (vendor objcode.c). Only referenced under the FULL
// build's compile() path (builtinevex.zig:`if (is_full)` selector).
// Under nano, vendor objcode.c is NOT in the compile graph and the
// extern would be undefined at link time — the FULL-only namespace
// below keeps the reference behind a `comptime is_full` gate.

// MP_QSTRnull = 0 (vendor qstr enum).
const MP_QSTRnull: Qstr = 0;

// ── raise_from_code ──────────────────────────────────────────────────
//
// Maps a compiler-internal error code to a Python exception. Builds the
// exception with a traceback frame attached (vendor parse.c pattern) so
// the printer emits the
//   Traceback (most recent call last):
//     File "<src>"
//   <ExcType>: <msg>
// prologue. Without add_traceback, mp_obj_print_exception suppresses
// the prologue (empty traceback list). Line=0 is fine — nano has
// MICROPY_ENABLE_SOURCE_LINE=0 so the printer omits line numbers.
//
// OOM stays on the dedicated mp_raise_OSError path (pre-allocated; the
// no-traceback message matches vendor under MEM_ERROR_MSG_TERSE).
fn raiseFromCode(code: c_int, source_file: Qstr) PyError!void {
    if (code == NPY_ZIG_OOM) {
        mp_raise_OSError_polled(MP_ENOMEM);
        return error.PyRaise;
    }
    const exc_type: *const anyopaque = switch (code) {
        NPY_ZIG_SYNTAX => &mp_type_SyntaxError,
        NPY_ZIG_INDENT => &mp_type_IndentationError,
        else => &mp_type_RuntimeError,
    };
    const msg: [*:0]const u8 = switch (code) {
        NPY_ZIG_SYNTAX, NPY_ZIG_INDENT => "invalid syntax",
        else => "zigpy compile failed",
    };
    const exc = mp_obj_new_exception_msg(exc_type, msg);
    mp_obj_exception_add_traceback(exc, source_file, 0, MP_QSTRnull);
    pyerr.pending_exc = exc;
    return error.PyRaise;
}

// ── compile_and_load ─────────────────────────────────────────────────
//
// Compile source → module function, sharing the active module globals
// (compile_source / eval_exec path). Raises (via raiseFromCode) on Zig
// compile failure.
fn compileAndLoad(
    src: [*]const u8,
    src_len: usize,
    source_file: Qstr,
    parse_input_kind: c_int,
) PyError!Obj {
    var mpy_buf: ?[*]u8 = null;
    var mpy_len: usize = 0;
    const rc = npy_zig_compile_to_mpy(
        src,
        src_len,
        qstr_str(source_file),
        parse_input_kind,
        &mpy_buf,
        &mpy_len,
    );
    if (rc != NPY_ZIG_OK) {
        try raiseFromCode(rc, source_file);
    }

    var cm: mirrors.MpCompiledModule = undefined;
    const ctx: *mirrors.MpModuleContext = @ptrCast(@alignCast(m_malloc(@sizeOf(mirrors.MpModuleContext)).?));
    cm.context = ctx;
    ctx.module.base.type = @ptrCast(&mp_type_module);
    ctx.module.globals = @ptrCast(@alignCast(mp_globals_get().?));

    // mp_raw_code_load_mem is PyError-aware (NX-3 N1): on raise it sets
    // pyerr.pending_exc + returns the zero sentinel via the bridge. We
    // poll pending_exc after the call.
    mp_raw_code_load_mem(mpy_buf.?, mpy_len, &cm);
    std.c.free(@ptrCast(mpy_buf.?));
    if (pyerr.pending_exc != 0) return error.PyRaise;

    return mp_make_function_from_proto_fun(@intFromPtr(cm.rc), cm.context, null);
}

// ── npy_zig_compile_source ───────────────────────────────────────────
//
// Script-execution / REPL entry. The caller invokes mp_call_function_0
// on the result to actually run the module code.
fn npyZigCompileSourceImpl(
    src: [*]const u8,
    src_len: usize,
    source_file: Qstr,
    parse_input_kind: c_int,
) PyError!Obj {
    return compileAndLoad(src, src_len, source_file, parse_input_kind);
}

pub export fn npy_zig_compile_source(
    src: [*c]const u8,
    src_len: usize,
    source_file: Qstr,
    parse_input_kind: c_int,
) callconv(.c) Obj {
    return pyerr.bridge(Obj, npyZigCompileSourceImpl(@ptrCast(src), src_len, source_file, parse_input_kind));
}

// ── npy_zig_eval_exec ────────────────────────────────────────────────
//
// eval() / exec() entry: compile under a swapped globals/locals scope
// and execute. Mirrors vendor mp_parse_compile_execute (runtime.c:1634).
//
// THE ARCHITECTURAL PIVOT: the C version used
// `nlr_push_jump_callback(&node, mp_globals_locals_set_from_nlr_jump_callback)`
// to restore globals/locals on NLR unwind. Here we use Zig `defer` —
// it runs on success AND on `error.PyRaise` return — so the callback
// infrastructure becomes deletable in N4.
fn npyZigEvalExecImpl(
    src: [*]const u8,
    src_len: usize,
    source_file: Qstr,
    parse_input_kind: c_int,
    globals: ?*anyopaque,
    locals: ?*anyopaque,
) PyError!Obj {
    const saved_g = mp_globals_get();
    const saved_l = mp_locals_get();
    defer mp_globals_set(saved_g);
    defer mp_locals_set(saved_l);
    mp_globals_set(globals);
    mp_locals_set(locals);

    const module_fun = try compileAndLoad(src, src_len, source_file, parse_input_kind);
    const ret = mp_call_function_0(module_fun);
    if (pyerr.pending_exc != 0) return error.PyRaise;
    return ret;
}

pub export fn npy_zig_eval_exec(
    src: [*c]const u8,
    src_len: usize,
    source_file: Qstr,
    parse_input_kind: c_int,
    globals: ?*anyopaque,
    locals: ?*anyopaque,
) callconv(.c) Obj {
    return pyerr.bridge(Obj, npyZigEvalExecImpl(@ptrCast(src), src_len, source_file, parse_input_kind, globals, locals));
}

// ── npy_zig_compile_to_code ──────────────────────────────────────────
//
// compile() builtin entry: compile + load, wrap as a `code` object,
// return without executing. Live under MICROPY_PY_BUILTINS_COMPILE
// (nano: =1, full: =1) BUT the body references `mp_type_code` which
// only exists if vendor `objcode.c` is in the compile graph — under
// nano it isn't (port/Makefile / build.zig exclude it). The caller
// (`builtinevex.zig::compile_glue`) is comptime-gated on
// `build_options.is_full`, so under nano this export is never
// invoked. We mirror that gate here: the FULL impl owns the body;
// the nano-branch impl is `unreachable`.
//
// Under FULL: MICROPY_PY_SYS_SETTRACE=0 and
// MICROPY_PY_FUNCTION_ATTRS_CODE=0 (port/mpconfigport.h), so
// MICROPY_PY_BUILTINS_CODE resolves to MICROPY_PY_BUILTINS_CODE_MINIMUM.
// The MINIMUM mp_obj_code_t layout is { base, module_fun } — 16 bytes.
// `mp_obj_new_code(module_fun)` is a static-inline that allocates via
// mp_obj_malloc_helper(sizeof(mp_obj_code_t), &mp_type_code) and
// stores module_fun. Ported inside `compile_to_code_glue` below.

const compile_to_code_glue = if (build_options.is_full) struct {
    const MpObjCodeMinimum = extern struct {
        base: mirrors.MpObjBase,
        module_fun: Obj,
    };

    extern const mp_type_code: anyopaque;
    extern fn mp_obj_malloc_helper(num_bytes: usize, t: *const anyopaque) callconv(.c) ?*anyopaque;

    inline fn newCodeMinimum(module_fun: Obj) Obj {
        const code: *MpObjCodeMinimum = @ptrCast(@alignCast(mp_obj_malloc_helper(@sizeOf(MpObjCodeMinimum), &mp_type_code).?));
        code.module_fun = module_fun;
        return @intFromPtr(code);
    }

    pub fn impl(
        src: [*]const u8,
        src_len: usize,
        source_file: Qstr,
        parse_input_kind: c_int,
    ) PyError!Obj {
        var mpy_buf: ?[*]u8 = null;
        var mpy_len: usize = 0;
        const rc = npy_zig_compile_to_mpy(
            src,
            src_len,
            qstr_str(source_file),
            parse_input_kind,
            &mpy_buf,
            &mpy_len,
        );
        if (rc != NPY_ZIG_OK) {
            try raiseFromCode(rc, source_file);
        }

        var cm: mirrors.MpCompiledModule = undefined;
        const ctx: *mirrors.MpModuleContext = @ptrCast(@alignCast(m_malloc(@sizeOf(mirrors.MpModuleContext)).?));
        cm.context = ctx;
        ctx.module.base.type = @ptrCast(&mp_type_module);
        // C: ctx->module.globals = NULL — compile() doesn't bind a
        // module's active globals dict; the result code object is
        // executed later under whatever globals the caller chooses.
        @as(*?*anyopaque, @ptrCast(&ctx.module.globals)).* = null;

        mp_raw_code_load_mem(mpy_buf.?, mpy_len, &cm);
        std.c.free(@ptrCast(mpy_buf.?));
        if (pyerr.pending_exc != 0) return error.PyRaise;

        // MINIMUM-level mp_obj_new_code (objcode.h:42).
        return newCodeMinimum(mp_make_function_from_proto_fun(@intFromPtr(cm.rc), cm.context, null));
    }
} else struct {
    pub fn impl(
        src: [*]const u8,
        src_len: usize,
        source_file: Qstr,
        parse_input_kind: c_int,
    ) PyError!Obj {
        _ = .{ src, src_len, source_file, parse_input_kind };
        unreachable; // nano: builtinevex.zig comptime-gates the caller
    }
};

pub export fn npy_zig_compile_to_code(
    src: [*c]const u8,
    src_len: usize,
    source_file: Qstr,
    parse_input_kind: c_int,
) callconv(.c) Obj {
    return pyerr.bridge(Obj, compile_to_code_glue.impl(@ptrCast(src), src_len, source_file, parse_input_kind));
}

comptime {
    _ = &npy_zig_compile_source;
    _ = &npy_zig_eval_exec;
    _ = &npy_zig_compile_to_code;
}
