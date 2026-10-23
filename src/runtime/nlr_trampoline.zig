// ADR 013 — NLR trampoline Zig bindings.
//
// The setjmp/longjmp side lives in src/runtime/nlr_trampoline.c (C
// keeps the setjmp call directly in the lexical scope of the local
// nlr_buf, which Zig's "returns twice" semantics make awkward). This
// file exports Zig accessors that the C trampoline calls back into
// (nlr_top getter/setter on mp_state_ctx.thread), and re-exports the
// C trampoline functions as Zig-callable wrappers.

const build_options = @import("build_options");
const mirrors = @import("../mp_mirrors.zig");
const pyerr = @import("../pyerr.zig");

const Obj = mirrors.Obj;

// ── Accessors called from C trampoline ──────────────────────────────

export fn npy_nlr_top_get() callconv(.c) ?*anyopaque {
    return mirrors.mp_state_ctx.thread.nlr_top;
}

export fn npy_nlr_top_set(top: ?*anyopaque) callconv(.c) void {
    mirrors.mp_state_ctx.thread.nlr_top = top;
}

// ── C trampoline entrypoints (defined in nlr_trampoline.c) ──────────

extern fn npy_nlr_call_binary_op(
    fn_ptr: ?*const anyopaque,
    op: c_int,
    lhs: Obj,
    rhs: Obj,
) callconv(.c) Obj;

extern fn npy_nlr_call_pow3(
    fn_ptr: ?*const anyopaque,
    base: Obj,
    exp: Obj,
    mod: Obj,
) callconv(.c) Obj;

extern fn npy_nlr_call_function(
    fn_ptr: ?*const anyopaque,
    fun_in: Obj,
    n_args: usize,
    n_kw: usize,
    args: [*c]const Obj,
) callconv(.c) Obj;

extern fn npy_nlr_call_ctx(
    fn_ptr: *const fn (?*anyopaque) callconv(.c) void,
    ctx: ?*anyopaque,
) callconv(.c) void;

extern fn npy_nlr_jump(exc: Obj) callconv(.c) noreturn;

// ── Zig wrappers — call these from runtime dispatch sites ───────────

pub fn callBinaryOp(
    fn_ptr: mirrors.MpBinaryOpFun,
    op: c_int,
    lhs: Obj,
    rhs: Obj,
) Obj {
    if (comptime !build_options.exception_unwind) {
        return fn_ptr(op, lhs, rhs);
    }
    return npy_nlr_call_binary_op(@ptrCast(fn_ptr), op, lhs, rhs);
}

pub fn callPow3(
    fn_ptr: *const fn (Obj, Obj, Obj) callconv(.c) Obj,
    base: Obj,
    exp: Obj,
    mod: Obj,
) Obj {
    if (comptime !build_options.exception_unwind) {
        return fn_ptr(base, exp, mod);
    }
    return npy_nlr_call_pow3(@ptrCast(fn_ptr), base, exp, mod);
}

pub fn callFunction(
    fn_ptr: mirrors.MpCallFun,
    fun_in: Obj,
    n_args: usize,
    n_kw: usize,
    args: [*c]const Obj,
) Obj {
    if (comptime !build_options.exception_unwind) {
        return fn_ptr(fun_in, n_args, n_kw, args);
    }
    return npy_nlr_call_function(@ptrCast(fn_ptr), fun_in, n_args, n_kw, args);
}

pub fn callCtx(fn_ptr: *const fn (?*anyopaque) callconv(.c) void, ctx: ?*anyopaque) void {
    if (comptime !build_options.exception_unwind) return fn_ptr(ctx);
    npy_nlr_call_ctx(fn_ptr, ctx);
}

// ── Raise side: longjmp into the registered handler if one exists ───

pub fn raiseViaLongjmp(exc: Obj) noreturn {
    // Caller must have already set pyerr.pending_exc = exc before invoking
    // (so that even if no nlr_top is registered, fallback path sees it).
    npy_nlr_jump(exc);
}

pub fn hasActiveHandler() bool {
    if (comptime !build_options.exception_unwind) return false;
    return mirrors.mp_state_ctx.thread.nlr_top != null;
}
