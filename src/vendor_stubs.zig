const std_c = @cImport({
    @cInclude("unistd.h");
});
const build_options = @import("build_options");

// zigonly Phase 2 — placeholders for vendor-side symbols not on smoke path.
// Modules/types/builtins that the restored shims reference but the smoke
// test doesn't actually use. Each is a panic stub (for fn-like symbols)
// or zero-init data (for module/type singletons).
//
// As real implementations are needed, these get replaced.

// Under full, py/builtinhelp.c (added to the build carveout) provides
// the real `mp_builtin_help_obj`; the zero-init shadow here is nano-only.
const nano_mp_builtin_help_obj_storage: [64]u8 align(8) = [_]u8{0} ** 64;
comptime {
    if (!build_options.is_full) {
        @export(&nano_mp_builtin_help_obj_storage, .{ .name = "mp_builtin_help_obj", .linkage = .strong });
    }
}

// (replaced by gc_info impl below)
// mp_format_float is now provided by vendor py/formatfloat.c via the
// float-arm carveout in build.zig.
pub export fn mp_hal_stdout_tx_strn_cooked(str: [*]const u8, len: usize) callconv(.c) void {
    _ = std_c.write(1, str, len);
}
// mp_obj_float_get is now provided by vendor py/objfloat.c via the
// float-arm carveout in build.zig. Panic stub retired.
// mp_repl_continue_with_input: vendor returns true when more input is
// expected (unmatched bracket, line continuation, compound statement).
// Without a port of vendor py/repl.c the REPL falls back to single-line
// statements; this stub returns false unconditionally — better than the
// signature-mismatched @panic that was here before (caller in
// src/support/readline.zig declares it as `(input) → bool`).
pub export fn mp_repl_continue_with_input(input: [*:0]const u8) callconv(.c) bool {
    _ = input;
    return false;
}

// mp_const_float_{e,inf,nan,pi,tau}_obj moved to src/modules/modmath.zig
// (initialized to real M_PI / M_E / etc. values).
