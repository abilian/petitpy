//! SystemExit classification + exit-code mapping, shared by both entry paths.
//!
//! `embed_exec.zig` (compile-then-exec, used by `nanopython`) and
//! `embed_run_mpy.zig` (load-a-.mpy, used by `nanopython-vm`) both have to
//! treat an uncaught SystemExit as a clean exit rather than a traceback.
//! It lived only in the former, so the VM binary printed a traceback for the
//! `except: print("SKIP"); raise SystemExit` skip idiom — 13 corpus tests.

const mirrors = @import("../mp_mirrors.zig");

const Obj = mirrors.Obj;

extern fn mp_obj_is_subclass_fast(t: Obj, classinfo: Obj) callconv(.c) bool;
extern fn mp_obj_exception_get_value(self_in: Obj) callconv(.c) Obj;
extern const mp_type_SystemExit: anyopaque;

/// mp_obj_base_t mirror; base->type is the head field.
const MpObjBase = extern struct { type: ?*const anyopaque };

const MP_CONST_NONE: Obj = 0x06;

/// True when `exc` is a SystemExit (or a subclass of one).
pub fn isSystemExit(exc: ?*anyopaque) bool {
    const e = exc orelse return false;
    const base: *const MpObjBase = @ptrCast(@alignCast(e));
    const ty = base.type orelse return false;
    return mp_obj_is_subclass_fast(@intFromPtr(ty), @intFromPtr(&mp_type_SystemExit));
}

/// Maps SystemExit args to a Unix exit code, CPython-style:
///   no arg / None → 0
///   int           → that int (low 8 bits)
///   anything else → 1
pub fn exitCode(exc: ?*anyopaque) c_int {
    const e = exc orelse return 0;
    const arg = mp_obj_exception_get_value(@intFromPtr(e));
    if (arg == MP_CONST_NONE) return 0;
    if (mirrors.isSmallInt(arg)) {
        const v = mirrors.smallIntValue(arg);
        return @intCast(v & 0xff);
    }
    return 1;
}
