// ADR 013 — NLR carveout trampoline. Native-only setjmp pad for wrapping
// vendor-C entry points that raise via the NLR convention (mp_raise_msg /
// mp_raise_ValueError / mp_raise_OSError / etc.).
//
// The strangler removed NLR entirely; nano runs on polled-sentinel
// (pyerr.pending_exc set + return, caller polls). Vendor C raise helpers
// in objint_mpz.c / mpz.c / modio.c / modre.c assume NLR will unwind
// back to a registered handler. Without NLR they'd hit longlongRaiseDie's
// exit(1) and bypass Python try/except.
//
// This trampoline restores a SCOPED NLR pad (only around enumerated wrap
// points) and converts the longjmp into the polled-sentinel pattern the
// rest of nano speaks. Native-only — wasi-libc setjmp.h #errors out per
// the 2026-06-13 spike documented in ADR 013 §6.
//
// The file is compiled into every link, because the Zig side declares its
// entry points `extern` and emits references to them even from
// comptime-dead branches. Only the setjmp/longjmp pad is conditional:
// build.zig defines NPY_EXCEPTION_UNWIND exactly where
// build_options.exception_unwind is true (full + native). Without it the
// wrappers below are plain forwarding calls, matching what the Zig
// wrappers comptime-collapse to. This is not an optimisation — wasi-libc
// has no longjmp symbol, so the pad cannot link on wasm at any -O level.

// glibc declares _longjmp only outside strict C99 (the build's -std=c99).
#define _DEFAULT_SOURCE
#include <stddef.h>

#ifdef NPY_EXCEPTION_UNWIND
#include <setjmp.h>

// nlr_buf_t mirror — must match vendor py/nlr.h:115 layout exactly
// (MICROPY_NLR_SETJMP=1, MICROPY_ENABLE_PYSTACK=0 in port/mpconfigport.h).
struct nlr_buf {
    struct nlr_buf *prev;
    void *ret_val;
    jmp_buf jmpbuf;
};
#endif // NPY_EXCEPTION_UNWIND

// Externs from Zig side (mp_state_ctx.thread.nlr_top at byte offset 32 of
// StateThread per mpstate.zig:248). Use accessor function rather than
// direct struct access so we don't depend on the StateCtx layout being
// exactly @cInclude'able.
extern void *npy_nlr_top_get(void);
extern void npy_nlr_top_set(void *top);
extern void npy_pyerr_set_pending(unsigned long exc);

// Call signatures we wrap. Add more as new wrap sites need them.
typedef unsigned long obj_t;
typedef obj_t (*binary_op_fn_t)(int op, obj_t lhs, obj_t rhs);
typedef obj_t (*pow3_fn_t)(obj_t base, obj_t exp, obj_t mod);

// Generic invocation pattern — duplicated per arity below to keep the
// setjmp call directly in the lexical scope of the local nlr_buf (vendor
// MP's nlr_push macro does the same — setjmp MUST run in the caller's
// stack frame to capture it).

#ifdef NPY_EXCEPTION_UNWIND
obj_t npy_nlr_call_binary_op(binary_op_fn_t fn, int op, obj_t lhs, obj_t rhs) {
    struct nlr_buf buf;
    buf.prev = (struct nlr_buf *)npy_nlr_top_get();
    buf.ret_val = NULL;
    if (_setjmp(buf.jmpbuf) == 0) {
        npy_nlr_top_set(&buf);
        obj_t result = fn(op, lhs, rhs);
        npy_nlr_top_set(buf.prev);
        return result;
    } else {
        // longjmp arrived — vendor C raised. Convert to polled-sentinel.
        npy_nlr_top_set(buf.prev);
        if (buf.ret_val != NULL) {
            npy_pyerr_set_pending((unsigned long)buf.ret_val);
        }
        return 0; // MP_OBJ_NULL — caller polls pending_exc
    }
}
#else
obj_t npy_nlr_call_binary_op(binary_op_fn_t fn, int op, obj_t lhs, obj_t rhs) {
    return fn(op, lhs, rhs);
}
#endif

#ifdef NPY_EXCEPTION_UNWIND
obj_t npy_nlr_call_pow3(pow3_fn_t fn, obj_t base, obj_t exp, obj_t mod) {
    struct nlr_buf buf;
    buf.prev = (struct nlr_buf *)npy_nlr_top_get();
    buf.ret_val = NULL;
    if (_setjmp(buf.jmpbuf) == 0) {
        npy_nlr_top_set(&buf);
        obj_t result = fn(base, exp, mod);
        npy_nlr_top_set(buf.prev);
        return result;
    } else {
        npy_nlr_top_set(buf.prev);
        if (buf.ret_val != NULL) {
            npy_pyerr_set_pending((unsigned long)buf.ret_val);
        }
        return 0;
    }
}
#else
obj_t npy_nlr_call_pow3(pow3_fn_t fn, obj_t base, obj_t exp, obj_t mod) {
    return fn(base, exp, mod);
}
#endif

// CALL_FUNCTION funnel — wraps the type's `.call` slot dispatch in
// mp_call_function_n_kw. Every Python call goes through this funnel, so
// any vendor-C raise (StringIO closed-file ValueError, MPZ to_bytes
// OverflowError, builtin int(...) TypeError, etc.) unwinds back into
// the polled-sentinel pattern instead of exit(1)ing past try/except.
// Cost: one _setjmp per Python call. _setjmp, not setjmp: setjmp also
// saves the signal mask, a system call on macOS that made every call ~8x
// slower. Nothing here changes the mask, so there is nothing to restore.
typedef obj_t (*call_fn_t)(obj_t fun_in, unsigned long n_args, unsigned long n_kw, const obj_t *args);

#ifdef NPY_EXCEPTION_UNWIND
obj_t npy_nlr_call_function(call_fn_t fn, obj_t fun_in, unsigned long n_args, unsigned long n_kw, const obj_t *args) {
    struct nlr_buf buf;
    buf.prev = (struct nlr_buf *)npy_nlr_top_get();
    buf.ret_val = NULL;
    if (_setjmp(buf.jmpbuf) == 0) {
        npy_nlr_top_set(&buf);
        obj_t result = fn(fun_in, n_args, n_kw, args);
        npy_nlr_top_set(buf.prev);
        return result;
    } else {
        npy_nlr_top_set(buf.prev);
        if (buf.ret_val != NULL) {
            npy_pyerr_set_pending((unsigned long)buf.ret_val);
        }
        return 0;
    }
}
#else
obj_t npy_nlr_call_function(call_fn_t fn, obj_t fun_in, unsigned long n_args, unsigned long n_kw, const obj_t *args) {
    return fn(fun_in, n_args, n_kw, args);
}
#endif

// Counterpart called by the raise side to perform the longjmp. Vendor C
// raise helpers call this through the Zig-side longlongRaiseDie when an
// nlr_top is registered.
#ifdef NPY_EXCEPTION_UNWIND
void npy_nlr_jump(unsigned long exc) {
    struct nlr_buf *top = (struct nlr_buf *)npy_nlr_top_get();
    if (top == NULL) {
        // No handler — shouldn't be called in this state; raise.zig checks
        // first and falls back to exit(1). Defensive.
        return;
    }
    top->ret_val = (void *)exc;
    _longjmp(top->jmpbuf, 1);
}
#else
void npy_nlr_jump(unsigned long exc) {
    // Unreachable: hasActiveHandler() is comptime-false without the pad, so
    // raise.zig never routes here. Zig declares this symbol `noreturn`, so
    // trap rather than return.
    (void)exc;
    __builtin_trap();
}
#endif
