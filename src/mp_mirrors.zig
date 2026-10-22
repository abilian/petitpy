//! Zig packed-struct mirrors of MicroPython C types that contain bitfields.
//!
//! Until now we believed Zig couldn't access C bitfields safely (lesson #11),
//! so we wrote per-field accessor wrappers (`npy_X_map_is_fixed`, etc.) in C
//! shims. That belief was incomplete: Zig's `extern struct` doesn't support
//! bitfields, but Zig's `packed struct(usize)` does, and produces byte-
//! identical layout to C bitfield structs on the same target.
//!
//! Spike validated (2026-05-22): `MpMap` + `MpObjDict` match the C layout
//! byte-for-byte on Apple aarch64 (sizeof=24/32, offsets 0/8/16 and 0/8,
//! bit pattern 0x2D matches C). See the comptime asserts at the end of
//! this file — they cross-check against shim-exported `sizeof`/`offsetof`.
//!
//! Usage: cast an `Obj` (which is `usize`) to a pointer to one of the
//! mirror types via `@ptrFromInt`, then access fields directly. No shim
//! call needed.
//!
//! This file is the foundation for eliminating the dozens of `npy_X_*`
//! accessor wrappers that exist across `src/objects/**/` shims.

const std = @import("std");

// `mp_obj_t` is `void *` under REPR_A (nano default); we represent it as
// `usize` in Zig and cast as needed.
pub const Obj = usize;

pub const MpObjBase = extern struct {
    type: ?*const anyopaque,
};

/// `mp_obj_float_t` (vendor objfloat.c, DOUBLE impl).
pub const MpObjFloat = extern struct {
    base: MpObjBase,
    value: f64,
};

/// Mirror of C `mp_map_t` from vendor/micropython_embed/py/obj.h:481.
/// Bitfield packing is 1+1+1+(N-3) where N = `8 * sizeof(usize)` = 64 on 64-bit.
pub const MpMap = extern struct {
    bits: packed struct(usize) {
        all_keys_are_qstrs: u1,
        is_fixed: u1,
        is_ordered: u1,
        used: std.meta.Int(.unsigned, @bitSizeOf(usize) - 3),
    },
    alloc: usize,
    table: ?*anyopaque, // [*]MpMapElem

    pub const Elem = extern struct {
        key: Obj,
        value: Obj,
    };

    /// Cast a raw `mp_map_t *` (passed as `void *` or `?*anyopaque` from C).
    pub inline fn fromPtr(p: ?*anyopaque) *MpMap {
        return @ptrCast(@alignCast(p));
    }
    /// Typed access to the hash table slots.
    pub inline fn tablePtr(self: *MpMap) [*]Elem {
        return @ptrCast(@alignCast(self.table));
    }
    /// `mp_map_slot_is_filled(m, i)`: slot non-NULL and non-SENTINEL.
    pub inline fn slotFilled(self: *MpMap, i: usize) bool {
        const k = self.tablePtr()[i].key;
        return k != OBJ_NULL and k != OBJ_SENTINEL;
    }
    pub inline fn keyAt(self: *MpMap, i: usize) Obj {
        return self.tablePtr()[i].key;
    }
    pub inline fn valueAt(self: *MpMap, i: usize) Obj {
        return self.tablePtr()[i].value;
    }
    /// `npy__map_lookup` (runtime_shim.c:53-56): look up a qstr key,
    /// return its value or OBJ_NULL if absent. Used by the
    /// {globals,locals,builtins,locals_dict}_lookup helpers.
    pub inline fn lookupQstr(self: *MpMap, q: u16) Obj {
        const e = mp_map_lookup(self, objFromQstr(q), MP_MAP_LOOKUP);
        return if (e) |el| el.value else OBJ_NULL;
    }
};

/// Mirror of C `mp_module_constants_t` (bc.h:200). Layout is
/// config-dependent in first-field semantics but invariant in size:
///   USES_QSTR_TABLE=1 (full): `qstr_short_t *qstr_table` (ptr, 8B)
///   USES_QSTR_TABLE=0 (nano): `qstr source_file` (= size_t, 8B)
/// `obj_table` follows at the same offset (8B) under both configs.
/// Caller interprets first field per `build_options.is_full`.
pub const MpModuleConstants = extern struct {
    qstr_table_or_source_file: usize,
    obj_table: [*]Obj,
};

/// Mirror of C `mp_module_context_t` (bc.h:210).
pub const MpModuleContext = extern struct {
    module: MpObjModule,
    constants: MpModuleConstants,

    pub inline fn fromPtr(p: ?*const anyopaque) *const MpModuleContext {
        return @ptrCast(@alignCast(p));
    }
};

/// Mirror of C `mp_obj_fun_bc_t` (objfun.h). Header before the flexible
/// `extra_args[]`. Under nano + full both:
///   SETTRACE=0   → no `rc` field
///   sizeof = 32, offsetof(bytecode) = 24, offsetof(context) = 8
/// The `extra_args[]` flex array is not accessed via this mirror (use a
/// child-table pointer or a dedicated helper).
pub const MpObjFunBc = extern struct {
    base: MpObjBase,
    context: ?*const anyopaque, // ptr to mp_module_context_t (opaque)
    child_table: ?*const anyopaque, // ptr-to-ptr, opaque
    bytecode: [*]const u8,

    pub inline fn fromObj(o: Obj) *MpObjFunBc {
        return @ptrFromInt(o);
    }
    pub inline fn extraArgsPtr(self: *MpObjFunBc) [*]Obj {
        return @ptrFromInt(@intFromPtr(self) + @sizeOf(MpObjFunBc));
    }
    /// Typed view of the `context` field (mp_module_context_t).
    pub inline fn contextPtr(self: *const MpObjFunBc) *const MpModuleContext {
        return MpModuleContext.fromPtr(self.context);
    }
    /// `child_table[i]` — returns the i-th proto-fun pointer as a usize.
    /// child_table is `const mp_proto_fun_t *` (= `const void **`).
    pub inline fn childTablePtr(self: *const MpObjFunBc, i: usize) usize {
        const ct: [*]const usize = @ptrCast(@alignCast(self.child_table));
        return ct[i];
    }
};

/// Mirror of C `mp_exc_stack_t` (bc.h:190). 3-slot stack frame for
/// exception handlers. `val_sp` is a MP_TAGPTR-encoded value (low bit
/// carries the WITH-flag tag) — represented as `usize` to allow the
/// tag bit (Zig pointer types assume alignment).
pub const MpExcStack = extern struct {
    handler: ?[*]const u8,
    val_sp: usize, // MP_TAGPTR(mp_obj_t *, tag) — see MpTagPtr namespace.
    prev_exc: ?*anyopaque,
};

// ── MP_TAGPTR (bc.h:291-294) — low-bit pointer tagging ──────────
// Trivial bit ops under all configs (encoding is fixed, not REPR-dependent).
pub const MpTagPtr = struct {
    pub inline fn ptr(x: usize) ?*anyopaque {
        return @ptrFromInt(x & ~@as(usize, 3));
    }
    pub inline fn tag0(x: usize) bool {
        return (x & 1) != 0;
    }
    pub inline fn tag1(x: usize) bool {
        return (x & 2) != 0;
    }
    pub inline fn make(p: anytype, tag: u2) usize {
        const ip: usize = if (@typeInfo(@TypeOf(p)) == .pointer) @intFromPtr(p) else @as(usize, @bitCast(p));
        return ip | tag;
    }
};

/// Mirror of C `mp_code_state_t` (bc.h:234). Under both nano + full:
///   STACKLESS=0 → no `prev` field
///   SETTRACE=0  → no `prev_state` / `frame` fields
///   sizeof = 40, offsetof(state) = 40 (state[] is the flex array)
/// 6 fields total. n_state/exc_sp_idx pack into one usize slot via the
/// natural u16+u16+padding C layout.
pub const MpCodeState = extern struct {
    fun_bc: ?*MpObjFunBc,
    ip: [*]const u8,
    sp: [*]Obj,
    n_state: u16,
    exc_sp_idx: u16,
    // No explicit padding: `extern struct` already inserts the alignment
    // padding C inserts (4 bytes before `old_globals` on 64-bit, none on
    // 32-bit). An earlier mirror carried `_pad: u32 = 0` which was correct
    // on amd64 but wrong on wasm32 — same class of bug as the
    // MpObjFunBuiltinVar fix (commit 0be7db3). Layout asserts below.
    old_globals: ?*anyopaque, // mp_obj_dict_t * (opaque)

    pub inline fn fromPtr(p: ?*anyopaque) *MpCodeState {
        return @ptrCast(@alignCast(p));
    }
    pub inline fn statePtr(self: *MpCodeState) [*]Obj {
        return @ptrFromInt(@intFromPtr(self) + @sizeOf(MpCodeState));
    }
    /// `npy__estk` (vm_shim.c:245). The exc_stack array starts
    /// immediately past `state[n_state]`.
    pub inline fn excStackPtr(self: *MpCodeState) [*]MpExcStack {
        return @ptrFromInt(@intFromPtr(self.statePtr() + self.n_state));
    }
    /// `npy__esp` (vm_shim.c:246). exc_sp = exc_stack + exc_sp_idx - 1.
    /// Only valid when `exc_sp_idx >= 1`.
    pub inline fn excSpPtr(self: *MpCodeState) *MpExcStack {
        return &self.excStackPtr()[self.exc_sp_idx - 1];
    }
    /// `npy_vm_push_exc_block` (vm_shim.c:246-252). Increments exc_sp_idx,
    /// writes a new frame with the value-sp tagged by `wf << 1`.
    pub inline fn pushExcBlock(self: *MpCodeState, handler: [*]const u8, vsp: usize, wf: u1) void {
        self.exc_sp_idx += 1;
        const e = self.excSpPtr();
        e.handler = handler;
        e.val_sp = MpTagPtr.make(vsp, @as(u2, wf) << 1);
        e.prev_exc = null;
    }
    /// `npy_vm_exc_sp_scan_prev_exc` (vm_shim.c:258-264). RAISE_LAST
    /// verbatim: walks back from exc_sp toward exc_stack, returns first
    /// non-null `prev_exc` as an Obj, or 0 (MP_OBJ_NULL) if none.
    pub inline fn excSpScanPrevExc(self: *MpCodeState) Obj {
        if (self.exc_sp_idx == 0) return OBJ_NULL;
        const stack = self.excStackPtr();
        var i: usize = self.exc_sp_idx;
        while (i > 0) : (i -= 1) {
            if (stack[i - 1].prev_exc) |p| return @intFromPtr(p);
        }
        return OBJ_NULL;
    }
};

/// Mirror of C `mp_obj_bound_meth_t` (objboundmeth.c). Plain { meth, self }.
pub const MpObjBoundMeth = extern struct {
    base: MpObjBase,
    meth: Obj,
    self_obj: Obj,

    pub inline fn fromObj(o: Obj) *MpObjBoundMeth {
        return @ptrFromInt(o);
    }
};

/// Mirror of C `mp_state_thread_t` PREFIX (mpstate.h:274). Layout
/// verified identical between nano and full via probe (sizeof=64,
/// offsetof(mp_pending_exception)=48 under 64-bit; sizeof=32 under
/// 32-bit). Active fields:
///   STACK_CHECK=0  → no stack_limit
///   PYSTACK=0      → no pystack_* trio
///   SETTRACE=0     → no prof_* trio
///   SSL_MBEDTLS=0  → no tls_ssl_context
///
/// Pad between `gc_lock_depth` (u16) and the next pointer-aligned field
/// is target-dependent: 6 bytes on 64-bit (ptr=8, stack_top(8)+u16(2)=10
/// → +6 to reach offset 16), 2 bytes on 32-bit/wasm32 (ptr=4,
/// stack_top(4)+u16(2)=6 → +2 to reach offset 8). The bug fixed here:
/// a hardcoded `[6]u8` pad silently mis-located `dict_locals` (et al.)
/// by 4 bytes on wasm32, so `mp_locals_set` (which writes via
/// `runtime/mpstate.zig::StateThread`, target-aware) and
/// `MpStateThread.localsObj()` (which reads via this mirror) targeted
/// different bytes — class bodies appeared empty.
const _MP_STATE_THREAD_PAD: usize = @sizeOf(?*anyopaque) - 2;
pub const MpStateThread = extern struct {
    stack_top: ?[*]u8,
    gc_lock_depth: u16,
    _pad: [_MP_STATE_THREAD_PAD]u8 = .{0} ** _MP_STATE_THREAD_PAD,
    dict_locals: ?*anyopaque,
    dict_globals: ?*anyopaque,
    nlr_top: ?*anyopaque,
    nlr_jump_callback_top: ?*anyopaque,
    mp_pending_exception: Obj, // volatile in C; Zig accepts plain Obj for reads
    stop_iteration_arg: Obj,

    /// Typed view of `mp_state_ctx.thread.dict_globals` (mp_obj_dict_t *).
    pub inline fn globalsDict() *MpObjDict {
        return @ptrCast(@alignCast(mp_state_ctx.thread.dict_globals.?));
    }
    /// Typed view of `mp_state_ctx.thread.dict_locals` (mp_obj_dict_t *).
    pub inline fn localsDict() *MpObjDict {
        return @ptrCast(@alignCast(mp_state_ctx.thread.dict_locals.?));
    }
    /// `mp_globals_get()` static-inline equivalent — returns Obj (= ptr).
    pub inline fn globalsObj() Obj {
        return @intFromPtr(mp_state_ctx.thread.dict_globals.?);
    }
    pub inline fn localsObj() Obj {
        return @intFromPtr(mp_state_ctx.thread.dict_locals.?);
    }
    pub inline fn localsNeGlobals() bool {
        return mp_state_ctx.thread.dict_locals != mp_state_ctx.thread.dict_globals;
    }
    pub inline fn globalsLookup(q: u16) Obj {
        return globalsDict().map.lookupQstr(q);
    }
    pub inline fn localsLookup(q: u16) Obj {
        return localsDict().map.lookupQstr(q);
    }
};

/// Partial mirror of C `mp_state_vm_t` — exposes the fields touched
/// by `mp_init`. Layout via probed offsets, verified identical between
/// nano + full builds (vm starts at +64 from mp_state_ctx, vm size 200B
/// under nano / 328B under full — partial covers first 200B).
///
/// Internal vm-relative offsets:
///   mp_loaded_modules_dict @ 40 (size 32: MpObjDict)
///   dict_main              @ 72 (size 32)
///   override_dict          @ 104 (size 8 — opaque ptr)
///   mp_sys_argv_obj        @ 112 (size 32: MpObjList)
///   sys_mutable[6]         @ 144 (size 48: 6× Obj)
///   mp_optimise_value      @ 192 (size 8)
pub const MpStateVmPartial = extern struct {
    _pad0: [40]u8 = .{0} ** 40,
    mp_loaded_modules_dict: MpObjDict,
    dict_main: MpObjDict,
    mp_module_builtins_override_dict: ?*MpObjDict,
    mp_sys_argv_obj: MpObjList,
    sys_mutable: [6]Obj,
    mp_optimise_value: usize,
};

/// Mirror of C `mp_state_ctx_t` — exposes the `thread` + `vm` prefix
/// slices (covering all fields currently accessed from Zig). The
/// trailing `vm` tail (full only) + `mem` block are opaque to Zig.
/// The `mp_state_ctx` symbol IS this struct, just larger.
pub const MpStateCtx = extern struct {
    thread: MpStateThread,
    vm: MpStateVmPartial,
};

/// The real C-side `mp_state_ctx` global. Declared with the truncated
/// `MpStateCtx` mirror type — Zig only sees the thread prefix, which is
/// all we currently access. The C-side struct is larger (nano=840B,
/// full=976B) but the prefix layout matches under both.
pub extern var mp_state_ctx: MpStateCtx;

/// Mirror of C `mp_obj_static_class_method_t` (obj.h:1267). 2 fields.
/// `fun` is `mp_rom_obj_t` = `uintptr_t` storing a fun-obj pointer; typed
/// here as `?*const anyopaque` so ROM consts can be initialised with
/// `&fun_obj` at link time (Zig forbids `@intFromPtr(&export)` at comptime).
pub const MpObjStaticClassMethod = extern struct {
    base: MpObjBase,
    fun: ?*const anyopaque,

    pub inline fn fromObj(o: Obj) *MpObjStaticClassMethod {
        return @ptrFromInt(o);
    }
};

/// Mirror of C `mp_obj_super_t` (objtype.c) — `{base, type, obj}`.
pub const MpObjSuper = extern struct {
    base: MpObjBase,
    type: Obj,
    obj: Obj,

    pub inline fn fromObj(o: Obj) *MpObjSuper {
        return @ptrFromInt(o);
    }
};

/// Mirror of C `mp_obj_iter_buf_t` (obj.h). 4-Obj-slot buffer used by
/// iterator protocols; we only need its `@sizeOf` at allocation sites.
pub const MpObjIterBuf = extern struct {
    base: MpObjBase,
    buf: [3]Obj,
};

/// Mirror of C `mp_obj_cell_t` (obj.h:1082). `mp_obj_cell_get` and
/// `mp_obj_cell_set` are `static inline` in vendor — ported here.
pub const MpObjCell = extern struct {
    base: MpObjBase,
    obj: Obj,

    pub inline fn fromObj(o: Obj) *MpObjCell {
        return @ptrFromInt(o);
    }
    /// `mp_obj_cell_get` (obj.h:1087-1090).
    pub inline fn cellGet(o: Obj) Obj {
        return fromObj(o).obj;
    }
    /// `mp_obj_cell_set` (obj.h:1092-1095).
    pub inline fn cellSet(o: Obj, v: Obj) void {
        fromObj(o).obj = v;
    }
};

/// Mirror of C `mp_arg_val_t` union (runtime.h:61-66). All variants are
/// ptr-sized or smaller — size = sizeof(usize) = 8, align = 8.
pub const MpArgVal = extern union {
    u_bool: bool,
    u_int: isize,
    u_obj: Obj,
    u_rom_obj: Obj,
};

/// Mirror of C `mp_arg_t` (runtime.h:68-72). Layout config-invariant:
/// `{u16 qst; u16 flags; 4B padding; mp_arg_val_t defval}` = 16B total
/// on 64-bit (defval's 8-byte alignment forces padding after flags).
pub const MpArg = extern struct {
    qst: u16,
    flags: u16,
    // No explicit padding: `extern struct` aligns `defval` to its natural
    // alignment (4 bytes on wasm32, 8 bytes on amd64). The earlier
    // `_pad: [4]u8` was correct on amd64 but inserted 4 phantom bytes on
    // wasm32, where vendor's `mp_arg_t` has no padding before defval —
    // same class of bug as MpObjFunBuiltinVar (commit 0be7db3) and
    // MpCodeState above. Layout asserts below.
    defval: MpArgVal,

    pub inline fn at(allowed: ?*const anyopaque, i: usize) *const MpArg {
        const base: [*]const MpArg = @ptrCast(@alignCast(allowed));
        return &base[i];
    }
};

/// Mirror of C `mp_obj_fun_builtin_fixed_t` (obj.h:1232). A union of
/// mp_fun_{0,1,2,3}_t over a single ptr-sized slot — represented as
/// `?*const anyopaque` (all union variants share offset/size).
/// Used to construct ROM const fun-objects (e.g., mp_op_getitem_obj)
/// directly from Zig, replacing MP_DEFINE_CONST_FUN_OBJ_N macros.
pub const MpObjFunBuiltinFixed = extern struct {
    base: MpObjBase,
    fun: ?*const anyopaque,
};

/// Mirror of C `mp_obj_fun_builtin_var_t` (obj.h:1242). Variadic/kw
/// fun-obj. The `sig` field encodes min/max args + takes_kw flag via
/// MP_OBJ_FUN_MAKE_SIG. extern struct's natural C-layout discipline
/// handles the post-sig padding correctly on both 64-bit (4 bytes
/// before the pointer for 8-byte alignment) and 32-bit (no padding —
/// sig + ptr are both 4-byte aligned). An earlier mirror had an
/// explicit `_pad: u32 = 0` here which was correct on amd64 but
/// inserted phantom padding on wasm32, shifting `fun` from offset
/// 8 to offset 12 and causing every fun_builtin_var dispatch to
/// pull a garbage function pointer through the wasm function table —
/// manifesting as `wasm trap: undefined element` deep in any
/// builtin_var caller (e.g. re.compile). No layout-assert was
/// catching this because the mirror lacked one. ADR 010 §A3a slice 2
/// follow-up.
pub const MpObjFunBuiltinVar = extern struct {
    base: MpObjBase,
    sig: u32,
    fun: ?*const anyopaque,
};

comptime {
    // Layout asserts so a future vendor pull, or another `_pad: u32`
    // patch, can't silently re-introduce the wasm32 shift bug.
    if (@offsetOf(MpObjFunBuiltinVar, "base") != 0) @compileError("MpObjFunBuiltinVar.base offset drift");
    if (@offsetOf(MpObjFunBuiltinVar, "sig") != @sizeOf(usize)) @compileError("MpObjFunBuiltinVar.sig offset drift — check ABI vs vendor");
    if (@offsetOf(MpObjFunBuiltinVar, "fun") != @sizeOf(usize) * 2) @compileError("MpObjFunBuiltinVar.fun offset drift — usually means phantom padding (32-bit) or missing padding (64-bit)");
    if (@sizeOf(MpObjFunBuiltinVar) != @sizeOf(usize) * 3) @compileError("MpObjFunBuiltinVar total size drift");

    // MpCodeState — vendor `_mp_code_state_t` in py/bc.h:234. The
    // 64-bit C layout adds 4 bytes of natural padding between
    // `exc_sp_idx` (u16 @ 26) and `old_globals` (ptr @ 32); the
    // 32-bit layout has none (`old_globals` @ 16, naturally aligned).
    // `extern struct` reproduces both via target ABI. Asserts pin
    // both arms — any drift means the mirror is out of sync with C.
    if (@offsetOf(MpCodeState, "fun_bc") != 0) @compileError("MpCodeState.fun_bc offset drift");
    if (@offsetOf(MpCodeState, "ip") != @sizeOf(usize)) @compileError("MpCodeState.ip offset drift");
    if (@offsetOf(MpCodeState, "sp") != @sizeOf(usize) * 2) @compileError("MpCodeState.sp offset drift");
    if (@offsetOf(MpCodeState, "n_state") != @sizeOf(usize) * 3) @compileError("MpCodeState.n_state offset drift");
    if (@offsetOf(MpCodeState, "exc_sp_idx") != @sizeOf(usize) * 3 + 2) @compileError("MpCodeState.exc_sp_idx offset drift");
    if (@offsetOf(MpCodeState, "old_globals") != @sizeOf(usize) * 4) @compileError("MpCodeState.old_globals offset drift — usually means phantom padding (32-bit) or missing padding (64-bit)");
    if (@sizeOf(MpCodeState) != @sizeOf(usize) * 5) @compileError("MpCodeState total size drift");

    // MpArg — vendor `_mp_arg_t` in py/runtime.h. The defval union is
    // ptr-sized so 64-bit C adds 4 bytes between flags (u16 @ 2) and
    // defval (@ 8); 32-bit C has none (defval @ 4, naturally aligned).
    if (@offsetOf(MpArg, "qst") != 0) @compileError("MpArg.qst offset drift");
    if (@offsetOf(MpArg, "flags") != 2) @compileError("MpArg.flags offset drift");
    if (@offsetOf(MpArg, "defval") != @sizeOf(usize)) @compileError("MpArg.defval offset drift — usually means phantom padding (32-bit) or missing padding (64-bit)");
    if (@sizeOf(MpArg) != @sizeOf(usize) * 2) @compileError("MpArg total size drift");
}

/// `MP_OBJ_FUN_MAKE_SIG(min, max, kw)` — same bit layout as obj.h macro.
pub inline fn makeFunSig(min: u32, max: u32, kw: bool) u32 {
    return (min << 17) | (max << 1) | @as(u32, if (kw) 1 else 0);
}

/// Mirror of C `mp_obj_closure_t` (objclosure.c). Flexible-array `closed[]`
/// at the end; access via `closedPtr()` past the struct end.
pub const MpObjClosure = extern struct {
    base: MpObjBase,
    fun: Obj,
    n_closed: usize,

    pub inline fn fromObj(o: Obj) *MpObjClosure {
        return @ptrFromInt(o);
    }
    pub inline fn closedPtr(self: *MpObjClosure) [*]Obj {
        return @ptrFromInt(@intFromPtr(self) + @sizeOf(MpObjClosure));
    }
};

// ── REPR_A obj-tag encoding (vendor py/obj.h:84-102) ─────────────
// Bit pattern (REPR_A, IMMEDIATE_OBJS=1, DEBUG_SENTINELS=0; verified
// invariant across nano + full builds):
//   (o & 1) == 1       → small int   (value = (int)o >> 1)
//   (o & 7) == 2       → qstr        (id = o >> 3)
//   (o & 7) == 6       → immediate   (none=6, false=14, true=30)
//   (o & 3) == 0       → object ptr
// Sentinel values (DEBUG_SENTINELS=0 → STOP_ITERATION aliases NULL,
// vendor pattern at obj.h:75-77):
pub const OBJ_NULL: Obj = 0;
pub const OBJ_STOP_ITERATION: Obj = 0;
pub const OBJ_SENTINEL: Obj = 4;
pub const OBJ_NONE: Obj = 6; // MP_OBJ_NEW_IMMEDIATE_OBJ(0)
pub const OBJ_FALSE: Obj = 14; // MP_OBJ_NEW_IMMEDIATE_OBJ(1)
pub const OBJ_TRUE: Obj = 30; // MP_OBJ_NEW_IMMEDIATE_OBJ(3)

/// `MP_OBJ_NEW_SMALL_INT(n)` = `(n << 1) | 1` (REPR_A).
pub inline fn newSmallInt(n: isize) Obj {
    return (@as(Obj, @bitCast(n)) << 1) | 1;
}
/// `MP_OBJ_SMALL_INT_VALUE(o)` = `(mp_int_t)o >> 1` (signed arithmetic shift).
pub inline fn smallIntValue(o: Obj) isize {
    return @as(isize, @bitCast(o)) >> 1;
}
pub inline fn isSmallInt(o: Obj) bool {
    return (o & 1) != 0;
}
pub inline fn isQstr(o: Obj) bool {
    return (o & 7) == 2;
}
pub inline fn qstrValue(o: Obj) u32 {
    return @intCast(o >> 3);
}
/// Build an `mp_obj_t`-encoded qstr from a qstr id: `(q << 3) | 2`.
pub inline fn objFromQstr(q: anytype) Obj {
    return (@as(Obj, @intCast(q)) << 3) | 2;
}
/// `MP_OBJ_FROM_PTR(p)` — under REPR_A this is just a bit-cast.
pub inline fn objFromPtr(p: ?*const anyopaque) Obj {
    return @intFromPtr(p);
}
/// `MP_OBJ_TO_PTR(o)` — under REPR_A this is just a bit-cast.
pub inline fn objToPtr(o: Obj) ?*anyopaque {
    return @ptrFromInt(o);
}

/// `mp_obj_is_obj(o)` (obj.h macro): low-2-bit tag is 0 AND o != 0.
pub inline fn isObj(o: Obj) bool {
    return o != 0 and (o & 3) == 0;
}

/// `mp_obj_is_type(o, t)` — checks o is a real heap obj (not tagged) AND
/// its base.type matches t. Equivalent to vendor's mp_obj_is_exact_type.
pub inline fn isExactType(o: Obj, t: *const anyopaque) bool {
    if (!isObj(o)) return false;
    return objBaseType(o) == t;
}

/// `mp_obj_new_bool(b)` (static-inline in vendor): map to the
/// immediate-obj OBJ_TRUE / OBJ_FALSE constants directly.
pub inline fn newBool(b: bool) Obj {
    return if (b) OBJ_TRUE else OBJ_FALSE;
}

// Small-int range under REPR_A: 1 bit lost to the tag.
//   MP_SMALL_INT_BITS = MP_IMAX_BITS(MP_SMALL_INT_MAX) + 1 = 63 on 64-bit
//   MP_SMALL_INT_MAX  = 2^62 - 1
//   MP_SMALL_INT_MIN  = -2^62
pub const SMALL_INT_BITS: u8 = @bitSizeOf(isize) - 1;
pub const SMALL_INT_MAX: isize = (@as(isize, 1) << (SMALL_INT_BITS - 1)) - 1;
pub const SMALL_INT_MIN: isize = -(@as(isize, 1) << (SMALL_INT_BITS - 1));

/// `MP_SMALL_INT_FITS(n)` — `((n ^ (n<<1)) & WORD_MSBIT) == 0` (REPR_A).
pub inline fn smallIntFits(n: isize) bool {
    const u: usize = @bitCast(n);
    const word_msbit = @as(usize, 1) << (@bitSizeOf(usize) - 1);
    return ((u ^ (u << 1)) & word_msbit) == 0;
}

/// Read the `mp_obj_base_t.type` field of any heap object (every concrete
/// mp_obj type starts with `mp_obj_base_t`). Returns `?*const anyopaque`
/// to match the existing `TypePtr` convention.
///
/// Note: under REPR_A, `mp_obj_is_obj(o)` checks only the low-2-bit tag
/// (`o & 3 == 0`), which guarantees 4-byte alignment but not the 8-byte
/// alignment Zig requires for a `*MpObjBase`. We bypass Zig's alignment
/// check with `*align(1)`.
pub inline fn objBaseType(o: Obj) ?*const anyopaque {
    const base: *align(1) const MpObjBase = @ptrFromInt(o);
    return base.type;
}

/// Mirror of C `mp_obj_dict_t`.
pub const MpObjDict = extern struct {
    base: MpObjBase,
    map: MpMap,

    pub inline fn fromObj(o: Obj) *MpObjDict {
        return @ptrFromInt(o);
    }
};

/// Mirror of C `mp_obj_list_t` (objlist.h). No bitfields.
pub const MpObjList = extern struct {
    base: MpObjBase,
    alloc: usize,
    len: usize,
    items: [*]Obj,

    pub inline fn fromObj(o: Obj) *MpObjList {
        return @ptrFromInt(o);
    }
    pub inline fn lenOf(o: Obj) usize {
        return fromObj(o).len;
    }
    pub inline fn itemsOf(o: Obj) [*]Obj {
        return fromObj(o).items;
    }
};

/// Mirror of C `mp_obj_module_t` (obj.h). No bitfields.
pub const MpObjModule = extern struct {
    base: MpObjBase,
    globals: *MpObjDict,

    pub inline fn fromObj(o: Obj) *MpObjModule {
        return @ptrFromInt(o);
    }
};

/// Mirror of C `mp_obj_str_t` (objstr.h). No bitfields.
pub const MpObjStr = extern struct {
    base: MpObjBase,
    hash: usize,
    len: usize,
    data: [*]const u8,

    pub inline fn fromObj(o: Obj) *MpObjStr {
        return @ptrFromInt(o);
    }
};

/// Mirror of C `mp_obj_tuple_t` (objtuple.h). The C struct has a
/// flexible-array `items[]` member at the end; we expose access to it
/// via `itemsPtr` (pointer past the struct). Don't add an `items` field
/// here — `extern struct` doesn't mirror flexible arrays.
pub const MpObjTuple = extern struct {
    base: MpObjBase,
    len: usize,

    pub inline fn fromObj(o: Obj) *MpObjTuple {
        return @ptrFromInt(o);
    }
    pub inline fn itemsPtr(self: *MpObjTuple) [*]Obj {
        return @ptrFromInt(@intFromPtr(self) + @sizeOf(MpObjTuple));
    }
};

/// Mirror of C `mp_obj_exception_t` (objexcept.h). The bitfields
/// `traceback_alloc : usize/2` + `traceback_len : usize/2` pack into one
/// usize-sized slot — same trick as `MpMap`.
pub const MpObjException = extern struct {
    base: MpObjBase,
    tb_bits: packed struct(usize) {
        traceback_alloc: std.meta.Int(.unsigned, @bitSizeOf(usize) / 2),
        traceback_len: std.meta.Int(.unsigned, @bitSizeOf(usize) / 2),
    },
    traceback_data: ?[*]usize,
    args: ?*MpObjTuple,

    pub inline fn fromObj(o: Obj) *MpObjException {
        return @ptrFromInt(o);
    }
};

/// Mirror of C `mp_obj_instance_t` (objtype.h). Flexible-array `subobj[]`
/// at end; access via `subobjPtr()` past the struct end.
pub const MpObjInstance = extern struct {
    base: MpObjBase,
    members: MpMap,

    pub inline fn fromObj(o: Obj) *MpObjInstance {
        return @ptrFromInt(o);
    }
    pub inline fn subobjPtr(self: *MpObjInstance) [*]Obj {
        return @ptrFromInt(@intFromPtr(self) + @sizeOf(MpObjInstance));
    }
};

// ── MP_TYPE_FLAG_* (vendor py/obj.h:565-578) ──────────────────────
// FLAG_ITER_IS_STREAM == ITERNEXT | CUSTOM (composite — see obj.h:576).
pub const FLAG_NONE: u16 = 0x0000;
pub const FLAG_IS_SUBCLASSED: u16 = 0x0001;
pub const FLAG_HAS_SPECIAL_ACCESSORS: u16 = 0x0002;
pub const FLAG_EQ_NOT_REFLEXIVE: u16 = 0x0004;
pub const FLAG_EQ_CHECKS_OTHER_TYPE: u16 = 0x0008;
pub const FLAG_EQ_HAS_NEQ_TEST: u16 = 0x0010;
pub const FLAG_BINDS_SELF: u16 = 0x0020;
pub const FLAG_BUILTIN_FUN: u16 = 0x0040;
pub const FLAG_ITER_IS_GETITER: u16 = 0x0000;
pub const FLAG_ITER_IS_ITERNEXT: u16 = 0x0080;
pub const FLAG_ITER_IS_CUSTOM: u16 = 0x0100;
pub const FLAG_ITER_IS_STREAM: u16 = 0x0180;
pub const FLAG_INSTANCE_TYPE: u16 = 0x0200;
pub const FLAG_SUBSCR_ALLOWS_STACK_SLICE: u16 = 0x0400;

/// Mirror of C `mp_obj_type_t` PREFIX (vendor obj.h:638). The C struct
/// ends in `const void *slots[]` (flex array) — we mirror only the fixed
/// 24-byte prefix, matching `mp_obj_empty_type_t` exactly (obj.h:723).
/// Concrete ROM instances use `mp_obj_full_type_t` (11 fixed slots);
/// access them via `MpObjTypeFull` in `mp_type_roms.zig`, which composes
/// this struct as its header.
///
/// READ-VIEW ONLY: never construct an `MpObjType` from Zig at call sites.
/// Type-table definitions remain in C shims (or `mp_type_roms.zig`) via
/// vendor `MP_DEFINE_CONST_OBJ_TYPE_NARGS_N` macro semantics.
///
/// Slot convention (obj.h:798-805): `slot_index_X == 0` means "unset";
/// otherwise the slot pointer lives at `slotsPtr()[slot_index_X - 1]`.
/// 1-based indexing lets zero-init ROM mean "no slots".
///
/// 4 of 12 slots are NOT plain fn pointers:
///   - `iter`        tri-modal per `FLAG_ITER_IS_*` (getiter / iternext / custom struct)
///   - `protocol`    opaque struct ptr (e.g., `mp_stream_p_t *`)
///   - `parent`      `*const MpObjType` (1 parent) or `*const MpObjTuple` (≥2)
///   - `locals_dict` `*MpObjDict` (not callable)
/// `getSlot()` returns `?*const anyopaque`; caller picks the cast target.
pub const MpObjType = extern struct {
    base: MpObjBase,
    flags: u16,
    name: u16,

    slot_index_make_new: u8,
    slot_index_print: u8,
    slot_index_call: u8,
    slot_index_unary_op: u8,
    slot_index_binary_op: u8,
    slot_index_attr: u8,
    slot_index_subscr: u8,
    slot_index_iter: u8,
    slot_index_buffer: u8,
    slot_index_protocol: u8,
    slot_index_parent: u8,
    slot_index_locals_dict: u8,
    // C: `const void *slots[]` flex array — access via `slotsPtr()`.

    pub const Slot = enum {
        make_new,
        print,
        call,
        unary_op,
        binary_op,
        attr,
        subscr,
        iter,
        buffer,
        protocol,
        parent,
        locals_dict,
    };

    pub inline fn fromPtr(p: ?*const anyopaque) *const MpObjType {
        return @ptrCast(@alignCast(p));
    }

    pub inline fn slotsPtr(self: *const MpObjType) [*]const ?*const anyopaque {
        return @ptrFromInt(@intFromPtr(self) + @sizeOf(MpObjType));
    }

    inline fn slotIndex(self: *const MpObjType, comptime s: Slot) u8 {
        return switch (s) {
            .make_new => self.slot_index_make_new,
            .print => self.slot_index_print,
            .call => self.slot_index_call,
            .unary_op => self.slot_index_unary_op,
            .binary_op => self.slot_index_binary_op,
            .attr => self.slot_index_attr,
            .subscr => self.slot_index_subscr,
            .iter => self.slot_index_iter,
            .buffer => self.slot_index_buffer,
            .protocol => self.slot_index_protocol,
            .parent => self.slot_index_parent,
            .locals_dict => self.slot_index_locals_dict,
        };
    }

    /// `MP_OBJ_TYPE_HAS_SLOT(t, f)` (obj.h:804).
    pub inline fn hasSlot(self: *const MpObjType, comptime s: Slot) bool {
        return self.slotIndex(s) != 0;
    }

    /// `MP_OBJ_TYPE_GET_SLOT(t, f)` (obj.h:805) — returns null when unset.
    pub inline fn getSlot(self: *const MpObjType, comptime s: Slot) ?*const anyopaque {
        const idx = self.slotIndex(s);
        if (idx == 0) return null;
        return self.slotsPtr()[idx - 1];
    }

    // ── flag predicates ───────────────────────────────────────
    pub inline fn flagBindsSelf(self: *const MpObjType) bool {
        return (self.flags & FLAG_BINDS_SELF) != 0;
    }
    pub inline fn flagBuiltinFun(self: *const MpObjType) bool {
        return (self.flags & FLAG_BUILTIN_FUN) != 0;
    }
    pub inline fn flagInstanceType(self: *const MpObjType) bool {
        return (self.flags & FLAG_INSTANCE_TYPE) != 0;
    }
    pub inline fn flagSubscrAllowsStackSlice(self: *const MpObjType) bool {
        return (self.flags & FLAG_SUBSCR_ALLOWS_STACK_SLICE) != 0;
    }
    pub inline fn flagEqChecksOtherType(self: *const MpObjType) bool {
        return (self.flags & FLAG_EQ_CHECKS_OTHER_TYPE) != 0;
    }

    // ── compound iter predicates (vendor runtime.c:69 + runtime_shim.c:121-150) ──
    /// `TYPE_HAS_ITERNEXT(t)` — any of ITERNEXT|CUSTOM|STREAM set.
    pub inline fn hasIterNext(self: *const MpObjType) bool {
        return (self.flags & (FLAG_ITER_IS_ITERNEXT | FLAG_ITER_IS_CUSTOM | FLAG_ITER_IS_STREAM)) != 0;
    }
    /// `npy_rt_type_iter_is_identity` (runtime_shim.c:127-129).
    pub inline fn iterIsIdentity(self: *const MpObjType) bool {
        return (self.flags & FLAG_ITER_IS_ITERNEXT) == FLAG_ITER_IS_ITERNEXT or (self.flags & FLAG_ITER_IS_STREAM) == FLAG_ITER_IS_STREAM;
    }
    pub inline fn iterIsCustom(self: *const MpObjType) bool {
        return (self.flags & FLAG_ITER_IS_CUSTOM) != 0;
    }
    /// Exact-equality match against FLAG_ITER_IS_STREAM (ITERNEXT|CUSTOM).
    pub inline fn iterIsStream(self: *const MpObjType) bool {
        return (self.flags & FLAG_ITER_IS_STREAM) == FLAG_ITER_IS_STREAM;
    }
    pub inline fn iterIsIterNext(self: *const MpObjType) bool {
        return (self.flags & FLAG_ITER_IS_ITERNEXT) != 0;
    }

    // ── iter / locals_dict polymorphic dispatch (vendor runtime_shim.c) ──

    /// `npy_rt_type_iter_slot_is_instance_getiter` — identity-compare the
    /// iter slot fn-ptr against `mp_obj_instance_getiter` (objtype.h:53).
    pub inline fn iterSlotIsInstanceGetiter(self: *const MpObjType) bool {
        const raw = self.getSlot(.iter) orelse return false;
        return @intFromPtr(raw) == @intFromPtr(&mp_obj_instance_getiter);
    }

    /// `npy_rt_type_call_getiter` (runtime_shim.c:132-137). Branches on
    /// FLAG_ITER_IS_CUSTOM: CUSTOM dereferences the custom struct's
    /// `getiter` field; non-CUSTOM casts the slot directly.
    pub inline fn callGetiter(self: *const MpObjType, o: Obj, iter_buf: ?*anyopaque) Obj {
        const raw = self.getSlot(.iter) orelse return 0;
        const fn_ptr: MpGetiterFun = if (self.iterIsCustom()) blk: {
            const cu: *const MpGetiterIternextCustom = @ptrCast(@alignCast(raw));
            break :blk cu.getiter;
        } else @ptrCast(@alignCast(raw));
        return fn_ptr(o, iter_buf);
    }

    /// `npy_rt_type_call_iternext` (runtime_shim.c:142-151). Tri-modal:
    /// STREAM → mp_stream_unbuffered_iter; ITERNEXT → slot as MpIternextFun;
    /// CUSTOM → custom struct's `iternext` field.
    pub inline fn callIternext(self: *const MpObjType, o: Obj) Obj {
        if (self.iterIsStream()) return mp_stream_unbuffered_iter(o);
        const raw = self.getSlot(.iter) orelse return 0;
        const fn_ptr: MpIternextFun = if (self.iterIsCustom()) blk: {
            const cu: *const MpGetiterIternextCustom = @ptrCast(@alignCast(raw));
            break :blk cu.iternext;
        } else @ptrCast(@alignCast(raw));
        return fn_ptr(o);
    }

    /// `npy_rt_locals_dict_lookup` (runtime_shim.c:114-117). Looks up `q`
    /// in the type's `locals_dict.map`; returns the value or 0 if absent.
    /// Caller must verify `hasSlot(.locals_dict)` first.
    pub inline fn localsDictLookup(self: *const MpObjType, q: u16) Obj {
        const ld_ptr = self.getSlot(.locals_dict) orelse return 0;
        const dict: *MpObjDict = @ptrCast(@alignCast(@constCast(ld_ptr)));
        const e = mp_map_lookup(&dict.map, objFromQstr(q), MP_MAP_LOOKUP);
        return if (e) |elem| elem.value else 0;
    }
    /// `MP_OBJ_TYPE_GET_SLOT(t, subscr)(self, index, value)`. Caller is
    /// responsible for verifying the slot is set (panics on null slot).
    pub inline fn callSubscr(self: *const MpObjType, self_in: Obj, index: Obj, value: Obj) Obj {
        const raw = self.getSlot(.subscr).?;
        const fn_ptr: MpSubscrFun = @ptrCast(@alignCast(raw));
        return fn_ptr(self_in, index, value);
    }
    /// `MP_OBJ_TYPE_GET_SLOT(t, binary_op)(op, lhs, rhs)`. Caller is
    /// responsible for verifying the slot is set (panics on null slot).
    pub inline fn callBinaryOp(self: *const MpObjType, op: c_int, lhs: Obj, rhs: Obj) Obj {
        const raw = self.getSlot(.binary_op).?;
        const fn_ptr: MpBinaryOpFun = @ptrCast(@alignCast(raw));
        return fn_ptr(op, lhs, rhs);
    }
};

// ── typed fn-pointer aliases for the 8 single-signature slots
// (vendor py/obj.h:599-606, 627). Slot pointers loaded via `getSlot()`
// can be `@ptrCast(@alignCast(_))` to these types at call sites.
// `[*c]` matches C ABI (`T*` — null-coercible). Vendor C accepts NULL
// for empty `args` arrays and `dest`; using `[*]` here breaks calls
// from contexts that pass null (e.g. mp_call_function_0).
pub const MpMakeNewFun = *const fn (type_in: *const MpObjType, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj;
pub const MpPrintFun = *const fn (print: *const anyopaque, o: Obj, kind: c_int) callconv(.c) void;
pub const MpCallFun = *const fn (fun: Obj, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj;
pub const MpUnaryOpFun = *const fn (op: c_int, self_in: Obj) callconv(.c) Obj;
pub const MpBinaryOpFun = *const fn (op: c_int, lhs: Obj, rhs: Obj) callconv(.c) Obj;
pub const MpAttrFun = *const fn (self_in: Obj, attr: u16, dest: [*c]Obj) callconv(.c) void;
pub const MpSubscrFun = *const fn (self_in: Obj, index: Obj, value: Obj) callconv(.c) Obj;
pub const MpBufferFun = *const fn (obj: Obj, bufinfo: *anyopaque, flags: usize) callconv(.c) isize;

/// `iter` slot is polymorphic per `FLAG_ITER_IS_*` (obj.h:689-699):
///   GETITER  → MpGetiterFun (load+@ptrCast)
///   ITERNEXT → MpIternextFun (load+@ptrCast)
///   CUSTOM   → *const MpGetiterIternextCustom (struct ptr, not callable)
///   STREAM   → slot unset; iter dispatch routes to mp_stream_unbuffered_iter
pub const MpGetiterFun = *const fn (self_in: Obj, iter_buf: ?*anyopaque) callconv(.c) Obj;
pub const MpIternextFun = *const fn (self_in: Obj) callconv(.c) Obj;
pub const MpGetiterIternextCustom = extern struct {
    getiter: MpGetiterFun,
    iternext: MpIternextFun,
};

// Externs used by MpObjType's iter / locals_dict dispatch convenience methods.
pub const MP_MAP_LOOKUP: c_int = 0; // mp_map_lookup_kind_t (obj.h:492)
pub const MP_MAP_LOOKUP_ADD_IF_NOT_FOUND: c_int = 1;
pub const MP_MAP_LOOKUP_REMOVE_IF_FOUND: c_int = 2;
pub extern fn mp_map_lookup(map: *MpMap, key: Obj, mode: c_int) callconv(.c) ?*MpMap.Elem;
extern fn mp_obj_instance_getiter(self_in: Obj, iter_buf: ?*anyopaque) callconv(.c) Obj;
extern fn mp_stream_unbuffered_iter(self_in: Obj) callconv(.c) Obj;

// ── persistentcode.c mirrors (NX-1 prep) ────────────────────────────
//
// Types touched by the persistentcode load path that we'll port from
// vendor/micropython_embed/py/persistentcode.c in NX-1. Adding the
// mirrors now (no behavior change) lets later sessions wire Zig fns
// without churning this file.
//
// Config posture (both nano + full arms — verified in mpconfigport.h
// against vendor defaults in py/mpconfig.h:416-433, 506-559, 734-735,
// 1263, 2285-2320):
//   MICROPY_PERSISTENT_CODE_LOAD             = 1
//   MICROPY_PERSISTENT_CODE_SAVE             = 0  (depends on SYS_SETTRACE=0)
//   MICROPY_PERSISTENT_CODE_SAVE_FUN         = 0  (depends on PY_MARSHAL=0)
//   MICROPY_PERSISTENT_CODE_TRACK_BSS_RODATA = 0  (else-arm; NATIVE off)
//   MICROPY_PERSISTENT_CODE_TRACK_FUN_DATA   = 0  (else-arm; NATIVE off)
//   MICROPY_PERSISTENT_CODE_TRACK_RELOC_CODE = 0  (undefined → 0)
//   MICROPY_ENABLE_NATIVE_CODE               = 0
//   MICROPY_EMIT_MACHINE_CODE                = 0
//   MICROPY_EMIT_INLINE_ASM                  = 0
//   MICROPY_EMIT_RV32                        = 0
//   MICROPY_VFS_ROM                          = 0
//   MICROPY_DYNAMIC_COMPILER                 = 0
//   MICROPY_HAS_FILE_READER                  = 0
//   MICROPY_PY_SYS_SETTRACE                  = 0
//
// Under this posture, fields gated by SAVE / NATIVE / INLINE_ASM /
// SETTRACE are absent from the C structs. The mirrors omit them; any
// future config flip MUST add them back and re-verify with a fresh
// `make check`. Search this file for `CONFIG-COUPLED:` to find every
// affected mirror.

/// Mirror of C `mp_raw_code_kind_t` enum (emitglue.h:48-55). 6 values
/// total; only BYTECODE is exercised under our config (the persistent
/// loader raises ValueError on any other kind, persistentcode.c:299).
/// Numeric values match the C enum's declaration order (0-based).
pub const MpRawCodeKind = enum(u8) {
    MP_CODE_UNUSED = 0,
    MP_CODE_RESERVED = 1,
    MP_CODE_BYTECODE = 2,
    MP_CODE_NATIVE_PY = 3,
    MP_CODE_NATIVE_VIPER = 4,
    MP_CODE_NATIVE_ASM = 5,
};

/// Mirror of C `mp_raw_code_t` (emitglue.h:74-99). Bytecode is
/// distinguished from a raw_code via the two-byte indicator prefix:
/// raw_code starts with `{0, 0}`; bytecode is guaranteed to have one
/// of the first two bytes non-zero (see `mp_proto_fun_is_bytecode`).
///
/// CONFIG-COUPLED: MICROPY_PERSISTENT_CODE_SAVE (=0 here). When SAVE=1,
/// adds: `u32 fun_data_len; u16 n_children;`. When SAVE && (EMIT_INLINE_ASM
/// || ENABLE_NATIVE_CODE), further adds `u16 prelude_offset;`. When
/// SAVE && PY_SYS_SETTRACE, further adds `u32 line_of_definition;
/// mp_bytecode_prelude_t prelude;`.
/// CONFIG-COUPLED: MICROPY_EMIT_INLINE_ASM (=0 here). When on, adds
/// trailing bitfield `u32 asm_n_pos_args:8, asm_type_sig:24`.
pub const MpRawCode = extern struct {
    proto_fun_indicator: [2]u8,
    kind: u8, // mp_raw_code_kind_t — only 3 bits used
    is_generator: bool,
    fun_data: ?*const anyopaque,
    /// C: `struct _mp_raw_code_t **children`. Array of child raw_code
    /// pointers (size implicit from caller).
    children: [*c]?*MpRawCode,
};

/// Mirror of C `mp_compiled_module_t` (bc.h:216-225). Outer struct
/// produced by the persistent-code load path.
///
/// CONFIG-COUPLED: MICROPY_PERSISTENT_CODE_SAVE (=0 here). When SAVE=1,
/// adds trailing `bool has_native; size_t n_qstr; size_t n_obj;
/// size_t arch_flags;` fields. The load path writes those at
/// persistentcode.c:524-529, gated by the same macro.
pub const MpCompiledModule = extern struct {
    context: ?*MpModuleContext,
    rc: ?*const MpRawCode,
};

/// Mirror of C `mp_reader_t` (reader.h:40-44). Caller-supplied byte
/// stream backing `mp_raw_code_load`. `readbyte` returns `mp_uint_t`
/// (= `uintptr_t` under default `mp_int_t`) per reader.h:42;
/// `MP_READER_EOF` is `((mp_uint_t)(-1))`.
pub const MpReader = extern struct {
    data: ?*anyopaque,
    readbyte: ?*const fn (data: ?*anyopaque) callconv(.c) usize,
    close: ?*const fn (data: ?*anyopaque) callconv(.c) void,
};

/// Mirror of C `mp_print_t` (mpprint.h:50-53). `print_strn` matches
/// the `mp_print_strn_t` typedef at mpprint.h:48 — returns void.
pub const MpPrint = extern struct {
    data: ?*anyopaque,
    print_strn: ?*const fn (data: ?*anyopaque, str: [*]const u8, len: usize) callconv(.c) void,
};

/// Internal Zig struct (no C ABI requirement) — return value of the
/// future `bcPreludeSigDecode` port. Matches the 6 `uint`s that
/// `MP_BC_PRELUDE_SIG_DECODE_INTO` writes into local vars
/// (bc.h:104-129); the 7th output `code_info_size` belongs to
/// `MP_BC_PRELUDE_SIZE_DECODE` instead.
pub const MpBytecodePrelude = struct {
    n_state: u32,
    n_exc_stack: u32,
    scope_flags: u32,
    n_pos_args: u32,
    n_kwonly_args: u32,
    n_def_pos_args: u32,
};

// ── persistentcode constants ────────────────────────────────────────

/// `qstr_short_t` from qstr.h:61 — `uint16_t`. Indices into the qstr
/// constants table; distinct from the wider `qstr` (= `size_t`) used
/// for enum values.
pub const QstrShort = u16;

/// `mp_proto_fun_t` from emitglue.h:60 — opaque pointer to either
/// bytecode bytes or an `MpRawCode` struct.
pub const MpProtoFun = *const anyopaque;

/// Mirror of `mp_proto_fun_is_bytecode` (emitglue.h:65-68). Both
/// `MP_PROTO_FUN_INDICATOR_RAW_CODE_*` macros are 0 (emitglue.h:36-37),
/// so the predicate reduces to: "either of the first two bytes is
/// non-zero".
pub inline fn protoFunIsBytecode(p: MpProtoFun) bool {
    const header: [*]const u8 = @ptrCast(p);
    return (header[0] | header[1]) != 0;
}

/// `MPY_VERSION` (persistentcode.h:37) — current .mpy file format major
/// version. Embedded in the 4-byte header at byte[1].
pub const MPY_VERSION: u8 = 6;

/// `MPY_SUB_VERSION` (persistentcode.h:38) — native-arch sub-version.
/// Encoded into header byte[2] alongside the arch tag.
pub const MPY_SUB_VERSION: u8 = 3;

/// `BYTES_FOR_INT` from persistentcode.c:561 — max bytes for the
/// 7-bit varint encoding of any `size_t` value, computed at compile
/// time from the target word size. Used by the future `read_uint`
/// / `mp_print_uint` ports.
pub const BYTES_FOR_INT: usize = (@sizeOf(usize) * 8 + 6) / 7;

/// QSTR_LAST_STATIC = `MP_QSTR_zip` (persistentcode.c:48). Numeric value
/// is generated by makeqstrdata.py and only known via the C enum.
/// Resolved in the runtime port (Session 2, `load_qstr`) via `@cImport`
/// of `py/qstr.h`, following the pattern in `src/mp_type_roms.zig:38`.

// ── scope_flags bits (runtime0.h:34-44) ──────────────────────────────
// Used by the load_raw_code prelude decode + native viper arms. We
// only need the bottom 4 for bytecode (the rest gate native-only paths
// that are dead under our config).
pub const MP_SCOPE_FLAG_ALL_SIG: u32 = 0x0f;
pub const MP_SCOPE_FLAG_GENERATOR: u32 = 0x01;
pub const MP_SCOPE_FLAG_VARKEYWORDS: u32 = 0x02;
pub const MP_SCOPE_FLAG_VARARGS: u32 = 0x04;
pub const MP_SCOPE_FLAG_DEFKWARGS: u32 = 0x08;

// ── MP_PERSISTENT_OBJ_* tag bytes (persistentcode.h:122-134) ─────────
// `load_obj`/`save_obj` discriminator.
pub const MP_PERSISTENT_OBJ_FUN_TABLE: u8 = 0;
pub const MP_PERSISTENT_OBJ_NONE: u8 = 1;
pub const MP_PERSISTENT_OBJ_FALSE: u8 = 2;
pub const MP_PERSISTENT_OBJ_TRUE: u8 = 3;
pub const MP_PERSISTENT_OBJ_ELLIPSIS: u8 = 4;
pub const MP_PERSISTENT_OBJ_STR: u8 = 5;
pub const MP_PERSISTENT_OBJ_BYTES: u8 = 6;
pub const MP_PERSISTENT_OBJ_INT: u8 = 7;
pub const MP_PERSISTENT_OBJ_FLOAT: u8 = 8;
pub const MP_PERSISTENT_OBJ_COMPLEX: u8 = 9;
pub const MP_PERSISTENT_OBJ_TUPLE: u8 = 10;
