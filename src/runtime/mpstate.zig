// zigonly Phase 2 — hand-written Zig mirror of mp_state_ctx_t.
//
// WHY HAND-WRITTEN (not @cImport):
//   The original 30-line draft did `const mp = @cImport({ @cInclude("py/mpstate.h"); });`
//   and exported `var mp_state_ctx: mp.mp_state_ctx_t = std.mem.zeroes(...)`.
//   That silently produced a ZERO-SIZED bss symbol because translate-c demotes
//   `mp_state_ctx_t` to `opaque{}`. Root cause: `mp_obj_exception_t` (nested
//   inline at MP_STATE_VM(mp_emergency_exception_obj)) and `qstr_pool_t` use
//   computed-width bitfields like `: (8 * sizeof(size_t) / 2)`. translate-c
//   can't express these in Zig, so the type becomes opaque, and opacity
//   propagates up the inclusion chain to mp_state_ctx_t itself. Any C TU
//   linking with that bss symbol then reads garbage / overwrites neighbours.
//
//   We satisfy the link contract by emitting an `extern struct` whose byte
//   layout matches the C definition for the *nano* config (the only one
//   relevant to the Phase 2 smoke test). Bitfields are replaced with plain
//   unsigned fields of equivalent total width — the runtime never reads them
//   in zigonly mode.
//
// CONFIG ASSUMED (port/mpconfigport.h default arm, PETITPY_CONFIG_FULL undefined):
//   MICROPY_PY_THREAD                       = 0
//   MICROPY_MEM_STATS                       = 0
//   MICROPY_ENABLE_FINALISER                = 0  → GC_LOCK_DEPTH_SHIFT = 0
//   MICROPY_GC_SPLIT_HEAP                   = 0
//   MICROPY_ENABLE_EMERGENCY_EXCEPTION_BUF  = 0
//   MICROPY_KBD_EXCEPTION                   = 0  (MINIMUM ROM level)
//   MICROPY_CAN_OVERRIDE_BUILTINS           = 0  (MINIMUM ROM level)
//   MICROPY_TRACKED_ALLOC                   = 0
//   MICROPY_ENABLE_COMPILER                 = 1  → mp_optimise_value present
//   MICROPY_EMIT_NATIVE                     = 0  (MINIMUM ROM level)
//   MICROPY_ENABLE_SCHEDULER                = 0  (MINIMUM ROM level)
//   MICROPY_ENABLE_VM_ABORT                 = 0
//   MICROPY_OPT_MAP_LOOKUP_CACHE            = 1 in mpconfigport.h, but the
//     cache is a Zig global in map.zig, so this mirror omits C's 128-byte
//     map_lookup_cache at the end of mp_state_vm_t: in the C view,
//     mp_state_mem_t sits 128 bytes later. No compiled C reads it.
//   MICROPY_STACK_CHECK                     = 0  (MINIMUM ROM level)
//   MICROPY_ENABLE_PYSTACK                  = 0
//   MICROPY_PY_SYS_SETTRACE                 = 0
//   MICROPY_PY_SSL_MBEDTLS_NEED_ACTIVE_CONTEXT = 0
//   MICROPY_NLR_SETJMP                      = 1
//   MICROPY_PY_SYS_PATH                     = 1  → MP_SYS_MUTABLE_PATH    = 0
//   MICROPY_PY_SYS_PS1_PS2                  = 1  → MP_SYS_MUTABLE_PS1     = 1
//                                                  MP_SYS_MUTABLE_PS2     = 2
//   MICROPY_PY_SYS_TRACEBACKLIMIT           = 0
//   MICROPY_PY_SYS_ATTR_DELEGATION          = 1  → MP_SYS_MUTABLE_NUM     = 3
//   MICROPY_QSTR_BYTES_IN_LEN               = 1
//   MICROPY_QSTR_BYTES_IN_HASH              = 2
//   MICROPY_ALLOC_GC_STACK_SIZE             = 64
//   MICROPY_GC_STACK_ENTRY_TYPE             = size_t (8 bytes on 64-bit)
//   sizeof(mp_obj_t)                        = 8     (REPR_A: void *)
//
// Target ABI: 64-bit (sizeof(size_t) = 8, alignof(size_t) = 8) primary.
// On wasm32 (sizeof(size_t) = 4), the same `extern struct` layout works —
// every field is either usize or pointer-sized so natural C alignment
// already follows. The pad fields are sized to round up to the next usize
// alignment, computed via a comptime helper.

const std = @import("std");

const USIZE_BYTES: usize = @sizeOf(usize);

inline fn padTo(comptime current: usize, comptime align_to: usize) usize {
    const m = current % align_to;
    return if (m == 0) 0 else align_to - m;
}

// ─── inner-struct mirrors ──────────────────────────────────────────────
//
// Each of these matches the bytes the C compiler emits for the SAME named
// struct under the nano config above. We expose them as `extern struct` so
// `@sizeOf` / `@offsetOf` are well-defined and so a C consumer linking
// against the mirror sees identical layout.

/// Mirror of `mp_obj_base_t` (py/obj.h:54).
const ObjBase = extern struct {
    type: ?*const anyopaque,
};

/// Mirror of `mp_map_t` (py/obj.h:481). The three single-bit flags and
/// `used` field share one usize-sized bitfield slot in C; we represent
/// that slot as a raw usize because zigonly never inspects it (the map
/// is created empty by mp_init() and only ever read by mp_map_lookup —
/// itself stubbed in Phase 1).
const Map = extern struct {
    bits: usize, // [all_keys_are_qstrs:1][is_fixed:1][is_ordered:1][used:N-3]
    alloc: usize,
    table: ?*anyopaque,
};

/// Mirror of `mp_obj_dict_t` (py/obj.h:1196).
const ObjDict = extern struct {
    base: ObjBase,
    map: Map,
};

/// Mirror of `mp_obj_list_t` (py/objlist.h:31).
const ObjList = extern struct {
    base: ObjBase,
    alloc: usize,
    len: usize,
    items: ?*anyopaque, // mp_obj_t *
};

/// Mirror of `mp_obj_exception_t` (py/objexcept.h:32). The two halved-width
/// bitfields pack into one usize slot — we expose the slot as a usize.
const ObjException = extern struct {
    base: ObjBase,
    tb_bits: usize, // [traceback_alloc:N/2][traceback_len:N/2]
    traceback_data: ?*anyopaque, // size_t *
    args: ?*anyopaque, // mp_obj_tuple_t *
};

/// Mirror of `mp_state_mem_area_t` (py/mpstate.h:100) under nano:
/// no `next` (SPLIT_HEAP=0), no `gc_finaliser_table_start` (FINALISER=0).
const StateMemArea = extern struct {
    gc_alloc_table_start: ?[*]u8,
    gc_alloc_table_byte_len: usize,
    gc_pool_start: ?[*]u8,
    gc_pool_end: ?[*]u8,
    gc_last_free_atb_index: usize,
    gc_last_used_block: usize,
};

/// Mirror of root_pointers.h contents inlined at the end of the root
/// pointer section of `mp_state_vm_t`. Three entries under nano:
///   mp_obj_base_t *cur_exception;
///   mp_obj_list_t  mp_sys_argv_obj;
///   mp_obj_t       sys_mutable[MP_SYS_MUTABLE_NUM];
const SYS_MUTABLE_NUM: usize = 3; // PATH, PS1, PS2 — see config block above
const RootPointers = extern struct {
    cur_exception: ?*anyopaque, // mp_obj_base_t *
    mp_sys_argv_obj: ObjList,
    sys_mutable: [SYS_MUTABLE_NUM]usize, // mp_obj_t
};

// ─── mp_state_thread_t (nano) ──────────────────────────────────────────
//
// Field order matches py/mpstate.h:274 exactly. Padding inserted manually
// to match natural C alignment under -m64.

// Padding between gc_lock_depth (u16) and the next usize-aligned pointer.
// On 64-bit: stack_top(8) + u16(2) → 6 pad bytes to reach offset 16.
// On 32-bit: stack_top(4) + u16(2) → 2 pad bytes to reach offset  8.
const _STATE_THREAD_GC_LOCK_PAD: usize = padTo(USIZE_BYTES + 2, USIZE_BYTES);

pub const StateThread = extern struct {
    // Non-root header
    stack_top: ?[*]u8,
    gc_lock_depth: u16,
    _pad_gc_lock: [_STATE_THREAD_GC_LOCK_PAD]u8 = [_]u8{0} ** _STATE_THREAD_GC_LOCK_PAD,

    // ROOT POINTER SECTION — every field here is GC-scanned in vendor;
    // in zigonly we just need correct offsets so MP_STATE_THREAD(x)
    // expands to the right byte.
    dict_locals: ?*anyopaque, // mp_obj_dict_t *
    dict_globals: ?*anyopaque, // mp_obj_dict_t *
    nlr_top: ?*anyopaque, // nlr_buf_t *
    nlr_jump_callback_top: ?*anyopaque,
    mp_pending_exception: usize, // volatile mp_obj_t
    stop_iteration_arg: usize, // mp_obj_t
};

// ─── mp_state_vm_t (nano) ──────────────────────────────────────────────

const StateVm = extern struct {
    // ROOT POINTER SECTION (continues from mp_state_thread_t end)
    last_pool: ?*anyopaque, // qstr_pool_t *      (offset 0)
    mp_emergency_exception_obj: ObjException, //    (offset 8, size 32)
    mp_loaded_modules_dict: ObjDict, //              (offset 40, size 32)
    dict_main: ObjDict, //                            (offset 72, size 32)
    root_pointers: RootPointers, //                   (offset 104, size 64)
    // END ROOT POINTER SECTION

    qstr_last_chunk: ?[*]u8, //                       (offset 168)
    qstr_last_alloc: usize, //                        (offset 176)
    qstr_last_used: usize, //                         (offset 184)
    mp_optimise_value: usize, // mp_uint_t            (offset 192)
};

// ─── mp_state_mem_t (nano) ─────────────────────────────────────────────

const GC_STACK_SIZE: usize = 64; // MICROPY_ALLOC_GC_STACK_SIZE

// Padding after gc_stack_overflow (c_int = 4 bytes) before usize-aligned
// gc_block_stack. On 64-bit: 4 pad. On 32-bit: 0 pad.
const _STATE_MEM_OVERFLOW_PAD: usize = padTo(4, USIZE_BYTES);
// Trailing pad after gc_auto_collect_enabled (u16) to round struct size
// up to USIZE_BYTES alignment. On 64-bit: 6 pad. On 32-bit: 2 pad.
const _STATE_MEM_TAIL_PAD: usize = padTo(2, USIZE_BYTES);

const StateMem = extern struct {
    area: StateMemArea,
    gc_stack_overflow: c_int,
    _pad_overflow: [_STATE_MEM_OVERFLOW_PAD]u8 = [_]u8{0} ** _STATE_MEM_OVERFLOW_PAD,
    gc_block_stack: [GC_STACK_SIZE]usize,
    gc_auto_collect_enabled: u16,
    _pad_tail: [_STATE_MEM_TAIL_PAD]u8 = [_]u8{0} ** _STATE_MEM_TAIL_PAD,
};

// ─── mp_state_ctx_t ────────────────────────────────────────────────────
//
// Field order MUST stay { thread, vm, mem } — the GC root scan walks from
// `&thread.dict_locals` (root section start) to `&vm.qstr_last_chunk - 1`
// (root section end) as one contiguous span. Reordering changes the size
// of that span and breaks the scan (silently; corrupts memory).

pub const StateCtx = extern struct {
    thread: StateThread,
    vm: StateVm,
    mem: StateMem,
};

// ─── THE singleton ─────────────────────────────────────────────────────
//
// `extern` C-ABI symbol named exactly `mp_state_ctx`. Every C TU that
// `#include`s py/mpstate.h sees `extern mp_state_ctx_t mp_state_ctx;` and
// references this symbol. Macros expand to `mp_state_ctx.vm.x` etc.,
// resolved by the linker against this storage. Zero-initialised (matches
// the C BSS-resident original — fields get filled in by mp_init()).

pub export var mp_state_ctx: StateCtx = std.mem.zeroes(StateCtx);

// ─── comptime layout assertions ────────────────────────────────────────
//
// Hard-coded numeric expectations from the config-block analysis above.
// If any field offset or struct size drifts (e.g. someone flips a config
// bit without revisiting this file), the build fails here — not at
// runtime when an MP_STATE_VM read hits the wrong byte. There are no
// C-side `sizeof` constants to cross-check against; these asserts are
// the only guard.

comptime {
    if (USIZE_BYTES == 8) {
        // 64-bit host: nano-config canonical layout. These are the original
        // hand-verified offsets/sizes; if they drift, the build fails here
        // before runtime corruption occurs.
        std.debug.assert(@sizeOf(ObjBase) == 8);
        std.debug.assert(@sizeOf(Map) == 24);
        std.debug.assert(@sizeOf(ObjDict) == 32);
        std.debug.assert(@sizeOf(ObjList) == 32);
        std.debug.assert(@sizeOf(ObjException) == 32);
        std.debug.assert(@sizeOf(StateMemArea) == 48);
        std.debug.assert(@sizeOf(RootPointers) == 8 + 32 + SYS_MUTABLE_NUM * 8);

        std.debug.assert(@offsetOf(StateThread, "stack_top") == 0);
        std.debug.assert(@offsetOf(StateThread, "gc_lock_depth") == 8);
        std.debug.assert(@offsetOf(StateThread, "dict_locals") == 16);
        std.debug.assert(@offsetOf(StateThread, "dict_globals") == 24);
        std.debug.assert(@offsetOf(StateThread, "nlr_top") == 32);
        std.debug.assert(@offsetOf(StateThread, "nlr_jump_callback_top") == 40);
        std.debug.assert(@offsetOf(StateThread, "mp_pending_exception") == 48);
        std.debug.assert(@offsetOf(StateThread, "stop_iteration_arg") == 56);
        std.debug.assert(@sizeOf(StateThread) == 64);

        std.debug.assert(@offsetOf(StateVm, "last_pool") == 0);
        std.debug.assert(@offsetOf(StateVm, "mp_emergency_exception_obj") == 8);
        std.debug.assert(@offsetOf(StateVm, "mp_loaded_modules_dict") == 40);
        std.debug.assert(@offsetOf(StateVm, "dict_main") == 72);
        std.debug.assert(@offsetOf(StateVm, "root_pointers") == 104);
        std.debug.assert(@offsetOf(StateVm, "qstr_last_chunk") == 168);
        std.debug.assert(@offsetOf(StateVm, "qstr_last_alloc") == 176);
        std.debug.assert(@offsetOf(StateVm, "qstr_last_used") == 184);
        std.debug.assert(@offsetOf(StateVm, "mp_optimise_value") == 192);
        std.debug.assert(@sizeOf(StateVm) == 200);

        std.debug.assert(@offsetOf(StateMem, "area") == 0);
        std.debug.assert(@offsetOf(StateMem, "gc_stack_overflow") == 48);
        std.debug.assert(@offsetOf(StateMem, "gc_block_stack") == 56);
        std.debug.assert(@offsetOf(StateMem, "gc_auto_collect_enabled") == 568);
        std.debug.assert(@sizeOf(StateMem) == 576);

        std.debug.assert(@offsetOf(StateCtx, "thread") == 0);
        std.debug.assert(@offsetOf(StateCtx, "vm") == 64);
        std.debug.assert(@offsetOf(StateCtx, "mem") == 264);
        std.debug.assert(@sizeOf(StateCtx) == 64 + 200 + 576);
    } else {
        // 32-bit host (wasm32): the same extern-struct definitions yield
        // half-sized pointers and usize, so offsets and sizes scale down
        // accordingly. We do not pin numeric values here — the layout is
        // exercised by the wasm smoke test rather than asserted.
        std.debug.assert(USIZE_BYTES == 4);
    }
}

// ─── typed accessors for Zig-side consumers ────────────────────────────
//
// MP_STATE_VM(x) / MP_STATE_MEM(x) / MP_STATE_THREAD(x) are C macros —
// useless from Zig. These helpers let Zig modules (qstr port, gc port,
// runtime port) reach the same fields with type safety. They take a
// pointer-to-field so callers can pass `&mp_state_ctx.vm.last_pool`
// and let inference do the rest.

/// Pointer to the VM substate, for use as `&vmState().last_pool`.
pub inline fn vmState() *StateVm {
    return &mp_state_ctx.vm;
}

/// Pointer to the MEM substate.
pub inline fn memState() *StateMem {
    return &mp_state_ctx.mem;
}

/// Pointer to the (single) thread substate. With MICROPY_PY_THREAD=0
/// this is always the main thread's slab.
pub inline fn threadState() *StateThread {
    return &mp_state_ctx.thread;
}

// ─── force-keep ────────────────────────────────────────────────────────
//
// `main.zig` does `_ = @import("runtime/mpstate.zig");` — that pulls the
// file in but Zig may still DCE unused decls. The export above is the
// load-bearing symbol; reference it from a comptime block so the linker
// can't drop it.

comptime {
    _ = &mp_state_ctx;
}
