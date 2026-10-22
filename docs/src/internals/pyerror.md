# PyError Convention

MicroPython raises exceptions with NLR (non-local return): `mp_raise_*` calls `nlr_jump`, which longjmps to the nearest `nlr_push` buffer. petitpy replaces this with a Zig error union. Every Zig function that can raise a Python exception follows this convention.

## The pieces

`src/pyerr.zig` holds the whole mechanism:

```zig
pub const PyError = error{PyRaise};
pub var pending_exc: usize = 0;

pub inline fn bridge(comptime T: type, r: PyError!T) T {
    return r catch {
        return std.mem.zeroes(T);
    };
}
```

The error union says that a raise happened, `pending_exc` holds the exception object, and `bridge` converts between the two at C-ABI boundaries.

## Raising and propagating

Set the exception, then return the error:

```zig
fn computeImpl(arg: Obj) PyError!Obj {
    if (bad(arg)) {
        pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_TypeError, "bad arg");
        return error.PyRaise;
    }
    return doWork(arg);
}
```

Callers that are themselves `PyError!T` just `try computeImpl(arg)`. A function exported with the C ABI cannot return an error union, so it wraps the call:

```zig
pub export fn npy_compute(arg: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, computeImpl(arg));
}
```

On a raise, `bridge` returns a zeroed `T`, which is `MP_OBJ_NULL` for an `Obj`. It leaves `pending_exc` set.

## The polled sentinel

The other half of `bridge` is the caller's check. Code that calls a C-ABI function, such as a type slot or a bridged export, tests `pending_exc` after the call and turns it back into an error:

```zig
const result = mp_call_function_0(module_fun);
if (pyerr.pending_exc != 0) return error.PyRaise;
```

Functions that return pointers use the same pattern: `mp_obj_str_get_str` returns `null` and sets `pending_exc` on bad input, and callers check both.

## Why replace NLR

- **wasm has no setjmp/longjmp.** wasi-libc does not provide them, so NLR cannot run on the wasm target at all.
- **Cleanup runs on unwind.** `defer` and `errdefer` fire on the error path. Where vendor C uses `nlr_push_jump_callback` to restore globals and locals, Zig uses a `defer`:

  ```zig
  const saved_g = mp_globals_get();
  defer mp_globals_set(saved_g);
  ```

- **Raising is visible in the type.** A function that can raise returns `PyError!T`, and the compiler rejects a caller that ignores it.

## Vendor C that still raises

The vendor C files that are still compiled (float, MPZ, `re`, `io`) call the `mp_raise_*` helpers and expect them not to return. Those helpers, in `src/runtime/raise.zig`, set `pending_exc` and then either longjmp to a scoped trampoline that converts the raise back into the polled sentinel, or, where the trampoline is not available, print the traceback and exit. The trampoline exists only on native `full` builds, because it needs setjmp. [ADR 013](../adrs/013-exception-unwind-vendor-c.md) describes it.

## Mistakes to avoid

- **Returning `error.PyRaise` without setting `pending_exc`.** Callers then see a raise with no exception object, or a stale one.
- **Calling a C-ABI function without polling.** A zero return can mean a raise; check `pending_exc` before using the result.
- **Clearing `pending_exc` by accident.** `bridge` does not clear it, on purpose. Code that handles an exception takes it and resets it to zero.

## Limits

`pending_exc` is a plain global, not `threadlocal`: it is polled on every opcode, and on macOS each thread-local access is a function call. There are no threads today; real threading would move it into per-thread VM state.

## See also

- [`src/pyerr.zig`](https://github.com/abilian/petitpy/blob/main/src/pyerr.zig) and [`src/runtime/raise.zig`](https://github.com/abilian/petitpy/blob/main/src/runtime/raise.zig)
- [ADR 013](../adrs/013-exception-unwind-vendor-c.md): exception unwind through vendor C
- [The strangler journey](../strangler-journey.md)
