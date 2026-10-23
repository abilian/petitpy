//! nanopython runtime — Zig port of py/runtime.c (Phase 2.4.2 strangle).
//!
//! __qstr_shadow_begin__
//! MP_QSTR___path__
//! __qstr_shadow_end__
//!
//! Whole-file strangle (40 exported fns, core-internal callers).
//! @cImports ONLY the two bc.h-free headers (npy_runtime_api.h +
//! npy_nlr_trampoline.h) — no MicroPython headers. runtime.c is
//! stateless (operates on MP_STATE via the shim), so there is no private
//! state struct (unlike compile.zig's Compiler).
//!
//! The 2 true setjmp HOST sites (mp_load_method_protected;
//! mp_iternext's __next__ sub-block only) host via the proven C
//! `npy_nlr_run` trampoline (Step 2.4.1). The jump-callback host
//! (mp_parse_compile_execute) is NOT a setjmp pad → shim push/pop.
//!
//! ┌─ STATUS: batch 1 (scaffold). All 40 exports are ABI-locked stubs
//! │  (`@panic`, plain `fn` — `export` added at batch-6 wiring).
//! │  UNWIRED: not in build.zig `strangled[]` nor @imported; py/
//! │  runtime.c stays active, corpus 550/550. Bodies land batches 2–5;
//! └─ wired + verified 550/550 at the single atomic batch 6.

const mp = @cImport({
    @cInclude("py/runtime.h");
    @cInclude("py/qstr.h");
});
const pyerr = @import("../pyerr.zig");
const mirrors = @import("../mp_mirrors.zig");
const opmethods = @import("opmethods.zig");
const build_options = @import("build_options");
const PyError = pyerr.PyError;

// ── ABI-locked aliases ──────────────────────────────────────────────────
const Obj = mirrors.Obj; // mp_obj_t (= usize under REPR_A)
const Qstr = usize; // qstr (uintptr_t)
const TypePtr = ?*const anyopaque; // const mp_obj_type_t * — opaque (use MpObjType mirror to deref)
const ObjOut = [*c]Obj; // mp_obj_t * (out arrays / dest[2])
const IterBuf = ?*anyopaque; // mp_obj_iter_buf_t *
const RomText = ?[*:0]const u8; // mp_rom_error_text_t

const TODO = "runtime.zig: not yet ported";

// W6 long-tail: direct extern fn calls to eliminate type-cast C wrappers
// in npy_runtime_shim.c (npy_rt_obj_get_int, _obj_equal, _obj_equal_not_equal).
extern fn mp_obj_get_int(arg: Obj) callconv(.c) isize;
extern fn mp_obj_equal(o1: Obj, o2: Obj) callconv(.c) bool;
extern fn mp_obj_equal_not_equal(op: c_int, o1: Obj, o2: Obj) callconv(.c) Obj;
// Stage 6 Tier C: small-int helpers (real vendor extern fns).
extern fn mp_small_int_floor_divide(a: isize, b: isize) callconv(.c) isize;
extern fn mp_small_int_modulo(a: isize, b: isize) callconv(.c) isize;
// Stage 6 followup: 2 thin npy_rt_* wrappers retired via direct fns.
// (`mp_obj_new_bool` and `mp_cstack_check` are `static inline` in
// vendor headers — wrappers must stay.)
extern fn mp_obj_new_int(v: isize) callconv(.c) Obj;
extern fn mp_obj_exception_get_value(self_in: Obj) callconv(.c) Obj;
// Stage 1 of runtime_shim sweep: more direct extern fns.
extern fn mp_obj_new_list(n: usize, items: [*c]const Obj) callconv(.c) Obj;
extern fn mp_obj_new_getitem_iter(dest: [*c]Obj, iter_buf: ?*anyopaque) callconv(.c) Obj;
extern fn mp_obj_gen_resume(self: Obj, send_val: Obj, throw_val: Obj, ret_val: [*c]Obj) callconv(.c) c_int;
// Stage 3 sweep — type-compare predicates need these extern singletons.
extern const mp_type_tuple: anyopaque;
extern const mp_type_list: anyopaque;
extern const mp_type_dict: anyopaque;
extern const mp_type_complex: anyopaque;
// Stage 4: builtins dict for the builtins lookup helper.
extern var mp_module_builtins_globals: mirrors.MpObjDict;
// Zig-side override dict (v0.7.1 — replaces the CAN_OVERRIDE_BUILTINS
// vendor mpstate slot; see src/objects/objtype/objmodule.zig). Under
// nano it is never written to, so the checks below stay dead.
extern var mp_module_builtins_override_dict: ?*mirrors.MpObjDict;
// Stage 5: builtin obj data symbols + extern fns for small mirrors.
extern const mp_builtin_next_obj: anyopaque;
extern const mp_builtin___build_class___obj: anyopaque;
extern fn mp_obj_new_tuple(n: usize, items: [*c]const Obj) callconv(.c) Obj;
// NX-3 N4a: mp_obj_str_get_str returns null + sets pending_exc on bad input
// (non-str-or-bytes). Callers MUST check the returned ptr for null.
extern fn mp_obj_str_get_str(self_in: Obj) callconv(.c) ?[*]const u8;
extern fn m_malloc(num_bytes: usize) callconv(.c) ?*anyopaque;
// `mp_make_stop_iteration` is static-inline (runtime.h:256-259) — port body.
inline fn makeStopIteration(o: Obj) Obj {
    mirrors.mp_state_ctx.thread.stop_iteration_arg = o;
    return mirrors.OBJ_STOP_ITERATION;
}

// Stage 6 nonlocal / args / mul-overflow / cstack — direct extern fns or
// inline-body ports (matching vendor static-inline definitions).
extern fn m_realloc(ptr: ?*anyopaque, new_num_bytes: usize) callconv(.c) ?*anyopaque;
extern fn m_malloc_maybe(num_bytes: usize) callconv(.c) ?*anyopaque;
extern fn m_free(ptr: ?*anyopaque) callconv(.c) void;

// `mp_cstack_check` is static-inline; under nano (MICROPY_STACK_CHECK=0)
// the vendor body is empty — no-op port.
inline fn cstackCheck() void {}

// `mp_mul_mp_int_t_overflow` static-inline (misc.h:477) — port via Zig
// builtin. Returns true on overflow.
inline fn mulOverflow(x: isize, y: isize, res: *isize) bool {
    const r = @mulWithOverflow(x, y);
    res.* = r[0];
    return r[1] != 0;
}

// `mp_obj_is_float` macro (obj.h:165 under FULL): isExactType vs mp_type_float.
extern const mp_type_float: anyopaque;
inline fn isFloat(o: Obj) bool {
    return mirrors.isExactType(o, &mp_type_float);
}
// Under FULL only — REPR_A confirmed under both nano and full, so
// mp_obj_new_float is the real extern (obj.h:122), not the static-inline.
extern fn mp_obj_new_float(f: f64) callconv(.c) Obj;
extern fn mp_obj_float_binary_op(op: c_int, lhs: f64, rhs: Obj) callconv(.c) Obj;
extern fn mp_obj_complex_binary_op(op: c_int, lhs_re: f64, lhs_im: f64, rhs: Obj) callconv(.c) Obj;

// Stage 9 — small straggler helpers ported.
extern const mp_obj_str_binary_op: anyopaque;
extern fn qstr_hash(q: usize) callconv(.c) usize;
extern fn qstr_data(q: usize, len_out: *usize) callconv(.c) [*]const u8;
extern fn qstr_compute_hash(data: [*]const u8, len: usize) callconv(.c) usize;

// `mp_obj_is_str_or_bytes` macro port (obj.h:988). Qstr OR (heap obj whose
// type's binary_op slot equals mp_obj_str_binary_op).
inline fn isStrOrBytes(o: Obj) bool {
    if (mirrors.isQstr(o)) return true;
    if (!mirrors.isObj(o)) return false;
    const t_ptr = mirrors.objBaseType(o) orelse return false;
    const t = mirrors.MpObjType.fromPtr(t_ptr);
    const bop = t.getSlot(.binary_op) orelse return false;
    return @intFromPtr(bop) == @intFromPtr(&mp_obj_str_binary_op);
}

// `npy_rt_str_unary_hash` port — GET_STR_HASH macro + qstr_compute_hash
// fallback. Mirrors the C wrapper line-by-line.
inline fn strUnaryHash(o: Obj) usize {
    var h: usize = if (mirrors.isQstr(o))
        qstr_hash(mirrors.qstrValue(o))
    else
        mirrors.MpObjStr.fromObj(o).hash;
    if (h == 0) {
        var data: [*]const u8 = undefined;
        var len: usize = undefined;
        if (mirrors.isQstr(o)) {
            data = qstr_data(mirrors.qstrValue(o), &len);
        } else {
            const s = mirrors.MpObjStr.fromObj(o);
            data = s.data;
            len = s.len;
        }
        h = qstr_compute_hash(data, len);
    }
    return h;
}

// C-variadic exception constructor — mp_obj_new_exception_msg_varg counts % escapes in fmt.
extern fn mp_obj_new_exception_msg_varg(t: *const anyopaque, fmt: [*:0]const u8, ...) callconv(.c) Obj;
// `mp_obj_new_exception_arg1` is static-inline (obj.h:1117) — port body.
extern fn mp_obj_new_exception_args(t: *const anyopaque, n_args: usize, args: [*c]const Obj) callconv(.c) Obj;
inline fn newExceptionArg1(t: TypePtr, arg: Obj) Obj {
    const args = [_]Obj{arg};
    return mp_obj_new_exception_args(@ptrCast(t.?), 1, &args);
}
extern const mp_type_ImportError: anyopaque;
// Cleanup pass: retire pure pass-through npy_rt_* wrappers.
extern fn mp_obj_get_type(o: Obj) callconv(.c) TypePtr;
// VM-track Stage 3: retire npy_rt_type_* type-pointer wrappers. Each was
// `return (const npy_type *)&mp_type_X` — just declare the underlying
// vendor `mp_type_X` extern and use `&mp_type_X` directly.
extern const mp_type_TypeError: anyopaque;
extern const mp_type_NameError: anyopaque;
extern const mp_type_ValueError: anyopaque;
extern const mp_type_AttributeError: anyopaque;
extern const mp_type_StopIteration: anyopaque;
extern const mp_type_RuntimeError: anyopaque;
extern const mp_type_ZeroDivisionError: anyopaque;
extern const mp_type_MemoryError: anyopaque;
extern const mp_type_GeneratorExit: anyopaque;
extern const mp_type_staticmethod: anyopaque;
extern const mp_type_classmethod: anyopaque;
extern const mp_type_type: anyopaque;
extern const mp_type_gen_instance: anyopaque;
// mp_obj_new_bool is static inline in obj.h — wrapper stays.
extern fn mp_obj_new_int_from_ll(v: c_longlong) callconv(.c) Obj;
extern fn mp_obj_get_array(o: Obj, len: *usize, items: *[*c]Obj) callconv(.c) void;
// Already-Zig (objexcept.zig + objtype.zig):
extern fn mp_obj_is_subclass_fast(object: Obj, classinfo: Obj) callconv(.c) bool;
extern fn mp_obj_new_exception_msg(t: TypePtr, msg: [*:0]const u8) callconv(.c) Obj;
extern fn mp_obj_is_exception_type(o: Obj) callconv(.c) bool;
extern fn mp_obj_is_exception_instance(o: Obj) callconv(.c) bool;
extern fn mp_obj_new_exception(t: TypePtr) callconv(.c) Obj;
// More vendor extern fns to retire pass-through wrappers:
extern fn mp_obj_dict_store(d: Obj, k: Obj, v: Obj) callconv(.c) Obj;
extern fn mp_obj_dict_delete(d: Obj, k: Obj) callconv(.c) Obj;
extern fn mp_obj_list_append(l: Obj, it: Obj) callconv(.c) Obj;
extern fn mp_obj_list_set_len(l: Obj, n: usize) callconv(.c) void;
extern fn mp_obj_is_true(o: Obj) callconv(.c) bool;
extern fn mp_obj_new_bound_meth(meth: Obj, self: Obj) callconv(.c) Obj;
// mp_nonlocal_alloc/_realloc/_free are static inline (pystack.h) — wrappers stay.
extern fn mp_obj_len_maybe(o: Obj) callconv(.c) Obj;
extern fn mp_obj_dict_len(o: Obj) callconv(.c) usize;
extern fn mp_obj_str_intern_checked(o: Obj) callconv(.c) Obj;
extern fn mp_obj_exception_match(e: Obj, et: Obj) callconv(.c) bool;
// mp_builtin___import__ macro-redirects to mp_builtin___import___default;
// the latter is the actual symbol (now Zig from builtinimport.zig).
extern fn mp_builtin___import___default(n_args: usize, args: [*c]const Obj) callconv(.c) Obj;
extern fn mp_obj_str_get_qstr(o: Obj) callconv(.c) usize;

const ITER_BUF_CAP: usize = 64; // mp_obj_iter_buf_t (asserted at use)
inline fn stopIter() Obj {
    return mirrors.OBJ_STOP_ITERATION;
}
// Internal Zig-side raise helpers — set pyerr.pending_exc and return
// error.PyRaise (B1.5 convention). After NX-3 N4 the prior C-public
// noreturn siblings (`mp_raise_msg`/`mp_raise_type_arg`/`mp_raise_msg_varg`)
// have been deleted (no Zig callers under nano).
fn raiseMsg(exc_type: TypePtr, msg: RomText) PyError!void {
    pyerr.pending_exc = if (msg) |m|
        mp_obj_new_exception_msg(exc_type, m)
    else
        mp_obj_new_exception(exc_type);
    return error.PyRaise;
}
fn raiseTypeArg(exc_type: TypePtr, arg: Obj) PyError!void {
    pyerr.pending_exc = newExceptionArg1(exc_type, arg);
    return error.PyRaise;
}

// nano TERSE: every too_short/too_long label raises the SAME message
// (the #else varg variants are dead) → one faithful-equivalent helper.
fn unpackErr() PyError!void {
    return raiseMsg(@as(TypePtr, @ptrCast(&mp_type_ValueError)), "wrong number of values to unpack");
}

// ── 40 exported entry points (ABI from py/runtime.h) — batch-1 stubs ─────
// Signatures are final (C ABI for batch-6 `export`); bodies are batches
// 2–5. `fn` not `export fn` yet (export at wiring, else link clash with
// the still-active C runtime.c).

// VM init/deinit: config/MP_STATE-heavy → verbatim C body lives in
// mp_init / mp_deinit body — ported from vendor runtime.c via mirrors.
// Most of the vendor #if-gates are dead under both nano + full:
//   SCHEDULER=0, EMERGENCY_EXCEPTION_BUF=0, KBD_EXCEPTION=0,
//   CAN_OVERRIDE_BUILTINS=0, PY_OS_DUPTERM=0, VFS=0,
//   PY_SYS_PATH_ARGV_DEFAULTS=0, SYS_ATEXIT=0, SYS_PS1_PS2=0,
//   SYS_SETTRACE=0, SYS_TRACEBACKLIMIT=0, PY_BLUETOOTH=0,
//   HW_ENABLE_USB_RUNTIME_DEVICE=0, PY_THREAD_GIL=0, VFS_ROM=0.
// COMPILER is the only live arm (sets mp_optimise_value=0).
extern fn qstr_init() callconv(.c) void;
extern fn mp_obj_dict_init(o: *mirrors.MpObjDict, alloc: usize) callconv(.c) void;
extern fn mp_locals_set(d: *mirrors.MpObjDict) callconv(.c) void;
extern fn mp_globals_set(d: *mirrors.MpObjDict) callconv(.c) void;
// mp_obj_list_append already declared above.
extern fn mp_obj_list_init(o: *mirrors.MpObjList, n: usize) callconv(.c) void;

export fn mp_init() callconv(.c) void {
    qstr_init();
    // no pending exceptions to start with
    mirrors.mp_state_ctx.thread.mp_pending_exception = mirrors.OBJ_NULL;
    // MICROPY_ENABLE_COMPILER live: optimization disabled by default.
    mirrors.mp_state_ctx.vm.mp_optimise_value = 0;
    // init global module dict
    mp_obj_dict_init(&mirrors.mp_state_ctx.vm.mp_loaded_modules_dict, mp.MICROPY_LOADED_MODULES_DICT_SIZE);
    // initialise the __main__ module
    mp_obj_dict_init(&mirrors.mp_state_ctx.vm.dict_main, 1);
    _ = mp_obj_dict_store(
        @intFromPtr(&mirrors.mp_state_ctx.vm.dict_main),
        mirrors.objFromQstr(mp.MP_QSTR___name__),
        mirrors.objFromQstr(mp.MP_QSTR___main__),
    );
    // locals = globals for the outer module
    mp_locals_set(&mirrors.mp_state_ctx.vm.dict_main);
    mp_globals_set(&mirrors.mp_state_ctx.vm.dict_main);
    // MICROPY_PY_SYS_PATH_ARGV_DEFAULTS live (both nano + full):
    // mp_sys_path = MP_STATE_VM(sys_mutable[MP_SYS_MUTABLE_PATH=0]),
    // mp_sys_argv = MP_OBJ_FROM_PTR(&MP_STATE_VM(mp_sys_argv_obj)).
    mirrors.mp_state_ctx.vm.sys_mutable[0] = mp_obj_new_list(0, null);
    _ = mp_obj_list_append(mirrors.mp_state_ctx.vm.sys_mutable[0], mirrors.objFromQstr(mp.MP_QSTR_)); // empty qstr
    mp_obj_list_init(&mirrors.mp_state_ctx.vm.mp_sys_argv_obj, 0);
    // MP_THREAD_GIL_ENTER() — empty under PY_THREAD_GIL=0.
}

export fn mp_deinit() callconv(.c) void {
    // MP_THREAD_GIL_EXIT() — empty under PY_THREAD_GIL=0. PORT_DEINIT_FUNC undefined.
}
// MICROPY_WRAP_MP_LOAD_NAME = identity under nano (no profiling).
fn mpLoadNameImpl(qst: Qstr) PyError!Obj {
    // outer scope (locals==globals) → fall straight to load_global
    if (mirrors.MpStateThread.localsNeGlobals()) {
        const v = mirrors.MpStateThread.localsLookup(@intCast(qst));
        if (v != 0) return v;
    }
    return try mpLoadGlobalImpl(qst);
}
export fn mp_load_name(qst: Qstr) callconv(.c) Obj {
    return pyerr.bridge(Obj, mpLoadNameImpl(qst));
}
// MICROPY_WRAP_MP_LOAD_GLOBAL = identity.
// v0.7.1: override_dict search wired for `builtins.X = Y` support (full).
fn mpLoadGlobalImpl(qst: Qstr) PyError!Obj {
    var v = mirrors.MpStateThread.globalsLookup(@intCast(qst));
    if (v == 0) {
        if (build_options.is_full) {
            if (mp_module_builtins_override_dict) |od| {
                v = od.map.lookupQstr(@intCast(qst));
            }
        }
        if (v == 0) {
            v = mp_module_builtins_globals.map.lookupQstr(@intCast(qst));
        }
        if (v == 0) {
            // Format the failing name into the message: "name 'foo' isn't defined".
            // Saves a print-debug round-trip — the most common debugging scenario.
            pyerr.pending_exc = mp_obj_new_exception_msg_varg(
                &mp_type_NameError,
                "name '%q' isn't defined",
                @as(usize, qst));
            return error.PyRaise;
        }
    }
    return v;
}
export fn mp_load_global(qst: Qstr) callconv(.c) Obj {
    return pyerr.bridge(Obj, mpLoadGlobalImpl(qst));
}
// v0.7.1: override_dict lookup for `builtins.__build_class__ = X` (full).
export fn mp_load_build_class() callconv(.c) Obj {
    if (build_options.is_full) {
        if (mp_module_builtins_override_dict) |od| {
            const v = od.map.lookupQstr(@intCast(mp.MP_QSTR___build_class__));
            if (v != 0) return v;
        }
    }
    return mirrors.objFromPtr(&mp_builtin___build_class___obj);
}
export fn mp_store_name(qst: Qstr, obj: Obj) callconv(.c) void {
    _ = mp_obj_dict_store(mirrors.MpStateThread.localsObj(), mirrors.objFromQstr(qst), obj);
}
export fn mp_store_global(qst: Qstr, obj: Obj) callconv(.c) void {
    _ = mp_obj_dict_store(mirrors.MpStateThread.globalsObj(), mirrors.objFromQstr(qst), obj);
}
export fn mp_delete_name(qst: Qstr) callconv(.c) void {
    _ = mp_obj_dict_delete(mirrors.MpStateThread.localsObj(), mirrors.objFromQstr(qst));
}
export fn mp_delete_global(qst: Qstr) callconv(.c) void {
    _ = mp_obj_dict_delete(mirrors.MpStateThread.globalsObj(), mirrors.objFromQstr(qst));
}
// FLOAT/COMPLEX=0 → the *_MAYBE float/complex disjuncts are dead;
// TERSE → the final raise is mp_raise_TypeError (=mp_raise_msg). The
// op switch is if/else-if (npy_rt_UNARY_OP_* are runtime consts).
fn mpUnaryOpImpl(op: c_int, arg: Obj) PyError!Obj {
    if (op == mp.MP_UNARY_OP_NOT) {
        return mirrors.newBool(mp_obj_is_true(arg) == false);
    } else if (mirrors.isSmallInt(arg)) {
        const val = mirrors.smallIntValue(arg);
        if (op == mp.MP_UNARY_OP_BOOL) {
            return mirrors.newBool(val != 0);
        } else if (op == mp.MP_UNARY_OP_HASH) {
            return arg;
        } else if (op == mp.MP_UNARY_OP_POSITIVE or op == mp.MP_UNARY_OP_INT_MAYBE) {
            return arg;
        } else if (op == mp.MP_UNARY_OP_NEGATIVE) {
            if (val == mirrors.SMALL_INT_MIN) {
                return mp_obj_new_int(-val);
            } else {
                return mirrors.newSmallInt(-val);
            }
        } else if (op == mp.MP_UNARY_OP_ABS) {
            if (val >= 0) {
                return arg;
            } else if (val == mirrors.SMALL_INT_MIN) {
                return mp_obj_new_int(-val);
            } else {
                return mirrors.newSmallInt(-val);
            }
        } else {
            // assert(op == MP_UNARY_OP_INVERT)
            return mirrors.newSmallInt(~val);
        }
    } else if (op == mp.MP_UNARY_OP_HASH and isStrOrBytes(arg)) {
        return mirrors.newSmallInt(@bitCast(strUnaryHash(arg)));
    } else {
        const t = mp_obj_get_type(arg);
        const tm = mirrors.MpObjType.fromPtr(t);
        if (tm.getSlot(.unary_op)) |raw| {
            const fn_ptr: mirrors.MpUnaryOpFun = @ptrCast(@alignCast(raw));
            const result = fn_ptr(op, arg);
            if (result != 0) return result; // != MP_OBJ_NULL
        } else if (op == mp.MP_UNARY_OP_HASH) {
            return mirrors.newSmallInt(@bitCast(arg)); // hash of instance id
        }
        if (op == mp.MP_UNARY_OP_BOOL) return mirrors.OBJ_TRUE;
        // INT/FLOAT/COMPLEX_MAYBE all "return NULL when type doesn't support it"
        // per vendor py/runtime.c:354-365. FLOAT_MAYBE was previously omitted
        // here as "dead under nano", but FLOAT=1 in our build — adding the
        // branch is faithful to vendor + necessary for COMPLEX (which routes
        // mp_obj_get_complex_maybe through FLOAT_MAYBE).
        if (op == mp.MP_UNARY_OP_INT_MAYBE) return 0; // MP_OBJ_NULL
        if (op == mp.MP_UNARY_OP_FLOAT_MAYBE) return 0;
        if (comptime build_options.is_full) {
            if (op == mp.MP_UNARY_OP_COMPLEX_MAYBE) return 0;
        }
        try raiseMsg(@as(TypePtr, @ptrCast(&mp_type_TypeError)), "unsupported type for operator"); // TERSE
        unreachable;
    }
}
export fn mp_unary_op(op: c_int, arg: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, mpUnaryOpImpl(op, arg));
}
// ── mp_binary_op (scaffold grep missed it: MICROPY_WRAP_ prefix).
// Largest fn in runtime.c. goto→labeled-blocks (lesson #6); op switch
// → if/else-if (runtime consts); FLOAT/COMPLEX/REVERSE_SPECIAL_METHODS
// dead-elided; signed overflow C relies on (-fno-sanitize) → Zig
// wrapping `+%`/`-%` so the Debug build matches the C build bit-for-bit.
// Sized so Zig treats this as the array symbol (not a pointer dereference).
// Using `[*]const u8` extern made Zig deref the address-of-the-array as if
// it were a `**u8`, segfaulting on the first lookup. Vendor C declares
// this as `extern const byte mp_binary_op_method_name[]` and lets the
// linker resolve the size — we hardcode it.
extern const mp_binary_op_method_name: [mp.MP_BINARY_OP_NUM_RUNTIME]u8;

// ADR 010 §C5 — richer arithmetic TypeError. CPython's format is
// "unsupported operand type(s) for +: 'int' and 'str'". We emit a
// vendor-NORMAL-shaped variant carrying the same information.
//
// Implementation: route through `mp_obj_new_exception_msg_varg`, which
// formats into m_malloc'd memory owned by the new exception — every
// raise gets its own lifetime-clean message. Earlier revisions used a
// module-static buffer (since `mp_obj_new_exception_msg` stores the msg
// pointer rather than copying), but that buffer was shared across
// raises and a second TypeError would mutate a held exception's text.
// Three uniform `%q` substitutions sidestep the Zig 0.16 C-vararg ABI
// concern (the earlier `(%q, %s, %s)` mixed shape was the original
// reason the varg path was avoided — uniform qstr is fine).
fn binopUnsupported(op: c_int, lhs: Obj, rhs: Obj) PyError!void {
    const op_qstr: usize = @intCast(mp_binary_op_method_name[@intCast(op)]);
    const lhs_qstr: usize = mirrors.MpObjType.fromPtr(mp_obj_get_type(lhs)).name;
    const rhs_qstr: usize = mirrors.MpObjType.fromPtr(mp_obj_get_type(rhs)).name;
    pyerr.pending_exc = mp_obj_new_exception_msg_varg(
        @as(*const anyopaque, @ptrCast(&mp_type_TypeError)),
        "unsupported types for %q: '%q', '%q'",
        op_qstr,
        lhs_qstr,
        rhs_qstr,
    );
    return error.PyRaise;
}
fn binopZeroDiv() PyError!void {
    return raiseMsg(@as(TypePtr, @ptrCast(&mp_type_ZeroDivisionError)), "divide by zero");
}

extern fn mp_obj_get_float(o: Obj) callconv(.c) f64;
extern const mp_type_int: anyopaque;
extern const mp_type_str: anyopaque;
extern const mp_type_bool: anyopaque;

// The value of a float, int or bool operand; null for anything else.
// mp_obj_get_type, not isExactType: nano's True/False are immediates.
fn realValue(o: Obj) ?f64 {
    if (mirrors.isSmallInt(o)) return @floatFromInt(mirrors.smallIntValue(o));
    if (isFloat(o)) return @as(*const mirrors.MpObjFloat, @ptrFromInt(o)).value;
    const t: *const anyopaque = @ptrCast(mp_obj_get_type(o));
    if (t == @as(*const anyopaque, &mp_type_int) or t == @as(*const anyopaque, &mp_type_bool)) return mp_obj_get_float(o);
    return null;
}

// Called where a float operation is about to enter vendor C. Vendor
// objfloat.c raises these errors of a float operation with
// mp_raise, a longjmp the VM's try/except cannot catch (ADR 013): `try:
// x / 0.0` ended the program. Raise them here first, catchably, with
// vendor's messages: ZeroDivisionError for a zero divisor or zero to a
// negative power, and ValueError for a negative base to a fractional
// power: vendor returns a complex there under MICROPY_PY_BUILTINS_COMPLEX,
// but objcomplex.c is not ported and full_stubs.zig panics.
// The operators that can raise; callers test this inline, so the
// operators that cannot (+, -, *, comparisons) pay one mask test.
const float_raising_ops: u64 = blk: {
    var m: u64 = 0;
    for ([_]c_int{ mp.MP_BINARY_OP_TRUE_DIVIDE, mp.MP_BINARY_OP_INPLACE_TRUE_DIVIDE, mp.MP_BINARY_OP_FLOOR_DIVIDE, mp.MP_BINARY_OP_INPLACE_FLOOR_DIVIDE, mp.MP_BINARY_OP_MODULO, mp.MP_BINARY_OP_INPLACE_MODULO, mp.MP_BINARY_OP_DIVMOD, mp.MP_BINARY_OP_POWER, mp.MP_BINARY_OP_INPLACE_POWER }) |op| m |= @as(u64, 1) << op;
    break :blk m;
};
inline fn floatOpMayRaise(op: c_int) bool {
    return op >= 0 and op < 64 and (float_raising_ops >> @intCast(op)) & 1 != 0;
}

noinline fn floatOpPrecheck(op: c_int, lhs: Obj, rhs: Obj) PyError!void {
    const r = realValue(rhs) orelse return;
    if (op == mp.MP_BINARY_OP_POWER or op == mp.MP_BINARY_OP_INPLACE_POWER) {
        const l = realValue(lhs) orelse return;
        if (l == 0 and r < 0) return binopZeroDiv();
        if (l < 0 and r != @trunc(r)) {
            return raiseMsg(@as(TypePtr, @ptrCast(&mp_type_ValueError)), "complex values not supported");
        }
    } else if (r == 0) {
        return binopZeroDiv();
    }
}
/// `1 + R(2)`, `1 < R(2)` or `"a" + S("b")` for a Python subclass R of
/// int or float, or S of str, with a native value of that kind on the
/// left. As in CPython, the subclass's reflected method (`__radd__`,
/// `__gt__`, ...) goes first if it defines one; otherwise the operation
/// uses its native value. MicroPython's int and str only take exactly an
/// int or str, and it has no reflected comparisons. Null when this does
/// not apply.
fn isNativeScalar(o: Obj) bool {
    return mirrors.isSmallInt(o) or isFloat(o) or mirrors.isExactType(o, &mp_type_int) or mirrors.isQstr(o) or mirrors.isExactType(o, &mp_type_str);
}

fn nativeSubclassOp(op: c_int, lhs: Obj, rhs: Obj) PyError!?Obj {
    if (!isNativeScalar(lhs)) return null;
    const native = opmethods.nativeBase(rhs);
    if (native == rhs or !isNativeScalar(native)) return null;
    var fwd = op;
    if (fwd >= mp.MP_BINARY_OP_INPLACE_OR and fwd <= mp.MP_BINARY_OP_INPLACE_POWER) fwd += mp.MP_BINARY_OP_OR - mp.MP_BINARY_OP_INPLACE_OR;
    const reflected: ?c_int = switch (fwd) {
        mp.MP_BINARY_OP_LESS => mp.MP_BINARY_OP_MORE,
        mp.MP_BINARY_OP_MORE => mp.MP_BINARY_OP_LESS,
        mp.MP_BINARY_OP_LESS_EQUAL => mp.MP_BINARY_OP_MORE_EQUAL,
        mp.MP_BINARY_OP_MORE_EQUAL => mp.MP_BINARY_OP_LESS_EQUAL,
        else => if (fwd >= mp.MP_BINARY_OP_OR and fwd <= mp.MP_BINARY_OP_POWER) fwd + (mp.MP_BINARY_OP_REVERSE_OR - mp.MP_BINARY_OP_OR) else null,
    };
    if (reflected) |rop| {
        var dest: [3]Obj = .{ mirrors.OBJ_NULL, mirrors.OBJ_NULL, lhs };
        mp_load_method_maybe(rhs, @intCast(mp_binary_op_method_name[@intCast(rop)]), @ptrCast(&dest));
        if (pyerr.pending_exc != 0) return error.PyRaise;
        if (dest[0] != mirrors.OBJ_NULL) {
            const res = mp_call_method_n_kw(1, 0, &dest);
            if (pyerr.pending_exc != 0) return error.PyRaise;
            return res;
        }
    }
    return try mpBinaryOpImpl(op, lhs, native);
}

fn mpBinaryOpImpl(op_in: c_int, lhs_in: Obj, rhs_in: Obj) PyError!Obj {
    var op = op_in;
    var lhs = lhs_in;
    var rhs = rhs_in;
    to_generic: {
        if (op == mp.MP_BINARY_OP_IS) return mirrors.newBool(lhs == rhs);
        if (op == mp.MP_BINARY_OP_EQUAL or op == mp.MP_BINARY_OP_NOT_EQUAL) {
            return mp_obj_equal_not_equal(op, lhs, rhs);
        }
        if (op == mp.MP_BINARY_OP_EXCEPTION_MATCH) {
            if (mp_obj_is_exception_type(rhs)) {
                return if (mp_obj_exception_match(lhs, rhs)) mirrors.OBJ_TRUE else mirrors.OBJ_FALSE;
            } else if (mirrors.isExactType(rhs, &mp_type_tuple)) {
                var len: usize = undefined;
                var items: [*c]Obj = undefined;
                mp_obj_get_array(rhs, &len, @ptrCast(&items));
                var i: usize = 0;
                while (i < len) : (i += 1) {
                    rhs = items[i];
                    if (!mp_obj_is_exception_type(rhs)) try binopUnsupported(op, lhs, rhs);
                    if (mp_obj_exception_match(lhs, rhs)) return mirrors.OBJ_TRUE;
                }
                return mirrors.OBJ_FALSE;
            }
            try binopUnsupported(op, lhs, rhs);
        }
        if (comptime build_options.is_full) {
            if (try nativeSubclassOp(op, lhs, rhs)) |res| return res;
        }
        if (mirrors.isSmallInt(lhs)) {
            var lhs_val = mirrors.smallIntValue(lhs);
            if (mirrors.isSmallInt(rhs)) {
                var rhs_val = mirrors.smallIntValue(rhs);
                var go_big = false;
                if (op == mp.MP_BINARY_OP_OR or op == mp.MP_BINARY_OP_INPLACE_OR) {
                    lhs_val |= rhs_val;
                } else if (op == mp.MP_BINARY_OP_XOR or op == mp.MP_BINARY_OP_INPLACE_XOR) {
                    lhs_val ^= rhs_val;
                } else if (op == mp.MP_BINARY_OP_AND or op == mp.MP_BINARY_OP_INPLACE_AND) {
                    lhs_val &= rhs_val;
                } else if (op == mp.MP_BINARY_OP_LSHIFT or op == mp.MP_BINARY_OP_INPLACE_LSHIFT) {
                    if (rhs_val < 0) {
                        try raiseMsg(@as(TypePtr, @ptrCast(&mp_type_ValueError)), "negative shift count");
                    } else if (rhs_val >= @as(isize, @intCast(@sizeOf(isize))) * 8 or
                        lhs_val > (mirrors.SMALL_INT_MAX >> @intCast(rhs_val)) or
                        lhs_val < (mirrors.SMALL_INT_MIN >> @intCast(rhs_val)))
                    {
                        lhs = mp_obj_new_int_from_ll(@intCast(lhs_val));
                        if (pyerr.pending_exc != 0) return error.PyRaise;
                        go_big = true;
                    } else {
                        lhs_val = @bitCast(@as(usize, @bitCast(lhs_val)) << @intCast(rhs_val));
                    }
                } else if (op == mp.MP_BINARY_OP_RSHIFT or op == mp.MP_BINARY_OP_INPLACE_RSHIFT) {
                    if (rhs_val < 0) {
                        try raiseMsg(@as(TypePtr, @ptrCast(&mp_type_ValueError)), "negative shift count");
                    } else {
                        if (rhs_val >= @as(isize, @intCast(@sizeOf(isize))) * 8) {
                            rhs_val = @as(isize, @intCast(@sizeOf(isize))) * 8 - 1;
                        }
                        lhs_val >>= @intCast(rhs_val);
                    }
                } else if (op == mp.MP_BINARY_OP_ADD or op == mp.MP_BINARY_OP_INPLACE_ADD) {
                    lhs_val +%= rhs_val; // C signed +; -fno-sanitize wrap
                } else if (op == mp.MP_BINARY_OP_SUBTRACT or op == mp.MP_BINARY_OP_INPLACE_SUBTRACT) {
                    lhs_val -%= rhs_val;
                } else if (op == mp.MP_BINARY_OP_MULTIPLY or op == mp.MP_BINARY_OP_INPLACE_MULTIPLY) {
                    var int_res: isize = undefined;
                    if (mulOverflow(lhs_val, rhs_val, &int_res)) {
                        lhs = mp_obj_new_int_from_ll(@intCast(lhs_val));
                        if (pyerr.pending_exc != 0) return error.PyRaise;
                        go_big = true;
                    } else {
                        lhs_val = int_res;
                    }
                } else if (op == mp.MP_BINARY_OP_FLOOR_DIVIDE or op == mp.MP_BINARY_OP_INPLACE_FLOOR_DIVIDE) {
                    if (rhs_val == 0) try binopZeroDiv();
                    lhs_val = mp_small_int_floor_divide(lhs_val, rhs_val);
                } else if (op == mp.MP_BINARY_OP_TRUE_DIVIDE or op == mp.MP_BINARY_OP_INPLACE_TRUE_DIVIDE) {
                    // int / int → float. Now that vendor py/objfloat.c is
                    // in the float-arm carveout, mp_obj_new_float works.
                    if (rhs_val == 0) try binopZeroDiv();
                    return mp_obj_new_float(@as(f64, @floatFromInt(lhs_val)) / @as(f64, @floatFromInt(rhs_val)));
                } else if (op == mp.MP_BINARY_OP_MODULO or op == mp.MP_BINARY_OP_INPLACE_MODULO) {
                    if (rhs_val == 0) try binopZeroDiv();
                    lhs_val = mp_small_int_modulo(lhs_val, rhs_val);
                } else if (op == mp.MP_BINARY_OP_POWER or op == mp.MP_BINARY_OP_INPLACE_POWER) {
                    if (rhs_val < 0) {
                        // int ** -n is a float, as vendor does with float support
                        // (on in every config); it raised the no-float ValueError.
                        // 0 ** -n raises here: vendor's raise is not catchable.
                        if (lhs_val == 0) try binopZeroDiv();
                        const res = mp_obj_float_binary_op(op, @as(f64, @floatFromInt(lhs_val)), rhs);
                        if (pyerr.pending_exc != 0) return error.PyRaise;
                        return res;
                    } else {
                        var ans: isize = 1;
                        var of = false;
                        while (rhs_val > 0) {
                            if (rhs_val & 1 != 0) {
                                if (mulOverflow(ans, lhs_val, &ans)) {
                                    of = true;
                                    break;
                                }
                            }
                            if (rhs_val == 1) break;
                            rhs_val = @divTrunc(rhs_val, 2);
                            var int_res: isize = undefined;
                            if (mulOverflow(lhs_val, lhs_val, &int_res)) {
                                of = true;
                                break;
                            }
                            lhs_val = int_res;
                        }
                        if (of) { // power_overflow:
                            lhs = mp_obj_new_int_from_ll(@intCast(mirrors.smallIntValue(lhs)));
                            if (pyerr.pending_exc != 0) return error.PyRaise;
                            go_big = true;
                        } else {
                            lhs_val = ans;
                        }
                    }
                } else if (op == mp.MP_BINARY_OP_DIVMOD) {
                    if (rhs_val == 0) try binopZeroDiv();
                    const items = [_]Obj{
                        mirrors.newSmallInt(mp_small_int_floor_divide(lhs_val, rhs_val)),
                        mirrors.newSmallInt(mp_small_int_modulo(lhs_val, rhs_val)),
                    };
                    return mp_obj_new_tuple(2, &items);
                } else if (op == mp.MP_BINARY_OP_LESS) {
                    return mirrors.newBool(lhs_val < rhs_val);
                } else if (op == mp.MP_BINARY_OP_MORE) {
                    return mirrors.newBool(lhs_val > rhs_val);
                } else if (op == mp.MP_BINARY_OP_LESS_EQUAL) {
                    return mirrors.newBool(lhs_val <= rhs_val);
                } else if (op == mp.MP_BINARY_OP_MORE_EQUAL) {
                    return mirrors.newBool(lhs_val >= rhs_val);
                } else {
                    try binopUnsupported(op, lhs, rhs);
                }
                if (go_big) break :to_generic; // goto generic_binary_op
                // inlined mp_obj_new_int
                if (mirrors.smallIntFits(lhs_val)) {
                    return mirrors.newSmallInt(lhs_val);
                } else {
                    const r = mp_obj_new_int_from_ll(@intCast(lhs_val));
                    if (pyerr.pending_exc != 0) return error.PyRaise;
                    return r;
                }
            }
            // v0.2 #5: FLOAT enabled — int op float promotes to float.
            if (isFloat(rhs)) {
                if (floatOpMayRaise(op)) try floatOpPrecheck(op, lhs, rhs);
                const res = mp_obj_float_binary_op(op, @as(f64, @floatFromInt(lhs_val)), rhs);
                if (pyerr.pending_exc != 0) return error.PyRaise;
                if (res != 0) return res;
                try binopUnsupported(op, lhs, rhs);
                unreachable;
            }
            // COMPLEX (full only): int op complex promotes to complex.
            if (comptime build_options.is_full) {
                if (mirrors.isExactType(rhs, &mp_type_complex)) {
                    const res = mp_obj_complex_binary_op(op, @as(f64, @floatFromInt(lhs_val)), 0, rhs);
                    if (pyerr.pending_exc != 0) return error.PyRaise;
                    if (res != 0) return res;
                    try binopUnsupported(op, lhs, rhs);
                    unreachable;
                }
            }
        }
        if (op == mp.MP_BINARY_OP_IN) {
            op = mp.MP_BINARY_OP_CONTAINS;
            const tmp = lhs;
            lhs = rhs;
            rhs = tmp;
        }
        break :to_generic;
    }
    // A float on the left reaches vendor's float_binary_op through the slot.
    if (floatOpMayRaise(op) and isFloat(lhs)) try floatOpPrecheck(op, lhs, rhs);
    // generic_binary_op:
    while (true) {
        const ty = mp_obj_get_type(lhs);
        const tym = mirrors.MpObjType.fromPtr(ty);
        if (tym.getSlot(.binary_op)) |raw| {
            const fn_ptr: mirrors.MpBinaryOpFun = @ptrCast(@alignCast(raw));
            // ADR 013 — wrap the slot call through the NLR trampoline so
            // vendor MPZ raises (divide by zero / negative shift / etc.)
            // longjmp back into a setjmp pad here instead of exit(1)ing
            // past the Python-level try/except. Compiles to a direct
            // fn_ptr call under non-exception_unwind builds.
            const nlr_trampoline = @import("nlr_trampoline.zig");
            const result = nlr_trampoline.callBinaryOp(fn_ptr, op, lhs, rhs);
            // polled-sentinel: distinguish "slot returned NULL" (try next)
            // from "slot raised" (propagate; the 0 is the bridge sentinel).
            if (pyerr.pending_exc != 0) return error.PyRaise;
            if (result != 0) return result;
        }
        if (op >= mp.MP_BINARY_OP_INPLACE_OR and op <= mp.MP_BINARY_OP_INPLACE_POWER) {
            op += mp.MP_BINARY_OP_OR - mp.MP_BINARY_OP_INPLACE_OR;
            continue; // goto generic_binary_op
        }
        // MICROPY_PY_REVERSE_SPECIAL_METHODS — swap operands, convert __op__
        // → __rop__, retry. On second failure, convert back for error msg.
        // Vendor runtime.c lines 642-655. Default-true on both arms per
        // ADR 012 D4.
        if (build_options.reverse_special_methods) {
            if (op >= mp.MP_BINARY_OP_OR and op <= mp.MP_BINARY_OP_POWER) {
                const t = rhs;
                rhs = lhs;
                lhs = t;
                op += mp.MP_BINARY_OP_REVERSE_OR - mp.MP_BINARY_OP_OR;
                continue;
            } else if (op >= mp.MP_BINARY_OP_REVERSE_OR) {
                const t = rhs;
                rhs = lhs;
                lhs = t;
                op -= mp.MP_BINARY_OP_REVERSE_OR - mp.MP_BINARY_OP_OR;
            }
        }
        if (op == mp.MP_BINARY_OP_CONTAINS) {
            var iter_buf: [ITER_BUF_CAP]u8 align(@alignOf(usize)) = undefined;
            const iter = mp_getiter(lhs, @ptrCast(&iter_buf));
            if (pyerr.pending_exc != 0) return error.PyRaise;
            var next = mp_iternext(iter);
            if (pyerr.pending_exc != 0) return error.PyRaise;
            while (next != stopIter()) : ({
                next = mp_iternext(iter);
                if (pyerr.pending_exc != 0) return error.PyRaise;
            }) {
                if (mp_obj_equal(next, rhs)) return mirrors.OBJ_TRUE;
                if (pyerr.pending_exc != 0) return error.PyRaise;
            }
            return mirrors.OBJ_FALSE;
        }
        break;
    }
    try binopUnsupported(op, lhs, rhs); // unsupported_op (TERSE)
    unreachable;
}
export fn mp_binary_op(op_in: c_int, lhs_in: Obj, rhs_in: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, mpBinaryOpImpl(op_in, lhs_in, rhs_in));
}

export fn mp_call_function_0(fun: Obj) callconv(.c) Obj {
    return mp_call_function_n_kw(fun, 0, 0, null);
}
export fn mp_call_function_1(fun: Obj, arg: Obj) callconv(.c) Obj {
    var a = arg; // C: &arg
    return mp_call_function_n_kw(fun, 1, 0, @ptrCast(&a));
}
export fn mp_call_function_2(fun: Obj, arg1: Obj, arg2: Obj) callconv(.c) Obj {
    var args = [2]Obj{ arg1, arg2 };
    return mp_call_function_n_kw(fun, 2, 0, @ptrCast(&args));
}
/// PyError-returning variant of mp_call_function_n_kw. Used by Zig
/// callers that catch PyError directly (B2 conversion path) — no bridge
/// longjmp involved.
pub fn mp_call_function_n_kw_py(fun_in: Obj, n_args: usize, n_kw: usize, args: [*c]const Obj) PyError!Obj {
    return mpCallFunctionNKwImpl(fun_in, n_args, n_kw, args);
}
fn mpCallFunctionNKwImpl(fun_in: Obj, n_args: usize, n_kw: usize, args: [*c]const Obj) PyError!Obj {
    const t = mp_obj_get_type(fun_in);
    const tm = mirrors.MpObjType.fromPtr(t);
    if (tm.getSlot(.call)) |raw| {
        const fn_ptr: mirrors.MpCallFun = @ptrCast(@alignCast(raw));
        // ADR 013 — wrap every Python call through the NLR trampoline so
        // vendor C raises (StringIO closed-file ValueError, OSError EINVAL,
        // int(...) TypeError, MPZ to_bytes OverflowError, etc.) unwind
        // back into the polled-sentinel pattern instead of exit(1) past
        // user try/except. Compiles to a direct fn_ptr call under
        // non-exception_unwind builds. One setjmp per call — same cost as
        // vendor MP's nlr_push at every call frame.
        const nlr_trampoline = @import("nlr_trampoline.zig");
        const result = nlr_trampoline.callFunction(fn_ptr, fun_in, n_args, n_kw, args);
        if (pyerr.pending_exc != 0) return error.PyRaise;
        return result;
    }
    try raiseMsg(@as(TypePtr, @ptrCast(&mp_type_TypeError)), "object not callable"); // TERSE
    unreachable;
}
export fn mp_call_function_n_kw(fun_in: Obj, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, mpCallFunctionNKwImpl(fun_in, n_args, n_kw, args));
}
/// PyError variant of mp_call_method_n_kw. See mp_call_function_n_kw_py.
pub fn mp_call_method_n_kw_py(n_args: usize, n_kw: usize, args: [*c]const Obj) PyError!Obj {
    const adjust: usize = if (args[1] == 0) 0 else 1; // args[1]==MP_OBJ_NULL
    return mp_call_function_n_kw_py(args[0], n_args + adjust, n_kw, args + (2 - adjust));
}
export fn mp_call_method_n_kw(n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    const adjust: usize = if (args[1] == 0) 0 else 1; // args[1]==MP_OBJ_NULL
    return mp_call_function_n_kw(args[0], n_args + adjust, n_kw, args + (2 - adjust));
}

// W6 long-tail: port mp_call_method_self_n_kw (was C in npy_objboundmeth_shim
// using alloca + m_new_maybe). The C frame was in raise paths from bound
// method calls + class instance method dispatch. Now pure Zig.
//
// alloca → fixed [17]Obj stack buffer for n_total ≤ 16 (covers typical
// method calls); heap fallback for n_total > 16. Under nano PYSTACK=0
// the PYSTACK alloc branch is dead.
const INLINE_ARGS_MAX: usize = 16;

fn mpCallMethodSelfNKwImpl(meth: Obj, self_obj: Obj, n_args: usize, n_kw: usize, args: [*c]const Obj) PyError!Obj {
    const n_total = n_args + 2 * n_kw;
    const total_slots = 1 + n_total;
    var inline_buf: [INLINE_ARGS_MAX + 1]Obj = undefined;
    var heap_buf: ?[*]Obj = null;
    defer if (heap_buf) |p| m_free(p);

    var args2: [*]Obj = undefined;
    if (total_slots <= inline_buf.len) {
        args2 = &inline_buf;
    } else {
        const got = @as(?[*]Obj, @ptrCast(@alignCast(m_malloc_maybe(total_slots * @sizeOf(Obj)))));
        if (got == null) {
            // Out-of-memory raise (m_new under hood) — but maybe is NULL.
            // For nano this is rare; raise MemoryError manually.
            try raiseMsg(@as(TypePtr, @ptrCast(&mp_type_MemoryError)), "no memory");
            unreachable;
        }
        heap_buf = got;
        args2 = got.?;
    }
    args2[0] = self_obj;
    @memcpy(args2[1..total_slots], args[0..n_total]);
    return mp_call_function_n_kw_py(meth, n_args + 1, n_kw, args2);
}

pub fn mp_call_method_self_n_kw_py(meth: Obj, self_obj: Obj, n_args: usize, n_kw: usize, args: [*c]const Obj) PyError!Obj {
    return mpCallMethodSelfNKwImpl(meth, self_obj, n_args, n_kw, args);
}

export fn mp_call_method_self_n_kw(meth: Obj, self_obj: Obj, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, mpCallMethodSelfNKwImpl(meth, self_obj, n_args, n_kw, args));
}
// CallArgs = mp_call_args_t. STACKLESS=0 ⇒ prepare_args is `static`
// in C (not exported) → a PRIVATE Zig fn here; only _var is exported.
// Risk R2: arg marshalling/aliasing — transcribed line-by-line; C's
// mixed size_t/ssize_t size arithmetic kept as usize wrapping ops
// (lesson #6 size_t-wrap), seq_copy → @memcpy.
const CallArgs = struct { fun: Obj, args: [*c]Obj, n_args: usize, n_kw: usize, n_alloc: usize };

fn mp_call_prepare_args_n_kw_var(have_self: bool, n_args_n_kw: usize, args_in: [*c]const Obj, out_args: *CallArgs) void {
    var args = args_in;
    const fun = args[0];
    args += 1;
    var self: Obj = 0; // MP_OBJ_NULL
    if (have_self) {
        self = args[0];
        args += 1;
    }
    const n_args = n_args_n_kw & 0xff;
    const n_kw = (n_args_n_kw >> 8) & 0xff;
    const star_args: usize = @bitCast(mirrors.smallIntValue(args[n_args + 2 * n_kw]));

    var args2: [*c]Obj = undefined;
    var args2_alloc: usize = undefined;
    var args2_len: usize = 0;

    var list_len: isize = 0;
    if (star_args != 0) {
        var i: usize = 0;
        while (i < n_args) : (i += 1) {
            if ((star_args >> @intCast(i)) & 1 != 0) {
                const len = mp_obj_len_maybe(args[i]);
                if (len != 0) list_len += mp_obj_get_int(len) - 1;
            }
        }
    }

    var kw_dict_len: isize = 0;
    {
        var i: usize = 0;
        while (i < n_kw) : (i += 1) {
            const key = args[n_args + i * 2];
            const value = args[n_args + i * 2 + 1];
            if (key == 0 and value != 0 and mirrors.isExactType(value, &mp_type_dict)) {
                kw_dict_len += @as(isize, @intCast(mp_obj_dict_len(value))) - 1;
            }
        }
    }

    if (star_args == 0) {
        // C mixes size_t/ssize_t → unsigned; mirror with wrapping usize.
        args2_alloc = 1 +% n_args +% 2 *% (n_kw +% @as(usize, @bitCast(kw_dict_len)));
        args2 = @ptrCast(@alignCast(m_malloc(args2_alloc * @sizeOf(Obj))));
        if (self != 0) {
            args2[args2_len] = self;
            args2_len += 1;
        }
        @memcpy(args2[args2_len .. args2_len + n_args], args[0..n_args]);
        args2_len += n_args;
    } else {
        args2_alloc = 1 +% n_args +% @as(usize, @bitCast(list_len)) +% 2 *% (n_kw +% @as(usize, @bitCast(kw_dict_len)));
        args2 = @ptrCast(@alignCast(m_malloc(args2_alloc * @sizeOf(Obj))));
        if (self != 0) {
            args2[args2_len] = self;
            args2_len += 1;
        }
        var i: usize = 0;
        while (i < n_args) : (i += 1) {
            const arg = args[i];
            if ((star_args >> @intCast(i)) & 1 != 0) {
                if ((mirrors.isExactType(arg, &mp_type_tuple) or mirrors.isExactType(arg, &mp_type_list))) {
                    var len: usize = undefined;
                    var items: [*c]Obj = undefined;
                    mp_obj_get_array(arg, &len, @ptrCast(&items));
                    @memcpy(args2[args2_len .. args2_len + len], items[0..len]);
                    args2_len += len;
                } else {
                    var iter_buf: [ITER_BUF_CAP]u8 align(@alignOf(usize)) = undefined;
                    const iterable = mp_getiter(arg, @ptrCast(&iter_buf));
                    var item = mp_iternext(iterable);
                    while (item != stopIter()) : (item = mp_iternext(iterable)) {
                        if (args2_len + (n_args - i) >= args2_alloc) {
                            args2 = @ptrCast(@alignCast(m_realloc(args2, args2_alloc * 2 * @sizeOf(Obj))));
                            args2_alloc *= 2;
                        }
                        args2[args2_len] = item;
                        args2_len += 1;
                    }
                }
            } else {
                args2[args2_len] = arg;
                args2_len += 1;
            }
        }
    }

    const pos_args_len = args2_len;

    if (args2_len + 2 * (n_kw +% @as(usize, @bitCast(kw_dict_len))) > args2_alloc) {
        const new_alloc = args2_len + 2 * (n_kw +% @as(usize, @bitCast(kw_dict_len)));
        args2 = @ptrCast(@alignCast(m_realloc(args2, new_alloc * @sizeOf(Obj))));
        args2_alloc = new_alloc;
    }

    {
        var i: usize = 0;
        while (i < n_kw) : (i += 1) {
            const kw_key = args[n_args + i * 2];
            const kw_value = args[n_args + i * 2 + 1];
            if (kw_key == 0) {
                if (mirrors.isExactType(kw_value, &mp_type_dict)) {
                    const map = &mirrors.MpObjDict.fromObj(kw_value).map;
                    const malloc_ = map.alloc;
                    var j: usize = 0;
                    while (j < malloc_) : (j += 1) {
                        if (mirrors.MpMap.fromPtr(map).slotFilled(j)) {
                            var key = mirrors.MpMap.fromPtr(map).keyAt(j);
                            if (!mirrors.isQstr(key)) key = mp_obj_str_intern_checked(key);
                            args2[args2_len] = key;
                            args2_len += 1;
                            args2[args2_len] = mirrors.MpMap.fromPtr(map).valueAt(j);
                            args2_len += 1;
                        }
                    }
                } else {
                    var dest: [3]Obj = undefined;
                    mp_load_method(kw_value, @intCast(mp.MP_QSTR_keys), @ptrCast(&dest));
                    const iterable = mp_getiter(mp_call_method_n_kw(0, 0, @ptrCast(&dest)), null);
                    var key = mp_iternext(iterable);
                    while (key != stopIter()) : (key = mp_iternext(iterable)) {
                        if (args2_len + 1 >= args2_alloc) {
                            const new_alloc = args2_alloc * 2;
                            args2 = @ptrCast(@alignCast(m_realloc(args2, new_alloc * @sizeOf(Obj))));
                            args2_alloc = new_alloc;
                        }
                        if (!mirrors.isQstr(key)) key = mp_obj_str_intern_checked(key);
                        mp_load_method(kw_value, @intCast(mp.MP_QSTR___getitem__), @ptrCast(&dest));
                        dest[2] = key;
                        const value = mp_call_method_n_kw(1, 0, @ptrCast(&dest));
                        args2[args2_len] = key;
                        args2_len += 1;
                        args2[args2_len] = value;
                        args2_len += 1;
                    }
                }
            } else {
                args2[args2_len] = kw_key;
                args2_len += 1;
                args2[args2_len] = kw_value;
                args2_len += 1;
            }
        }
    }

    out_args.fun = fun;
    out_args.args = args2;
    out_args.n_args = pos_args_len;
    out_args.n_kw = (args2_len - pos_args_len) / 2;
    out_args.n_alloc = args2_alloc;
}

export fn mp_call_method_n_kw_var(have_self: bool, n_args_n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    var out_args: CallArgs = undefined;
    mp_call_prepare_args_n_kw_var(have_self, n_args_n_kw, args, &out_args);
    const res = mp_call_function_n_kw(out_args.fun, out_args.n_args, out_args.n_kw, out_args.args);
    m_free(out_args.args);
    return res;
}
fn mpUnpackSequenceImpl(seq_in: Obj, num: usize, items: ObjOut) PyError!void {
    std.debug.assert(@sizeOf(mirrors.MpObjIterBuf) <= ITER_BUF_CAP);
    var seq_len: usize = undefined;
    if ((mirrors.isExactType(seq_in, &mp_type_tuple) or mirrors.isExactType(seq_in, &mp_type_list))) {
        var seq_items: [*c]Obj = undefined;
        mp_obj_get_array(seq_in, &seq_len, @ptrCast(&seq_items));
        if (seq_len < num) try unpackErr(); // C: goto too_short
        if (seq_len > num) try unpackErr(); // C: goto too_long (TERSE: same msg)
        var i: usize = 0;
        while (i < num) : (i += 1) items[i] = seq_items[num - 1 - i];
    } else {
        var iter_buf: [ITER_BUF_CAP]u8 align(@alignOf(usize)) = undefined;
        const iterable = mp_getiter(seq_in, @ptrCast(&iter_buf));
        seq_len = 0;
        while (seq_len < num) : (seq_len += 1) {
            const el = mp_iternext(iterable);
            if (el == stopIter()) try unpackErr();
            items[num - 1 - seq_len] = el;
        }
        if (mp_iternext(iterable) != stopIter()) try unpackErr();
    }
}
export fn mp_unpack_sequence(seq_in: Obj, num: usize, items: ObjOut) callconv(.c) void {
    pyerr.bridge(void, mpUnpackSequenceImpl(seq_in, num, items));
}
// unpacked items are stored in reverse order into `items`.
fn mpUnpackExImpl(seq_in: Obj, num_in: usize, items: ObjOut) PyError!void {
    const num_left = num_in & 0xff;
    const num_right = (num_in >> 8) & 0xff;
    var seq_len: usize = undefined;
    if ((mirrors.isExactType(seq_in, &mp_type_tuple) or mirrors.isExactType(seq_in, &mp_type_list))) {
        // `seq` is the C `volatile` GC anchor (seq_items points into its
        // GC cell; mp_obj_new_list may collect). Keep it live across.
        var seq: Obj = seq_in;
        var seq_items: [*c]Obj = undefined;
        mp_obj_get_array(seq, &seq_len, @ptrCast(&seq_items));
        if (seq_len < num_left + num_right) try unpackErr();
        var i: usize = 0;
        while (i < num_right) : (i += 1) items[i] = seq_items[seq_len - 1 - i];
        items[num_right] = mp_obj_new_list(seq_len - num_left - num_right, seq_items + num_left);
        i = 0;
        while (i < num_left) : (i += 1) items[num_right + 1 + i] = seq_items[num_left - 1 - i];
        seq = 0;
        std.mem.doNotOptimizeAway(seq);
    } else {
        const iterable = mp_getiter(seq_in, null);
        var item: Obj = undefined;
        seq_len = 0;
        while (seq_len < num_left) : (seq_len += 1) {
            item = mp_iternext(iterable);
            if (item == stopIter()) try unpackErr();
            items[num_left + num_right + 1 - 1 - seq_len] = item;
        }
        const rest = mp_obj_new_list(0, null);
        item = mp_iternext(iterable);
        while (item != stopIter()) {
            _ = mp_obj_list_append(rest, item);
            item = mp_iternext(iterable);
        }
        const rlen = mirrors.MpObjList.lenOf(rest);
        if (rlen < num_right) try unpackErr();
        items[num_right] = rest;
        const ritems = mirrors.MpObjList.itemsOf(rest);
        var i: usize = 0;
        while (i < num_right) : (i += 1) items[num_right - 1 - i] = ritems[rlen - num_right + i];
        mp_obj_list_set_len(rest, rlen - num_right);
    }
}
export fn mp_unpack_ex(seq_in: Obj, num_in: usize, items: ObjOut) callconv(.c) void {
    pyerr.bridge(void, mpUnpackExImpl(seq_in, num_in, items));
}
export fn mp_load_attr(base: Obj, attr: Qstr) callconv(.c) Obj {
    var dest: [2]Obj = undefined;
    mp_load_method(base, attr, @ptrCast(&dest));
    if (dest[1] == 0) {
        return dest[0]; // normal attribute
    } else {
        return mp_obj_new_bound_meth(dest[0], dest[1]); // bound method
    }
}
// BUILTIN_METHOD_CHECK_SELF_ARG=0 → the checked_fun wrap (middle
// else-if) is dead.
export fn mp_convert_member_lookup(self: Obj, type_in: TypePtr, member: Obj, dest: ObjOut) callconv(.c) void {
    var t = type_in;
    if (mirrors.isObj(member)) {
        const m_type: TypePtr = @ptrCast(mirrors.objBaseType(member));
        const m_type_mirror = mirrors.MpObjType.fromPtr(m_type);
        if (m_type_mirror.flagBindsSelf()) {
            if (m_type_mirror.flagBuiltinFun()) {
                if (mirrors.MpObjType.fromPtr(t).flagInstanceType()) {
                    dest[0] = member; // built-in fn on user type → staticmethod
                } else {
                    dest[0] = member;
                    dest[1] = self;
                }
            } else {
                dest[0] = member;
                dest[1] = self;
            }
        } else if (m_type == @as(TypePtr, @ptrCast(&mp_type_staticmethod))) {
            dest[0] = @intFromPtr(mirrors.MpObjStaticClassMethod.fromObj(member).fun);
        } else if (m_type == @as(TypePtr, @ptrCast(&mp_type_classmethod))) {
            if (self != 0) { // self != MP_OBJ_NULL
                t = mp_obj_get_type(self);
                if (t == @as(TypePtr, @ptrCast(&mp_type_type))) {
                    t = @as(TypePtr, @ptrCast(mirrors.objToPtr(self)));
                }
            }
            dest[0] = @intFromPtr(mirrors.MpObjStaticClassMethod.fromObj(member).fun);
            dest[1] = mirrors.objFromPtr(t);
        } else {
            dest[0] = member;
        }
    } else {
        dest[0] = member;
    }
}
fn mpLoadMethodImpl(base: Obj, attr: Qstr, dest: ObjOut) PyError!void {
    mp_load_method_maybe(base, attr, dest);
    // B2: if mp_load_method_maybe's internal __getattr__ call raised, dest
    // is left zero. Don't overwrite the pending exc with our generic
    // "no such attribute" — propagate.
    if (pyerr.pending_exc != 0) return error.PyRaise;
    if (dest[0] == 0) { // MP_OBJ_NULL — no such attr
        // Include the attribute name: "no attribute 'foo'". Saves the
        // print-debug round-trip when the developer typo'd a method name.
        pyerr.pending_exc = mp_obj_new_exception_msg_varg(
            &mp_type_AttributeError,
            "no attribute '%q'",
            @as(usize, attr));
        return error.PyRaise;
    }
}
export fn mp_load_method(base: Obj, attr: Qstr, dest: ObjOut) callconv(.c) void {
    pyerr.bridge(void, mpLoadMethodImpl(base, attr, dest));
}
// MICROPY_CPYTHON_COMPAT=1: a.__class__ ≡ type(a). Vendor runtime.c:1185.
// Gated on is_full to preserve nano-C byte-exact reference (which the
// frozen nano corpus was generated against — adding the branch under nano
// changes class_descriptor/setname_hazard/special_methods2 outputs).
export fn mp_load_method_maybe(obj: Obj, attr: Qstr, dest: ObjOut) callconv(.c) void {
    dest[0] = 0; // MP_OBJ_NULL
    dest[1] = 0;
    const t = mp_obj_get_type(obj);
    // Zero-init stubs like mp_module_io have
    // base.type=NULL. Treat as "no attribute" so the caller raises a
    // normal AttributeError instead of crashing on null-ptr cast.
    if (build_options.is_full and t == null) return;
    const tm = mirrors.MpObjType.fromPtr(t);
    if (build_options.is_full and attr == @as(Qstr, @intCast(mp.MP_QSTR___class__))) {
        dest[0] = @intFromPtr(t);
        return;
    }
    if (attr == @as(Qstr, @intCast(mp.MP_QSTR___next__)) and tm.hasIterNext()) {
        dest[0] = mirrors.objFromPtr(&mp_builtin_next_obj);
        dest[1] = obj;
        return;
    }
    if (tm.getSlot(.attr)) |raw| {
        const fn_ptr: mirrors.MpAttrFun = @ptrCast(@alignCast(raw));
        fn_ptr(obj, @intCast(attr), dest);
        // dest[1]==SENTINEL → keep looking (locals_dict); else done.
        if (dest[1] != mirrors.OBJ_SENTINEL) {
            return;
        }
        dest[1] = 0; // clear the fail flag type->attr set
    }
    if (tm.hasSlot(.locals_dict)) {
        const v = tm.localsDictLookup(@intCast(attr)); // value|0 (dict vals never NULL)
        if (v != 0) {
            mp_convert_member_lookup(obj, t, v, dest);
        }
        return;
    }
}
// HOST #1 — the proven §2.4.1 trampoline pattern, first use in
// runtime. C: `if(nlr_push){maybe} else { if(!catch_all && exc not
// AttributeError) re-raise }`. The body calls the Zig sibling
// mp_load_method_maybe (stub until its batch — fine while unwired;
// the whole model is exercised only at batch-6 wiring).
fn mpLoadMethodProtectedImpl(obj: Obj, attr: Qstr, dest: ObjOut, catch_all_exc: bool) PyError!void {
    // NX-3 N4: npy_nlr_run wrap dropped — no Zig code longjmps under nano.
    mp_load_method_maybe(obj, attr, dest);
    if (pyerr.pending_exc != 0) {
        const ev = pyerr.pending_exc;
        pyerr.pending_exc = 0;
        const is_attr = mp_obj_is_subclass_fast(
            @intFromPtr(mirrors.objBaseType(ev)),
            mirrors.objFromPtr(&mp_type_AttributeError),
        );
        if (!catch_all_exc and !is_attr) {
            pyerr.pending_exc = ev; // re-raise via PyError
            return error.PyRaise;
        }
        // else: swallowed — dest left as mp_load_method_maybe left it.
    }
}
export fn mp_load_method_protected(obj: Obj, attr: Qstr, dest: ObjOut, catch_all_exc: bool) callconv(.c) void {
    pyerr.bridge(void, mpLoadMethodProtectedImpl(obj, attr, dest, catch_all_exc));
}
fn mpStoreAttrImpl(base: Obj, attr: Qstr, value: Obj) PyError!void {
    const t = mp_obj_get_type(base);
    const tm = mirrors.MpObjType.fromPtr(t);
    if (tm.getSlot(.attr)) |raw| {
        var dest = [2]Obj{ mirrors.OBJ_SENTINEL, value };
        const fn_ptr: mirrors.MpAttrFun = @ptrCast(@alignCast(raw));
        fn_ptr(base, @intCast(attr), @ptrCast(&dest));
        if (dest[0] == 0) {
            return; // success
        }
    }
    // Include the attribute name: "no attribute 'foo'" (matches the
    // mp_load_attr / mp_load_method form for consistency).
    pyerr.pending_exc = mp_obj_new_exception_msg_varg(
        &mp_type_AttributeError,
        "no attribute '%q'",
        @as(usize, attr));
    return error.PyRaise;
}
export fn mp_store_attr(base: Obj, attr: Qstr, value: Obj) callconv(.c) void {
    pyerr.bridge(void, mpStoreAttrImpl(base, attr, value));
}
fn mpGetiterImpl(o_in: Obj, iter_buf: IterBuf) PyError!Obj {
    const t = mp_obj_get_type(o_in);
    // B2 defensive: NULL type means o_in was MP_OBJ_NULL (sentinel from a
    // polled raise). Propagate.
    if (t == null) return error.PyRaise;
    const tm = mirrors.MpObjType.fromPtr(t);
    if (tm.iterIsIdentity()) return o_in;
    var ib = iter_buf;
    if (tm.hasSlot(.iter)) {
        if (ib == null and !tm.iterSlotIsInstanceGetiter()) {
            ib = m_malloc(@sizeOf(mirrors.MpObjIterBuf));
        }
        const iter = tm.callGetiter(o_in, ib);
        if (iter != 0) return iter;
    }
    var dest: [2]Obj = undefined;
    mp_load_method_maybe(o_in, @intCast(mp.MP_QSTR___getitem__), @ptrCast(&dest));
    if (dest[0] != 0) {
        if (ib == null) ib = m_malloc(@sizeOf(mirrors.MpObjIterBuf));
        return mp_obj_new_getitem_iter(@ptrCast(&dest), ib);
    }
    try raiseMsg(@as(TypePtr, @ptrCast(&mp_type_TypeError)), "object not iterable"); // TERSE
    unreachable;
}
export fn mp_getiter(o_in: Obj, iter_buf: IterBuf) callconv(.c) Obj {
    return pyerr.bridge(Obj, mpGetiterImpl(o_in, iter_buf));
}
fn mpIternextAllowRaiseImpl(o_in: Obj) PyError!Obj {
    const t = mp_obj_get_type(o_in);
    const tm = mirrors.MpObjType.fromPtr(t);
    if (tm.hasIterNext()) {
        mirrors.mp_state_ctx.thread.stop_iteration_arg = 0;
        return tm.callIternext(o_in);
    } else {
        var dest: [2]Obj = undefined;
        mp_load_method_maybe(o_in, @intCast(mp.MP_QSTR___next__), @ptrCast(&dest));
        if (dest[0] != 0) {
            return mp_call_method_n_kw(0, 0, @ptrCast(&dest));
        } else {
            try raiseMsg(@as(TypePtr, @ptrCast(&mp_type_TypeError)), "object not an iterator"); // TERSE
            unreachable;
        }
    }
}
export fn mp_iternext_allow_raise(o_in: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, mpIternextAllowRaiseImpl(o_in));
}
// HOST #2 — only the `__next__` sub-block hosts the polled-sentinel
// catch; the TYPE_HAS_ITERNEXT fast path is NOT wrapped.
fn mpIternextImpl(o_in: Obj) PyError!Obj {
    cstackCheck(); // recursive iternext (enumerate/filter/map/zip)
    const t = mp_obj_get_type(o_in);
    const tm = mirrors.MpObjType.fromPtr(t);
    if (tm.hasIterNext()) {
        mirrors.mp_state_ctx.thread.stop_iteration_arg = 0;
        return tm.callIternext(o_in);
    } else {
        var dest: [2]Obj = undefined;
        mp_load_method_maybe(o_in, @intCast(mp.MP_QSTR___next__), @ptrCast(&dest));
        if (dest[0] != 0) {
            // NX-3 N4: npy_nlr_run wrap dropped — no Zig code longjmps.
            const ret = mp_call_method_n_kw(0, 0, @ptrCast(&dest));
            if (pyerr.pending_exc != 0) {
                const ev = pyerr.pending_exc;
                pyerr.pending_exc = 0;
                if (mp_obj_is_subclass_fast(
                    @intFromPtr(mirrors.objBaseType(ev)),
                    mirrors.objFromPtr(&mp_type_StopIteration),
                )) {
                    return makeStopIteration(mp_obj_exception_get_value(ev));
                } else {
                    pyerr.pending_exc = ev; // re-raise via PyError
                    return error.PyRaise;
                }
            }
            return ret;
        } else {
            try raiseMsg(@as(TypePtr, @ptrCast(&mp_type_TypeError)), "object not an iterator"); // TERSE
            unreachable;
        }
    }
}
export fn mp_iternext(o_in: Obj) callconv(.c) Obj {
    if (pyerr.pending_exc != 0) return 0; // B2: pre-flight skip if already raised
    return pyerr.bridge(Obj, mpIternextImpl(o_in));
}
export fn mp_resume(self_in: Obj, send_value: Obj, throw_value: Obj, ret_val: ObjOut) callconv(.c) c_int {
    const t = mp_obj_get_type(self_in);
    if (t == @as(TypePtr, @ptrCast(&mp_type_gen_instance))) {
        return mp_obj_gen_resume(self_in, send_value, throw_value, ret_val);
    }
    const tm = mirrors.MpObjType.fromPtr(t);
    if (tm.hasIterNext() and send_value == mirrors.OBJ_NONE) {
        mirrors.mp_state_ctx.thread.stop_iteration_arg = 0;
        const ret = tm.callIternext(self_in);
        ret_val[0] = ret;
        if (ret != stopIter()) {
            return mp.MP_VM_RETURN_YIELD;
        } else {
            ret_val[0] = mirrors.mp_state_ctx.thread.stop_iteration_arg;
            if (ret_val[0] == 0) ret_val[0] = mirrors.OBJ_NONE;
            return mp.MP_VM_RETURN_NORMAL;
        }
    }
    var dest: [3]Obj = undefined; // slot for send() arg
    if (send_value == mirrors.OBJ_NONE) {
        mp_load_method_maybe(self_in, @intCast(mp.MP_QSTR___next__), @ptrCast(&dest));
        if (dest[0] != 0) {
            ret_val[0] = mp_call_method_n_kw(0, 0, @ptrCast(&dest));
            // B2: distinguish raise (esp. StopIteration) from yield. If
            // __next__ raised StopIteration, translate to RETURN_NORMAL
            // with the value. Other raises propagate via pending_exc.
            if (pyerr.pending_exc != 0) {
                const ev = pyerr.pending_exc;
                if (mp_obj_is_subclass_fast(
                    @intFromPtr(mirrors.objBaseType(ev)),
                    mirrors.objFromPtr(&mp_type_StopIteration),
                )) {
                    pyerr.pending_exc = 0;
                    ret_val[0] = mp_obj_exception_get_value(ev);
                    if (ret_val[0] == 0) ret_val[0] = mirrors.OBJ_NONE;
                    return mp.MP_VM_RETURN_NORMAL;
                }
                // Non-StopIteration raise — propagate.
                ret_val[0] = ev;
                pyerr.pending_exc = 0;
                return mp.MP_VM_RETURN_EXCEPTION;
            }
            return mp.MP_VM_RETURN_YIELD;
        }
    }
    if (send_value != 0) {
        mp_load_method(self_in, @intCast(mp.MP_QSTR_send), @ptrCast(&dest));
        dest[2] = send_value;
        ret_val[0] = mp_call_method_n_kw(1, 0, @ptrCast(&dest));
        // Same translation for the send() path.
        if (pyerr.pending_exc != 0) {
            const ev = pyerr.pending_exc;
            if (mp_obj_is_subclass_fast(
                @intFromPtr(mirrors.objBaseType(ev)),
                mirrors.objFromPtr(&mp_type_StopIteration),
            )) {
                pyerr.pending_exc = 0;
                ret_val[0] = mp_obj_exception_get_value(ev);
                if (ret_val[0] == 0) ret_val[0] = mirrors.OBJ_NONE;
                return mp.MP_VM_RETURN_NORMAL;
            }
            ret_val[0] = ev;
            pyerr.pending_exc = 0;
            return mp.MP_VM_RETURN_EXCEPTION;
        }
        return mp.MP_VM_RETURN_YIELD;
    }
    // assert(throw_value != MP_OBJ_NULL)
    if (mp_obj_is_subclass_fast(
        mirrors.objFromPtr(mp_obj_get_type(throw_value)),
        mirrors.objFromPtr(&mp_type_GeneratorExit),
    )) {
        mp_load_method_maybe(self_in, @intCast(mp.MP_QSTR_close), @ptrCast(&dest));
        if (dest[0] != 0) {
            ret_val[0] = mp_call_method_n_kw(0, 0, @ptrCast(&dest));
            return mp.MP_VM_RETURN_NORMAL;
        }
    } else {
        mp_load_method_maybe(self_in, @intCast(mp.MP_QSTR_throw), @ptrCast(&dest));
        if (dest[0] != 0) {
            dest[2] = throw_value;
            ret_val[0] = mp_call_method_n_kw(1, 0, @ptrCast(&dest));
            return mp.MP_VM_RETURN_YIELD;
        }
    }
    if (mp_obj_exception_match(throw_value, mirrors.objFromPtr(&mp_type_StopIteration))) {
        // PEP479: StopIteration in a generator → RuntimeError
        ret_val[0] = mp_obj_new_exception_msg(@as(TypePtr, @ptrCast(&mp_type_RuntimeError)), "generator raised StopIteration");
    } else {
        ret_val[0] = mp_make_raise_obj(throw_value);
    }
    return mp.MP_VM_RETURN_EXCEPTION;
}
export fn mp_make_raise_obj(o_in: Obj) callconv(.c) Obj {
    var o = o_in;
    if (mp_obj_is_exception_type(o)) {
        o = mp_call_function_n_kw(o, 0, 0, null);
    }
    if (mp_obj_is_exception_instance(o)) {
        return o;
    } else {
        return mp_obj_new_exception_msg(@as(TypePtr, @ptrCast(&mp_type_TypeError)), "exceptions must derive from BaseException");
    }
}
// v0.7.1: override_dict lookup for `builtins.__import__ = X` (full).
export fn mp_import_name(name: Qstr, fromlist: Obj, level: Obj) callconv(.c) Obj {
    var args = [5]Obj{
        mirrors.objFromQstr(name),
        mirrors.MpStateThread.globalsObj(), // MP_OBJ_FROM_PTR(mp_globals_get())
        mirrors.OBJ_NONE, // TODO should be locals (mirrors C)
        fromlist,
        level,
    };
    if (build_options.is_full) {
        if (mp_module_builtins_override_dict) |od| {
            const custom = od.map.lookupQstr(@intCast(mp.MP_QSTR___import__));
            if (custom != 0) {
                return mp_call_function_n_kw(custom, 5, 0, @ptrCast(&args));
            }
        }
    }
    return mp_builtin___import___default(5, @ptrCast(&args));
}
// Vendor py/runtime.c:mp_import_from. Under EXTERNAL_IMPORT=1 (our
// setting), attribute-miss on `from pkg import sub` falls back to a
// submodule import — construct "pkg.sub" and hand it to
// mp_import_name. This is what makes `from hop3_rootd import cgroup`
// load `hop3_rootd/cgroup.py` when the parent package didn't
// pre-import cgroup as an attribute.
fn mpImportFromImpl(module: Obj, name: Qstr) PyError!Obj {
    var dest: [2]Obj = undefined;
    mp_load_method_maybe(module, name, @ptrCast(&dest));
    if (dest[1] != 0) {
        return mp_obj_new_bound_meth(dest[0], dest[1]);
    } else if (dest[0] != 0) {
        return dest[0];
    }

    // Attribute miss. Fall back to submodule import if `module` is a
    // package (has __path__).
    mp_load_method_maybe(module, @intCast(mp.MP_QSTR___path__), @ptrCast(&dest));
    if (dest[0] == 0) {
        pyerr.pending_exc = mp_obj_new_exception_msg_varg(&mp_type_ImportError, "can't import name %q", @as(usize, name));
        return error.PyRaise;
    }

    // Get __name__ as a C string — mp_load_method_maybe stashes value at dest[0].
    mp_load_method_maybe(module, @intCast(mp.MP_QSTR___name__), @ptrCast(&dest));
    const pkg_name = mp_obj_str_get_str(dest[0]) orelse {
        pyerr.pending_exc = mp_obj_new_exception_msg_varg(&mp_type_ImportError, "can't import name %q", @as(usize, name));
        return error.PyRaise;
    };
    var pkg_len: usize = 0;
    while (pkg_name[pkg_len] != 0) : (pkg_len += 1) {}

    // "pkg.name". PATH_MAX-shape buffer covers deeply-nested dotted
    // packages; realistic imports are ≤4 levels deep so 512 is generous.
    var dot_name: [512]u8 = undefined;
    const sub_name_c = qstr_str_ext(@as(usize, name));
    var sub_len: usize = 0;
    while (sub_name_c[sub_len] != 0) : (sub_len += 1) {}
    const total = pkg_len + 1 + sub_len;
    if (total > dot_name.len) {
        pyerr.pending_exc = mp_obj_new_exception_msg_varg(&mp_type_ImportError, "can't import name %q", @as(usize, name));
        return error.PyRaise;
    }
    @memcpy(dot_name[0..pkg_len], pkg_name[0..pkg_len]);
    dot_name[pkg_len] = '.';
    @memcpy(dot_name[pkg_len + 1 .. total], sub_name_c[0..sub_len]);

    const dot_qstr = qstr_from_strn_ext(&dot_name, total);
    // Pass mp_const_true as fromlist to force leaf-module return.
    return mp_import_name(@intCast(dot_qstr), MP_OBJ_CONST_TRUE, mirrors.newSmallInt(0));
}

// Vendor C exports (py/qstr.c). Suffixed to avoid symbol-shadowing
// gotchas at file scope.
extern fn qstr_str(q: usize) callconv(.c) [*:0]const u8;
extern fn qstr_from_strn(str: [*]const u8, len: usize) callconv(.c) usize;
const qstr_str_ext = qstr_str;
const qstr_from_strn_ext = qstr_from_strn;

const MP_OBJ_CONST_TRUE: Obj = 0x1E;  // (3 << 3) | 6 — vendor py/obj.h:917
export fn mp_import_from(module: Obj, name: Qstr) callconv(.c) Obj {
    return pyerr.bridge(Obj, mpImportFromImpl(module, name));
}
// MICROPY_MODULE___ALL__=0 → the __all__ explicit-load block is dead.
fn mpImportAllImpl(module: Obj) PyError!void {
    const map = &mirrors.MpObjModule.fromObj(module).globals.map;
    const alloc_ = mirrors.MpMap.fromPtr(map).alloc;
    var i: usize = 0;
    while (i < alloc_) : (i += 1) {
        if (mirrors.MpMap.fromPtr(map).slotFilled(i)) {
            const key = mirrors.MpMap.fromPtr(map).keyAt(i);
            const name = mp_obj_str_get_str(key) orelse return error.PyRaise;
            if (name[0] != '_') {
                const qname = mp_obj_str_get_qstr(key);
                mp_store_name(@intCast(qname), mirrors.MpMap.fromPtr(map).valueAt(i));
            }
        }
    }
}
export fn mp_import_all(module: Obj) callconv(.c) void {
    return pyerr.bridge(void, mpImportAllImpl(module));
}
// raise family — nano resolved (ERROR_REPORTING=TERSE, STACK_CHECK=
// PYSTACK=0): `mp_raise_type` is a MACRO (→mp_raise_msg(t,NULL)),
// `mp_raise_recursion_depth` is NOT compiled — neither is a symbol.
// NX-3 N4 (2026-06-05): the prior `mp_raise_msg` / `mp_raise_msg_varg`
// / `mp_raise_type_arg` noreturn exports were deleted — they had no
// Zig callers in the nano graph (the only call site was
// `stream.zig:145`, whole-module dead under nano; converted to @panic
// in the same commit). This eliminates 4 `nlr_jump` call sites here.
// mp_obj_new_checked_fun: `static` AND #if BUILTIN_METHOD_CHECK_SELF_
// ARG (=0 nano) → not compiled, not a symbol. Not ported (3rd
// config-removes-symbol case after mp_raise_type/recursion_depth).
//
// mp_parse_compile_execute: removed at Stage 3b-step-2. eval/exec/REPL/
// script all route through src/runtime/zig_compile_bridge.c. The legacy
// import path (do_load_from_lexer in builtinimport_shim.c) is
// comptime-dead under MICROPY_ENABLE_EXTERNAL_IMPORT=0.
// jump-callback helpers (mp_globals_locals_set_from_nlr_jump_callback /
// mp_call_function_1_from_nlr_jump_callback) were deleted at NX-3 N3b —
// no callers remained after N3a ported zig_compile_bridge.c to Zig
// defer/errdefer.

const std = @import("std");

comptime {
    // Force full body+ABI analysis of every stub (the `_ = &fn;` rule —
    // `_ = fn;` is a fake green). Removed/replaced by `export` at batch 6.
    for (.{
        &mp_init,                                   &mp_deinit,
        &mp_load_name,                              &mp_load_global,
        &mp_load_build_class,                       &mp_store_name,
        &mp_store_global,                           &mp_delete_name,
        &mp_delete_global,                          &mp_unary_op,
        &mp_call_function_0,                        &mp_call_function_1,
        &mp_call_function_2,                        &mp_call_function_n_kw,
        &mp_call_method_n_kw,                       &mp_call_method_n_kw_var,
        &mp_call_prepare_args_n_kw_var,             &mp_unpack_sequence,
        &mp_unpack_ex,                              &mp_load_attr,
        &mp_convert_member_lookup,                  &mp_load_method,
        &mp_load_method_maybe,                      &mp_load_method_protected,
        &mp_store_attr,                             &mp_getiter,
        &mp_iternext_allow_raise,                   &mp_iternext,
        &mp_resume,                                 &mp_make_raise_obj,
        &mp_import_name,                            &mp_import_from,
        &mp_import_all,                             &mp_binary_op,
    }) |f| {
        _ = f;
    }
    _ = std;
}
