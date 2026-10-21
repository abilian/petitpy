# PyError Convention

`pyerr.PyError` is the Zig error type that replaced MicroPython's `setjmp`/`longjmp`-based NLR (non-local return). It's the convention every Zig fn that can raise a Python exception must use.

## The full type

```zig
pub const PyError = error{PyRaise};
pub threadlocal var pending_exc: usize = 0;

pub inline fn bridge(comptime T: type, r: PyError!T) T {
    return r catch {
        return std.mem.zeroes(T);
    };
}
```

That's it. Three declarations in `src/pyerr.zig`. The simplicity is intentional: the error union is Zig-idiomatic, the threadlocal holds the exception object, the bridge converts between the two at C-ABI boundaries.

## The propagation pattern

Inside Zig code:

```zig
fn computeImpl(arg: Obj) PyError!Obj {
    if (bad(arg)) try raiseTypeErrorBadArg();
    return doWork(arg);
}

fn raiseTypeErrorBadArg() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_TypeError, "bad arg");
    return error.PyRaise;
}
```

At C-ABI export boundaries, the bridge converts:

```zig
pub export fn npy_compute(arg: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, computeImpl(arg));
}
```

`pyerr.bridge` catches `error.PyRaise` and returns `std.mem.zeroes(Obj)` (which is `MP_OBJ_NULL` for the `Obj = usize` representation). The exception object is in `pyerr.pending_exc` for any C caller to poll.

## Why this replaces NLR

MicroPython uses a longjmp-based NLR. Every `mp_raise_*` macro is `noreturn` and calls `nlr_jump(exc)` which longjmps to the nearest `nlr_push` buffer. The protected regions are wrapped:

```c
nlr_buf_t nlr;
if (nlr_push(&nlr) == 0) {
    // protected body
    nlr_pop();
} else {
    // unwind path: nlr.ret_val is the exception
}
```

This is C-idiomatic but has costs:

- **Setjmp/longjmp is a stack-unwinding primitive that's hard to wrap in Zig.** Zig has no `setjmp.h`; bringing it in requires linking to libc and giving up on platforms like wasm32 (which lacks native setjmp).
- **No destructors fire on unwind.** Allocations between `nlr_push` and the raise are leaked.
- **The control flow is invisible to the type system.** Any C fn might longjmp; you can't tell from the signature.

Zig's error union gives all three:

- It's syntactically explicit (`return error.PyRaise`, `try`, `catch`).
- `defer` and `errdefer` run on unwind, so cleanup is automatic.
- Functions that can raise are typed as `PyError!T`; the type system enforces correct handling.

The transition (NX-3) took ~20 commits across 4 days of intensive work; see Strangler Journey § NX-3 (`strangler-journey.md`).

## The bridge mechanism in detail

`pyerr.bridge(T, r)` does two things:

1. If `r` is `T` (success), return it.
2. If `r` is `error.PyRaise`, return `std.mem.zeroes(T)`.

Critically, `pyerr.bridge` does NOT clear `pyerr.pending_exc`. The pending exception remains set after the bridge returns. This is intentional: C callers that don't yet know about the PyError convention can poll `pyerr.pending_exc` to detect the raise.

```zig
// Inside Zig
const result = pyerr.bridge(Obj, computeImpl(arg));
if (pyerr.pending_exc != 0) {
    // The bridge returned MP_OBJ_NULL because computeImpl raised.
    // pending_exc holds the exception object.
    pyerr.pending_exc = 0;  // claim it
    // ... handle the exception
}
```

Inside Zig (where the caller is also PyError-aware), the bridge isn't needed:

```zig
const result = try computeImpl(arg);  // propagates PyError
```

The mixed model (Zig callers using `try`, C-ABI exports using `bridge` + polled-sentinel) made the NX-3 transition incremental. Old C callers never had to change; new Zig callers got native error propagation.

## When bridge isn't enough

The bridge handles the simple case: function returns `T`; on raise, return zero. It does not cover two cases:

### `noreturn` exports

Some `pub export fn`s have `noreturn` signature (typically the `mp_raise_*` family that vendor C calls expecting longjmp). After NX-3, the remaining noreturn exports call `@panic` where they used to call `nlr_jump`:

```zig
pub export fn mp_raise_TypeError(msg: [*:0]const u8) callconv(.c) noreturn {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_TypeError, msg);
    @panic("TypeError raised — callers must convert to PyError before strangle completes");
}
```

This is acceptable for nano because the remaining callers are in dead-under-nano code paths (`file_io.zig`, `stream.zig`). Under full those modules would be live and would need PyError-style conversion; that's the full-arm rehab arc.

### `mp_obj_str_get_str` returning a pointer

`mp_obj_str_get_str` returns `?[*]const u8`, a nullable raw pointer. The bridge mechanism is built for zero-able value types; a nullable pointer needs a custom shape.

The convention (locked in NX-3 N4a) is:

```zig
pub export fn mp_obj_str_get_str(self_in: Obj) callconv(.c) ?[*]const u8 {
    // ... checks if self_in is str-or-bytes ...
    // On bad input: sets pyerr.pending_exc to TypeError, returns null.
    // On good input: returns pointer to byte data.
}
```

Callers must `orelse return error.PyRaise` (if PyError-aware) or check the null + `pyerr.pending_exc` themselves (if at a C-ABI boundary).

This is the closest equivalent to "PyError for fns that return pointers" the codebase has. It works because `?[*]const u8` is one machine word, so the C ABI is preserved.

## Polled sentinel: the bridge pattern's other half

When a Zig fn returns via `pyerr.bridge` and the C caller doesn't speak PyError, the caller polls:

```c
// In a hypothetical remaining C caller (vendor-style):
mp_obj_t result = npy_some_zig_fn(arg);
if (npy_pyerr_get_pending() != 0) {
    // A Zig raise happened; result is MP_OBJ_NULL.
    mp_obj_t exc = npy_pyerr_take_pending();
    // ... handle the exception (typically nlr_raise back, in old code)
}
```

The polled-sentinel accessors (`npy_pyerr_get_pending`, `npy_pyerr_take_pending`, `npy_pyerr_set_pending`) are exported from `pyerr.zig`. After NX-3, there are no C callers using them; the only remaining poll site is `zig_compile_bridge.zig` (Zig polling its own Zig exports after a bridge wrap).

These accessors are documented as "EXPERIMENTAL (deleted after B2 finalization)"; they'll go when no consumer remains.

## `errdefer` for allocator cleanup

Zig's `errdefer` is the strangler's answer to vendor's `nlr_push_jump_callback`. In MicroPython:

```c
nlr_jump_callback_node_globals_locals_t ctx;
ctx.globals = mp_globals_get();
ctx.locals = mp_locals_get();
mp_globals_set(new_globals);
nlr_push_jump_callback(&ctx.callback, mp_globals_locals_set_from_nlr_jump_callback);
// ... protected body ...
nlr_pop_jump_callback(true);  // runs the callback on clean exit too
```

The callback fires on either clean exit OR longjmp unwind, restoring globals/locals before propagating.

In Zig (post-NX-3a):

```zig
const saved_g = mp_globals_get();
defer mp_globals_set(saved_g);
const saved_l = mp_locals_get();
defer mp_locals_set(saved_l);
mp_globals_set(new_globals);
// ... protected body using try/catch ...
// defers run on scope exit, including PyError-return
```

`defer` runs on BOTH paths (success and error.PyRaise). The cleanup is invisible to the type system. It still runs reliably. This is the exact pattern that replaced `zig_compile_bridge.c`'s `nlr_push_jump_callback` in NX-3a (commit `46e4647`).

## Common failure modes

### Forgot `try`

```zig
fn outer() PyError!Obj {
    const inner = computeImpl(arg);  // BUG: no try
    return doMore(inner);
}
```

Without `try`, `inner` has type `PyError!Obj`; `doMore` expects `Obj`, so the compiler catches the mismatch. The fix is `try computeImpl(arg)`.

### Forgot to set pending_exc before returning error.PyRaise

```zig
fn check(arg: Obj) PyError!void {
    if (bad(arg)) return error.PyRaise;  // BUG: no exception set
}
```

`pyerr.pending_exc` is still whatever it was before. If anything in the caller chain reads it as "an exception is pending," they'll see stale data. The fix is always `pyerr.pending_exc = ...; return error.PyRaise;` as a pair.

### Bridge wrap with the wrong type

```zig
pub export fn npy_compute() callconv(.c) Obj {
    return pyerr.bridge(void, computeImpl());  // BUG: T should be Obj
}
```

`std.mem.zeroes(void)` produces `{}`; `std.mem.zeroes(Obj)` produces `0`. Wrong T → wrong sentinel → callers get garbage. The fix is `pyerr.bridge(Obj, ...)`.

### Calling pyerr.bridge from a noreturn fn

`bridge` returns a value; it can't be the last expression in a `noreturn` fn. If the fn is noreturn, use `@panic` or call a polled helper that sets `pending_exc` without trying to return.

## Lifecycle and threading

`pyerr.pending_exc` is declared `threadlocal`. Each OS thread has its own value. This matches MicroPython's threading model (which is, in petitpy, "no threads"; the threadlocal is single-instance).

When threading lands (future work, under `full` config), the threadlocal ensures multiple threads don't trample each other's pending exceptions.

## See also

- [`src/pyerr.zig`](https://git.sr.ht/~sfermigier/petitpy/tree/main/item/src/pyerr.zig) (in tree): the canonical source
- Strangler Journey § NX-3 (`strangler-journey.md`): the narrative
- Contributing § The validator pattern (`contributing.md`): how to apply the convention to new code
