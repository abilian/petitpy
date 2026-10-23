//! petitpy — Zig port of py/emitglue.c (replaces emitglue_shim.c).
//!
//! Compile/emit-internal glue: builds mp_raw_code_t records during the
//! compile pass, and at runtime turns a proto-fun (bytecode pointer OR
//! raw_code) into a callable function object.
//!
//! Live exports (vendor consumers + zig_compile_bridge + vm.zig):
//!   - mp_emit_glue_new_raw_code     (persistentcode.c, scope.c)
//!   - mp_emit_glue_assign_bytecode  (persistentcode.c, emitbc.c)
//!   - mp_make_function_from_proto_fun  (vm.zig, zig_compile_bridge.c, objfun_shim.c)
//!   - mp_make_closure_from_proto_fun   (vm.zig)
//!
//! Config audit (nano + full both — all default off under both configs):
//!   MICROPY_DEBUG_VERBOSE=0           → DEBUG_printf is a no-op (dropped)
//!   MICROPY_DEBUG_PRINTERS=0          → mp_verbose_flag dropped
//!   MICROPY_PERSISTENT_CODE_SAVE=0    → fun_data_len/n_children/prelude_offset dropped
//!   MICROPY_EMIT_INLINE_ASM=0         → asm_n_pos_args/asm_type_sig dropped
//!   MICROPY_ENABLE_NATIVE_CODE=0      → mp_emit_glue_assign_native + NATIVE branches dropped
//!   MICROPY_PY_SYS_SETTRACE=0         → line_of_definition + prelude + rc-field dropped
//!   MICROPY_MODULE_FROZEN_MPY=0       → frozen-bytecode branch dropped
//!   NDEBUG set in cflags              → assert() compiles to nothing
//!
//! With all those off, the proto_fun switch collapses to the BYTECODE default
//! case, and mp_emit_glue_assign_native is gone entirely.

const mirrors = @import("../mp_mirrors.zig");

const Obj = mirrors.Obj;

// ── mp_raw_code_t mirror ─────────────────────────────────────────────
// emitglue.h:71-91. Under nano/full (PERSISTENT_CODE_SAVE=0,
// EMIT_INLINE_ASM=0) the struct contains exactly these fields. proto_fun
// detection inlines the first two bytes (both 0 means raw_code).
const MpRawCode = extern struct {
    proto_fun_indicator: [2]u8,
    kind: u8, // mp_raw_code_kind_t — only 3 bits used
    is_generator: bool,
    fun_data: ?*const anyopaque,
    children: ?*?*MpRawCode,
};

const MP_CODE_RESERVED: u8 = 1;
const MP_CODE_BYTECODE: u8 = 2;
const MP_SCOPE_FLAG_GENERATOR: u16 = 0x01;

extern fn m_malloc0(num_bytes: usize) callconv(.c) ?*anyopaque;
extern fn mp_obj_new_fun_bc(
    def_args: [*c]const Obj,
    code: [*]const u8,
    context: ?*const anyopaque,
    child_table: ?*const anyopaque,
) callconv(.c) Obj;
extern fn mp_obj_new_closure(fun: Obj, n_closed_over: usize, closed: [*c]const Obj) callconv(.c) Obj;

extern const mp_type_gen_wrap: anyopaque;

// ── mp_emit_glue_new_raw_code ────────────────────────────────────────
// Vendor: zero-allocates an mp_raw_code_t and sets kind = RESERVED.
export fn mp_emit_glue_new_raw_code() callconv(.c) *MpRawCode {
    const raw = m_malloc0(@sizeOf(MpRawCode)).?;
    const rc: *MpRawCode = @ptrCast(@alignCast(raw));
    rc.kind = MP_CODE_RESERVED;
    return rc;
}

// ── mp_emit_glue_assign_bytecode ─────────────────────────────────────
// Vendor: fills in an existing raw_code with bytecode + child table.
// Under nano/full the `len`/`n_children` params don't exist (PERSISTENT_CODE_SAVE=0),
// nor do the prelude/SETTRACE fields.
export fn mp_emit_glue_assign_bytecode(
    rc: *MpRawCode,
    code: [*]const u8,
    children: ?*?*MpRawCode,
    scope_flags: u16,
) callconv(.c) void {
    rc.kind = MP_CODE_BYTECODE;
    rc.is_generator = (scope_flags & MP_SCOPE_FLAG_GENERATOR) != 0;
    rc.fun_data = @ptrCast(code);
    rc.children = children;
}

// ── mp_make_function_from_proto_fun ──────────────────────────────────
// Under nano/full all the FROZEN_MPY / NATIVE / INLINE_ASM / SETTRACE
// branches are dead. What remains is the default BYTECODE case: make a
// fun_bc and, if generator, retype it to gen_wrap.
// (The C does an mp_proto_fun_is_bytecode header check first, but under
// MICROPY_MODULE_FROZEN_MPY=0 that path is dead — proto_fun is always a
// raw_code_t built by mp_emit_glue_new_raw_code with indicator = {0,0}.)
export fn mp_make_function_from_proto_fun(
    proto_fun: *const anyopaque,
    context: ?*const anyopaque,
    def_args: [*c]const Obj,
) callconv(.c) Obj {
    const rc: *const MpRawCode = @ptrCast(@alignCast(proto_fun));
    // rc.kind must be BYTECODE under nano/full (NATIVE_PY/VIPER/ASM all dead).
    const code: [*]const u8 = @ptrCast(rc.fun_data);
    const fun = mp_obj_new_fun_bc(def_args, code, context, @ptrCast(rc.children));
    if (rc.is_generator) {
        const base: *mirrors.MpObjBase = @ptrFromInt(fun);
        base.type = &mp_type_gen_wrap;
    }
    return fun;
}

// ── mp_make_closure_from_proto_fun ───────────────────────────────────
// n_closed_over packs three pieces:
//   bit 8 (0x100):   def_args present in `args`
//   bits 0..7:       n_closed
//   bit 7 (>>7 & 2): adjusts args offset for kw-default presence
export fn mp_make_closure_from_proto_fun(
    proto_fun: *const anyopaque,
    context: ?*const anyopaque,
    n_closed_over: usize,
    args: [*c]const Obj,
) callconv(.c) Obj {
    const ffun = if ((n_closed_over & 0x100) != 0)
        mp_make_function_from_proto_fun(proto_fun, context, args)
    else
        mp_make_function_from_proto_fun(proto_fun, context, null);
    const closed_offset = (n_closed_over >> 7) & 2;
    return mp_obj_new_closure(ffun, n_closed_over & 0xff, args + closed_offset);
}

comptime {
    _ = &mp_emit_glue_new_raw_code;
    _ = &mp_emit_glue_assign_bytecode;
    _ = &mp_make_function_from_proto_fun;
    _ = &mp_make_closure_from_proto_fun;
}
