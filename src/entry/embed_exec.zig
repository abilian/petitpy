//! nanopython — the top-level exec HOST in Zig.
//!
//! Replaces `mp_embed_exec_str`'s C `if (nlr_push(&nlr) == 0) {body} else
//! {print exc}` with:
//!   - a Zig error `error.PyRaise`
//!   - a module-level `pending_exc` carrying the exception object
//!   - the host catching with `catch` instead of an nlr `else` branch.
//!
//! NX-3 N4 (2026-06-05): npy_nlr_run wrap dropped — no Zig code longjmps
//! under nano (m_malloc_fail is polled) and no vendor C is in the build,
//! so the setjmp landing pad is dead code. Compile + call run directly;
//! raises arrive via pyerr.pending_exc. Also absorbs the tiny vendor-fn
//! wrappers (npy_print_exc, npy_exc_is_system_exit, npy_repl_exec_line)
//! from src/runtime/nlr_trampoline.c so the .c file can be deleted.

const mirrors = @import("../mp_mirrors.zig");
const pyerr = @import("../pyerr.zig");
const systemexit = @import("systemexit.zig");
const gc = @import("../memory/gc.zig");
const build_options = @import("build_options");
const std = @import("std");

const PyError = error{PyRaise};

const Obj = usize;
extern fn mp_obj_exception_get_value(self_in: Obj) callconv(.c) Obj;

// mp_const_none is a vendor macro, not a linkable symbol: under
// MICROPY_OBJ_REPR_A (our setting throughout the codebase — same as
// mirrors.smallIntValue's shift assumption) it expands to
// `MP_OBJ_NEW_IMMEDIATE_OBJ(0)` = `(0 << 3) | 6` = 6. The vendor
// definition is in sandbox/micropython/py/obj.h:102 + :915.
const MP_CONST_NONE: Obj = 0x06;
// Matches C `qstr` (= size_t per qstr.h:60) and the export declaration in
// src/runtime/zig_compile_bridge.zig. Using u16 here causes the Zig linker
// to detect the type mismatch and emit a "bitcast_invalid" stub instead of
// the real function — fatal on wasm32 where u16 and usize have different
// wire widths (i32 always, but the LLVM type system tracks them apart).
const Qstr = usize;

// mp_parse_input_kind_t enum (vendor py/parse.h):
//   SINGLE_INPUT=0, FILE_INPUT=1, EVAL_INPUT=2
const MP_PARSE_FILE_INPUT: c_int = 1;
const MP_PARSE_SINGLE_INPUT: c_int = 0;

extern fn npy_zig_compile_source(
    src: [*]const u8,
    src_len: usize,
    source_file: Qstr,
    parse_input_kind: c_int,
) callconv(.c) Obj;
extern fn mp_call_function_0(fun: Obj) callconv(.c) Obj;

// Vendor symbols used by the (replaces nlr_trampoline.c's tiny wrappers).
extern fn mp_obj_print_exception(print: *const anyopaque, exc: Obj) callconv(.c) void;
extern fn mp_obj_is_subclass_fast(t: Obj, classinfo: Obj) callconv(.c) bool;
extern const mp_type_SystemExit: anyopaque;

// mp_obj_base_t mirror; base->type is the head field. Used to extract
// the type pointer from an exception instance for SystemExit detection.
const MpObjBase = extern struct { type: ?*const anyopaque };

const mp_qstrs = @cImport({
    @cInclude("py/qstr.h");
});

extern const mp_stderr_print: anyopaque;
extern fn fflush(stream: ?*anyopaque) callconv(.c) c_int;

// An uncaught exception goes to stderr, as CPython and vendor's unix port
// print it, after flushing stdout: print() on full writes through libc's
// buffered stdout, and a traceback written straight to fd 1 came out
// before the program's earlier output when stdout was a pipe.
fn printExc(exc: ?*anyopaque) void {
    if (exc) |e| {
        _ = fflush(null);
        mp_obj_print_exception(&mp_stderr_print, @intFromPtr(e));
    }
}

/// Replaces `nlr_top->ret_val`. Not `threadlocal`: the GC's root scan
/// covers the data segment, not thread-local storage, and printExc
/// allocates while this holds the only guaranteed reference. No threads
/// today (see pyerr.pending_exc).
var pending_exc: ?*anyopaque = null;

fn execProtected(src: [*:0]const u8) PyError!void {
    pyerr.pending_exc = 0;
    const len = std.mem.len(src);
    const module_fun = npy_zig_compile_source(src, len, mp_qstrs.MP_QSTR__lt_stdin_gt_, MP_PARSE_FILE_INPUT);
    if (pyerr.pending_exc != 0) {
        pending_exc = @ptrFromInt(pyerr.pending_exc);
        pyerr.pending_exc = 0;
        return error.PyRaise;
    }
    _ = mp_call_function_0(module_fun);
    if (pyerr.pending_exc != 0) {
        pending_exc = @ptrFromInt(pyerr.pending_exc);
        pyerr.pending_exc = 0;
        return error.PyRaise;
    }
}

/// Drop-in for the C `mp_embed_exec_str`. main.zig calls this and uses
/// the return value as the process exit code:
///   0  — clean exit (no exception, or SystemExit() / SystemExit(None) /
///        SystemExit(0))
///   1  — uncaught non-SystemExit exception (traceback already printed)
///        or SystemExit with a non-int arg
///   N  — SystemExit(N) where N is an int (lower 8 bits)
export fn npy_embed_exec_str_zig(src: [*:0]const u8) callconv(.c) c_int {
    gc.enterPython();
    defer gc.leavePython(); // a safe point on wasm (memory/gc.zig)
    var status: c_int = 0;
    execProtected(src) catch {
        // Suppress traceback for SystemExit on both nano and full —
        // CPython convention (`sys.exit()` / `raise SystemExit` should
        // exit silently). Previously gated on `is_full`, leaving nano
        // showing 'Traceback (most recent call last):\n  File "<stdin>",
        // in <module>\nSystemExit:' for the common
        //   try: x
        //   except: print("SKIP"); raise SystemExit
        // skip pattern — 45 programs in golden-programs/needs-stdlib
        // and 48 corpus tests trip on this.
        if (systemexit.isSystemExit(pending_exc)) {
            status = systemexit.exitCode(pending_exc);
        } else {
            printExc(pending_exc);
            status = 1;
        }
        pending_exc = null;
    };
    return status;
}

/// REPL: compile + call src in PARSE_SINGLE_INPUT mode (bare expressions
/// echo). Returns 0 on clean completion, 1 on raise (printed). main.zig's
/// REPL loop calls this for each accumulated statement.
export fn npy_repl_exec_line(src: [*:0]const u8) callconv(.c) c_int {
    gc.enterPython();
    defer gc.leavePython(); // a safe point on wasm (memory/gc.zig)
    pyerr.pending_exc = 0;
    const len = std.mem.len(src);
    const module_fun = npy_zig_compile_source(src, len, mp_qstrs.MP_QSTR__lt_stdin_gt_, MP_PARSE_SINGLE_INPUT);
    if (pyerr.pending_exc != 0) {
        const exc: ?*anyopaque = @ptrFromInt(pyerr.pending_exc);
        pyerr.pending_exc = 0;
        printExc(exc);
        return 1;
    }
    _ = mp_call_function_0(module_fun);
    if (pyerr.pending_exc != 0) {
        const exc: ?*anyopaque = @ptrFromInt(pyerr.pending_exc);
        pyerr.pending_exc = 0;
        printExc(exc);
        return 1;
    }
    return 0;
}
