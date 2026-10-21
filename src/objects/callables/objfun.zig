//! nanopython — Zig port of py/objfun.c (Axis-B B1.5 W4 + ROM lift).
//!
//! Under nano + full (EMIT_NATIVE=0, EMIT_INLINE_ASM=0, STACKLESS=0,
//! FUNCTION_ATTRS_CODE=0, STACK_CHECK=0): everything live in vendor
//! objfun.c lives here. The companion shim (objfun_shim.c) was deleted
//! once mirrors + a direct extern for `mp_map_init_fixed_table`
//! eliminated the last thin C-ABI helpers; static-inline vendor fns
//! (mp_cstack_check, mp_globals_{get,set}) are reproduced inline.
//!
//! Entry points exported from this file:
//!   - fun_builtin_0/1/2/3_call, fun_builtin_var_call (5 dispatchers)
//!   - mp_obj_fun_get_name (bc-prelude varint decode)
//!   - mp_obj_new_fun_bc (flex-array alloc)
//!   - fun_bc_call (mp_code_state_t VM entry; stack-buf common path,
//!     heap for state_size > 88B, MemoryError on heap-fail — semantic
//!     departure from C alloca-as-heap-fallback, corpus-invisible)
//!   - fun_bc_print (CPYTHON_COMPAT — "<function NAME at 0xADDR>")
//!   - mp_obj_fun_bc_attr (FUNCTION_ATTRS — __name__, __globals__)
//!
//! ROM type singletons exported from this file:
//!   - mp_type_fun_builtin_0/1/2/3, mp_type_fun_builtin_var
//!   - mp_type_fun_bc
//!
//! Dropped (config-dead under both arms, see notes/02-detailed-design):
//!   - mp_type_fun_native / fun_native_call (MICROPY_ENABLE_NATIVE_CODE=0)
//!   - mp_type_fun_viper  / fun_viper_call  (same)
//!   - mp_type_fun_asm    / fun_asm_call + convert_obj_for_inline_asm
//!                                          (MICROPY_EMIT_INLINE_ASM=0)
//!   - mp_obj_fun_bc_prepare_codestate      (MICROPY_STACKLESS=0)
//!   - fun_bc_make_new                      (MICROPY_PY_FUNCTION_ATTRS_CODE=0)

const mp = @cImport({
    @cInclude("py/qstr.h");
});
const pyerr = @import("../../pyerr.zig");
const mirrors = @import("../../mp_mirrors.zig");

// Already-Zig: mp_arg_check_num_sig (argcheck.zig). mp_arg_check_num
// is a `static inline` C wrapper around it that just computes the sig
// — we inline the same logic here.
extern fn mp_arg_check_num_sig(n_args: usize, n_kw: usize, sig: u32) callconv(.c) void;

// `mp_map_init_fixed_table` (py/map.c:103) is non-static; link-callable.
extern fn mp_map_init_fixed_table(map: *mirrors.MpMap, n: usize, table: [*c]const Obj) callconv(.c) void;

inline fn makeSig(n_min: u32, n_max: u32, takes_kw: bool) u32 {
    return (n_min << 17) | (n_max << 1) | (if (takes_kw) @as(u32, 1) else 0);
}
inline fn argCheckNum(n_args: usize, n_kw: usize, n_min: u32, n_max: u32) void {
    mp_arg_check_num_sig(n_args, n_kw, makeSig(n_min, n_max, false));
}

const Obj = mirrors.Obj;

// Typed fn-pointer aliases for the mp_obj_fun_builtin_{fixed,var}_t union
// members. `.fun` is stored as `?*const anyopaque` in the mirrors; we
// @ptrCast to the right arity here.
const FnPtr0 = *const fn () callconv(.c) Obj;
const FnPtr1 = *const fn (Obj) callconv(.c) Obj;
const FnPtr2 = *const fn (Obj, Obj) callconv(.c) Obj;
const FnPtr3 = *const fn (Obj, Obj, Obj) callconv(.c) Obj;
const FnPtrVar = *const fn (usize, [*c]const Obj) callconv(.c) Obj;
const FnPtrKw = *const fn (usize, [*c]const Obj, *mirrors.MpMap) callconv(.c) Obj;

inline fn fixedSelf(self_in: Obj) *mirrors.MpObjFunBuiltinFixed {
    return @ptrFromInt(self_in);
}
inline fn varSelf(self_in: Obj) *mirrors.MpObjFunBuiltinVar {
    return @ptrFromInt(self_in);
}

export fn fun_builtin_0_call(self_in: Obj, n_args: usize, n_kw: usize, _: [*c]const Obj) callconv(.c) Obj {
    argCheckNum(n_args, n_kw, 0, 0);
    if (pyerr.pending_exc != 0) return 0; // B2 polled-sentinel: arity check raised
    const fn_ptr: FnPtr0 = @ptrCast(@alignCast(fixedSelf(self_in).fun.?));
    return fn_ptr();
}

export fn fun_builtin_1_call(self_in: Obj, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    argCheckNum(n_args, n_kw, 1, 1);
    if (pyerr.pending_exc != 0) return 0;
    const fn_ptr: FnPtr1 = @ptrCast(@alignCast(fixedSelf(self_in).fun.?));
    return fn_ptr(args[0]);
}

export fn fun_builtin_2_call(self_in: Obj, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    argCheckNum(n_args, n_kw, 2, 2);
    if (pyerr.pending_exc != 0) return 0;
    const fn_ptr: FnPtr2 = @ptrCast(@alignCast(fixedSelf(self_in).fun.?));
    return fn_ptr(args[0], args[1]);
}

export fn fun_builtin_3_call(self_in: Obj, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    argCheckNum(n_args, n_kw, 3, 3);
    if (pyerr.pending_exc != 0) return 0;
    const fn_ptr: FnPtr3 = @ptrCast(@alignCast(fixedSelf(self_in).fun.?));
    return fn_ptr(args[0], args[1], args[2]);
}

export fn fun_builtin_var_call(self_in: Obj, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    const self = varSelf(self_in);
    const sig = self.sig;
    mp_arg_check_num_sig(n_args, n_kw, sig);
    if (pyerr.pending_exc != 0) return 0;
    if ((sig & 1) != 0) {
        // takes_kw → set up the fixed-table kw map and call self->fun.kw.
        var kw_map: mirrors.MpMap = undefined;
        mp_map_init_fixed_table(&kw_map, n_kw, args + n_args);
        const fn_ptr: FnPtrKw = @ptrCast(@alignCast(self.fun.?));
        return fn_ptr(n_args, args, &kw_map);
    } else {
        const fn_ptr: FnPtrVar = @ptrCast(@alignCast(self.fun.?));
        return fn_ptr(n_args, args);
    }
}

const std = @import("std");

// ── bc.h spike: mp_obj_fun_get_name (port of bc-prelude decode) ─────
//
// Under both nano and full configs we have:
//   MICROPY_ENABLE_NATIVE_CODE = 0     → no fun_native/native_gen_wrap branch
//   MICROPY_PY_SYS_SETTRACE   = 0      → no `rc` field in mp_obj_fun_bc_t
//   MICROPY_EMIT_BYTECODE_USES_QSTR_TABLE = 0  → no qstr_table mapping
//
// The bc.h macros MP_BC_PRELUDE_SIG_DECODE / MP_BC_PRELUDE_SIZE_DECODE
// are pure bit-twiddling varint advances (xSSSSEAA pattern for sig,
// xIIIIIIC pattern for size). mp_decode_uint is a 7-bit varint with
// high-bit continuation. All trivially portable to Zig — no MP_STATE,
// no FFI hops, no shim helpers needed.

// Skip past the SIG prelude: read bytes until the high bit is clear.
inline fn skipPreludeSig(ip: *[*]const u8) void {
    var z = ip.*[0];
    ip.* += 1;
    while (z & 0x80 != 0) {
        z = ip.*[0];
        ip.* += 1;
    }
}

// Skip past the SIZE prelude: read bytes until the high bit is clear
// (note SIZE's continuation test is in the loop body, not the header).
inline fn skipPreludeSize(ip: *[*]const u8) void {
    while (true) {
        const z = ip.*[0];
        ip.* += 1;
        if (z & 0x80 == 0) break;
    }
}

// Standard 7-bit varint decode. Faithful port of mp_decode_uint (bc.c:61).
inline fn decodeUint(ip: *[*]const u8) usize {
    var unum: usize = 0;
    var p = ip.*;
    var val: u8 = undefined;
    while (true) {
        val = p[0];
        p += 1;
        unum = (unum << 7) | (val & 0x7f);
        if (val & 0x80 == 0) break;
    }
    ip.* = p;
    return unum;
}

export fn mp_obj_fun_get_name(fun_in: Obj) callconv(.c) usize {
    // Return type widened from u16 to usize to match the vendor `qstr`
    // convention (= size_t) and every other qstr-returning extern in
    // the project (qstr_from_strn, mp_errno_to_str, ...). The u16 worked
    // on amd64 only because the value lived in the low 16 bits of RAX
    // and the high bits weren't read — see src/runtime/qstr.zig:27 for
    // the documented note. On wasm32, the typed wasm signature + Zig
    // Debug-mode integer checks made the truncation explicit; the
    // objgenerator.zig caller declared usize (correctly), and the
    // mismatch fired @unreachable when print(repr(generator)) was the
    // first path that exercised it.
    const fun = mirrors.MpObjFunBc.fromObj(fun_in);
    var bc: [*]const u8 = fun.bytecode;
    skipPreludeSig(&bc);
    skipPreludeSize(&bc);
    const idx = decodeUint(&bc);
    // USES_QSTR_TABLE=1 always under both nano + full (MICROPY_PERSISTENT_CODE
    // is set via MICROPY_PERSISTENT_CODE_LOAD). The varint is a TABLE INDEX
    // into fun->context->constants.qstr_table — same pattern as vm.zig.
    const qstr_table: [*]const u16 = @ptrFromInt(fun.contextPtr().constants.qstr_table_or_source_file);
    return qstr_table[idx];
}

// ── mp_obj_new_fun_bc (bc.h spike #2, follow-up to get_name) ────────
//
// Builds an mp_obj_fun_bc_t with a flex-array of extra_args slots holding
// (optional) positional defaults + (optional) kw defaults dict. The flex
// array is sized at alloc time based on what's in `def_args`.
//
// def_args layout (NULL-tolerant, both slots optional):
//   def_args[0] = tuple of positional defaults (or MP_OBJ_NULL)
//   def_args[1] = dict of keyword defaults     (or MP_OBJ_NULL)
//
// Asserts in the C source are no-ops under -DNDEBUG; skipped here.
extern fn mp_obj_malloc_helper(num_bytes: usize, type_in: ?*const anyopaque) callconv(.c) ?*anyopaque;
// mp_type_fun_bc defined further down in this file (pub export const).

export fn mp_obj_new_fun_bc(
    def_args: [*c]const Obj,
    code: [*]const u8,
    context: ?*const anyopaque,
    child_table: ?*const anyopaque,
) callconv(.c) Obj {
    var n_def_args: usize = 0;
    var n_extra_args: usize = 0;
    var def_pos_args: ?*mirrors.MpObjTuple = null;
    var def_kw_args: Obj = 0; // MP_OBJ_NULL

    if (def_args != null and def_args[0] != 0) {
        def_pos_args = mirrors.MpObjTuple.fromObj(def_args[0]);
        n_def_args = def_pos_args.?.len;
        n_extra_args = def_pos_args.?.len;
    }
    if (def_args != null and def_args[1] != 0) {
        def_kw_args = def_args[1];
        n_extra_args += 1;
    }

    const total_bytes = @sizeOf(mirrors.MpObjFunBc) + n_extra_args * @sizeOf(Obj);
    const raw = mp_obj_malloc_helper(total_bytes, &mp_type_fun_bc);
    const o: *mirrors.MpObjFunBc = @ptrCast(@alignCast(raw));
    o.bytecode = code;
    o.context = context;
    o.child_table = child_table;

    const extra = o.extraArgsPtr();
    if (def_pos_args) |dp| {
        @memcpy(extra[0..n_def_args], dp.itemsPtr()[0..n_def_args]);
    }
    if (def_kw_args != 0) {
        extra[n_def_args] = def_kw_args;
    }
    return @intFromPtr(o);
}

// ── fun_bc_call (bc.h spike #3 — the wall) ───────────────────────────
//
// The VM bytecode entry point. Three blockers from notes/18:
//   (a) mp_code_state_t has flex array state[] → use MpCodeState mirror
//       with statePtr() (same pattern as MpObjTuple.itemsPtr).
//   (b) C uses alloca for state_size <= VM_MAX_STATE_ON_STACK (88 bytes,
//       the common case). Zig has no dynamic-stack-alloc, so we use a
//       fixed-size stack buffer at the upper bound. Always-enough for
//       the common case.
//   (c) C's alloca also serves as a fallback when m_malloc_maybe returns
//       NULL for the large-frame case. Zig can't recover into a dynamic
//       stack frame, so on heap-fail we set MemoryError and return null.
//       Semantic departure: under heap pressure C runs, Zig fails.
//       Invisible to our 541-test corpus (512KB heap, never full).
//
// SIG_DECODE_INTO is the OUTPUT variant of skipPreludeSig — we need
// n_state + n_exc_stack to size the state[] flex area. The S/E/A/K/D/F
// bit-twiddling is the same; this variant just keeps two of the outputs.

// Non-static C fns we can call directly (mp_setup_code_state is now Zig
// — see src/runtime/bc.zig — but resolves cross-module via the C ABI):
extern fn mp_setup_code_state(code_state: *mirrors.MpCodeState, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) void;
extern fn mp_execute_bytecode(code_state: ?*anyopaque, inject_exc: Obj) callconv(.c) c_int;
extern fn m_malloc_maybe(num_bytes: usize) callconv(.c) ?*anyopaque;
extern fn m_free(ptr: ?*anyopaque) callconv(.c) void;
extern fn npy_pyerr_get_pending() callconv(.c) usize;
extern fn npy_pyerr_set_pending(exc: usize) callconv(.c) void;
extern fn mp_obj_new_exception(exc_type: ?*const anyopaque) callconv(.c) Obj;
extern const mp_type_MemoryError: anyopaque;
// mp_cstack_check / mp_globals_get / mp_globals_set are static-inline in
// vendor headers (cstack.h, runtime.h). Under our config MICROPY_STACK_CHECK
// = 0 (ROM_LEVEL_MINIMUM), so mp_cstack_check is a no-op — call sites elided.
// mp_globals_{get,set} resolve to mp_state_ctx.thread.dict_globals (see
// mirrors.mp_state_ctx) — same pattern as runtime/jcb_glue.zig.
inline fn globalsGet() ?*anyopaque {
    return mirrors.mp_state_ctx.thread.dict_globals;
}
inline fn globalsSet(d: ?*anyopaque) void {
    mirrors.mp_state_ctx.thread.dict_globals = d;
}

const VM_MAX_STATE_ON_STACK: usize = @sizeOf(usize) * 11; // 88 on 64-bit
const MP_VM_RETURN_NORMAL: c_int = 0;
const MP_VM_RETURN_EXCEPTION: c_int = 2;

// Faithful Zig port of MP_BC_PRELUDE_SIG_DECODE_INTO restricted to the
// two fields fun_bc_call needs (n_state and n_exc_stack). The other 4
// fields (F/A/K/D) are decoded by the C macro then discarded; we just
// skip them by advancing past the continuation bytes.
inline fn decodePreludeSig(
    ip: *[*]const u8,
    n_state_out: *usize,
    n_exc_stack_out: *usize,
) void {
    var z = ip.*[0];
    ip.* += 1;
    // First byte: xSSSSEAA. Initialize S, E. Skip A.
    var S: usize = (z >> 3) & 0xf;
    var E: usize = (z >> 2) & 0x1;
    // Continuation bytes: xFSSKAED. Accumulate S and E; ignore the rest.
    // ShiftAmt is u6 on 64-bit hosts and u5 on 32-bit hosts (wasm32).
    const ShiftAmt = std.math.Log2Int(usize);
    var n: ShiftAmt = 0;
    while (z & 0x80 != 0) : (n += 1) {
        z = ip.*[0];
        ip.* += 1;
        S |= (@as(usize, z) & 0x30) << (@as(ShiftAmt, 2) * n);
        E |= (@as(usize, z) & 0x02) << n;
    }
    n_state_out.* = S + 1;
    n_exc_stack_out.* = E;
}

export fn fun_bc_call(self_in: Obj, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    // mp_cstack_check is a no-op under MICROPY_STACK_CHECK=0 (see above).

    const self = mirrors.MpObjFunBc.fromObj(self_in);

    // Decode codestate size from bytecode prelude.
    var bc: [*]const u8 = self.bytecode;
    var n_state: usize = 0;
    var n_exc_stack: usize = 0;
    decodePreludeSig(&bc, &n_state, &n_exc_stack);
    const state_size = n_state * @sizeOf(Obj) + n_exc_stack * @sizeOf(mirrors.MpExcStack);

    // Allocate state. Common path: fixed Zig stack buffer (upper-bound
    // sized). Large path: heap. Heap-fail: MemoryError (semantic
    // departure from C alloca-on-heap-fail, see header).
    var stack_buf: [@sizeOf(mirrors.MpCodeState) + VM_MAX_STATE_ON_STACK]u8 align(@alignOf(mirrors.MpCodeState)) = undefined;
    var code_state: *mirrors.MpCodeState = undefined;
    var on_heap: bool = false;

    if (state_size > VM_MAX_STATE_ON_STACK) {
        const raw = m_malloc_maybe(@sizeOf(mirrors.MpCodeState) + state_size);
        if (raw == null) {
            npy_pyerr_set_pending(mp_obj_new_exception(&mp_type_MemoryError));
            return 0;
        }
        code_state = @ptrCast(@alignCast(raw));
        on_heap = true;
    } else {
        code_state = @ptrCast(@alignCast(&stack_buf));
    }

    // INIT_CODESTATE: assign fields, call mp_setup_code_state, snapshot
    // old_globals so we can restore after mp_execute_bytecode.
    code_state.fun_bc = self;
    code_state.n_state = @intCast(n_state);
    mp_setup_code_state(code_state, n_args, n_kw, args);
    code_state.old_globals = globalsGet();

    // mp_setup_code_state can now set pending_exc (B2 polled-sentinel)
    // instead of longjmping. Propagate before entering the VM.
    if (npy_pyerr_get_pending() != 0) {
        if (on_heap) m_free(@ptrCast(code_state));
        return 0;
    }

    // Switch to function's module globals, execute, restore.
    // self.context points at mp_module_context_t; module is at offset 0
    // so the same pointer IS an MpObjModule * for the first 16 bytes.
    const ctx_as_module: *const mirrors.MpObjModule = @ptrCast(@alignCast(self.context));
    globalsSet(@ptrCast(ctx_as_module.globals));
    const vm_return_kind = mp_execute_bytecode(@ptrCast(code_state), 0);
    globalsSet(code_state.old_globals);

    // Pluck the result (NORMAL: top-of-stack; EXCEPTION: state[0]).
    const result: Obj = if (vm_return_kind == MP_VM_RETURN_NORMAL)
        code_state.sp[0]
    else
        code_state.statePtr()[0];

    if (on_heap) m_free(@ptrCast(code_state));

    if (vm_return_kind == MP_VM_RETURN_NORMAL) {
        return result;
    }
    // MP_VM_RETURN_EXCEPTION → polled-sentinel: set pending_exc, return null.
    npy_pyerr_set_pending(result);
    return 0;
}

// ── ROM type singletons (ported from objfun_shim.c) ─────────────────
//
// The 5 builtin function types + mp_type_fun_bc. Same `MpObjTypeFull`
// shape used by mp_type_roms.zig (fixed slots[11]; vendor reads via
// the prefix and only the indexed slots are touched).
//
// Dead under nano + full (skipped here, deleted from the C shim):
//   - mp_type_fun_native, mp_type_fun_viper (MICROPY_ENABLE_NATIVE_CODE=0)
//   - mp_type_fun_asm (MICROPY_EMIT_INLINE_ASM=0)

const FLAG_NONE: u16 = 0x0000;
const FLAG_BINDS_SELF: u16 = 0x0020;
const FLAG_BUILTIN_FUN: u16 = 0x0040;

const MpObjTypeFull = extern struct {
    header: mirrors.MpObjType,
    slots: [11]?*const anyopaque,
};

extern const mp_type_type: anyopaque;

fn builtinFunType(call_fn: anytype) MpObjTypeFull {
    return .{
        .header = .{
            .base = .{ .type = &mp_type_type },
            .flags = FLAG_BINDS_SELF | FLAG_BUILTIN_FUN,
            .name = mp.MP_QSTR_function,
            .slot_index_make_new = 0,
            .slot_index_print = 0,
            .slot_index_call = 1,
            .slot_index_unary_op = 0,
            .slot_index_binary_op = 0,
            .slot_index_attr = 0,
            .slot_index_subscr = 0,
            .slot_index_iter = 0,
            .slot_index_buffer = 0,
            .slot_index_protocol = 0,
            .slot_index_parent = 0,
            .slot_index_locals_dict = 0,
        },
        .slots = .{
            @ptrCast(call_fn),
            null,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
        },
    };
}

pub export const mp_type_fun_builtin_0: MpObjTypeFull = builtinFunType(&fun_builtin_0_call);
pub export const mp_type_fun_builtin_1: MpObjTypeFull = builtinFunType(&fun_builtin_1_call);
pub export const mp_type_fun_builtin_2: MpObjTypeFull = builtinFunType(&fun_builtin_2_call);
pub export const mp_type_fun_builtin_3: MpObjTypeFull = builtinFunType(&fun_builtin_3_call);
pub export const mp_type_fun_builtin_var: MpObjTypeFull = builtinFunType(&fun_builtin_var_call);

// ── mp_type_fun_bc: bytecode function ───────────────────────────────
// Under nano + full both: MICROPY_CPYTHON_COMPAT=1 (print slot live),
// MICROPY_PY_FUNCTION_ATTRS=1 (attr slot live), MICROPY_PY_FUNCTION_ATTRS_CODE=0
// (no make_new slot). Slot layout: print=1, attr=2, call=3.

extern fn mp_printf(print: ?*const anyopaque, fmt: [*:0]const u8, ...) callconv(.c) c_int;

export fn fun_bc_print(
    print_in: ?*const anyopaque,
    o_in: Obj,
    kind: c_int,
) callconv(.c) void {
    _ = kind;
    const o: *mirrors.MpObjFunBc = mirrors.MpObjFunBc.fromObj(o_in);
    _ = mp_printf(print_in, "<function %q at 0x%p>", @as(usize, mp_obj_fun_get_name(o_in)), o);
}

// `mp_obj_fun_bc_attr` is also called from objgenerator_shim.c — keep
// the symbol C-ABI-visible (export, not pub).
export fn mp_obj_fun_bc_attr(self_in: Obj, attr: u16, dest: [*c]Obj) callconv(.c) void {
    // "load attribute" only — store/delete paths set dest[0] != MP_OBJ_NULL.
    if (dest[0] != 0) return;

    if (attr == mp.MP_QSTR___name__) {
        dest[0] = mirrors.objFromQstr(@as(usize, mp_obj_fun_get_name(self_in)));
    }
    if (attr == mp.MP_QSTR___globals__) {
        const self = mirrors.MpObjFunBc.fromObj(self_in);
        const ctx_as_module: *const mirrors.MpObjModule = @ptrCast(@alignCast(self.context));
        dest[0] = @intFromPtr(ctx_as_module.globals);
    }
    // MICROPY_PY_FUNCTION_ATTRS_CODE branch (___code__) is dead under
    // nano + full — vendor mpconfig defaults it OFF and our port doesn't
    // flip it on. Restore behind a comptime gate if/when needed.
}

pub export const mp_type_fun_bc: MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = FLAG_BINDS_SELF,
        .name = mp.MP_QSTR_function,
        .slot_index_make_new = 0,
        .slot_index_print = 1,
        .slot_index_call = 3,
        .slot_index_unary_op = 0,
        .slot_index_binary_op = 0,
        .slot_index_attr = 2,
        .slot_index_subscr = 0,
        .slot_index_iter = 0,
        .slot_index_buffer = 0,
        .slot_index_protocol = 0,
        .slot_index_parent = 0,
        .slot_index_locals_dict = 0,
    },
    .slots = .{
        @ptrCast(&fun_bc_print),
        @ptrCast(&mp_obj_fun_bc_attr),
        @ptrCast(&fun_bc_call),
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
    },
};

comptime {
    _ = &fun_builtin_0_call;
    _ = &fun_builtin_1_call;
    _ = &fun_builtin_2_call;
    _ = &fun_builtin_3_call;
    _ = &fun_builtin_var_call;
    _ = &mp_obj_fun_get_name;
    _ = &mp_obj_new_fun_bc;
    _ = &fun_bc_call;
    _ = &fun_bc_print;
    _ = &mp_obj_fun_bc_attr;
    _ = &mp_type_fun_builtin_0;
    _ = &mp_type_fun_builtin_1;
    _ = &mp_type_fun_builtin_2;
    _ = &mp_type_fun_builtin_3;
    _ = &mp_type_fun_builtin_var;
    _ = &mp_type_fun_bc;
}
