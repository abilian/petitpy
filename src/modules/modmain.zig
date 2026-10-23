//! petitpy — Zig port of src/runtime/runtime_shim.c.
//!
//! Provides `mp_module___main__`, the (singleton) `__main__` module that
//! holds the top-level script's globals dict. The dict body lives in
//! `mp_state_ctx.vm.dict_main` (state-init in `mp_init`); this module
//! is just a `{ type=mp_type_module, globals=&dict_main }` wrapper that
//! the loader resolves via `import __main__` / `sys.modules['__main__']`.
//!
//! The MP_REGISTER_MODULE marker is provided by vendor `py/runtime.c`
//! which is in the qstr-gen scan path (the C source is preprocessed for
//! markers even though it's strangled out of the zig build).

const mirrors = @import("../mp_mirrors.zig");

extern const mp_type_module: anyopaque;

pub export const mp_module___main__: mirrors.MpObjModule = .{
    .base = .{ .type = &mp_type_module },
    .globals = @ptrCast(&mirrors.mp_state_ctx.vm.dict_main),
};

comptime {
    _ = &mp_module___main__;
}
