//! Root of the embedding library (ADR 022): the runtime as `main.zig`
//! assembles it, without `main`, which Zig's start code would export from
//! a library whose root declares one. On wasm, a reactor module that also
//! takes host functions from JavaScript.
const builtin = @import("builtin");

comptime {
    _ = @import("petitpy");
    if (builtin.target.cpu.arch.isWasm()) _ = @import("entry/api_wasm.zig");
}
