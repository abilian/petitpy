//! Portable access to libc `errno` across Darwin, Linux, and wasi.
//!
//! `extern var errno: c_int` only works where the loader actually resolves
//! a symbol named `errno`. On Darwin that used to be true (later replaced
//! by `__error`), on glibc/musl it never was — `errno` is a macro that
//! expands to `(*__errno_location())` and referencing an `errno` symbol
//! either links to an unrelated address or, on Linux, segfaults on write.
//!
//! Comptime-picks the right accessor: `__error` on Darwin, `__errno_location`
//! on glibc/musl/wasi-libc. Same pattern as `src/modules/file_io.zig`
//! `errnoVal()` and `src/support/readline.zig`; centralised here so the
//! six per-module bodies don't each carry their own copy.

const libc = @cImport({
    @cInclude("errno.h");
});

pub inline fn errnoRef() *c_int {
    if (@hasDecl(libc, "__error")) return libc.__error();
    if (@hasDecl(libc, "__errno_location")) return libc.__errno_location();
    return &libc.errno;
}
