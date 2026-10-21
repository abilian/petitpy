//! VM-only entry — load a .mpy buffer and execute its top-level function.
//!
//! Mirrors the post-compile half of `runtime/zig_compile_bridge.zig`'s
//! `compileAndLoad` (lines 134-168): allocate an `MpCompiledModule`,
//! point its `module` at the active globals, call `mp_raw_code_load_mem`
//! (Zig-side persistentcode loader), then build a function-obj via
//! `mp_make_function_from_proto_fun` and call it with `mp_call_function_0`.
//!
//! No compile step — the caller has already produced bytecode out-of-band
//! (via `zigpy-compile`). Used by `src/main_vm.zig` to build the VM-only
//! `nanopython-vm` binary that excludes the compiler track from the link.

const std = @import("std");
const mirrors = @import("../mp_mirrors.zig");
const pyerr = @import("../pyerr.zig");
const systemexit = @import("systemexit.zig");
const gc = @import("../memory/gc.zig");

const Obj = mirrors.Obj;

// Persistent-code loader — Zig-side as of NX-1 (persistentcode.zig).
extern fn mp_raw_code_load_mem(buf: [*]const u8, len: usize, cm: *mirrors.MpCompiledModule) callconv(.c) void;
extern fn mp_make_function_from_proto_fun(proto: usize, ctx: ?*const anyopaque, defargs: [*c]const Obj) callconv(.c) Obj;
extern fn mp_call_function_0(fun: Obj) callconv(.c) Obj;
extern fn m_malloc(num_bytes: usize) callconv(.c) ?*anyopaque;

extern fn mp_globals_get() callconv(.c) ?*anyopaque;
extern const mp_type_module: anyopaque;

extern fn mp_obj_print_exception(print: *const anyopaque, exc: Obj) callconv(.c) void;
extern const mp_plat_print: anyopaque;

const PyError = error{PyRaise};

fn runMpyImpl(buf: [*]const u8, len: usize) PyError!void {
    var cm: mirrors.MpCompiledModule = undefined;
    const ctx: *mirrors.MpModuleContext = @ptrCast(@alignCast(m_malloc(@sizeOf(mirrors.MpModuleContext)).?));
    cm.context = ctx;
    ctx.module.base.type = @ptrCast(&mp_type_module);
    ctx.module.globals = @ptrCast(@alignCast(mp_globals_get().?));

    pyerr.pending_exc = 0;
    mp_raw_code_load_mem(buf, len, &cm);
    if (pyerr.pending_exc != 0) return error.PyRaise;

    const module_fun = mp_make_function_from_proto_fun(@intFromPtr(cm.rc), cm.context, null);
    _ = mp_call_function_0(module_fun);
    if (pyerr.pending_exc != 0) return error.PyRaise;
}

/// Load + execute an in-memory .mpy. Exit-code contract matches
/// `npy_embed_exec_str_zig` in embed_exec.zig:
///   0  — clean, or SystemExit() / SystemExit(None) / SystemExit(0)
///   1  — uncaught non-SystemExit exception (traceback printed), or
///        SystemExit with a non-int arg
///   N  — SystemExit(N) for int N (low 8 bits)
///
/// SystemExit is suppressed rather than printed, per CPython: the
/// `except: print("SKIP"); raise SystemExit` skip idiom must exit quietly.
pub export fn npy_embed_run_mpy(buf: [*]const u8, len: usize) callconv(.c) c_int {
    gc.enterPython();
    defer gc.leavePython(); // a safe point on wasm (memory/gc.zig)
    var status: c_int = 0;
    runMpyImpl(buf, len) catch {
        const raw: Obj = pyerr.pending_exc;
        pyerr.pending_exc = 0;
        if (raw != 0) {
            const exc: ?*anyopaque = @ptrFromInt(raw);
            if (systemexit.isSystemExit(exc)) {
                status = systemexit.exitCode(exc);
            } else {
                mp_obj_print_exception(&mp_plat_print, raw);
                status = 1;
            }
        } else {
            status = 1;
        }
    };
    return status;
}
