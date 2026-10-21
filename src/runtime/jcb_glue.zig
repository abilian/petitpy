// zigonly Phase 2 — NLR jump-callback glue (npy_rt_jcb_* family).
//
// vendor py/runtime.c defines tiny wrappers that read func+arg from a
// callback node struct and dispatch. Phase 1 stubbed these as panics;
// real implementations are straight struct field reads.

// Struct layouts mirror vendor py/runtime.h:84-95 — first 16 bytes are
// the nlr_jump_callback_node_t base (prev + fun).

const CallbackNodeCallFn1 = extern struct {
    base_prev: ?*anyopaque,
    base_fun: ?*anyopaque,
    func: *const fn (?*anyopaque) callconv(.c) void,
    arg: ?*anyopaque,
};

const CallbackNodeGlobalsLocals = extern struct {
    base_prev: ?*anyopaque,
    base_fun: ?*anyopaque,
    globals: ?*anyopaque,
    locals: ?*anyopaque,
};

// mp_globals_set / mp_locals_set are static-inline in vendor/py/mpstate.h
// (translate-c skips them). Implement here as plain field writes on the
// mp_state_ctx mirror — same effect as the macros MP_STATE_THREAD(dict_*)=...

const state = @import("mpstate.zig");

pub export fn mp_globals_set(globals: ?*anyopaque) void {
    state.mp_state_ctx.thread.dict_globals = globals;
}

pub export fn mp_locals_set(locals: ?*anyopaque) void {
    state.mp_state_ctx.thread.dict_locals = locals;
}

pub export fn mp_globals_get() ?*anyopaque {
    return state.mp_state_ctx.thread.dict_globals;
}

pub export fn mp_locals_get() ?*anyopaque {
    return state.mp_state_ctx.thread.dict_locals;
}

// jcb dispatchers removed — runtime_shim.c (C carveout) provides them.
