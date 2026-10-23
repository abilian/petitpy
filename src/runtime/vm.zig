//! petitpy VM — Zig port of py/vm.c (Phase 2.4.3, the keystone).
//!
//! `mp_execute_bytecode` (the ~77-opcode dispatch loop, the ONLY
//! remaining setjmp host). Design = trampoline-hosted OUTER LOOP:
//! Zig owns the `for(;;)` + exception_handler; each iteration runs the
//! opcode dispatch via the proven C `npy_nlr_run` trampoline (§2.4.1).
//! @cImports ONLY the two bc.h-free headers
//! (npy_vm_api.h + npy_nlr_trampoline.h) — `mp_code_state_t` is THE
//! translate-c flexible-array type, never @cImported.
//!
//! ┌─ STATUS: ✅ DONE & WIRED (batch 6, 2026-05-19). Full host +
//! │  exception_handler + all 75 opcodes + ENTRY_DEFAULT + prologue.
//! │  py/vm.c excluded from the C build (build.zig strangled[]),
//! │  compiles 0×; mp_execute_bytecode is this Zig export; corpus
//! └─ 550/550 byte-identical. One wiring bug (STORE_COMP) found+fixed.

const mp = @cImport({
    @cInclude("py/runtime.h");
    @cInclude("py/bc0.h");
    @cInclude("py/qstr.h");
});
const pyerr = @import("../pyerr.zig");
const mirrors = @import("../mp_mirrors.zig");
const build_options = @import("build_options");
const builtin = @import("builtin");

const Obj = mirrors.Obj; // mp_obj_t (= usize under REPR_A)
const CodeState = ?*anyopaque; // mp_code_state_t * (opaque — bc.h reason)

// W6 long-tail batch: eliminate 13 pure type-cast wrappers in
// npy_vm_shim.c by calling the bridged Zig exports directly via extern
// fn. Each elim removes 1 C frame from the bytecode-dispatch raise
// path → pure Zig→Zig dispatch chain.
// qstr = uintptr_t = usize in this build (matches runtime.zig's Qstr).
const Qstr = usize;
extern fn mp_load_name(q: Qstr) callconv(.c) Obj;
extern fn mp_load_global(q: Qstr) callconv(.c) Obj;
extern fn mp_load_attr(base: Obj, q: Qstr) callconv(.c) Obj;
extern fn mp_load_method(base: Obj, q: Qstr, dest: [*c]Obj) callconv(.c) void;
extern fn mp_store_attr(base: Obj, q: Qstr, value: Obj) callconv(.c) void;
extern fn mp_getiter(o: Obj, iter_buf: ?*anyopaque) callconv(.c) Obj;
extern fn mp_iternext_allow_raise(o: Obj) callconv(.c) Obj;
extern fn mp_unpack_sequence(seq: Obj, n: usize, items: [*c]Obj) callconv(.c) void;
extern fn mp_unpack_ex(seq: Obj, n: usize, items: [*c]Obj) callconv(.c) void;
extern fn mp_call_function_n_kw(fun: Obj, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj;
extern fn mp_unary_op(op: c_int, arg: Obj) callconv(.c) Obj;
extern fn mp_binary_op(op: c_int, lhs: Obj, rhs: Obj) callconv(.c) Obj;
extern fn mp_import_from(module: Obj, name: Qstr) callconv(.c) Obj;
// Cleanup pass: retire pure pass-through npy_vm_* wrappers.
extern fn mp_obj_subscr(base: Obj, index: Obj, value: Obj) callconv(.c) Obj;
extern fn mp_load_build_class() callconv(.c) Obj;
extern fn mp_load_super_method(attr: Qstr, dest: [*c]Obj) callconv(.c) void;
extern fn mp_store_name(qst: Qstr, obj: Obj) callconv(.c) void;
extern fn mp_store_global(qst: Qstr, obj: Obj) callconv(.c) void;
extern fn mp_delete_name(qst: Qstr) callconv(.c) void;
extern fn mp_delete_global(qst: Qstr) callconv(.c) void;
extern fn mp_obj_new_tuple(n: usize, items: [*c]const Obj) callconv(.c) Obj;
extern fn mp_obj_new_list(n: usize, items: [*c]const Obj) callconv(.c) Obj;
extern fn mp_obj_new_dict(n: usize) callconv(.c) Obj;
// mp_obj_cell_get/set are static inline — wrappers stay.
extern fn mp_obj_is_true(o: Obj) callconv(.c) bool;
// Stage 6 Tier B: direct extern fns retiring `npy_vm_obj_new_slice`
// and `npy_vm_resume`. `mp_obj_is_small_int` is `static inline` in
// vendor obj.h (no symbol), `mp_warning` is `#define ... empty` when
// MICROPY_WARNINGS=0 (nano default) — both wrappers must stay.
extern fn mp_obj_new_slice(start: Obj, stop: Obj, step: Obj) callconv(.c) Obj;
extern fn mp_resume(self: Obj, send_value: Obj, throw_value: Obj, ret_val: *Obj) callconv(.c) c_int;
extern fn mp_obj_dict_store(d: Obj, k: Obj, v: Obj) callconv(.c) Obj;
extern fn mp_obj_new_set(n: usize, items: [*c]const Obj) callconv(.c) Obj;
extern fn mp_make_function_from_proto_fun(proto: usize, ctx: ?*const anyopaque, defargs: [*c]const Obj) callconv(.c) Obj;
extern fn mp_make_closure_from_proto_fun(proto: usize, ctx: ?*const anyopaque, n_closed: usize, args: [*c]const Obj) callconv(.c) Obj;
extern fn mp_call_method_n_kw(n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj;
extern fn mp_call_method_n_kw_var(have_self: bool, n_args_n_kw: usize, args: [*c]const Obj) callconv(.c) Obj;
extern fn mp_import_name(name: Qstr, fromlist: Obj, level: Obj) callconv(.c) Obj;
extern fn mp_import_all(module: Obj) callconv(.c) void;
extern fn mp_make_raise_obj(o: Obj) callconv(.c) Obj;
extern fn mp_obj_exception_match(e: Obj, et: Obj) callconv(.c) bool;
extern fn mp_obj_get_type(o: Obj) callconv(.c) ?*const anyopaque;
extern fn mp_obj_list_append(l: Obj, it: Obj) callconv(.c) Obj;
extern fn mp_obj_set_store(s: Obj, it: Obj) callconv(.c) Obj;
extern const mp_type_GeneratorExit: anyopaque;
// Stage 6 Tier E: exception constructor + type singletons used inline.
extern fn mp_obj_new_exception_msg(t: *const anyopaque, msg: [*:0]const u8) callconv(.c) Obj;
extern const mp_type_NameError: anyopaque;
extern const mp_type_NotImplementedError: anyopaque;
extern const mp_type_RuntimeError: anyopaque;
extern fn npy_exception_set_cause(exc: Obj, cause: Obj) callconv(.c) void;
extern fn mp_obj_is_exception_instance(o: Obj) callconv(.c) bool;
extern fn mp_obj_is_exception_type(o: Obj) callconv(.c) bool;
extern const mp_type_TypeError: anyopaque;
// Convenience constructors for the 3 retired vm_shim exception helpers.
inline fn newNameErrorLocal() Obj {
    return mp_obj_new_exception_msg(&mp_type_NameError, "local variable referenced before assignment");
}
inline fn newNoActiveExc() Obj {
    return mp_obj_new_exception_msg(&mp_type_RuntimeError, "no active exception to reraise");
}
inline fn newNotImplOpcode() Obj {
    return mp_obj_new_exception_msg(&mp_type_NotImplementedError, "opcode");
}

// Stage 6 Tier G: pending-exception polling. Under nano (SCHEDULER=0,
// VM_ABORT=0, PY_THREAD=0) the live body simplifies to:
//   if (MP_STATE_THREAD(mp_pending_exception) != MP_OBJ_NULL)
//       mp_handle_pending(true);
// `mp_handle_pending(true)` is a static-inline wrapper around
// mp_handle_pending_internal(MP_HANDLE_PENDING_CALLBACKS_AND_EXCEPTIONS=1).
extern fn mp_handle_pending_internal(behavior: c_int) callconv(.c) void;
inline fn pendingExcCheck() void {
    if (mirrors.mp_state_ctx.thread.mp_pending_exception != 0) {
        mp_handle_pending_internal(1); // CALLBACKS_AND_EXCEPTIONS
    }
}

// Stage 6 Tier H: exception_handler port externs.
extern fn mp_obj_is_subclass_fast(o: Obj, et: Obj) callconv(.c) bool;
extern fn mp_obj_exception_get_value(self_in: Obj) callconv(.c) Obj;
extern fn mp_decode_uint_value(ip: [*]const u8) callconv(.c) usize;
extern fn mp_decode_uint_skip(ip: [*]const u8) callconv(.c) [*]const u8;
// `mp_bytecode_get_source_line` + `mp_bytecode_decode_lineinfo` are static
// inline in bc.h:317-348 — port the bodies (lineinfo varint encoding).
inline fn bytecodeGetSourceLine(li_start: [*]const u8, top: [*]const u8, bc_in: usize) usize {
    var line_info: [*]const u8 = li_start;
    var bc_offset: usize = bc_in;
    var source_line: usize = 1;
    while (@intFromPtr(line_info) < @intFromPtr(top)) {
        const z: u8 = line_info[0];
        var bc_inc: usize = undefined;
        var line_inc: usize = undefined;
        if ((z & 0x80) == 0) {
            bc_inc = z & 0x1f;
            line_inc = z >> 5;
            line_info += 1;
        } else {
            bc_inc = z & 0xf;
            line_inc = (@as(usize, z) << 4 & 0x700) | line_info[1];
            line_info += 2;
        }
        if (bc_offset >= bc_inc) {
            bc_offset -= bc_inc;
            source_line += line_inc;
        } else break;
    }
    return source_line;
}
extern fn mp_obj_exception_add_traceback(exc: Obj, source_file: Qstr, source_line: usize, block_name: Qstr) callconv(.c) void;
extern const mp_const_GeneratorExit_obj: anyopaque;
extern const mp_type_StopIteration: anyopaque;
extern const mp_type_list: anyopaque;
extern fn mp_obj_instance_make_new(self_type: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj;

// MP_BC_PRELUDE_SIG_DECODE_INTO (bc.h:106-126). Returns n_pos_args + n_kwonly_args
// (the only fields the exception handler uses); ip advances past the prelude header.
inline fn preludeSigSkip(ip: *[*]const u8) struct { n_pos: usize, n_kw: usize } {
    var z: u8 = ip.*[0];
    ip.* += 1;
    var A: usize = z & 0x3;
    var K: usize = 0;
    var n: u5 = 0;
    while ((z & 0x80) != 0) : (n += 1) {
        z = ip.*[0];
        ip.* += 1;
        A |= @as(usize, z & 0x4) << n;
        K |= @as(usize, (z & 0x08) >> 3) << n;
    }
    return .{ .n_pos = A, .n_kw = K };
}

// MP_BC_PRELUDE_SIZE_DECODE_INTO (bc.h:148-162). Returns n_info, n_cell.
inline fn preludeSizeDecode(ip: *[*]const u8) struct { n_info: usize, n_cell: usize } {
    var z: u8 = undefined;
    var C: usize = 0;
    var I: usize = 0;
    var n: u5 = 0;
    while (true) : (n += 1) {
        z = ip.*[0];
        ip.* += 1;
        C |= @as(usize, z & 1) << n;
        I |= @as(usize, (z & 0x7e) >> 1) << (6 * n);
        if ((z & 0x80) == 0) break;
    }
    return .{ .n_info = I, .n_cell = C };
}

/// Vendor `vm.c` exception_handler body, ported verbatim from
/// `npy_vm_exception_handler` (vm_shim.c:33-159). Live arms under nano:
///   SYS_EXC_INFO=0 → no MP_STATE_VM(cur_exception) write
///   SELECTIVE_EXC_IP=0 → no ip -= 1
///   SYS_SETTRACE=0 → no TRACE_TICK call
///   STACKLESS=0 → no unwind_loop / prev-frame walk
/// Returns 1 → re-enter dispatch; 0 → propagate.
fn exceptionHandler(code_state: ?*anyopaque, exc: Obj) c_int {
    const csm = mirrors.MpCodeState.fromPtr(code_state);
    // exc_stack = csm.excStackPtr(); exc_sp = exc_stack + exc_sp_idx - 1
    // (only valid when exc_sp_idx >= 1).

    // StopIteration within FOR_ITER / YIELD_FROM fast-path.
    const exc_base: *const mirrors.MpObjBase = @ptrCast(@alignCast(mirrors.objToPtr(exc).?));
    const exc_type = mirrors.objFromPtr(exc_base.type);
    if (mp_obj_is_subclass_fast(exc_type, mirrors.objFromPtr(&mp_type_StopIteration))) {
        const cur_op = csm.ip[0];
        if (cur_op == mp.MP_BC_FOR_ITER) {
            var ipt: Op = csm.ip + 1;
            const ulab = decodeUlabel(&ipt);
            csm.ip = @ptrCast(ipt + ulab);
            const NSLOTS: usize = @intCast(mp.MP_OBJ_ITER_BUF_NSLOTS);
            csm.sp -= NSLOTS;
            return 1;
        } else if (cur_op == mp.MP_BC_YIELD_FROM) {
            csm.sp[0] = mp_obj_exception_get_value(exc);
            csm.ip += 1;
            return 1;
        }
    }

    // Traceback annotation (skip for re-raises / GeneratorExit).
    const cur_op = csm.ip[0];
    if (@intFromPtr(mirrors.objToPtr(exc).?) != @intFromPtr(&mp_const_GeneratorExit_obj)
        and cur_op != mp.MP_BC_END_FINALLY
        and cur_op != mp.MP_BC_RAISE_LAST)
    {
        var ip2: [*]const u8 = csm.fun_bc.?.bytecode;
        const sig = preludeSigSkip(&ip2);
        const sz = preludeSizeDecode(&ip2);
        const line_info_top = ip2 + sz.n_info;
        const bytecode_start = ip2 + sz.n_info + sz.n_cell;
        const bc: usize = @intFromPtr(csm.ip) - @intFromPtr(bytecode_start);
        var block_name: usize = mp_decode_uint_value(ip2);
        var i: usize = 0;
        const arg_count = 1 + sig.n_pos + sig.n_kw;
        while (i < arg_count) : (i += 1) {
            ip2 = mp_decode_uint_skip(ip2);
        }
        const ctx = csm.fun_bc.?.contextPtr();
        const qstr_table: [*]const u16 = @ptrFromInt(ctx.constants.qstr_table_or_source_file);
        block_name = qstr_table[block_name];
        const source_file: Qstr = qstr_table[0];
        const source_line = bytecodeGetSourceLine(ip2, line_info_top, bc);
        mp_obj_exception_add_traceback(exc, source_file, source_line, block_name);
    }

    // Pop exception blocks whose handlers are already past ip (nested).
    while (csm.exc_sp_idx >= 1 and @intFromPtr(csm.excSpPtr().handler) <= @intFromPtr(csm.ip)) {
        csm.exc_sp_idx -= 1; // POP_EXC_BLOCK
    }

    if (csm.exc_sp_idx >= 1) {
        // Catch — pass exception to bytecode handler.
        const esp = csm.excSpPtr();
        csm.ip = @ptrCast(esp.handler);
        const sp: [*c]Obj = @ptrCast(@alignCast(mirrors.MpTagPtr.ptr(esp.val_sp)));
        esp.prev_exc = mirrors.objToPtr(exc);
        const sp_after: [*c]Obj = sp + 1;
        sp_after[0] = exc; // PUSH(exc)
        csm.sp = sp_after;
        // exc_sp_idx unchanged (matches vendor: rewritten with same value).
        return 1;
    } else {
        // Propagate: stash exc in state[0]; sp invalid at this point.
        csm.statePtr()[0] = exc;
        // exc_sp_idx is already 0 here (loop exits when idx == 0).
        return 0;
    }
}

const TODO = "vm.zig: opcode dispatch not yet ported";

// Contract: the dispatch outcome
// travels OUT-OF-BAND via this ctx (npy_nlr_run discards the body
// return). The host detects a raise as exc!=null (C-longjmp path) OR
// outcome==.raised (Zig-RAISE path) — one handler, two detections.
const Outcome = enum(u8) { running, normal, yield, raised, ret_exc, reenter };
const Ctx = extern struct {
    code_state: ?*anyopaque,
    inject_exc: Obj,
    pending_exc: usize, // set with outcome=.raised on a Zig-level RAISE
    outcome: u8, // Outcome (u8 for a stable extern layout)
};

// The ~77-opcode dispatch loop — batch 4. Reads/writes code_state->
// ip/sp; syncs them (and exc_sp_idx) into the heap code_state BEFORE
// any raising op (R1 contract — heap survives the longjmp). A Python
// RAISE → set ctx.pending_exc, ctx.outcome=.raised, return. A clean
// terminal (RETURN_VALUE/YIELD) → set ctx.outcome accordingly, return.
// A C-runtime raise → longjmps to npy_nlr_run (unchanged, proven).
const Op = [*c]const u8;
inline fn decodeUint(ip: *Op) usize {
    var unum: usize = 0;
    while (true) {
        const b = ip.*[0];
        unum = (unum << 7) + (b & 0x7f);
        ip.* += 1;
        if ((b & 0x80) == 0) break;
    }
    return unum;
}
// MICROPY_EMIT_BYTECODE_USES_QSTR_TABLE=1 under BOTH nano and full —
// cascade from MICROPY_PERSISTENT_CODE_LOAD=1 (needed for the Zig
// compile bridge). Look up via fun_bc->context->constants.qstr_table[i].
inline fn decodeQstr(cs: ?*anyopaque, ip: *Op) Qstr {
    const i = decodeUint(ip);
    const csm = mirrors.MpCodeState.fromPtr(cs);
    const ctx = csm.fun_bc.?.contextPtr();
    const qstr_table: [*]const u16 = @ptrFromInt(ctx.constants.qstr_table_or_source_file);
    return @intCast(qstr_table[i]);
}
inline fn decodeUlabel(ip: *Op) usize {
    var ulab: usize = undefined;
    if ((ip.*[0] & 0x80) != 0) {
        ulab = (ip.*[0] & 0x7f) | (@as(usize, ip.*[1]) << 7);
        ip.* += 2;
    } else {
        ulab = ip.*[0];
        ip.* += 1;
    }
    return ulab;
}
inline fn decodeSlabel(ip: *Op) usize { // size_t holding a signed offset
    var slab: usize = undefined;
    if ((ip.*[0] & 0x80) != 0) {
        slab = ((ip.*[0] & 0x7f) | (@as(usize, ip.*[1]) << 7)) -% 0x4000;
        ip.* += 2;
    } else {
        slab = @as(usize, ip.*[0]) -% 0x40;
        ip.* += 1;
    }
    return slab;
}
inline fn jumpBy(ip: *Op, off: usize) void { // ip += off (size_t ptr arith)
    ip.* = @ptrFromInt(@intFromPtr(ip.*) +% off);
}
inline fn fastnAt(fastn: [*c]Obj, off: isize) [*c]Obj { // &fastn[off], off<=0
    return @ptrFromInt(@intFromPtr(fastn) +% (@as(usize, @bitCast(off)) *% @sizeOf(Obj)));
}
// Hot small-int cases of mp_binary_op, inlined into the loop; null
// means "not handled here" and the caller falls back to mp_binary_op.
// The sum or difference of two small ints can't overflow isize, so
// only the small-int range needs checking.
inline fn smallIntBinaryOp(op: c_int, lhs: Obj, rhs: Obj) ?Obj {
    if (!mirrors.isSmallInt(lhs) or !mirrors.isSmallInt(rhs)) return null;
    const a = mirrors.smallIntValue(lhs);
    const b = mirrors.smallIntValue(rhs);
    const r: isize = switch (op) {
        mp.MP_BINARY_OP_LESS => return mirrors.newBool(a < b),
        mp.MP_BINARY_OP_MORE => return mirrors.newBool(a > b),
        mp.MP_BINARY_OP_LESS_EQUAL => return mirrors.newBool(a <= b),
        mp.MP_BINARY_OP_MORE_EQUAL => return mirrors.newBool(a >= b),
        mp.MP_BINARY_OP_EQUAL => return mirrors.newBool(a == b),
        mp.MP_BINARY_OP_NOT_EQUAL => return mirrors.newBool(a != b),
        mp.MP_BINARY_OP_ADD, mp.MP_BINARY_OP_INPLACE_ADD => a + b,
        mp.MP_BINARY_OP_SUBTRACT, mp.MP_BINARY_OP_INPLACE_SUBTRACT => a - b,
        else => return null,
    };
    return if (mirrors.smallIntFits(r)) mirrors.newSmallInt(r) else null;
}
// Bool fast path for the conditional jumps (comparisons push exact
// True/False); anything else goes through mp_obj_is_true.
inline fn isTrue(o: Obj) bool {
    if (o == mirrors.OBJ_TRUE) return true;
    if (o == mirrors.OBJ_FALSE) return false;
    return mp_obj_is_true(o);
}
// `list[small_int]` for an exact list and an in-range index, inlined
// into LOAD_SUBSCR/STORE_SUBSCR. null falls back to mp_obj_subscr,
// which handles subclasses, slices and the IndexError.
inline fn listSlot(base: Obj, index: Obj) ?*Obj {
    if (!mirrors.isSmallInt(index) or !mirrors.isExactType(base, &mp_type_list)) return null;
    const list = mirrors.MpObjList.fromObj(base);
    var i = mirrors.smallIntValue(index);
    if (i < 0) i += @intCast(list.len);
    if (i < 0 or i >= list.len) return null;
    return &list.items[@intCast(i)];
}
// MICROPY_OPT_LOAD_ATTR_FAST_PATH (vendor vm.c): an instance of a user
// class keeps its attributes in its members map, which
// mp_obj_instance_load_attr also checks first; look there before the
// generic mp_load_attr. null falls back to mp_load_attr.
inline fn instanceMember(o: Obj, q: Qstr) ?Obj {
    if (!mirrors.isObj(o)) return null;
    const t = mirrors.MpObjType.fromPtr(mirrors.objBaseType(o));
    if (t.getSlot(.make_new) != @as(?*const anyopaque, @ptrCast(&mp_obj_instance_make_new))) return null;
    const members = &mirrors.MpObjInstance.fromObj(o).members;
    const elem = mirrors.mp_map_lookup(members, mirrors.objFromQstr(q), mirrors.MP_MAP_LOOKUP) orelse return null;
    return elem.value;
}
// Native threaded prongs that cannot leave an exception pending
// (constants, locals, stack shuffles, and the inline fast paths when they
// succeed) dispatch with poll=false: nothing was pending when they
// started, or the poll before them would have caught it. Bubble: -13%
// instructions, -2% cycles. Not on wasm, where every prong returns to one
// shared fetch: carrying the flag there cost more than the poll it saved
// (ADR 020 §2 C3).
// Threaded dispatch on native: every prong ends in `continue :dispatch
// fetch(...)`, so each opcode gets its own indirect branch (1.2-1.4x on
// fibo/bubble). On wasm each such continue becomes its own
// br_table, 1.3x slower under wasmtime than one shared dispatch, so
// prongs `continue` the enclosing loop instead. PENDING (not a byte
// value) routes a raise left by a bridge-wrapped call to its prong.
const threaded = !builtin.cpu.arch.isWasm();
const PENDING: u16 = 0x100;
inline fn fetch(csm: anytype, ip: *Op, op: *u16, poll: bool) u16 {
    // B2 polled-sentinel: check FIRST, before updating cs->ip. If
    // any bridge-wrapped fn raised in the previous opcode, cs->ip
    // is still pointing at THAT opcode's start, which is what
    // vm_exception_handler needs for correct WITH/FOR_ITER/etc.
    // context recognition.
    if (poll and pyerr.pending_exc != 0) return PENDING;
    csm.ip = ip.*; // MARK_EXC_IP_GLOBAL (auto ip-sync)
    op.* = ip.*[0];
    ip.* += 1;
    return op.*;
}
// wasm: V8 runs a function's baseline (Liftoff) code until the function
// is called again, since wasm has no on-stack replacement. A loop that
// never leaves one dispatchBody call stays on baseline code: bubble ran
// 3.6x slower than with TurboFan (ADR 020 §2 C2). So every REENTER_JUMPS
// jumps, dispatchBody saves ip/sp and returns to mp_execute_bytecode,
// which calls it again. Native compiles ahead of time: never.
const reenter_for_tier_up = builtin.cpu.arch.isWasm();
const REENTER_JUMPS: u32 = 1 << 16;
var jumps_until_reenter: u32 = REENTER_JUMPS;
/// Never while an exception is pending: dispatchBody clears it on entry.
inline fn reenterDue(ctx: *Ctx, csm: anytype, ip: Op, sp: [*c]Obj) bool {
    if (!reenter_for_tier_up) return false;
    jumps_until_reenter -= 1;
    if (jumps_until_reenter != 0) return false;
    jumps_until_reenter = REENTER_JUMPS;
    if (pyerr.pending_exc != 0) return false;
    csm.ip = ip;
    csm.sp = sp;
    ctx.outcome = @intFromEnum(Outcome.reenter);
    return true;
}
inline fn raise(ctx: *Ctx, exc: usize) ?*anyopaque {
    ctx.pending_exc = exc; // code_state->ip already synced (MARK_EXC_IP_GLOBAL)
    ctx.outcome = @intFromEnum(Outcome.raised);
    return null;
}
const Flow = enum { dispatch, ret }; // goto dispatch_loop vs return outcome
inline fn cancelActiveFinally(sp: *[*c]Obj) void { // CANCEL_ACTIVE_FINALLY(sp)
    if (mirrors.isSmallInt((sp.* - 1)[0])) {
        (sp.* - 2)[0] = sp.*[0];
        sp.* -= 2;
    } else {
        (sp.* - 1)[0] = sp.*[0];
        sp.* -= 1;
    }
}
fn unwindReturn(ctx: *Ctx, cs: ?*anyopaque, ip: *Op, sp: *[*c]Obj) Flow {
    const csm = mirrors.MpCodeState.fromPtr(cs);
    while (csm.exc_sp_idx >= 1) { // exc_sp >= exc_stack
        const esp = csm.excSpPtr();
        if (mirrors.MpTagPtr.tag1(esp.val_sp)) {
            if (@intFromPtr(esp.handler) >= @intFromPtr(ip.*)) {
                const finally_sp: [*c]Obj = @ptrCast(@alignCast(mirrors.MpTagPtr.ptr(esp.val_sp)));
                (finally_sp + 1)[0] = sp.*[0];
                sp.* = finally_sp + 1;
                sp.* += 1; // PUSH(MP_OBJ_NEW_SMALL_INT(-1)) — finally sentinel
                sp.*[0] = mirrors.newSmallInt(-1);
                ip.* = @ptrCast(esp.handler);
                return .dispatch; // goto dispatch_loop
            } else {
                cancelActiveFinally(sp);
            }
        }
        csm.exc_sp_idx -= 1; // POP_EXC_BLOCK
    }
    csm.sp = sp.*; // code_state->sp = sp (STACKLESS dead)
    ctx.outcome = @intFromEnum(Outcome.normal);
    return .ret; // FRAME_LEAVE noop; return MP_VM_RETURN_NORMAL
}
fn unwindJump(ctx: *Ctx, cs: ?*anyopaque, ip: *Op, sp: *[*c]Obj) Flow {
    _ = ctx;
    const csm = mirrors.MpCodeState.fromPtr(cs);
    var unum: usize = sp.*[0]; // (mp_uint_t)POP()
    sp.* -= 1;
    while ((unum & 0x7f) > 0) {
        unum -%= 1;
        if (csm.exc_sp_idx >= 1 and mirrors.MpTagPtr.tag1(csm.excSpPtr().val_sp)) {
            if (@intFromPtr(csm.excSpPtr().handler) >= @intFromPtr(ip.*)) {
                sp.* += 1;
                sp.*[0] = mirrors.newSmallInt(@bitCast(unum)); // sentinel
                ip.* = @ptrCast(csm.excSpPtr().handler);
                return .dispatch; // goto dispatch_loop
            } else {
                cancelActiveFinally(sp);
            }
        }
        csm.exc_sp_idx -= 1; // POP_EXC_BLOCK
    }
    ip.* = @ptrFromInt(sp.*[0]); // (const byte*)MP_OBJ_TO_PTR(POP())
    sp.* -= 1;
    if (unum != 0) {
        const NSLOTS: usize = @intCast(mp.MP_OBJ_ITER_BUF_NSLOTS);
        sp.* -= NSLOTS; // pop the exhausted iterator
    }
    pendingExcCheck(); // DISPATCH_WITH_PEND_EXC_CHECK
    return .dispatch;
}
fn dispatchBody(ctx_in: ?*anyopaque) callconv(.c) ?*anyopaque {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_in));
    const cs = ctx.code_state;
    const csm = mirrors.MpCodeState.fromPtr(cs);
    var ip: Op = csm.ip;
    var sp: [*c]Obj = csm.sp;
    const fastn: [*c]Obj = @ptrCast(csm.statePtr() + csm.n_state - 1);
    pyerr.pending_exc = 0; // B2 polled-sentinel: clear on entry
    // MICROPY_VM_HOOK_INIT empty (nano). If we have an exception to
    // inject, raise it now (as if MP_BC_RAISE_OBJ ran) — except YIELD_FROM
    // handles injection itself. Runs each dispatchBody entry; cleared
    // after first use (faithful: C runs this on every nlr_push).
    if (ctx.inject_exc != 0 and @as(c_int, ip[0]) != mp.MP_BC_YIELD_FROM) {
        const e = ctx.inject_exc;
        ctx.inject_exc = 0;
        return raise(ctx, mp_make_raise_obj(e));
    }
    var op: u16 = undefined;
    while (true) dispatch: switch (fetch(csm, &ip, &op, true)) {
    PENDING => {
        const exc = pyerr.pending_exc;
        pyerr.pending_exc = 0;
        return raise(ctx, exc);
    },
        mp.MP_BC_LOAD_CONST_FALSE => {
            sp += 1;
            sp[0] = mirrors.OBJ_FALSE;
            if (threaded) continue :dispatch fetch(csm, &ip, &op, false) else continue;
        },
        mp.MP_BC_LOAD_CONST_NONE => {
            sp += 1;
            sp[0] = mirrors.OBJ_NONE;
            if (threaded) continue :dispatch fetch(csm, &ip, &op, false) else continue;
        },
        mp.MP_BC_LOAD_CONST_TRUE => {
            sp += 1;
            sp[0] = mirrors.OBJ_TRUE;
            if (threaded) continue :dispatch fetch(csm, &ip, &op, false) else continue;
        },
        mp.MP_BC_LOAD_CONST_SMALL_INT => {
            var num: usize = 0;
            if ((ip[0] & 0x40) != 0) num -%= 1; // sign-extend
            while (true) {
                const b = ip[0];
                num = (num << 7) | (b & 0x7f);
                ip += 1;
                if ((b & 0x80) == 0) break;
            }
            sp += 1;
            sp[0] = mirrors.newSmallInt(@bitCast(num));
            if (threaded) continue :dispatch fetch(csm, &ip, &op, false) else continue;
        },
        mp.MP_BC_LOAD_CONST_STRING => {
            const q = decodeQstr(cs, &ip);
            sp += 1;
            sp[0] = mirrors.objFromQstr(q);
            if (threaded) continue :dispatch fetch(csm, &ip, &op, false) else continue;
        },
        mp.MP_BC_LOAD_CONST_OBJ => {
            const u = decodeUint(&ip);
            sp += 1;
            sp[0] = csm.fun_bc.?.contextPtr().constants.obj_table[u];
            if (threaded) continue :dispatch fetch(csm, &ip, &op, false) else continue;
        },
        mp.MP_BC_LOAD_NULL => {
            sp += 1;
            sp[0] = 0; // MP_OBJ_NULL
            if (threaded) continue :dispatch fetch(csm, &ip, &op, false) else continue;
        },
        mp.MP_BC_LOAD_FAST_N => {
            const u = decodeUint(&ip);
            const v = (fastn - u)[0];
            if (v == 0) return raise(ctx, newNameErrorLocal());
            sp += 1;
            sp[0] = v;
            if (threaded) continue :dispatch fetch(csm, &ip, &op, false) else continue;
        },
        mp.MP_BC_LOAD_DEREF => {
            const u = decodeUint(&ip);
            const v = mirrors.MpObjCell.cellGet((fastn - u)[0]); // goto load_check
            if (v == 0) return raise(ctx, newNameErrorLocal());
            sp += 1;
            sp[0] = v;
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_LOAD_NAME => {
            const q = decodeQstr(cs, &ip);
            sp += 1;
            sp[0] = mp_load_name(q);
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_LOAD_GLOBAL => {
            const q = decodeQstr(cs, &ip);
            sp += 1;
            sp[0] = mp_load_global(q);
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_LOAD_ATTR => {
            const q = decodeQstr(cs, &ip);
            sp[0] = instanceMember(sp[0], q) orelse mp_load_attr(sp[0], q);
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_LOAD_METHOD => {
            const q = decodeQstr(cs, &ip);
            mp_load_method(sp[0], q, sp);
            sp += 1;
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_LOAD_SUPER_METHOD => {
            const q = decodeQstr(cs, &ip);
            sp -= 1;
            mp_load_super_method(q, sp - 1);
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_LOAD_BUILD_CLASS => {
            sp += 1;
            sp[0] = mp_load_build_class();
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_LOAD_SUBSCR => {
            const index = sp[0];
            sp -= 1;
            if (listSlot(sp[0], index)) |slot| {
                sp[0] = slot.*;
                if (threaded) continue :dispatch fetch(csm, &ip, &op, false) else continue;
            }
            sp[0] = mp_obj_subscr(sp[0], index, mirrors.OBJ_SENTINEL);
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_STORE_FAST_N => {
            const u = decodeUint(&ip);
            const val = sp[0];
            sp -= 1; // POP()
            (fastn - u)[0] = val;
            if (threaded) continue :dispatch fetch(csm, &ip, &op, false) else continue;
        },
        mp.MP_BC_STORE_DEREF => {
            const u = decodeUint(&ip);
            const val = sp[0];
            sp -= 1;
            mirrors.MpObjCell.cellSet((fastn - u)[0], val);
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_STORE_NAME => {
            const q = decodeQstr(cs, &ip);
            const val = sp[0];
            sp -= 1;
            mp_store_name(q, val);
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_STORE_GLOBAL => {
            const q = decodeQstr(cs, &ip);
            const val = sp[0];
            sp -= 1;
            mp_store_global(q, val);
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_STORE_ATTR => {
            const q = decodeQstr(cs, &ip);
            mp_store_attr(sp[0], q, (sp - 1)[0]);
            sp -= 2;
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_STORE_SUBSCR => {
            // value NULL is `del x[i]` (DELETE_SUBSCR = LOAD_NULL + STORE_SUBSCR)
            const slot = if ((sp - 2)[0] != mirrors.OBJ_NULL) listSlot((sp - 1)[0], sp[0]) else null;
            if (slot) |s| {
                s.* = (sp - 2)[0];
                sp -= 3;
                if (threaded) continue :dispatch fetch(csm, &ip, &op, false) else continue;
            }
            _ = mp_obj_subscr((sp - 1)[0], sp[0], (sp - 2)[0]);
            sp -= 3;
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_DELETE_FAST => {
            const u = decodeUint(&ip);
            if ((fastn - u)[0] == 0) return raise(ctx, newNameErrorLocal());
            (fastn - u)[0] = 0; // MP_OBJ_NULL
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_DELETE_DEREF => {
            const u = decodeUint(&ip);
            if (mirrors.MpObjCell.cellGet((fastn - u)[0]) == 0) return raise(ctx, newNameErrorLocal());
            mirrors.MpObjCell.cellSet((fastn - u)[0], 0);
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_DELETE_NAME => {
            const q = decodeQstr(cs, &ip);
            mp_delete_name(q);
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_DELETE_GLOBAL => {
            const q = decodeQstr(cs, &ip);
            mp_delete_global(q);
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_DUP_TOP => {
            const top = sp[0];
            sp += 1;
            sp[0] = top;
            if (threaded) continue :dispatch fetch(csm, &ip, &op, false) else continue;
        },
        mp.MP_BC_DUP_TOP_TWO => {
            sp += 2;
            sp[0] = (sp - 2)[0];
            (sp - 1)[0] = (sp - 3)[0];
            if (threaded) continue :dispatch fetch(csm, &ip, &op, false) else continue;
        },
        mp.MP_BC_POP_TOP => {
            sp -= 1;
            if (threaded) continue :dispatch fetch(csm, &ip, &op, false) else continue;
        },
        mp.MP_BC_ROT_TWO => {
            const top = sp[0];
            sp[0] = (sp - 1)[0];
            (sp - 1)[0] = top;
            if (threaded) continue :dispatch fetch(csm, &ip, &op, false) else continue;
        },
        mp.MP_BC_ROT_THREE => {
            const top = sp[0];
            sp[0] = (sp - 1)[0];
            (sp - 1)[0] = (sp - 2)[0];
            (sp - 2)[0] = top;
            if (threaded) continue :dispatch fetch(csm, &ip, &op, false) else continue;
        },
        mp.MP_BC_JUMP => {
            const slab = decodeSlabel(&ip);
            jumpBy(&ip, slab);
            pendingExcCheck(); // DISPATCH_WITH_PEND_EXC_CHECK
            if (reenterDue(ctx, csm, ip, sp)) return null;
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_POP_JUMP_IF_TRUE => {
            const slab = decodeSlabel(&ip);
            const t = sp[0];
            sp -= 1; // POP()
            if (isTrue(t)) jumpBy(&ip, slab);
            pendingExcCheck();
            if (reenterDue(ctx, csm, ip, sp)) return null;
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_POP_JUMP_IF_FALSE => {
            const slab = decodeSlabel(&ip);
            const t = sp[0];
            sp -= 1;
            if (!isTrue(t)) jumpBy(&ip, slab);
            pendingExcCheck();
            if (reenterDue(ctx, csm, ip, sp)) return null;
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_JUMP_IF_TRUE_OR_POP => {
            const ulab = decodeUlabel(&ip);
            if (isTrue(sp[0])) jumpBy(&ip, ulab) else sp -= 1;
            pendingExcCheck();
            if (reenterDue(ctx, csm, ip, sp)) return null;
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_JUMP_IF_FALSE_OR_POP => {
            const ulab = decodeUlabel(&ip);
            if (isTrue(sp[0])) sp -= 1 else jumpBy(&ip, ulab);
            pendingExcCheck();
            if (reenterDue(ctx, csm, ip, sp)) return null;
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_GET_ITER => {
            sp[0] = mp_getiter(sp[0], null);
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_GET_ITER_STACK => {
            const NSLOTS: usize = @intCast(mp.MP_OBJ_ITER_BUF_NSLOTS);
            const obj0 = sp[0];
            const iter_buf = sp;
            sp += NSLOTS - 1;
            const it = mp_getiter(obj0, iter_buf);
            if (it != mirrors.objFromPtr(iter_buf)) {
                (sp - (NSLOTS - 1))[0] = 0; // *(sp-NSLOTS+1) = MP_OBJ_NULL
                (sp - (NSLOTS - 2))[0] = it; // *(sp-NSLOTS+2) = obj
            }
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_FOR_ITER => {
            const ulab = decodeUlabel(&ip);
            const NSLOTS: usize = @intCast(mp.MP_OBJ_ITER_BUF_NSLOTS);
            csm.sp = sp; // code_state->sp = sp (pre-raise sync, R1)
            const base1 = sp - (NSLOTS - 1); // &sp[-NSLOTS+1]
            const iobj = if (base1[0] == 0) (sp - (NSLOTS - 2))[0] else mirrors.objFromPtr(base1);
            const value = mp_iternext_allow_raise(iobj);
            if (value == mirrors.OBJ_STOP_ITERATION) {
                sp -= NSLOTS;
                jumpBy(&ip, ulab);
            } else {
                sp += 1;
                sp[0] = value; // SYS_SETTRACE block dead
            }
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_BUILD_TUPLE => {
            const u = decodeUint(&ip);
            sp -= u -% 1;
            sp[0] = mp_obj_new_tuple(u, sp);
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_BUILD_LIST => {
            const u = decodeUint(&ip);
            sp -= u -% 1;
            sp[0] = mp_obj_new_list(u, sp);
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_BUILD_MAP => {
            const u = decodeUint(&ip);
            sp += 1;
            sp[0] = mp_obj_new_dict(u);
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_BUILD_SET => {
            const u = decodeUint(&ip);
            sp -= u -% 1;
            sp[0] = mp_obj_new_set(u, sp);
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_BUILD_SLICE => {
            // Slice can be 2-arg (start, stop) or 3-arg (start, stop, step).
            // The 1-byte arg after the op selects which.
            const n_args = ip[0];
            ip += 1;
            var step: Obj = mirrors.OBJ_NONE;
            if (n_args == 3) {
                step = sp[0];
                sp -= 1;
            }
            const stop = sp[0];
            sp -= 1;
            sp[0] = mp_obj_new_slice(sp[0], stop, step);
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_STORE_MAP => {
            sp -= 2;
            _ = mp_obj_dict_store(sp[0], sp[2], sp[1]);
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_UNPACK_SEQUENCE => {
            const u = decodeUint(&ip);
            mp_unpack_sequence(sp[0], u, sp);
            sp += u -% 1;
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_UNPACK_EX => {
            const u = decodeUint(&ip);
            mp_unpack_ex(sp[0], u, sp);
            sp += (u & 0xff) + ((u >> 8) & 0xff);
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_MAKE_FUNCTION => {
            const u = decodeUint(&ip);
            const ptr = csm.fun_bc.?.childTablePtr(u); // DECODE_PTR
            sp += 1;
            sp[0] = mp_make_function_from_proto_fun(ptr, csm.fun_bc.?.context, null);
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_MAKE_FUNCTION_DEFARGS => {
            const u = decodeUint(&ip);
            const ptr = csm.fun_bc.?.childTablePtr(u);
            sp -= 1;
            sp[0] = mp_make_function_from_proto_fun(ptr, csm.fun_bc.?.context, sp);
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_MAKE_CLOSURE => {
            const u = decodeUint(&ip);
            const ptr = csm.fun_bc.?.childTablePtr(u);
            const nco: usize = ip[0];
            ip += 1;
            sp -= nco -% 1;
            sp[0] = mp_make_closure_from_proto_fun(ptr, csm.fun_bc.?.context, nco, sp);
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_MAKE_CLOSURE_DEFARGS => {
            const u = decodeUint(&ip);
            const ptr = csm.fun_bc.?.childTablePtr(u);
            const nco: usize = ip[0];
            ip += 1;
            sp -= (2 +% nco) -% 1;
            sp[0] = mp_make_closure_from_proto_fun(ptr, csm.fun_bc.?.context, 0x100 | nco, sp);
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_CALL_FUNCTION => {
            const u = decodeUint(&ip);
            sp -= (u & 0xff) + ((u >> 7) & 0x1fe);
            sp[0] = mp_call_function_n_kw(sp[0], u & 0xff, (u >> 8) & 0xff, sp + 1);
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_CALL_FUNCTION_VAR_KW => {
            const u = decodeUint(&ip);
            sp -= (u & 0xff) + ((u >> 7) & 0x1fe) + 1;
            sp[0] = mp_call_method_n_kw_var(false, u, sp);
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_CALL_METHOD => {
            const u = decodeUint(&ip);
            sp -= (u & 0xff) + ((u >> 7) & 0x1fe) + 1;
            sp[0] = mp_call_method_n_kw(u & 0xff, (u >> 8) & 0xff, sp);
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_CALL_METHOD_VAR_KW => {
            const u = decodeUint(&ip);
            sp -= (u & 0xff) + ((u >> 7) & 0x1fe) + 2;
            sp[0] = mp_call_method_n_kw_var(true, u, sp);
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_IMPORT_NAME => {
            const q = decodeQstr(cs, &ip);
            const o = sp[0];
            sp -= 1; // POP()
            sp[0] = mp_import_name(q, o, sp[0]);
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_IMPORT_FROM => {
            const q = decodeQstr(cs, &ip);
            const o = mp_import_from(sp[0], q);
            sp += 1;
            sp[0] = o;
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_IMPORT_STAR => {
            const o = sp[0];
            sp -= 1;
            mp_import_all(o);
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_SETUP_EXCEPT, mp.MP_BC_SETUP_FINALLY => {
            // wf: code_state->ip[0] == SETUP_FINALLY (== op here; ip synced
            // at loop top, not yet advanced past the opcode). SELECTIVE=0.
            const wf: u1 = if (op == mp.MP_BC_SETUP_FINALLY) 1 else 0;
            const ulab = decodeUlabel(&ip); // PUSH_EXC_BLOCK: DECODE_ULABEL
            const handler: [*c]const u8 = @ptrFromInt(@intFromPtr(ip) +% ulab);
            csm.pushExcBlock(@ptrCast(handler), @intFromPtr(sp), wf);
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_END_FINALLY => {
            csm.exc_sp_idx -= 1; // POP_EXC_BLOCK
            if (sp[0] == mirrors.OBJ_NONE) {
                sp -= 1;
            } else if (mirrors.isSmallInt(sp[0])) {
                const cause: isize = mirrors.smallIntValue(sp[0]);
                sp -= 1; // POP()
                if (cause < 0) {
                    switch (unwindReturn(ctx, cs, &ip, &sp)) {
                        .dispatch => if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue,
                        .ret => return null,
                    }
                } else {
                    sp += 1;
                    sp[0] = @bitCast(cause); // PUSH((mp_obj_t)cause)
                    switch (unwindJump(ctx, cs, &ip, &sp)) {
                        .dispatch => if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue,
                        .ret => return null,
                    }
                }
            } else {
                return raise(ctx, sp[0]); // RAISE(TOP())
            }
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_UNWIND_JUMP => {
            const slab = decodeSlabel(&ip);
            sp += 1;
            sp[0] = @intFromPtr(ip) +% slab; // PUSH(dest ip)
            sp += 1;
            sp[0] = @as(Obj, ip[0]); // PUSH(*ip) (no advance)
            switch (unwindJump(ctx, cs, &ip, &sp)) {
                .dispatch => if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue,
                .ret => return null,
            }
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_POP_EXCEPT_JUMP => {
            csm.exc_sp_idx -= 1; // POP_EXC_BLOCK
            const ulab = decodeUlabel(&ip);
            jumpBy(&ip, ulab);
            pendingExcCheck();
            if (reenterDue(ctx, csm, ip, sp)) return null;
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_SETUP_WITH => {
            const obj = sp[0];
            mp_load_method(obj, @intCast(mp.MP_QSTR___exit__), sp);
            mp_load_method(obj, @intCast(mp.MP_QSTR___enter__), sp + 2);
            const ret = mp_call_method_n_kw(0, 0, sp + 2);
            // B2: if __enter__ raised, DON'T push the exc block — the
            // raise should propagate to the OUTER handler (per Python
            // spec: __exit__ only runs if __enter__ succeeded).
            if (pyerr.pending_exc != 0) {
                const exc = pyerr.pending_exc;
                pyerr.pending_exc = 0;
                return raise(ctx, exc);
            }
            sp += 1;
            const ulab = decodeUlabel(&ip); // PUSH_EXC_BLOCK(1)
            const handler: [*c]const u8 = @ptrFromInt(@intFromPtr(ip) +% ulab);
            csm.pushExcBlock(@ptrCast(handler), @intFromPtr(sp), 1);
            sp += 1;
            sp[0] = ret; // PUSH(ret)
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_WITH_CLEANUP => {
            if (sp[0] == mirrors.OBJ_NONE) {
                (sp + 1)[0] = mirrors.OBJ_NONE;
                (sp + 2)[0] = mirrors.OBJ_NONE;
                sp -= 2;
                _ = mp_call_method_n_kw(3, 0, sp);
                sp[0] = mirrors.OBJ_NONE; // SET_TOP(None)
            } else if (mirrors.isSmallInt(sp[0])) {
                const data = (sp - 1)[0];
                const cause = sp[0];
                (sp - 1)[0] = mirrors.OBJ_NONE;
                sp[0] = mirrors.OBJ_NONE;
                (sp + 1)[0] = mirrors.OBJ_NONE;
                _ = mp_call_method_n_kw(3, 0, sp - 3);
                (sp - 3)[0] = data;
                (sp - 2)[0] = cause;
                sp -= 2;
            } else { // exception instance
                (sp + 1)[0] = sp[0];
                sp[0] = @intFromPtr(mp_obj_get_type(sp[0]));
                (sp + 2)[0] = mirrors.OBJ_NONE;
                sp -= 2;
                const rv = mp_call_method_n_kw(3, 0, sp);
                if (mp_obj_is_true(rv)) {
                    sp[0] = mirrors.OBJ_NONE; // SET_TOP(None)
                } else {
                    sp[0] = (sp + 3)[0];
                }
            }
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_RETURN_VALUE => {
            switch (unwindReturn(ctx, cs, &ip, &sp)) { // unwind_return
                .dispatch => if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue,
                .ret => return null,
            }
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_RAISE_LAST => {
            var o = csm.excSpScanPrevExc();
            if (o == 0) o = newNoActiveExc();
            return raise(ctx, o);
        },
        mp.MP_BC_RAISE_OBJ => {
            return raise(ctx, mp_make_raise_obj(sp[0]));
        },
        mp.MP_BC_RAISE_FROM => {
            // `raise exc from cause` (PEP 3134): a class cause is
            // instantiated, None suppresses the context. Vendor warns
            // "exception chaining not supported" and drops the cause.
            const from_value = sp[0];
            sp -= 1; // POP()
            if (from_value != mirrors.OBJ_NONE and !mp_obj_is_exception_instance(from_value) and !mp_obj_is_exception_type(from_value)) {
                return raise(ctx, mp_obj_new_exception_msg(&mp_type_TypeError, "exception causes must derive from BaseException"));
            }
            const exc = mp_make_raise_obj(sp[0]);
            if (pyerr.pending_exc != 0) return raise(ctx, pyerr.pending_exc);
            const cause = if (from_value == mirrors.OBJ_NONE) from_value else mp_make_raise_obj(from_value);
            if (pyerr.pending_exc != 0) return raise(ctx, pyerr.pending_exc);
            npy_exception_set_cause(exc, cause);
            return raise(ctx, exc);
        },
        mp.MP_BC_YIELD_VALUE => {
            csm.ip = ip;
            csm.sp = sp;
            ctx.outcome = @intFromEnum(Outcome.yield);
            return null;
        },
        mp.MP_BC_YIELD_FROM => {
            const send_value = sp[0];
            sp -= 1; // POP()
            var t_exc: Obj = 0;
            csm.sp = sp; // needed if mp_resume raises StopIteration
            var ret_value: Obj = 0;
            var ret_kind: c_int = undefined;
            if (ctx.inject_exc != 0) {
                t_exc = ctx.inject_exc;
                ctx.inject_exc = 0;
                ret_kind = mp_resume(sp[0], 0, t_exc, &ret_value);
            } else {
                ret_kind = mp_resume(sp[0], send_value, 0, &ret_value);
            }
            if (ret_kind == mp.MP_VM_RETURN_YIELD) {
                ip -= 1;
                sp += 1;
                sp[0] = ret_value; // PUSH(ret_value); goto yield
                csm.ip = ip;
                csm.sp = sp;
                ctx.outcome = @intFromEnum(Outcome.yield);
                return null;
            } else if (ret_kind == mp.MP_VM_RETURN_NORMAL) {
                sp[0] = ret_value; // SET_TOP — generator returned via StopIteration
                if (t_exc != 0 and mp_obj_exception_match(t_exc, @intFromPtr(&mp_type_GeneratorExit))) {
                    return raise(ctx, mp_make_raise_obj(t_exc));
                }
                // DISPATCH
            } else { // MP_VM_RETURN_EXCEPTION
                sp -= 1; // pop exhausted gen
                return raise(ctx, ret_value);
            }
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_STORE_COMP => {
            const u = decodeUint(&ip);
            const obj = (sp - (u >> 2))[0]; // sp[-(unum>>2)]
            const tag = u & 3;
            if (tag == 0) {
                _ = mp_obj_list_append(obj, sp[0]); // SCOPE_LIST_COMP
                sp -= 1;
            } else if (tag == 1) {
                _ = mp_obj_dict_store(obj, sp[0], (sp - 1)[0]); // SCOPE_DICT_COMP
                sp -= 2;
            } else { // tag == 2 → SCOPE_SET_COMP
                // Previously under nano this was lumped into the dict path
                // ("matches the frozen nano corpus's buggy set_comprehension
                // output"). The buggy output (TypeError: object not an
                // iterator) was bug-for-bug compat with vendor nano-C. The
                // principle of least user surprise wins: call the real
                // mp_obj_set_store so `{x for x in range(5)}` produces
                // {0, 1, 2, 3, 4} instead of a TypeError. compile.zig:3527
                // already emits BUILD_SET unconditionally, so the stack
                // layout has the set at sp[-5] when we get here.
                _ = mp_obj_set_store(obj, sp[0]);
                sp -= 1;
            }
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_LOAD_CONST_SMALL_INT_MULTI...mp.MP_BC_LOAD_CONST_SMALL_INT_MULTI + mp.MP_BC_LOAD_CONST_SMALL_INT_MULTI_NUM - 1 => {
            const last: isize = op;
            const A: isize = @as(isize, mp.MP_BC_LOAD_CONST_SMALL_INT_MULTI);
            const n: isize = last - A - @as(isize, mp.MP_BC_LOAD_CONST_SMALL_INT_MULTI_EXCESS);
            sp += 1;
            sp[0] = mirrors.newSmallInt(n);
            if (threaded) continue :dispatch fetch(csm, &ip, &op, false) else continue;
        },
        mp.MP_BC_LOAD_FAST_MULTI...mp.MP_BC_LOAD_FAST_MULTI + mp.MP_BC_LOAD_FAST_MULTI_NUM - 1 => {
            const last: isize = op;
            const B: isize = @as(isize, mp.MP_BC_LOAD_FAST_MULTI);
            const off: isize = B - last; // <= 0
            const w = fastnAt(fastn, off)[0];
            if (w == 0) return raise(ctx, newNameErrorLocal()); // load_check
            sp += 1;
            sp[0] = w;
            if (threaded) continue :dispatch fetch(csm, &ip, &op, false) else continue;
        },
        mp.MP_BC_STORE_FAST_MULTI...mp.MP_BC_STORE_FAST_MULTI + mp.MP_BC_STORE_FAST_MULTI_NUM - 1 => {
            const last: isize = op;
            const D: isize = @as(isize, mp.MP_BC_STORE_FAST_MULTI);
            const off: isize = D - last;
            const val = sp[0];
            sp -= 1; // POP()
            fastnAt(fastn, off)[0] = val;
            if (threaded) continue :dispatch fetch(csm, &ip, &op, false) else continue;
        },
        mp.MP_BC_UNARY_OP_MULTI...mp.MP_BC_UNARY_OP_MULTI + mp.MP_BC_UNARY_OP_MULTI_NUM - 1 => {
            const last: isize = op;
            const U: isize = @as(isize, mp.MP_BC_UNARY_OP_MULTI);
            sp[0] = mp_unary_op(@intCast(last - U), sp[0]);
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        mp.MP_BC_BINARY_OP_MULTI...mp.MP_BC_BINARY_OP_MULTI + mp.MP_BC_BINARY_OP_MULTI_NUM - 1 => {
            const last: isize = op;
            const E: isize = @as(isize, mp.MP_BC_BINARY_OP_MULTI);
            const rhs = sp[0];
            sp -= 1; // POP()
            const bop: c_int = @intCast(last - E);
            if (smallIntBinaryOp(bop, sp[0], rhs)) |r| {
                sp[0] = r;
                if (threaded) continue :dispatch fetch(csm, &ip, &op, false) else continue;
            }
            sp[0] = mp_binary_op(bop, sp[0], rhs);
            if (threaded) continue :dispatch fetch(csm, &ip, &op, true) else continue;
        },
        else => {
            // unknown opcode → NotImplementedError, return EXCEPTION
            // directly (C bypasses exception_handler here).
            csm.statePtr()[0] = newNotImplOpcode();
            ctx.outcome = @intFromEnum(Outcome.ret_exc);
            return null;
        },
    };
}

// vm.c's sole export (nm-verified). WIRED (batch 6): py/vm.c excluded
// from the C build (build.zig strangled[]); this `export` is the live
// mp_execute_bytecode. FRAME_ENTER/SETUP are no-ops under nano
// (SYS_SETTRACE=0).
export fn mp_execute_bytecode(code_state: CodeState, inject_exc: Obj) c_int {
    var ctx = Ctx{
        .code_state = code_state,
        .inject_exc = inject_exc,
        .pending_exc = 0,
        .outcome = @intFromEnum(Outcome.running),
    };
    while (true) { // the outer exception loop (Zig-owned)
        ctx.pending_exc = 0;
        ctx.outcome = @intFromEnum(Outcome.running);
        // NX-3 N4: npy_nlr_run wrap dropped — no Zig code longjmps under
        // nano (m_malloc_fail is polled), and no vendor C is in the build
        // graph. dispatchBody now runs directly; raises arrive via
        // ctx.outcome=.raised + ctx.pending_exc.
        _ = dispatchBody(&ctx);
        const exc: ?*anyopaque = switch (@as(Outcome, @enumFromInt(ctx.outcome))) {
            .normal => return mp.MP_VM_RETURN_NORMAL,
            .yield => return mp.MP_VM_RETURN_YIELD,
            .raised => @ptrFromInt(ctx.pending_exc), // Zig-level RAISE
            .ret_exc => return mp.MP_VM_RETURN_EXCEPTION, // direct (bypasses handler)
            .reenter => continue, // tier-up re-entry (wasm): resume at the saved ip
            .running => unreachable, // dispatch must always set an outcome
        };
        // raised → the Zig-ported exception_handler
        if (exceptionHandler(code_state, @intFromPtr(exc)) != 0) {
            continue; // re-enter dispatch (handler / StopIteration special)
        }
        return mp.MP_VM_RETURN_EXCEPTION; // propagate
    }
}

const std = @import("std");

comptime {
    // Force full body+ABI analysis (the `_ = &fn;` rule — `_ = fn;` is
    // a fake green). Replaced by `export` at batch-6 wiring.
    _ = &mp_execute_bytecode;
    _ = &dispatchBody;
    _ = &unwindReturn;
    _ = &unwindJump;
    _ = &cancelActiveFinally;
    _ = std;
}
