//! nanopython — full Zig port of py/objgenerator.c (post-deep-sweep).
//!
//! Lifts what remained in objgenerator_shim.c:
//!   - mp_const_GeneratorExit_obj      (singleton GeneratorExit instance)
//!   - gen_wrap_call                   (generating-fn constructor)
//!   - mp_obj_gen_resume               (full body, direct mirror access)
//!   - gen_instance_print              (mp_printf wrapper)
//!   - mp_type_gen_wrap                (ROM type)
//!   - mp_type_gen_instance + locals_dict (ROM type + send/throw/close)
//!
//! Dropped (config-dead under nano + full):
//!   - mp_type_native_gen_wrap / native_gen_wrap_call  (NATIVE_CODE=0)
//!   - gen_instance_pend_throw                         (PEND_THROW gated;
//!     nano off, full uses the same accessor on pend_exc — but the body
//!     hits a `mp_raise_ValueError` host raise and is not on the corpus
//!     path; preserved here behind comptime gate)

const std = @import("std");
const build_options = @import("build_options");
const mp = @cImport({
    @cInclude("py/qstr.h");
    @cInclude("py/runtime.h");
});
const mirrors = @import("../../mp_mirrors.zig");
const types = @import("../../mp_type_roms.zig");
const pyerr = @import("../../pyerr.zig");
const PyError = pyerr.PyError;

const Obj = mirrors.Obj;
const Qstr = usize;

// ── extern types + helpers ───────────────────────────────────────────
extern const mp_type_type: anyopaque;
extern const mp_type_dict: anyopaque;
extern const mp_type_fun_builtin_2: anyopaque;
extern const mp_type_fun_builtin_var: anyopaque;
extern const mp_type_GeneratorExit: anyopaque;
extern const mp_type_StopIteration: anyopaque;
extern const mp_type_TypeError: anyopaque;
extern const mp_type_ValueError: anyopaque;
extern const mp_type_RuntimeError: anyopaque;
extern const mp_const_empty_tuple_obj: anyopaque;

// `mp_cstack_check` is static-inline (cstack.h); under both nano + full
// MICROPY_STACK_CHECK=0 ⇒ no-op body.
inline fn mp_cstack_check() void {}
extern fn mp_setup_code_state(code_state: *mirrors.MpCodeState, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) void;
extern fn mp_execute_bytecode(code_state: *mirrors.MpCodeState, inject_exc: Obj) callconv(.c) c_int;
extern fn mp_obj_malloc_helper(num_bytes: usize, type_in: ?*const anyopaque) callconv(.c) ?*anyopaque;
extern fn mp_obj_new_exception(exc_type: ?*const anyopaque) callconv(.c) Obj;
extern fn mp_obj_new_exception_msg(exc_type: ?*const anyopaque, msg: [*:0]const u8) callconv(.c) Obj;
extern fn mp_obj_new_exception_args(exc_type: ?*const anyopaque, n_args: usize, args: [*c]const Obj) callconv(.c) Obj;
extern fn mp_obj_get_type(o: Obj) callconv(.c) ?*const anyopaque;
extern fn mp_obj_is_subclass_fast(object: Obj, classinfo: Obj) callconv(.c) bool;
extern fn mp_obj_exception_get_value(self_in: Obj) callconv(.c) Obj;
extern fn mp_printf(print: ?*const anyopaque, fmt: [*:0]const u8, ...) callconv(.c) c_int;
extern fn mp_obj_fun_get_name(fun_in: Obj) callconv(.c) usize;
extern fn mp_obj_fun_bc_attr(self_in: Obj, attr: usize, dest: [*c]Obj) callconv(.c) void;

// NX-3 N1 raise helpers (PyError convention; notes/41, /42). One per
// distinct exception+message used at a PyError raise site.
fn raiseStopIteration(arg: Obj) PyError!void {
    if (arg == mirrors.OBJ_NULL) {
        pyerr.pending_exc = mp_obj_new_exception(&mp_type_StopIteration);
    } else {
        const args = [_]Obj{arg};
        pyerr.pending_exc = mp_obj_new_exception_args(&mp_type_StopIteration, 1, &args);
    }
    return error.PyRaise;
}

fn raiseAlreadyExecutingValueError() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_ValueError, "generator already executing");
    return error.PyRaise;
}

// mp_make_stop_iteration is a static-inline; inline its body via direct
// MpStateThread access (sets stop_iteration_arg + returns MP_OBJ_STOP_ITERATION).
inline fn makeStopIteration(o: Obj) Obj {
    mirrors.mp_state_ctx.thread.stop_iteration_arg = o;
    return mirrors.OBJ_STOP_ITERATION;
}

// Mirror's `ip` field is `[*]const u8` (non-nullable). The C source sets
// it to 0 to mark a stopped generator. We bit-write zero through a usize
// alias to bypass Zig's null-ptr check on the field.
inline fn clearIp(cs: *mirrors.MpCodeState) void {
    const slot: *usize = @ptrCast(&cs.ip);
    slot.* = 0;
}

// mp_globals_get/set are static-inline; access MpStateThread directly.
inline fn globalsGet() ?*anyopaque {
    return mirrors.mp_state_ctx.thread.dict_globals;
}
inline fn globalsSet(d: ?*anyopaque) void {
    mirrors.mp_state_ctx.thread.dict_globals = d;
}

// VM_RETURN kinds (from runtime.h).
const VM_RETURN_NORMAL: c_int = 0;
const VM_RETURN_YIELD: c_int = 1;
const VM_RETURN_EXCEPTION: c_int = 2;

// ── MpObjGenInstance mirror ──────────────────────────────────────────
// Layout: { base, pend_exc, code_state: MpCodeState, then state[] flex }.
const MpObjGenInstance = extern struct {
    base: mirrors.MpObjBase,
    pend_exc: Obj,
    code_state: mirrors.MpCodeState,

    pub inline fn fromObj(o: Obj) *MpObjGenInstance {
        return @ptrFromInt(o);
    }
};

// ── mp_const_GeneratorExit_obj ───────────────────────────────────────
// Vendor: { {&mp_type_GeneratorExit}, 0, 0, NULL, (mp_obj_tuple_t *)&mp_const_empty_tuple_obj }
// Layout matches MpObjException (bitfield-packed tb_alloc/tb_len).
pub export const mp_const_GeneratorExit_obj: mirrors.MpObjException = .{
    .base = .{ .type = &mp_type_GeneratorExit },
    .tb_bits = .{ .traceback_alloc = 0, .traceback_len = 0 },
    .traceback_data = null,
    .args = @ptrCast(@alignCast(@constCast(&mp_const_empty_tuple_obj))),
};

// ── MP_BC_PRELUDE_SIG_DECODE_INTO (n_state + n_exc_stack) ────────────
// Faithful port; same logic as objfun.zig::decodePreludeSig.
inline fn decodePreludeSig(
    ip: *[*]const u8,
    n_state_out: *usize,
    n_exc_stack_out: *usize,
) void {
    var z = ip.*[0];
    ip.* += 1;
    var S: usize = (z >> 3) & 0xf;
    var E: usize = (z >> 2) & 0x1;
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

// ── gen_wrap_call ────────────────────────────────────────────────────
// Generating-fn constructor: decode prelude → alloc gen-instance with
// flex-area sized for state[] + exc-stack[] → mp_setup_code_state.
export fn gen_wrap_call(self_in: Obj, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    const self_fun = mirrors.MpObjFunBc.fromObj(self_in);

    var ip: [*]const u8 = self_fun.bytecode;
    var n_state: usize = 0;
    var n_exc_stack: usize = 0;
    decodePreludeSig(&ip, &n_state, &n_exc_stack);

    const flex_bytes = n_state * @sizeOf(Obj) + n_exc_stack * @sizeOf(mirrors.MpExcStack);
    const total = @sizeOf(MpObjGenInstance) + flex_bytes;
    const raw = mp_obj_malloc_helper(total, &mp_type_gen_instance);
    const o: *MpObjGenInstance = @ptrCast(@alignCast(raw));

    o.pend_exc = mirrors.OBJ_NONE;
    o.code_state.fun_bc = self_fun;
    o.code_state.n_state = @intCast(n_state);
    mp_setup_code_state(&o.code_state, n_args, n_kw, args);
    return @intFromPtr(o);
}

// ── mp_obj_gen_resume ────────────────────────────────────────────────
// Full port (direct field access via MpObjGenInstance mirror — no more
// accessor shims). Under nano: NATIVE_CODE=0 (no exc_sp_idx==SENTINEL
// branch) and PEND_THROW=0 (no pend-exc-as-throw); both gated.
export fn mp_obj_gen_resume(self_in: Obj, send_value: Obj, throw_value: Obj, ret_val: *Obj) callconv(.c) c_int {
    mp_cstack_check();
    std.debug.assert(mirrors.isExactType(self_in, &mp_type_gen_instance));

    const self = MpObjGenInstance.fromObj(self_in);

    if (@intFromPtr(self.code_state.ip) == 0) {
        // Already-stopped → optimised StopIteration(None).
        ret_val.* = mirrors.OBJ_NONE;
        return VM_RETURN_NORMAL;
    }

    // Reentrance guard: pend_exc == MP_OBJ_NULL means already executing.
    if (self.pend_exc == mirrors.OBJ_NULL) {
        ret_val.* = mp_obj_new_exception_msg(&mp_type_ValueError, "generator already executing");
        return VM_RETURN_EXCEPTION;
    }

    // PEND_THROW: if a pending exception was queued via .pend_throw(),
    // use it as the throw_value for this resume.
    var throw_value_mut = throw_value;
    if (comptime build_options.is_full) {
        if (self.pend_exc != mirrors.OBJ_NONE) {
            throw_value_mut = self.pend_exc;
        }
    }

    // sp == state - 1 ⇒ generator just started; can't accept send.
    const state_ptr = self.code_state.statePtr();
    const sp_is_state_start = @intFromPtr(self.code_state.sp) == @intFromPtr(state_ptr) - @sizeOf(Obj);
    if (sp_is_state_start) {
        if (send_value != mirrors.OBJ_NONE) {
            ret_val.* = mp_obj_new_exception_msg(&mp_type_TypeError, "can't send non-None value to a just-started generator");
            return VM_RETURN_EXCEPTION;
        }
    } else {
        self.code_state.sp[0] = send_value;
    }

    // Mark as running.
    self.pend_exc = mirrors.OBJ_NULL;

    // Set up globals for the generator's module, save the old.
    self.code_state.old_globals = globalsGet();
    const fun_bc = self.code_state.fun_bc.?;
    const ctx_as_module: *const mirrors.MpObjModule = @ptrCast(@alignCast(fun_bc.context));
    globalsSet(@ptrCast(ctx_as_module.globals));

    const ret_kind = mp_execute_bytecode(&self.code_state, throw_value_mut);
    globalsSet(self.code_state.old_globals);

    // Mark as not running.
    self.pend_exc = mirrors.OBJ_NONE;

    if (ret_kind == VM_RETURN_YIELD) {
        ret_val.* = self.code_state.sp[0];
        // PEND_THROW: clear sp slot so a subsequent pend_throw read of the
        // top-of-stack doesn't see the previous yielded value.
        if (comptime build_options.is_full) {
            self.code_state.sp[0] = mirrors.OBJ_NONE;
        }
        return ret_kind;
    }
    if (ret_kind == VM_RETURN_EXCEPTION) {
        clearIp(&self.code_state);
        ret_val.* = state_ptr[0];
        // PEP 479: StopIteration raised inside a generator → RuntimeError.
        if (mp_obj_is_subclass_fast(@intFromPtr(mp_obj_get_type(ret_val.*)), @intFromPtr(&mp_type_StopIteration))) {
            ret_val.* = mp_obj_new_exception_msg(&mp_type_RuntimeError, "generator raised StopIteration");
        }
        return ret_kind;
    }
    // RETURN_NORMAL (or any other value — matches C default branch).
    clearIp(&self.code_state);
    ret_val.* = self.code_state.sp[0];
    return VM_RETURN_NORMAL;
}

// ── gen_resume_and_raise (dispatch helper) ───────────────────────────
fn genResumeAndRaiseImpl(self_in: Obj, send_value: Obj, throw_value: Obj, raise_stop_iteration: bool) PyError!Obj {
    var ret: Obj = 0;
    const kind = mp_obj_gen_resume(self_in, send_value, throw_value, &ret);

    if (kind == VM_RETURN_YIELD) {
        return ret;
    }
    if (kind == VM_RETURN_EXCEPTION) {
        pyerr.pending_exc = ret;
        return error.PyRaise;
    }
    // VM_RETURN_NORMAL.
    var v = ret;
    if (v == mirrors.OBJ_NONE) v = mirrors.OBJ_NULL;
    if (raise_stop_iteration) {
        try raiseStopIteration(v);
        unreachable;
    }
    return makeStopIteration(v);
}

export fn gen_instance_iternext(self_in: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, genResumeAndRaiseImpl(self_in, mirrors.OBJ_NONE, mirrors.OBJ_NULL, false));
}

export fn gen_instance_send(self_in: Obj, send_value: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, genResumeAndRaiseImpl(self_in, send_value, mirrors.OBJ_NULL, true));
}

export fn gen_instance_throw(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    // throw(type[, value[, traceback]]): args[0]=self, args[1..]=user args.
    var exc = args[1];
    if (n_args > 2 and args[2] != mirrors.OBJ_NONE) {
        exc = args[2];
    }
    return pyerr.bridge(Obj, genResumeAndRaiseImpl(args[0], mirrors.OBJ_NONE, exc, true));
}

fn genInstanceCloseImpl(self_in: Obj) PyError!Obj {
    var ret: Obj = 0;
    const kind = mp_obj_gen_resume(self_in, mirrors.OBJ_NONE, @intFromPtr(&mp_const_GeneratorExit_obj), &ret);

    if (kind == VM_RETURN_YIELD) {
        pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_RuntimeError, "generator ignored GeneratorExit");
        return error.PyRaise;
    }
    if (kind == VM_RETURN_EXCEPTION) {
        // Swallow GeneratorExit; re-raise anything else.
        const ret_type = mp_obj_get_type(ret);
        if (mp_obj_is_subclass_fast(@intFromPtr(ret_type), @intFromPtr(&mp_type_GeneratorExit))) {
            return mirrors.OBJ_NONE;
        }
        pyerr.pending_exc = ret;
        return error.PyRaise;
    }
    // VM_RETURN_NORMAL → successful close.
    return mirrors.OBJ_NONE;
}

export fn gen_instance_close(self_in: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, genInstanceCloseImpl(self_in));
}

// ── gen_instance_pend_throw (PEND_THROW; full only) ──────────────────
// Body uses mp_raise_ValueError (NLR host). Under full it sits behind a
// comptime gate; under nano the locals_dict entry is omitted via the
// same gate.
fn genInstancePendThrowImpl(self_in: Obj, exc_in: Obj) PyError!Obj {
    const self = MpObjGenInstance.fromObj(self_in);
    if (self.pend_exc == mirrors.OBJ_NULL) try raiseAlreadyExecutingValueError();
    const prev = self.pend_exc;
    self.pend_exc = exc_in;
    return prev;
}

export fn gen_instance_pend_throw(self_in: Obj, exc_in: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, genInstancePendThrowImpl(self_in, exc_in));
}

// ── gen_instance_print ───────────────────────────────────────────────
export fn gen_instance_print(print_in: ?*const anyopaque, self_in: Obj, kind: c_int) callconv(.c) void {
    _ = kind;
    const self = MpObjGenInstance.fromObj(self_in);
    const fun_bc_obj: Obj = @intFromPtr(self.code_state.fun_bc);
    _ = mp_printf(
        print_in,
        "<generator object '%q' at 0x%p>",
        @as(usize, mp_obj_fun_get_name(fun_bc_obj)),
        self,
    );
}

// ── ROM: method fn-objs + locals_dict + types ────────────────────────

pub export const gen_instance_send_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&gen_instance_send),
};

// throw signature: (n_args: 2..4). MP_DEFINE_CONST_FUN_OBJ_VAR_BETWEEN.
pub export const gen_instance_throw_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(2, 4, false),
    .fun = @ptrCast(&gen_instance_throw),
};

extern const mp_type_fun_builtin_1: anyopaque;

pub export const gen_instance_close_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_1 },
    .fun = @ptrCast(&gen_instance_close),
};

const RomEntry = extern struct {
    key: Obj,
    value: *const anyopaque,
};

// PEND_THROW gated entry (full only). Under nano the locals dict has 3
// entries; under full, 4. Two ROM tables; pick at comptime.
const locals_dict_table_nano = [_]RomEntry{
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_close)), .value = &gen_instance_close_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_send)), .value = &gen_instance_send_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_throw)), .value = &gen_instance_throw_obj },
};

pub export const gen_instance_pend_throw_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&gen_instance_pend_throw),
};

const locals_dict_table_full = [_]RomEntry{
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_close)), .value = &gen_instance_close_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_send)), .value = &gen_instance_send_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_throw)), .value = &gen_instance_throw_obj },
    .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_pend_throw)), .value = &gen_instance_pend_throw_obj },
};

const locals_dict_table_len: usize = if (build_options.is_full) locals_dict_table_full.len else locals_dict_table_nano.len;

const locals_dict_table_ptr: *const anyopaque = if (build_options.is_full)
    @ptrCast(&locals_dict_table_full)
else
    @ptrCast(&locals_dict_table_nano);

pub export const gen_instance_locals_dict: mirrors.MpObjDict = .{
    .base = .{ .type = &mp_type_dict },
    .map = .{
        .bits = .{ .all_keys_are_qstrs = 1, .is_fixed = 1, .is_ordered = 1, .used = locals_dict_table_len },
        .alloc = locals_dict_table_len,
        .table = @ptrCast(@constCast(locals_dict_table_ptr)),
    },
};

// MP_TYPE_FLAG_BINDS_SELF = 0x0020. FUNCTION_ATTRS=1 → attr slot live.
// Order in MP_DEFINE_CONST_OBJ_TYPE: attr, mp_obj_fun_bc_attr, call, gen_wrap_call
// ⇒ attr=slot 1 (slots[0]), call=slot 2 (slots[1]).
pub export const mp_type_gen_wrap: types.MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = 0x0020, // MP_TYPE_FLAG_BINDS_SELF
        .name = mp.MP_QSTR_generator,
        .slot_index_make_new = 0,
        .slot_index_print = 0,
        .slot_index_call = 2,
        .slot_index_unary_op = 0,
        .slot_index_binary_op = 0,
        .slot_index_attr = 1,
        .slot_index_subscr = 0,
        .slot_index_iter = 0,
        .slot_index_buffer = 0,
        .slot_index_protocol = 0,
        .slot_index_parent = 0,
        .slot_index_locals_dict = 0,
    },
    .slots = .{
        @ptrCast(&mp_obj_fun_bc_attr),
        @ptrCast(&gen_wrap_call),
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

// MP_TYPE_FLAG_ITER_IS_ITERNEXT = 0x0080.
// Order: print, gen_instance_print, iter, gen_instance_iternext, locals_dict, &gen_instance_locals_dict
// ⇒ print=slot 1 (slots[0]), iter=slot 2 (slots[1]), locals_dict=slot 3 (slots[2]).
pub export const mp_type_gen_instance: types.MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = 0x0080, // MP_TYPE_FLAG_ITER_IS_ITERNEXT
        .name = mp.MP_QSTR_generator,
        .slot_index_make_new = 0,
        .slot_index_print = 1,
        .slot_index_call = 0,
        .slot_index_unary_op = 0,
        .slot_index_binary_op = 0,
        .slot_index_attr = 0,
        .slot_index_subscr = 0,
        .slot_index_iter = 2,
        .slot_index_buffer = 0,
        .slot_index_protocol = 0,
        .slot_index_parent = 0,
        .slot_index_locals_dict = 3,
    },
    .slots = .{
        @ptrCast(&gen_instance_print),
        @ptrCast(&gen_instance_iternext),
        @ptrCast(&gen_instance_locals_dict),
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
    _ = &mp_const_GeneratorExit_obj;
    _ = &gen_wrap_call;
    _ = &mp_obj_gen_resume;
    _ = &genResumeAndRaiseImpl;
    _ = &gen_instance_iternext;
    _ = &gen_instance_send;
    _ = &gen_instance_throw;
    _ = &genInstanceCloseImpl;
    _ = &gen_instance_close;
    _ = &genInstancePendThrowImpl;
    _ = &gen_instance_pend_throw;
    _ = &gen_instance_print;
    _ = &gen_instance_send_obj;
    _ = &gen_instance_throw_obj;
    _ = &gen_instance_close_obj;
    _ = &gen_instance_pend_throw_obj;
    _ = &gen_instance_locals_dict;
    _ = &mp_type_gen_wrap;
    _ = &mp_type_gen_instance;
}
