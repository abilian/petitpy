//! Root of libpetitpy.a (ADR 022): the runtime as `main.zig` assembles it,
//! without `main`, which Zig's start code would export from a library
//! whose root declares one.
comptime {
    _ = @import("petitpy");
}
