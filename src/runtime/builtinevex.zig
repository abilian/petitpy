//! nanopython — Zig port of py/builtinevex.c (Axis-B B1.5 W3; notes/11).
//!
//! Nano config (probed): MICROPY_PY_BUILTINS_COMPILE=0,
//! MICROPY_PY_BUILTINS_EXECFILE=0, MICROPY_PY_BUILTINS_EVAL_EXEC=1.
//! ⇒ the C `code`/`compile` block (~100 LOC) is dead, the `execfile`
//! branch is dead; the only LIVE algorithm is eval_exec_helper + the
//! 2 thin wrappers mp_builtin_eval / mp_builtin_exec (~30 LOC).
//!
//! Faithful: the `for i in 1..3 && i<n_args` loop pattern with the
//! `i==1 → globals = locals` shadowing is preserved exactly. Dict
//! type-check raises TypeError(NULL) via the PyError convention
//! (notes/11). The MP_QSTR__lt_string_gt_ filename is folded into
//! the shim's npy_evex_lexer_new_from_str. The const fn_obj wrappers
//! (MP_DEFINE_CONST_FUN_OBJ_VAR_BETWEEN) stay in the shim — Zig only
//! defines the body of the 2 callable symbols + the helper.

const mp = @cImport({
    @cInclude("py/parse.h");
});
const mirrors = @import("../mp_mirrors.zig");
const pyerr = @import("../pyerr.zig");
const build_options = @import("build_options");
const PyError = pyerr.PyError;

const Obj = mirrors.Obj;
const ParseKind = c_int;

// Direct extern decls (replacing the npy_evex_* C-shim helpers).
extern fn mp_obj_new_exception(t: *const anyopaque) callconv(.c) Obj;
// `mp_get_buffer_raise` is static-inline (obj.h:631) — port body:
// just calls `mp_get_buffer` (real extern) with the RAISE flag OR'd in.
extern fn mp_get_buffer(o: Obj, bufinfo: *anyopaque, flags: c_uint) callconv(.c) bool;
inline fn getBufferRaise(o: Obj, bufinfo: *MpBufferInfo, flags: c_uint) void {
    _ = mp_get_buffer(o, @ptrCast(bufinfo), flags | 4); // MP_BUFFER_RAISE_IF_UNSUPPORTED
}
extern const mp_type_TypeError: anyopaque;
extern const mp_type_ValueError: anyopaque;
extern const mp_type_dict: anyopaque;
extern const mp_type_fun_builtin_var: anyopaque;
extern fn mp_obj_new_exception_msg(t: *const anyopaque, msg: [*:0]const u8) callconv(.c) Obj;

// COMPILE path (FULL only). Under nano these branches are dead via
// the `comptime build_options.is_full` gate at the call site. Full
// mirrors mp_obj_code_t at the MINIMUM level (16 bytes = base +
// module_fun) — MICROPY_PY_BUILTINS_CODE_MINIMUM because
// PY_SYS_SETTRACE=0 and PY_FUNCTION_ATTRS_CODE=0 (port/mpconfigport.h).
const MpObjCodeMinimum = extern struct {
    base: mirrors.MpObjBase,
    module_fun: Obj,
};

extern const mp_type_code: anyopaque;
extern const mp_type_fun_bc: anyopaque;
extern fn mp_call_function_0(fun: Obj) callconv(.c) Obj;

inline fn objIsCode(o: Obj) bool {
    if (comptime !build_options.is_full) return false;
    return mirrors.isExactType(o, &mp_type_code);
}

// Vendor py/builtinevex.c:37-78 at MICROPY_PY_BUILTINS_CODE_MINIMUM.
// The vendor uses nlr_push_jump_callback to restore globals/locals on
// unwind; Zig `defer` covers both return paths.
fn codeExecute(code_in: Obj, globals: ?*anyopaque, locals: ?*anyopaque) PyError!Obj {
    const code: *MpObjCodeMinimum = @ptrFromInt(code_in);

    const saved_globals = mirrors.mp_state_ctx.thread.dict_globals;
    const saved_locals = mirrors.mp_state_ctx.thread.dict_locals;
    defer {
        mirrors.mp_state_ctx.thread.dict_globals = saved_globals;
        mirrors.mp_state_ctx.thread.dict_locals = saved_locals;
    }
    mirrors.mp_state_ctx.thread.dict_globals = globals;
    mirrors.mp_state_ctx.thread.dict_locals = locals;

    // Vendor: mp_builtin_compile passes NULL for the module's globals
    // slot at compile time; patch it now with the caller's globals so
    // load_global resolves against the correct dict.
    const module_fun = code.module_fun;
    if (mirrors.isExactType(module_fun, &mp_type_fun_bc)) {
        const fun_bc = mirrors.MpObjFunBc.fromObj(module_fun);
        const ctx_ptr: *mirrors.MpModuleContext = @ptrCast(@alignCast(@constCast(fun_bc.context.?)));
        @as(*?*anyopaque, @ptrCast(&ctx_ptr.module.globals)).* = globals;
    }

    const result = mp_call_function_0(module_fun);
    if (pyerr.pending_exc != 0) return error.PyRaise;
    return result;
}

// MICROPY_BUFFER_READ constant (vendor obj.h:622).
const MP_BUFFER_READ: c_uint = 1;

// mp_buffer_info_t layout (obj.h:616): { void *buf; size_t len; int typecode }.
const MpBufferInfo = extern struct {
    buf: ?*anyopaque,
    len: usize,
    typecode: c_int,
};

fn raiseTypeErrorNull() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception(&mp_type_TypeError);
    return error.PyRaise;
}

fn raiseBadCompileMode() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_ValueError, "bad compile mode");
    return error.PyRaise;
}

// source_file is `Qstr = usize` (matches the definition in zig_compile_bridge.zig).
// Declaring it as `u16` here was tolerated by amd64 (low bits of the arg register
// align by accident) but traps on wasm32's strict typed-call discipline. Same
// class-of-bug closed during v0.5 for mp_errno_to_str + mp_obj_fun_get_name.
extern fn npy_zig_eval_exec(src: [*c]const u8, src_len: usize, source_file: usize, parse_input_kind: c_int, globals: ?*anyopaque, locals: ?*anyopaque) callconv(.c) Obj;

fn evalExecHelperImpl(n_args: usize, args: [*c]const Obj, parse_input_kind: ParseKind) PyError!Obj {
    // Work out the context. mp_globals_get / mp_locals_get are
    // static-inline; the MpStateThread mirror exposes the same fields.
    var globals: ?*anyopaque = mirrors.mp_state_ctx.thread.dict_globals;
    var locals: ?*anyopaque = mirrors.mp_state_ctx.thread.dict_locals;
    var i: usize = 1;
    while (i < 3 and i < n_args) : (i += 1) {
        if (args[i] != mirrors.OBJ_NONE) {
            if (!mirrors.isExactType(args[i], &mp_type_dict)) try raiseTypeErrorNull();
            locals = mirrors.objToPtr(args[i]);
            if (i == 1) globals = locals;
        }
    }
    // BUILTINS_COMPILE (full only): code-object fast path.
    if (comptime build_options.is_full) {
        if (objIsCode(args[0])) {
            return try codeExecute(args[0], globals, locals);
        }
    }
    // (EXECFILE=0 → the file-input branch is dead; always str_len path)
    //
    // Still routed through the legacy frontend (mp_parse + mp_compile)
    // for now. Stage 3b retry needs our compiler to detect malformed
    // tokens (`123z`, `'abc`-unterminated, etc.) that surface only
    // through eval/exec test fixtures — bug present today, not a
    // regression. See notes/33 Stage 3b.
    var bufinfo: MpBufferInfo = undefined;
    getBufferRaise(args[0], &bufinfo, MP_BUFFER_READ);
    return npy_zig_eval_exec(@ptrCast(bufinfo.buf), bufinfo.len, qstrs.MP_QSTR__lt_string_gt_, parse_input_kind, globals, locals);
}

export fn mp_builtin_eval(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, evalExecHelperImpl(n_args, args, mp.MP_PARSE_EVAL_INPUT));
}

export fn mp_builtin_exec(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, evalExecHelperImpl(n_args, args, mp.MP_PARSE_FILE_INPUT));
}

// ── mp_builtin_compile — routes through the Zig compiler bridge.
//
// Under FULL (build_options.is_full=true), the compile() builtin calls
// npy_zig_compile_to_code (src/runtime/zig_compile_bridge.c) which
// compiles source bytes via the pure-Zig pipeline and wraps the result
// as an mp_obj_code_t. Under nano (BUILTINS_COMPILE=0) the shim's
// MP_DEFINE_CONST_FUN_OBJ_VAR_BETWEEN is #if-dead, so the else-branch
// `unreachable` is never hit.

extern fn mp_obj_str_get_data(obj: Obj, len_out: *usize) callconv(.c) [*c]const u8;
extern fn mp_obj_str_get_qstr(obj: Obj) callconv(.c) usize;
extern fn npy_zig_compile_to_code(src: [*c]const u8, src_len: usize, source_file: usize, parse_input_kind: c_int) callconv(.c) Obj;

// Qstr enum constants (genhdr/qstrdefs.generated.h — pulled via @cImport).
const qstrs = @cImport({
    @cInclude("py/qstr.h");
});

// The body is gated by comptime is_full: under nano (COMPILE=0) the
// is_full branch's extern reference to npy_zig_compile_to_code stays
// out of the link graph via the if-comptime selector.
const compile_glue = if (build_options.is_full) struct {
    pub fn impl(n_args: usize, args: [*c]const Obj) PyError!Obj {
        _ = n_args;
        var str_len: usize = 0;
        const str = mp_obj_str_get_data(args[0], &str_len);
        const filename = mp_obj_str_get_qstr(args[1]);
        const mode = mp_obj_str_get_qstr(args[2]);
        const parse_input_kind: c_int = if (mode == qstrs.MP_QSTR_single)
            mp.MP_PARSE_SINGLE_INPUT
        else if (mode == qstrs.MP_QSTR_exec)
            mp.MP_PARSE_FILE_INPUT
        else if (mode == qstrs.MP_QSTR_eval)
            mp.MP_PARSE_EVAL_INPUT
        else blk: {
            try raiseBadCompileMode();
            break :blk 0;
        };
        return npy_zig_compile_to_code(str, str_len, filename, parse_input_kind);
    }
} else struct {
    pub fn impl(n_args: usize, args: [*c]const Obj) PyError!Obj {
        _ = .{ n_args, args };
        unreachable; // shim's MP_DEFINE_CONST_FUN_OBJ_VAR_BETWEEN is #if-dead under nano
    }
};

export fn mp_builtin_compile(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, compile_glue.impl(n_args, args));
}

// ROM const fun-obj exports — replace the C-side MP_DEFINE_CONST_FUN_OBJ_VAR_BETWEEN
// macros (builtinevex_shim.c:24,25,101). Same layout via MpObjFunBuiltinVar mirror.
pub export const mp_builtin_eval_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(1, 3, false),
    .fun = @ptrCast(&mp_builtin_eval),
};
pub export const mp_builtin_exec_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(1, 3, false),
    .fun = @ptrCast(&mp_builtin_exec),
};
// `mp_builtin_compile_obj` lives only under FULL (MICROPY_PY_BUILTINS_COMPILE=1).
// Emit unconditionally — under nano the symbol is exported but unreferenced
// (the shim that used to gate it via `#if MICROPY_PY_BUILTINS_COMPILE` is gone).
pub export const mp_builtin_compile_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(3, 6, false),
    .fun = @ptrCast(&mp_builtin_compile),
};

comptime {
    _ = &mp_builtin_eval;
    _ = &mp_builtin_exec;
    _ = &mp_builtin_compile;
    _ = &mp_builtin_eval_obj;
    _ = &mp_builtin_exec_obj;
    _ = &mp_builtin_compile_obj;
}
