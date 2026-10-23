# ADR 022. Embedding: a small C API over a static library

- **Status**: Accepted (2026-10-23). Implemented for v0.9: the static library, the wasm module with a JavaScript wrapper, and several interpreters per process, which take turns. Interpreters that run in parallel are a later step (2.3).
- **Decider**: project maintainers
- **Supersedes**: nothing
- **Branches from**: ADR 021 §2.7 (embedding back in scope, ADR first), [ADR 019](019-garbage-collector.md) (the collector the API must work with), [ADR 013](013-exception-unwind-vendor-c.md) (catching exceptions raised in MicroPython's C code).
- **Consequences**: the project commits to a stable, versioned C API, shipped as a static library on native and as a wasm module; every API call names the interpreter it acts on, so a process can hold several; calls take turns behind a lock that petitpy takes, so a host may call from any thread; each interpreter has its own state, and no new process-wide variable may hold interpreter state unless it is saved per interpreter; host programs refer to Python values through handles that petitpy tracks, never through object pointers; no petitpy code path may end the host process.

## 1. Context

Embedding means running the interpreter inside another program, the host. The host starts the interpreter once and keeps it for as long as it needs it: it runs Python code, passes values in and reads results back, and registers its own functions so that Python code can call them. Games and plugin hosts use Lua this way, and applications that offer Python scripting use CPython or MicroPython this way.

petitpy cannot be embedded today, because it only runs as a program. `petitpy script.py` runs one script and exits. The npm package starts a new wasm instance for every `run()` call and throws it away afterwards, so nothing survives from one call to the next: a web page cannot define a Python function once and call it on every click. ADR 021 brings embedding back into scope and asks for this ADR before any code.

Inside the runtime, most of what an embedding API needs already exists. `main.zig` starts the interpreter and runs source code through two internal entry points (`mp_embed_init`, `npy_embed_exec_str_zig`). The functions that create and read objects, call functions, import modules and read globals are exported with the C calling convention (`mp_obj_new_str`, `mp_call_function_n_kw`, `mp_import_name`, `mp_load_global`, …). The JS bridge already calls into Python from outside, on every JavaScript callback, in a way the garbage collector supports.

What is missing is a layer that makes these functions safe to call from a host. Called directly, they break on these points:

- **The collector would free objects the host still uses.** It finds live objects by scanning the program's global variables and the part of the stack between the current frame and a frame that `main()` records at startup (`stack_top`). A pointer to a Python object stored in host memory, such as a `malloc`ed struct or a Zig `ArrayList`, is in neither place, so the object is freed while the host still holds it. In a host, petitpy's `main()` never runs, so nothing records that frame, and the collector does not know where on the stack the Python frames end. On wasm the stack is never scanned, and collection waits until no Python code is running.
- **A shared library would not be scanned.** The collector scans the global variables of the main executable only. If petitpy were a shared library, its own globals, the interpreter state among them, would be outside the scan.
- **Errors follow a convention only the runtime's own code respects.** An internal function that raises stores the exception in a global (`pyerr.pending_exc`) and returns a placeholder value, and the caller must check after every call. That works as an internal discipline and would be error-prone as a public API.
- **Some errors end the process.** On native nano, an exception raised in MicroPython's C code where ADR 013's catching mechanism is not active prints a message and calls `exit(1)`. Running out of memory for the collector's own bookkeeping panics. A host can accept neither.
- **All interpreter state is process-wide.** MicroPython keeps nearly all of it in one global struct, `mp_state_ctx`. The Zig side adds a short list of its own globals: the collector's state, the pending exception, the tables of strings interned at run time, the scheduler's pending exception, the `sys` stream objects and a few caches. A process can therefore hold one interpreter, and two threads must never run Python code at the same time.
- **The build makes executables only.** `build.zig` produces no library, and the project ships no header.

petitpy also has no threads of its own: `_thread` is a stub, and ADR 021 keeps it that way. Every question of threads in this ADR is about the host's threads.

How a C API treats interpreter state is hard to change once hosts depend on it. CPython's API assumed one implicit interpreter, extension modules kept their state in C globals, and built-in types were shared objects. Giving each interpreter its own state, and later its own lock, took years of work (PEP 554, PEP 684, PEP 734), most of it spent on code written against those assumptions. petitpy has no such code yet.

## 2. Decision

petitpy gets a small C API that wraps the internal functions and removes each of these obstacles. The rules below define its behaviour; section 3 lists the functions.

### 2.1 Interpreters are values the host creates

The host creates an interpreter, receives a pointer to it, and passes that pointer to every API call. Nothing in the API refers to an implicit current interpreter, so a process can hold several interpreters, each with its own modules, globals and heap, and a host can throw one away and create a fresh one instead of resetting it.

### 2.2 Calls take turns

Every API call takes a lock on entry and releases it on return. A host may therefore call from any thread without coordinating its threads: calls wait for each other. The lock is recursive, so a host function that Python calls can call back into the API. In this version there is one lock for the process, so calls into different interpreters also take turns; section 2.3 explains why, and what would let them run in parallel. On wasm, which runs one thread per instance, the lock does nothing.

As with CPython's global lock, one pattern deadlocks, and the header documents it: a host function that waits for another thread which itself calls the API.

### 2.3 Each interpreter has its own state

Each interpreter owns its state: MicroPython's `mp_state_ctx`, the Zig globals listed in section 1 that belong to an interpreter, and its own heap and collector. The `sys` stream objects stay shared, since they stand for the process's own streams, and so do caches that check their entries on use.

In this version the state stays in the process-wide variables, and each interpreter keeps a saved copy of them. When a call enters an interpreter other than the current one, the entry wrapper (2.5) saves the current interpreter's copy and loads the other's, a few kilobytes; repeated calls into the same interpreter copy nothing. When a host function calls into another interpreter, the wrapper switches back on return. The code that runs Python is unchanged, and so is its speed.

A collection marks only the current interpreter's heap. It scans the global variables, which hold the current interpreter's state, and the current thread's stack, and ignores pointers into other heaps. The saved copies are not scanned. That is safe because a heap is only ever collected while its own interpreter is current, and its state is then in the global variables.

Because the interpreters share the variables, calls into two of them cannot run at the same time, which is why the lock is one for the process. To run them in parallel, the runtime would reach its state through a per-thread pointer to the current interpreter instead. MicroPython's C code reaches its state through the single name `mp_state_ctx`, which a definition in the port's configuration header can turn into such a read without editing vendor code, and the Zig globals would move into a per-interpreter struct. The cost falls on the fast path: the runtime checks for a pending exception after nearly every operation, and when the check was measured through a per-thread variable, the CPU benchmarks ran about a fifth slower on macOS. That step waits until the pending exception no longer lives in a global variable, and it changes nothing in the API.

From the moment this ADR is accepted, no new process-wide mutable variable may hold interpreter state unless it joins the list of variables saved per interpreter, and native types stay immutable, so they can be shared by every interpreter.

On wasm, a module holds one interpreter. The `js` module's callbacks enter Python from JavaScript without naming an interpreter, and the JavaScript wrapper creates one module per interpreter anyway.

### 2.4 The host holds handles, not object pointers

The host never sees a pointer to a Python object. Every value the API gives it is a handle: a small integer naming a slot in a table that its interpreter keeps. The table is a block on the interpreter's heap, reached from a global table of interpreters, so the collector already reaches it and keeps alive every object it holds. The collector needs no new mechanism and no knowledge of the host, and the host's memory, stack and threads can stay outside the scan. The host releases a handle when it no longer needs the value. A handle belongs to one interpreter: passing it to another gives an error, never another interpreter's object.

The JS bridge already uses this scheme in the other direction: Python code holds JavaScript objects through handles.

### 2.5 Every call into the interpreter sets up and restores its own conditions

Every API function that runs Python code goes through one wrapper, which establishes what the runtime assumes and restores the previous state on return:

- It takes the lock and makes the interpreter current, loading its state if another interpreter was current (2.3).
- On the outermost call into that interpreter on this thread, it records its own stack frame as the top of the scanned stack, so the collector covers the Python frames below it wherever the host calls from. A nested call, where Python calls a host function that calls the API again, keeps the outer record, so the outer Python frames stay scanned.
- It tells the collector that Python code is running, and that it has stopped, so that on wasm a collection can run after the call returns, as it does after a JavaScript callback.
- It runs the call under ADR 013's catching mechanism, so an exception raised in MicroPython's C code is caught and reported like any other.
- It turns a pending exception into the function's return status.

### 2.6 Errors are return values

Every function returns a status: success, a Python exception, or `SystemExit`. Results come back through an output argument. After an exception, the host takes it from the interpreter as a handle, and can format it as the traceback the `petitpy` command would print. A host function signals an error the same way, by returning the error status after raising an exception or after an API call that failed, and the exception reaches its Python caller. After `SystemExit`, the host reads the exit code and decides itself whether to exit. The library is built with exception catching on in every case, which removes the `exit(1)` path. The one remaining fatal case, running out of memory for the collector's bookkeeping, is documented as fatal.

### 2.7 Builds

- **Native:** a static library and its header. It is built from the `full` profile with the standard library compiled in, so a host needs no files on disk; Python code imports modules from disk only from directories the host adds to `sys.path`. A shared library comes later: it first needs the collector to scan petitpy's own global variables rather than the main executable's.
- **Wasm:** the same functions, exported from a module that the host initialises once and then calls repeatedly (a WASI "reactor", where today's module is a "command" that runs from start to end). The npm package can later move to it and keep an interpreter alive across calls. JavaScript could then call a Python function, or evaluate an expression, without running a whole script. A page that wants Python running in parallel runs one instance per Web Worker, which works today because each instance has its own memory.
- **JavaScript host functions.** JavaScript cannot give wasm a C function pointer, so the wasm module adds `ppy_define_js_function(interp, module, name, id)`, and calls every such function back through one import, `env.ppy_js_call(id, ...)`, with a C host function's arguments and status.
- **Zig hosts** use the C header through `@cImport`. A thin Zig wrapper may follow, but there is no separate Zig API.

### 2.8 Versioning

The header defines the API version, and a function returns it at run time, so a host can check that the header and the library agree. The API is marked experimental in v0.9. From its first stable release, minor versions may add functions, and only major versions may change or remove them.

## 3. The API

The header is `petitpy.h`, and every name starts with `ppy_`. An interpreter is a `ppy_interp *`. A handle is a `ppy_handle` (`uint32_t`), and handle 0 means no value. A status is a `ppy_status`: `PPY_OK`, `PPY_ERROR` or `PPY_EXIT`.

Every function except `ppy_new` and `ppy_api_version` takes the interpreter as its first argument. The first version covers running code, exchanging values and calling in both directions:

- **Lifetime:** `ppy_new(const ppy_config *)` returns a new interpreter, or `NULL` if it cannot be created; `ppy_free(interp)` destroys it and every value it holds. The configuration gives the `sys.path` entries, `sys.argv`, and a function that receives what Python writes to stdout and stderr, in order (by default the process's stdout and stderr; on wasm, the JavaScript wrapper reads WASI's).
- **Running code:** `ppy_exec(interp, src, len, filename)` runs source in `__main__`; `ppy_eval(interp, src, len, &out)` evaluates an expression; `ppy_import(interp, name, &out)` imports a module.
- **Values:** `ppy_new_*` and `ppy_to_*` create and read `None`, `bool`, `int` (as `int64_t`), `float`, `str` (UTF-8, as pointer and length) and `bytes`; `ppy_new_list`, `ppy_new_tuple` and `ppy_new_dict` build containers, and `ppy_len`, `ppy_getitem` and `ppy_setitem` work on any container; `ppy_str`, `ppy_repr` and `ppy_type_name` describe a value. `ppy_release(interp, h)` frees a handle, and `ppy_dup(interp, h, &copy)` makes a second one to the same value.
- **Calls and attributes:** `ppy_call(interp, fn, argc, argv, &out)`, `ppy_getattr`, `ppy_setattr`, `ppy_get_global` and `ppy_set_global`.
- **Host functions:** `ppy_define_function(interp, module, name, fn, userdata)` makes a C function callable from that interpreter's Python code as `module.name`. The function receives the interpreter and its arguments as handles, and returns a status and a handle, like the API's own functions.
- **Errors:** `ppy_fetch_error` returns the exception as a handle and clears it; `ppy_format_exception` gives its traceback as a `str`; `ppy_raise(interp, type_name, message)` raises a built-in exception type from a host function and returns `PPY_ERROR`, and `ppy_raise_exception(interp, exc)` raises an exception object again; `ppy_exit_code` gives the code of a `SystemExit`.
- **Version:** `PPY_API_VERSION` and `ppy_api_version()`.

The internal `mp_*` functions stay internal. The API is a new layer over them, written in Zig and exported with the C calling convention.

A host that gives Python one function and calls back a Python function that uses it:

```c
#include <stdio.h>
#include <string.h>
#include "petitpy.h"

static ppy_status twice(ppy_interp *py, void *userdata, size_t argc,
                        const ppy_handle *argv, ppy_handle *out) {
    int64_t n;
    if (ppy_to_int(py, argv[0], &n) != PPY_OK) return PPY_ERROR;
    return ppy_new_int(py, 2 * n, out);
}

int main(void) {
    ppy_interp *py = ppy_new(NULL);
    if (py == NULL) return 1;
    ppy_define_function(py, "host", "twice", twice, NULL);

    const char *src = "import host\ndef f(x):\n    return host.twice(x) + 1\n";
    if (ppy_exec(py, src, strlen(src), "<host>") != PPY_OK) return 1;

    ppy_handle f, arg, result;
    int64_t n;
    ppy_get_global(py, "f", &f);
    ppy_new_int(py, 20, &arg);
    if (ppy_call(py, f, 1, &arg, &result) == PPY_OK && ppy_to_int(py, result, &n) == PPY_OK)
        printf("%lld\n", (long long)n);  /* 41 */

    ppy_free(py);  /* releases f, arg and result too */
    return 0;
}
```

## 4. Alternatives considered

**Publish the `mp_*` functions as the API.** No new code, and MicroPython's embedding users already know them. But every host would have to follow the error convention after every call, object pointers kept in host memory would be freed by the collector, and the internal names and signatures could no longer change. Rejected.

**Let the host register its pointers with the collector instead of using handles.** For example `ppy_pin(obj)` and `ppy_unpin(obj)` on object pointers, or a call that adds a range of host memory to the scan. That costs less per value, but every host mistake becomes a use-after-free inside the interpreter, far from its cause. On wasm, an object pointer is an offset into linear memory, which JavaScript cannot tell apart from an integer. A handle costs one table slot per live value, and misusing one gives a lookup error instead of corrupted memory.

**One implicit interpreter, with an interpreter argument added later.** The first draft of this ADR. It saves one argument per call today, and makes adding the argument a break for every host later, which is the path CPython took. Rejected.

**Leave thread coordination to the host.** Document that one interpreter must never be called from two threads at once, as Lua does, and take no lock. It saves a lock per call, but every multi-threaded host must then build the same lock itself, and a host that forgets corrupts the interpreter instead of waiting. Rejected.

**Threads inside one interpreter (`_thread`).** It would need either a global lock in the runtime or a heap and collector that are safe across threads, a collector that stops every thread and scans every stack, and on wasm shared memory, which browsers allow only on cross-origin-isolated pages. For an embedder, separate interpreters on separate threads give parallelism without any of this. Out of scope.

**Ship a shared library first.** Most hosts expect one, but it needs the collector change described in 2.7, plus symbol-visibility work on each platform. A static library already serves C, Zig and wasm hosts in v0.9.

**Embed through a subprocess**: run `petitpy` and talk to it over pipes. That works today and remains the answer when the host wants isolation. It cannot share values, and every call back and forth crosses a process boundary.

## 5. Consequences

**Positive.** A host can keep interpreters alive, run code, pass values and register functions, on native and on wasm, without having to know about the collector, the internal error convention or thread coordination. The handle table reuses the collector's existing roots, so ADR 019 needs no new mechanism. The npm package gets a path to a persistent interpreter. Interpreters that run in parallel can come later with no change to hosts.

**Negative.** A second public interface to keep stable, beside the Python language itself. Calls into different interpreters take turns, stated as a limit, and switching from one interpreter to another copies their state. Every call takes a lock, and every value that crosses the API costs a handle slot; a host that forgets to release a handle leaks until it frees the interpreter. Each interpreter has its own heap, so several interpreters use more memory than one. The static library carries the size of the `full` profile.

**Work.** First step: the API layer and its header, the lock and the entry wrapper; a `zig build lib` step; the wasm module's exports; removing the remaining process-ending paths from the library build; a C example, and a test that runs it with `NPY_GC_STRESS` to check that handles keep their values alive across collections; documentation. Second step: an audit of every process-wide variable, taken from the linker's list of writable data rather than from the source, so that it includes the variables declared inside Zig namespaces and C `static` variables; the list of variables saved per interpreter; one heap per interpreter, given back when the interpreter is destroyed; handles that name their interpreter; tests with two interpreters, calls from one into the other, and threads. Later: interpreters that run in parallel (2.3).

## 6. Open questions

- How does the pending exception leave its global variable, which parallel interpreters need (2.3)? Passing it through the interpreter loop is a large change.
- Should `ppy_exec` take a module name, so that a host can run code in separate namespaces of one interpreter, or are `__main__` and `ppy_import` enough?
- Do host functions need keyword arguments in v0.9?
- How does a host stop long-running Python code? One option is a `ppy_interrupt(interp)` that raises `KeyboardInterrupt` at the next point where the interpreter checks; it would be the one function callable from another thread without taking the lock.
- Should the npm package move to the new wasm module in v0.9, or wait until the API settles?
