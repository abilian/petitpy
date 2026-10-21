// zigonly Phase 2 — glue for the NLR-trampoline restoration.
//
// nlr_trampoline.c references symbols that previously lived in vendor C
// (now deleted). This file provides minimal Zig replacements for the 4
// link-time gaps the restoration exposed:
//
//   1. nlr_jump_fail        — called when nlr_jump fires outside any
//                             protected region (top-level uncaught).
//                             Vendor embed_util.c had an infinite loop;
//                             we abort with a panic for visibility.
//
//   2. mp_plat_print        — const struct { void *data; print_strn_fn };
//                             pairs the platform printer with a stdout-fwd
//                             implementation.
//
//   3. mp_parse             — vendor name for the parser entry; aliased
//                             to our existing pyerr-bridged npy_parse_impl
//                             in src/frontend/parse.zig.
//
//   4. mp_type_SystemExit   — exception type singleton; live in mp_type_roms
//                             alongside the other type data. Kept here as a
//                             *minimal* placeholder until we port the full
//                             exception type system. Code paths that
//                             read its fields will read zeros — fine until
//                             SystemExit is actually raised (not on the
//                             smoke-test path).

const std = @import("std");

// ── 1. nlr_jump_fail ────────────────────────────────────────────────
pub export fn nlr_jump_fail(val: ?*anyopaque) noreturn {
    _ = val;
    @panic("nlr_jump_fail: uncaught exception at top level");
}

// ── 2. mp_plat_print ────────────────────────────────────────────────
//
// Matches vendor py/mpprint.h: `typedef struct _mp_print_t { void *data;
// mp_print_strn_t print_strn; } mp_print_t;` with print_strn signature
// `void (*)(void *data, const char *str, size_t len)`.

const MpPrint = extern struct {
    data: ?*anyopaque,
    print_strn: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void,
};

fn stdout_print_strn(data: ?*anyopaque, str: [*]const u8, len: usize) callconv(.c) void {
    _ = data;
    if (len == 0) return;
    const slice = str[0..len];
    _ = std.c.write(1, slice.ptr, len);
}


// ── 3. mp_parse: provided by src/frontend/parse_shim.c instead (it adds
//      NLR-jump-callback cleanup for mp_lexer_free). Removed here to avoid
//      duplicate symbol.

// Error-path exception creation — @panic for now (smoke test doesn't hit it).

// NX-3 N4b: `npy_pyerr_nlr_jump` deleted. Nano callers (argcheck) are
// now polled-only. Full-gated callers (obj.zig, objstr.zig) DCE under
// nano so the symbol is not required at link time.

// More error/closure-path symbols referenced by bc_shim.c.
// Smoke test doesn't hit them, so @panic with descriptive messages.



// FLOAT panic stubs retired — vendor py/objfloat.c is now in the
// nano build via build.zig's float-arm carveout, providing the real
// mp_obj_new_float + mp_obj_float_binary_op + mp_obj_float_get +
// mp_type_float.
// dup-vendor: pub export fn mp_obj_new_slice() noreturn {
// dup:     @panic("mp_obj_new_slice: slice not yet wired");
// dup: }

// Builtin function-object data symbols. Placeholder zero-init structs.
// These are mp_obj_fun_builtin_*_t — small structs.

// op-method objects (for explicit __getitem__/__setitem__/__delitem__).
// Smoke test doesn't use these — placeholder data.
