# Embedding petitpy in a C program

petitpy can run inside another program, the host. The host creates an interpreter, keeps it for as long as it needs it, runs Python code in it, passes values in and reads results back, and gives Python functions of its own to call. The API is a C header, `petitpy.h`, and a static library, `libpetitpy.a`. Zig hosts use the same header through `@cImport`.

The API is experimental in this release: names and signatures may still change.

## Building

In a checkout of the repository:

```sh
make freeze-modules
zig build lib -Dconfig=full -Dfrozen-tiny=true
```

This writes `zig-out/lib/libpetitpy.a` and `zig-out/include/petitpy.h`. The library has the standard modules compiled in, so the host needs no files on disk. Link it into a host with any C compiler:

```sh
cc -Izig-out/include host.c zig-out/lib/libpetitpy.a -lpthread -lm -o host
```

On macOS, pass `-mmacosx-version-min` with your macOS version, or the linker warns that the library was built for a newer system than the one it links for.

## A first host

This host gives Python a function `host.twice`, defines a Python function that uses it, and calls that function from C. It is `examples/embed/host.c` in the repository.

```c
#include <stdio.h>
#include <string.h>
#include "petitpy.h"

static ppy_status twice(ppy_interp *py, void *userdata, size_t argc,
                        const ppy_handle *argv, ppy_handle *result) {
    int64_t n;
    if (argc != 1) return ppy_raise(py, "TypeError", "twice() takes one argument");
    if (ppy_to_int(py, argv[0], &n) != PPY_OK) return PPY_ERROR;
    return ppy_new_int(py, 2 * n, result);
}

int main(void) {
    ppy_interp *py = ppy_new(NULL);
    ppy_define_function(py, "host", "twice", twice, NULL);

    const char *src = "import host\ndef f(x):\n    return host.twice(x) + 1\n";
    if (ppy_exec(py, src, strlen(src), "<host>") != PPY_OK) return 1;

    ppy_handle f, arg, result;
    int64_t n;
    ppy_get_global(py, "f", &f);
    ppy_new_int(py, 20, &arg);
    if (ppy_call(py, f, 1, &arg, &result) == PPY_OK && ppy_to_int(py, result, &n) == PPY_OK)
        printf("%lld\n", (long long)n);  /* 41 */

    ppy_free(py);
    return 0;
}
```

## Interpreters

`ppy_new()` creates an interpreter and `ppy_free()` destroys it. Every other function takes the interpreter as its first argument. The configuration, which may be `NULL`, gives the directories of `sys.path` and the contents of `sys.argv`. Python code imports the standard modules from the library itself, and other modules only from the directories the host lists, never from the current directory.

In this release, a process holds one interpreter at a time: `ppy_new()` returns `NULL` while another exists. After `ppy_free()`, the host can create a new one, which starts with fresh modules and globals.

`ppy_exec()` runs source code in the namespace of `__main__`, and `ppy_eval()` evaluates an expression. `ppy_get_global()` and `ppy_set_global()` read and write that namespace. `ppy_import()` imports a module, dotted names included, and returns it.

## Handles

The host never holds a pointer to a Python object. Every value comes back as a `ppy_handle`, a small integer that names the value inside the interpreter, and 0 means no value. The interpreter keeps a value alive for as long as a handle names it: the garbage collector never frees it, even when nothing in Python refers to it any more. `ppy_release()` gives the handle back. `ppy_free()` releases every handle the interpreter still holds, so a short-lived host can skip releasing.

A handle belongs to its interpreter. Using a released handle, or a number that was never a handle, raises `ValueError`; it never reaches another object.

`ppy_new_*` create values (`None`, `bool`, `int`, `float`, `str`, `bytes`, `list`, `tuple`, `dict`). `ppy_to_*` read them. The pointer `ppy_to_str()` and `ppy_to_bytes()` return stays valid while the handle is held; use the length, since the data is not always NUL-terminated. `ppy_to_int()` raises `OverflowError` for an integer that does not fit a machine word. `ppy_len()`, `ppy_getitem()` and `ppy_setitem()` work on any container, `ppy_getattr()` and `ppy_setattr()` on any object, and `ppy_str()`, `ppy_repr()` and `ppy_type_name()` describe a value.

## Errors

Every function that can fail returns a status:

- `PPY_OK`: the call succeeded, and its results are in the output arguments.
- `PPY_ERROR`: Python raised an exception. `ppy_fetch_error()` returns it as a handle and clears it, and `ppy_format_exception()` turns it into the traceback text that `petitpy` would print. An output handle is 0 after an error.
- `PPY_EXIT`: Python raised `SystemExit`. `ppy_exit_code()` gives the code. The interpreter keeps running, and whether the program ends is the host's decision.

No error ends the host process. An exception raised deep in the runtime's C code is caught and returned like any other.

## Host functions

`ppy_define_function(py, "host", "name", fn, userdata)` makes `fn` callable from Python as `host.name`, and creates the module `host` the first time, so that `import host` finds it. The function receives the interpreter, the `userdata` pointer given at registration, and its arguments as handles, which the caller releases after the call. It returns `PPY_OK` with its result in `*result` (leave it 0 to return `None`), or `PPY_ERROR`:

- after `ppy_raise(py, "ValueError", "message")`, which raises an exception of the named built-in type and returns `PPY_ERROR`, so the function can `return ppy_raise(...)`;
- or after an API call of its own that failed, to pass that exception on to the Python caller.

A host function can call back into the interpreter, as `ppy_call()` does when Python passes it a function.

## Threads

The host may call the API from any thread. Calls into one interpreter take turns behind a lock that petitpy takes, and a host function that Python calls can call back into the API on the same thread. One pattern deadlocks: a host function that waits for another thread which itself calls the interpreter.

Python code itself cannot start threads: `_thread` is a stub.

## Limits of this release

- One interpreter per process at a time.
- Python's output goes to the C `stdout` and `stderr`; the host cannot capture it yet.
- Tracebacks name the file and function of each frame, without line numbers, as the `petitpy` command prints them.
- A static library only; no shared library yet, and no wasm build of the API.
