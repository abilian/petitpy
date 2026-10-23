//! petitpy bytecode emitter — pure-Zig (C6 of the compiler/ track).
//!
//! Port of src/frontend/emitbc.zig + emitcommon_shim.c, stripped of every
//! @cImport / C-ABI dependency. The algorithm is the one validated by
//! 552/552 .mpy round-trip parity against vendor — this file is mechanical
//! transcription with type/dispatch idioms swapped:
//!
//!   * @cImport → hand-ported pub const blocks for MP_BC_* / MP_EMIT_* /
//!     MP_BINARY_OP_* / MP_UNARY_OP_* / MP_TOKEN_KW_* / MP_QSTR_* /
//!     MP_OBJ_ITER_BUF_NSLOTS. Each block is pinned to its vendor source
//!     so a future bytecode-format bump fails loudly. The format itself
//!     is frozen by MPY_VERSION=6.
//!   * mp_emit_method_table_t (50+ function pointers) → methods on
//!     *Emit. Nano has bytecode-only emission; no runtime polymorphism
//!     is needed.
//!   * mp_obj_t-tagged const_obj_list → ConstObj discriminated union.
//!   * m_new / GC heap → std.mem.Allocator, errors surface as `!T`.
//!   * Three id-ops tables (load/store/delete) → EmitCommon.idOp(op, ...)
//!     with an enum operand.
//!
//! Validation: this file's unit tests cover the algorithmic core
//! (encoders, dedup, single-opcode emission, multi-pass consistency,
//! label resolution, suppress-flag). Byte-identical corpus diff against
//! mpy-cross is C7's job (compile.zig driver) — that's the integration
//! test that proves the full chain.

const std = @import("std");
const qstr_mod = @import("qstr.zig");
const scope_mod = @import("scope.zig");
const mpy = @import("mpy.zig");

pub const Qstr = qstr_mod.qstr;
pub const Scope = scope_mod.Scope;
pub const IdInfo = scope_mod.IdInfo;
pub const IdInfoKind = scope_mod.IdInfoKind;
pub const ScopeKind = scope_mod.ScopeKind;

// ─────────────────────────────────────────────────────────────────────────
// Vendor constants — hand-ported from py/bc0.h, py/emit.h, py/runtime0.h,
// py/lexer.h, py/obj.h. Pinned with comments to vendor file + line so a
// future regen drift is traceable.
// ─────────────────────────────────────────────────────────────────────────

/// Scratch buffer size for size-only / suppressed writes.
/// MP_ENCODE_UINT_MAX_BYTES from vendor py/bc.h.
const DUMMY_DATA_SIZE: usize = 10;

// ── py/bc0.h opcode bases ────────────────────────────────────────────────
const MP_BC_BASE_QSTR_O: u8 = 0x10;
const MP_BC_BASE_VINT_E: u8 = 0x20;
const MP_BC_BASE_VINT_O: u8 = 0x30;
const MP_BC_BASE_JUMP_E: u8 = 0x40;
const MP_BC_BASE_BYTE_O: u8 = 0x50;
const MP_BC_BASE_BYTE_E: u8 = 0x60;

// ── const loads ─────────────────────────────────────────────────────────
pub const MP_BC_LOAD_CONST_FALSE: u8 = MP_BC_BASE_BYTE_O + 0x00;
pub const MP_BC_LOAD_CONST_NONE: u8 = MP_BC_BASE_BYTE_O + 0x01;
pub const MP_BC_LOAD_CONST_TRUE: u8 = MP_BC_BASE_BYTE_O + 0x02;
pub const MP_BC_LOAD_CONST_SMALL_INT: u8 = MP_BC_BASE_VINT_E + 0x02;
pub const MP_BC_LOAD_CONST_STRING: u8 = MP_BC_BASE_QSTR_O + 0x00;
pub const MP_BC_LOAD_CONST_OBJ: u8 = MP_BC_BASE_VINT_E + 0x03;
pub const MP_BC_LOAD_NULL: u8 = MP_BC_BASE_BYTE_O + 0x03;

// ── locals/names ────────────────────────────────────────────────────────
pub const MP_BC_LOAD_FAST_N: u8 = MP_BC_BASE_VINT_E + 0x04;
pub const MP_BC_LOAD_DEREF: u8 = MP_BC_BASE_VINT_E + 0x05;
pub const MP_BC_LOAD_NAME: u8 = MP_BC_BASE_QSTR_O + 0x01;
pub const MP_BC_LOAD_GLOBAL: u8 = MP_BC_BASE_QSTR_O + 0x02;
pub const MP_BC_LOAD_ATTR: u8 = MP_BC_BASE_QSTR_O + 0x03;
pub const MP_BC_LOAD_METHOD: u8 = MP_BC_BASE_QSTR_O + 0x04;
pub const MP_BC_LOAD_SUPER_METHOD: u8 = MP_BC_BASE_QSTR_O + 0x05;
pub const MP_BC_LOAD_BUILD_CLASS: u8 = MP_BC_BASE_BYTE_O + 0x04;
pub const MP_BC_LOAD_SUBSCR: u8 = MP_BC_BASE_BYTE_O + 0x05;

pub const MP_BC_STORE_FAST_N: u8 = MP_BC_BASE_VINT_E + 0x06;
pub const MP_BC_STORE_DEREF: u8 = MP_BC_BASE_VINT_E + 0x07;
pub const MP_BC_STORE_NAME: u8 = MP_BC_BASE_QSTR_O + 0x06;
pub const MP_BC_STORE_GLOBAL: u8 = MP_BC_BASE_QSTR_O + 0x07;
pub const MP_BC_STORE_ATTR: u8 = MP_BC_BASE_QSTR_O + 0x08;
pub const MP_BC_STORE_SUBSCR: u8 = MP_BC_BASE_BYTE_O + 0x06;

pub const MP_BC_DELETE_FAST: u8 = MP_BC_BASE_VINT_E + 0x08;
pub const MP_BC_DELETE_DEREF: u8 = MP_BC_BASE_VINT_E + 0x09;
pub const MP_BC_DELETE_NAME: u8 = MP_BC_BASE_QSTR_O + 0x09;
pub const MP_BC_DELETE_GLOBAL: u8 = MP_BC_BASE_QSTR_O + 0x0a;

// ── stack ops ───────────────────────────────────────────────────────────
pub const MP_BC_DUP_TOP: u8 = MP_BC_BASE_BYTE_O + 0x07;
pub const MP_BC_DUP_TOP_TWO: u8 = MP_BC_BASE_BYTE_O + 0x08;
pub const MP_BC_POP_TOP: u8 = MP_BC_BASE_BYTE_O + 0x09;
pub const MP_BC_ROT_TWO: u8 = MP_BC_BASE_BYTE_O + 0x0a;
pub const MP_BC_ROT_THREE: u8 = MP_BC_BASE_BYTE_O + 0x0b;

// ── control flow ────────────────────────────────────────────────────────
pub const MP_BC_UNWIND_JUMP: u8 = MP_BC_BASE_JUMP_E + 0x00;
pub const MP_BC_JUMP: u8 = MP_BC_BASE_JUMP_E + 0x02;
pub const MP_BC_POP_JUMP_IF_TRUE: u8 = MP_BC_BASE_JUMP_E + 0x03;
pub const MP_BC_POP_JUMP_IF_FALSE: u8 = MP_BC_BASE_JUMP_E + 0x04;
pub const MP_BC_JUMP_IF_TRUE_OR_POP: u8 = MP_BC_BASE_JUMP_E + 0x05;
pub const MP_BC_JUMP_IF_FALSE_OR_POP: u8 = MP_BC_BASE_JUMP_E + 0x06;
pub const MP_BC_SETUP_WITH: u8 = MP_BC_BASE_JUMP_E + 0x07;
pub const MP_BC_SETUP_EXCEPT: u8 = MP_BC_BASE_JUMP_E + 0x08;
pub const MP_BC_SETUP_FINALLY: u8 = MP_BC_BASE_JUMP_E + 0x09;
pub const MP_BC_POP_EXCEPT_JUMP: u8 = MP_BC_BASE_JUMP_E + 0x0a;
pub const MP_BC_FOR_ITER: u8 = MP_BC_BASE_JUMP_E + 0x0b;
pub const MP_BC_WITH_CLEANUP: u8 = MP_BC_BASE_BYTE_O + 0x0c;
pub const MP_BC_END_FINALLY: u8 = MP_BC_BASE_BYTE_O + 0x0d;
pub const MP_BC_GET_ITER: u8 = MP_BC_BASE_BYTE_O + 0x0e;
pub const MP_BC_GET_ITER_STACK: u8 = MP_BC_BASE_BYTE_O + 0x0f;

// ── build / unpack / store_comp ─────────────────────────────────────────
pub const MP_BC_BUILD_TUPLE: u8 = MP_BC_BASE_VINT_E + 0x0a;
pub const MP_BC_BUILD_LIST: u8 = MP_BC_BASE_VINT_E + 0x0b;
pub const MP_BC_BUILD_MAP: u8 = MP_BC_BASE_VINT_E + 0x0c;
pub const MP_BC_STORE_MAP: u8 = MP_BC_BASE_BYTE_E + 0x02;
pub const MP_BC_BUILD_SET: u8 = MP_BC_BASE_VINT_E + 0x0d;
pub const MP_BC_BUILD_SLICE: u8 = MP_BC_BASE_VINT_E + 0x0e;
pub const MP_BC_STORE_COMP: u8 = MP_BC_BASE_VINT_E + 0x0f;
pub const MP_BC_UNPACK_SEQUENCE: u8 = MP_BC_BASE_VINT_O + 0x00;
pub const MP_BC_UNPACK_EX: u8 = MP_BC_BASE_VINT_O + 0x01;

// ── terminus ────────────────────────────────────────────────────────────
pub const MP_BC_RETURN_VALUE: u8 = MP_BC_BASE_BYTE_E + 0x03;
pub const MP_BC_RAISE_LAST: u8 = MP_BC_BASE_BYTE_E + 0x04;
pub const MP_BC_RAISE_OBJ: u8 = MP_BC_BASE_BYTE_E + 0x05;
pub const MP_BC_RAISE_FROM: u8 = MP_BC_BASE_BYTE_E + 0x06;
pub const MP_BC_YIELD_VALUE: u8 = MP_BC_BASE_BYTE_E + 0x07;
pub const MP_BC_YIELD_FROM: u8 = MP_BC_BASE_BYTE_E + 0x08;

// ── make / call ─────────────────────────────────────────────────────────
pub const MP_BC_MAKE_FUNCTION: u8 = MP_BC_BASE_VINT_O + 0x02;
pub const MP_BC_MAKE_FUNCTION_DEFARGS: u8 = MP_BC_BASE_VINT_O + 0x03;
pub const MP_BC_MAKE_CLOSURE: u8 = MP_BC_BASE_VINT_E + 0x00;
pub const MP_BC_MAKE_CLOSURE_DEFARGS: u8 = MP_BC_BASE_VINT_E + 0x01;
pub const MP_BC_CALL_FUNCTION: u8 = MP_BC_BASE_VINT_O + 0x04;
pub const MP_BC_CALL_FUNCTION_VAR_KW: u8 = MP_BC_BASE_VINT_O + 0x05;
pub const MP_BC_CALL_METHOD: u8 = MP_BC_BASE_VINT_O + 0x06;
pub const MP_BC_CALL_METHOD_VAR_KW: u8 = MP_BC_BASE_VINT_O + 0x07;

// ── imports ─────────────────────────────────────────────────────────────
pub const MP_BC_IMPORT_NAME: u8 = MP_BC_BASE_QSTR_O + 0x0b;
pub const MP_BC_IMPORT_FROM: u8 = MP_BC_BASE_QSTR_O + 0x0c;
pub const MP_BC_IMPORT_STAR: u8 = MP_BC_BASE_BYTE_E + 0x09;

// ── MULTI ranges ────────────────────────────────────────────────────────
pub const MP_BC_LOAD_CONST_SMALL_INT_MULTI: u8 = 0x70;
pub const MP_BC_LOAD_CONST_SMALL_INT_MULTI_NUM: isize = 64;
pub const MP_BC_LOAD_CONST_SMALL_INT_MULTI_EXCESS: isize = 16;
pub const MP_BC_LOAD_FAST_MULTI: u8 = 0xb0;
pub const MP_BC_STORE_FAST_MULTI: u8 = 0xc0;
pub const MP_BC_UNARY_OP_MULTI: u8 = 0xd0;
pub const MP_BC_BINARY_OP_MULTI: u8 = 0xd7;

// ── py/emit.h kind enums ────────────────────────────────────────────────
pub const Pass = enum(u8) {
    scope = 1,
    stack_size = 2,
    code_size = 3,
    emit = 4,
};

pub const MP_EMIT_IDOP_LOCAL_FAST: u8 = 0;
pub const MP_EMIT_IDOP_LOCAL_DEREF: u8 = 1;
pub const MP_EMIT_IDOP_GLOBAL_NAME: u8 = 0;
pub const MP_EMIT_IDOP_GLOBAL_GLOBAL: u8 = 1;

pub const MP_EMIT_IMPORT_NAME: u8 = 0;
pub const MP_EMIT_IMPORT_FROM: u8 = 1;
pub const MP_EMIT_IMPORT_STAR: u8 = 2;

pub const MP_EMIT_SUBSCR_LOAD: u8 = 0;
pub const MP_EMIT_SUBSCR_STORE: u8 = 1;
pub const MP_EMIT_SUBSCR_DELETE: u8 = 2;

pub const MP_EMIT_ATTR_LOAD: u8 = 0;
pub const MP_EMIT_ATTR_STORE: u8 = 1;
pub const MP_EMIT_ATTR_DELETE: u8 = 2;

pub const MP_EMIT_SETUP_BLOCK_WITH: u8 = 0;
pub const MP_EMIT_SETUP_BLOCK_EXCEPT: u8 = 1;
pub const MP_EMIT_SETUP_BLOCK_FINALLY: u8 = 2;

pub const MP_EMIT_BUILD_TUPLE: u8 = 0;
pub const MP_EMIT_BUILD_LIST: u8 = 1;
pub const MP_EMIT_BUILD_MAP: u8 = 2;
pub const MP_EMIT_BUILD_SET: u8 = 3;
pub const MP_EMIT_BUILD_SLICE: u8 = 4;

pub const MP_EMIT_YIELD_VALUE: u8 = 0;
pub const MP_EMIT_YIELD_FROM: u8 = 1;

pub const MP_EMIT_STAR_FLAG_SINGLE: u8 = 0x01;
pub const MP_EMIT_STAR_FLAG_DOUBLE: u8 = 0x02;
pub const MP_EMIT_BREAK_FROM_FOR: usize = 0x8000;

// ── py/runtime0.h unary / binary op ordinals (used in MULTI bytecode) ───
pub const MP_UNARY_OP_POSITIVE: u8 = 0;
pub const MP_UNARY_OP_NEGATIVE: u8 = 1;
pub const MP_UNARY_OP_INVERT: u8 = 2;
pub const MP_UNARY_OP_NOT: u8 = 3;

pub const MP_BINARY_OP_LESS: u8 = 0;
pub const MP_BINARY_OP_EQUAL: u8 = 2; // vendor py/runtime0.h:97
pub const MP_BINARY_OP_MORE_EQUAL: u8 = 4; // vendor py/runtime0.h:99
pub const MP_BINARY_OP_IN: u8 = 6;
pub const MP_BINARY_OP_IS: u8 = 7;
pub const MP_BINARY_OP_EXCEPTION_MATCH: u8 = 8;
// NOT_IN and IS_NOT are synthesised by the emitter; their ordinals exceed
// MP_BINARY_OP_NUM_BYTECODE. We only need their values for the
// binary_op dispatcher's `op == NOT_IN / IS_NOT` check; the actual
// bytecode goes via IN/IS + UNARY_NOT.
pub const MP_BINARY_OP_NOT_IN: u8 = 35; // vendor py/runtime0.h:163
pub const MP_BINARY_OP_IS_NOT: u8 = 36; // vendor py/runtime0.h:164

// ── py/lexer.h token ordinals (only the kw ones used here) ──────────────
// Pinned by mp_token_kind_t order: FALSE/NONE/TRUE follow ELLIPSIS.
// Vendor lexer.h:61-65 (with FSTRINGS disabled in nano config → no shift).
pub const MP_TOKEN_ELLIPSIS: u8 = 9;
pub const MP_TOKEN_KW_FALSE: u8 = 10;
pub const MP_TOKEN_KW_NONE: u8 = 11;
pub const MP_TOKEN_KW_TRUE: u8 = 12;

// ── well-known qstr ids (zero-based QDEF0 indices in the embedded table)
pub const MP_QSTR__star_: Qstr = 5; // "*"
pub const MP_QSTR_BaseException: Qstr = 33; // "BaseException"

// ── obj.h: iter-buf size on stack (4 slots on 32- and 64-bit). ──────────
pub const MP_OBJ_ITER_BUF_NSLOTS: usize = 4;

// ─────────────────────────────────────────────────────────────────────────
// ConstObj — discriminated-union value type for the const-obj table.
//
// The .mpy writer (mpy.zig) consumes these via toObjEntry() to produce
// its ObjEntry tags. Deduplicated in EmitCommon.useConstObj by
// strictlyEqual, which preserves vendor's signbit-aware ±0.0 distinction
// and recursive tuple equality (vendor emitcommon.c:strictly_equal).
// ─────────────────────────────────────────────────────────────────────────

pub const ConstObj = union(enum) {
    none,
    bool_true,
    bool_false,
    ellipsis,
    /// Decimal-text big int (already past the small-int range).
    int_big: []const u8,
    str: []const u8,
    bytes: []const u8,
    /// Text repr of a float; preserves sign for ±0 distinction.
    float: []const u8,
    complex: []const u8,
    tuple: []const ConstObj,

    /// Vendor strictly_equal: matches type, value, AND ±0.0 sign for
    /// floats. Tuples recurse. Note: True != 1.0 (different types).
    pub fn strictlyEqual(a: ConstObj, b: ConstObj) bool {
        if (@as(@typeInfo(ConstObj).@"union".tag_type.?, a) !=
            @as(@typeInfo(ConstObj).@"union".tag_type.?, b)) return false;
        return switch (a) {
            .none, .bool_true, .bool_false, .ellipsis => true,
            .int_big => std.mem.eql(u8, a.int_big, b.int_big),
            .str => std.mem.eql(u8, a.str, b.str),
            .bytes => std.mem.eql(u8, a.bytes, b.bytes),
            .float => std.mem.eql(u8, a.float, b.float),
            .complex => std.mem.eql(u8, a.complex, b.complex),
            .tuple => blk: {
                if (a.tuple.len != b.tuple.len) break :blk false;
                for (a.tuple, b.tuple) |ai, bi| {
                    if (!strictlyEqual(ai, bi)) break :blk false;
                }
                break :blk true;
            },
        };
    }

    /// Convert to the mpy.ObjEntry shape the writer expects. The byte
    /// slices are borrowed (not duplicated) — the caller must keep the
    /// ConstObj alive for the lifetime of the resulting ObjEntry.
    pub fn toObjEntry(
        self: ConstObj,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error!mpy.ObjEntry {
        return switch (self) {
            .none => .none,
            .bool_true => .true,
            .bool_false => .false,
            .ellipsis => .ellipsis,
            .int_big => |b| .{ .int = b },
            .str => |b| .{ .str = b },
            .bytes => |b| .{ .bytes = b },
            .float => |b| .{ .float = b },
            .complex => |b| .{ .complex = b },
            .tuple => |items| blk: {
                const out = try allocator.alloc(mpy.ObjEntry, items.len);
                for (items, 0..) |it, i| out[i] = try it.toObjEntry(allocator);
                break :blk .{ .tuple = out };
            },
        };
    }
};

// ─────────────────────────────────────────────────────────────────────────
// EmitCommon — per-compilation-unit constant tables and child registry.
//
// Vendor mp_emit_common_t. Owns:
//   - qstr_table: emit-local index → real Qstr id (the .mpy writer turns
//     each into a QstrEntry).
//   - const_obj_list: the constants any opcode references.
//   - children: nested scopes the emitter has seen (resolved to
//     mpy.RawCode by the C7 driver after compilation finishes).
//
// ct_cur_child ticks across passes so child allocation order is
// deterministic.
// ─────────────────────────────────────────────────────────────────────────

pub const EmitCommon = struct {
    allocator: std.mem.Allocator,
    pass: Pass = .scope,
    ct_cur_child: u16 = 0,
    children: std.ArrayListUnmanaged(*Scope) = .empty,
    qstr_table: std.ArrayListUnmanaged(Qstr) = .empty,
    qstr_index: std.AutoHashMapUnmanaged(Qstr, u16) = .empty,
    const_obj_list: std.ArrayListUnmanaged(ConstObj) = .empty,

    pub fn init(allocator: std.mem.Allocator) EmitCommon {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *EmitCommon) void {
        self.children.deinit(self.allocator);
        self.qstr_table.deinit(self.allocator);
        self.qstr_index.deinit(self.allocator);
        self.const_obj_list.deinit(self.allocator);
    }

    /// Vendor mp_emit_common_use_qstr — dedup + return short index.
    pub fn useQstr(self: *EmitCommon, q: Qstr) std.mem.Allocator.Error!u16 {
        const gop = try self.qstr_index.getOrPut(self.allocator, q);
        if (gop.found_existing) return gop.value_ptr.*;
        const idx: u16 = @intCast(self.qstr_table.items.len);
        try self.qstr_table.append(self.allocator, q);
        gop.value_ptr.* = idx;
        return idx;
    }

    /// Vendor mp_emit_common_use_const_obj — strictly_equal dedup.
    pub fn useConstObj(
        self: *EmitCommon,
        obj: ConstObj,
    ) std.mem.Allocator.Error!u16 {
        for (self.const_obj_list.items, 0..) |existing, i| {
            if (ConstObj.strictlyEqual(existing, obj)) return @intCast(i);
        }
        const idx: u16 = @intCast(self.const_obj_list.items.len);
        try self.const_obj_list.append(self.allocator, obj);
        return idx;
    }

    /// Vendor mp_emit_common_alloc_const_child — reserve a slot for a
    /// nested function. Counter bumps across passes; same scope hits the
    /// same slot on every pass (vendor relies on this for stable
    /// indices).
    pub fn allocConstChild(
        self: *EmitCommon,
        child: *Scope,
    ) std.mem.Allocator.Error!u16 {
        const idx = self.ct_cur_child;
        self.ct_cur_child += 1;
        // children array tracks only the unique scopes seen — extend it
        // on first sighting; subsequent passes hit the same slot.
        if (idx >= self.children.items.len) {
            try self.children.append(self.allocator, child);
        } else {
            // Make sure we got the same scope back; vendor invariant.
            std.debug.assert(self.children.items[idx] == child);
        }
        return idx;
    }

    /// Reset ct_cur_child at the start of every pass so child indices
    /// remain stable across re-emits (vendor mp_emit_common_start_pass).
    pub fn startPass(self: *EmitCommon, pass: Pass) void {
        self.pass = pass;
        self.ct_cur_child = 0;
    }

    /// Vendor mp_emit_common_get_id_for_modification (emitcommon.c).
    /// Inserts qst as GLOBAL_IMPLICIT, then rebinds: LOCAL in func-like
    /// scopes, GLOBAL_IMPLICIT_ASSIGNED elsewhere.
    pub fn getIdForModification(
        scope: *Scope,
        q: Qstr,
    ) std.mem.Allocator.Error!*IdInfo {
        const id = try scope.findOrAdd(q, .global_implicit);
        if (id.kind == .global_implicit) {
            if (scope.kind.isFuncLike()) {
                id.kind = .local;
            } else {
                id.kind = .global_implicit_assigned;
            }
        }
        return id;
    }

    /// Vendor mp_emit_common_id_op. Dispatches load / store / delete via
    /// the resolved IdInfo kind.
    pub fn idOp(
        emit: *Emit,
        op: enum { load, store, delete },
        scope: *Scope,
        q: Qstr,
    ) std.mem.Allocator.Error!void {
        const id = scope.find(q) orelse {
            // Vendor asserts id != NULL here. In our error-typed flow we
            // surface a corrupted-scope condition as OutOfMemory's only
            // available channel — this should never fire in practice.
            std.debug.assert(false);
            return error.OutOfMemory;
        };

        switch (op) {
            .load => {
                if (id.kind == .global_implicit or id.kind == .global_implicit_assigned) {
                    emit.loadGlobal(q, MP_EMIT_IDOP_GLOBAL_NAME);
                } else if (id.kind == .global_explicit) {
                    emit.loadGlobal(q, MP_EMIT_IDOP_GLOBAL_GLOBAL);
                } else if (id.kind == .local) {
                    emit.loadLocal(id.local_num, MP_EMIT_IDOP_LOCAL_FAST);
                } else {
                    std.debug.assert(id.kind == .cell or id.kind == .free);
                    emit.loadLocal(id.local_num, MP_EMIT_IDOP_LOCAL_DEREF);
                }
            },
            .store => {
                if (id.kind == .global_implicit or id.kind == .global_implicit_assigned) {
                    emit.storeGlobal(q, MP_EMIT_IDOP_GLOBAL_NAME);
                } else if (id.kind == .global_explicit) {
                    emit.storeGlobal(q, MP_EMIT_IDOP_GLOBAL_GLOBAL);
                } else if (id.kind == .local) {
                    emit.storeLocal(id.local_num, MP_EMIT_IDOP_LOCAL_FAST);
                } else {
                    std.debug.assert(id.kind == .cell or id.kind == .free);
                    emit.storeLocal(id.local_num, MP_EMIT_IDOP_LOCAL_DEREF);
                }
            },
            .delete => {
                if (id.kind == .global_implicit or id.kind == .global_implicit_assigned) {
                    emit.deleteGlobal(q, MP_EMIT_IDOP_GLOBAL_NAME);
                } else if (id.kind == .global_explicit) {
                    emit.deleteGlobal(q, MP_EMIT_IDOP_GLOBAL_GLOBAL);
                } else if (id.kind == .local) {
                    emit.deleteLocal(id.local_num, MP_EMIT_IDOP_LOCAL_FAST);
                } else {
                    std.debug.assert(id.kind == .cell or id.kind == .free);
                    emit.deleteLocal(id.local_num, MP_EMIT_IDOP_LOCAL_DEREF);
                }
            },
        }
    }
};

// ─────────────────────────────────────────────────────────────────────────
// Variable-length integer encoders. Wire-byte identical to vendor
// mp_encode_uint / signed encoder in emit_write_bytecode_byte_int.
// ─────────────────────────────────────────────────────────────────────────

/// Big-endian 7-bit chunked unsigned VLI. Writes into `buf` (must hold
/// at least DUMMY_DATA_SIZE bytes) starting from the end; returns the
/// slice of bytes actually written.
pub fn encodeUint(buf: []u8, val_in: usize) []u8 {
    var val = val_in;
    std.debug.assert(buf.len >= DUMMY_DATA_SIZE);
    var tmp: [DUMMY_DATA_SIZE]u8 = undefined;
    var p: usize = tmp.len;
    p -= 1;
    tmp[p] = @intCast(val & 0x7f);
    val >>= 7;
    while (val != 0) {
        p -= 1;
        tmp[p] = @as(u8, @intCast(val & 0x7f)) | 0x80;
        val >>= 7;
    }
    const written = tmp.len - p;
    @memcpy(buf[0..written], tmp[p..]);
    return buf[0..written];
}

/// Signed VLI: same encoding as encodeUint, except the sign-extension
/// trick from vendor emitbc.c — pads with 0x7f / 0x00 if the high bit
/// would otherwise be ambiguous with the value bit. Mirrors
/// emit_write_bytecode_byte_int exactly.
pub fn encodeInt(buf: []u8, val_in: isize) []u8 {
    std.debug.assert(buf.len >= DUMMY_DATA_SIZE);
    var num = val_in;
    var tmp: [DUMMY_DATA_SIZE]u8 = undefined;
    var p: usize = tmp.len;
    while (true) {
        p -= 1;
        tmp[p] = @intCast(@as(usize, @bitCast(num)) & 0x7f);
        num >>= 7;
        if (num == 0 or num == -1) break;
    }
    if (num == -1 and (tmp[p] & 0x40) == 0) {
        p -= 1;
        tmp[p] = 0x7f;
    } else if (num == 0 and (tmp[p] & 0x40) != 0) {
        p -= 1;
        tmp[p] = 0;
    }
    // Bytes are stored with high-bit continuation marker; only the last
    // (least-significant) byte gets bit 7 clear.
    var i: usize = p;
    var oi: usize = 0;
    while (i != tmp.len - 1) : (i += 1) {
        buf[oi] = tmp[i] | 0x80;
        oi += 1;
    }
    buf[oi] = tmp[i];
    oi += 1;
    return buf[0..oi];
}

// ─────────────────────────────────────────────────────────────────────────
// Emit — per-scope bytecode emitter state.
//
// One Emit instance per scope, reused across all passes. dummy_data is
// scratch used by size-only passes and suppressed writes (after
// unconditional control flow). The same Emit is driven SCOPE →
// STACK_SIZE → CODE_SIZE → EMIT (with EMIT possibly re-running if sizes
// changed).
// ─────────────────────────────────────────────────────────────────────────

pub const Emit = struct {
    allocator: std.mem.Allocator,
    emit_common: *EmitCommon,
    scope: ?*Scope = null,
    pass: Pass = .scope,

    suppress: bool = false,
    stack_size: i32 = 0,

    dummy_data: [DUMMY_DATA_SIZE]u8 = [_]u8{0} ** DUMMY_DATA_SIZE,
    label_offsets: []usize = &.{},
    max_num_labels: usize = 0,

    code_info_offset: usize = 0,
    code_info_size: usize = 0,
    bytecode_offset: usize = 0,
    bytecode_size: usize = 0,
    /// Owns the contiguous [code_info | bytecode] buffer once EMIT pass
    /// allocates it. Length = code_info_size + bytecode_size.
    code_base: []u8 = &.{},

    overflow: bool = false,
    n_info: usize = 0,
    n_cell: usize = 0,

    pub fn init(allocator: std.mem.Allocator, ec: *EmitCommon) Emit {
        return .{ .allocator = allocator, .emit_common = ec };
    }

    pub fn deinit(self: *Emit) void {
        if (self.label_offsets.len != 0) self.allocator.free(self.label_offsets);
        if (self.code_base.len != 0) self.allocator.free(self.code_base);
    }

    /// Reserve label_offsets storage. Vendor m_malloc(0) returns NULL;
    /// we leave the slice empty for max_num_labels==0 (never deref'd
    /// because no label-emit fires).
    pub fn setMaxNumLabels(
        self: *Emit,
        n: usize,
    ) std.mem.Allocator.Error!void {
        self.max_num_labels = n;
        if (n == 0) return;
        self.label_offsets = try self.allocator.alloc(usize, n);
        @memset(self.label_offsets, 0);
    }

    /// Start a pass. Resets per-pass state and emits the prelude
    /// (signature + size encoding from CODE_SIZE onward) plus the
    /// simple_name and parameter-name qstrs into code_info.
    pub fn startPass(
        self: *Emit,
        pass: Pass,
        scope: *Scope,
    ) std.mem.Allocator.Error!void {
        self.pass = pass;
        self.stack_size = 0;
        self.suppress = false;
        self.scope = scope;
        self.bytecode_offset = 0;
        self.code_info_offset = 0;
        self.overflow = false;

        // Vendor: n_state = num_locals + stack_size (or 1 if zero).
        var n_state: usize = @as(usize, scope.num_locals) + scope.stack_size;
        if (n_state == 0) n_state = 1;
        const n_exc_stack: usize = scope.exc_stack_size;
        preludeSigEncode(self, n_state, n_exc_stack, scope);

        if (@intFromEnum(self.pass) >= @intFromEnum(Pass.code_size)) {
            preludeSizeEncode(self, self.n_info, self.n_cell);
        }

        // After the size prelude, the code_info_offset points at where
        // n_info will start measuring from.
        self.n_info = self.code_info_offset;

        writeCodeInfoQstr(self, scope.simple_name);

        // Parameter-name qstrs. For each i in [0, num_pos_args +
        // num_kwonly_args), find the IdInfo with IS_PARAM flag and
        // local_num == i; emit its qst (or MP_QSTR__star_ as a
        // placeholder if not found).
        var i: u16 = 0;
        const total = scope.num_pos_args + scope.num_kwonly_args;
        while (i < total) : (i += 1) {
            var q: Qstr = MP_QSTR__star_;
            for (scope.id_info.items) |info| {
                if ((info.flags & scope_mod.ID_FLAG_IS_PARAM) != 0 and
                    info.local_num == i)
                {
                    q = info.qst;
                    break;
                }
            }
            writeCodeInfoQstr(self, q);
        }
    }

    /// End a pass. Returns true on success; false if the EMIT pass
    /// observed a size shift (caller must re-run EMIT).
    ///
    /// On CODE_SIZE: allocates code_base = code_info_size +
    /// bytecode_size bytes (zero-initialised, matches vendor m_malloc0).
    /// On EMIT: detects size drift, raises overflow if a label outgrew
    /// its compact encoding, and finalises. (We don't perform the
    /// raw_code wiring here — that's C7's compile.zig driver.)
    pub fn endPass(self: *Emit) std.mem.Allocator.Error!bool {
        if (self.pass == .scope) return true;

        self.n_info = self.code_info_offset - self.n_info;

        self.n_cell = 0;
        const scope = self.scope.?;
        for (scope.id_info.items) |info| {
            if (info.kind == .cell) {
                writeCodeInfoByte(self, @intCast(info.local_num));
                self.n_cell += 1;
            }
        }

        if (self.pass == .code_size) {
            self.code_info_size = self.code_info_offset;
            self.bytecode_size = self.bytecode_offset;
            const total = self.code_info_size + self.bytecode_size;
            if (self.code_base.len != 0) self.allocator.free(self.code_base);
            self.code_base = try self.allocator.alloc(u8, total);
            @memset(self.code_base, 0);
        } else if (self.pass == .emit) {
            if (self.code_info_offset != self.code_info_size or
                self.bytecode_offset != self.bytecode_size)
            {
                self.code_info_size = self.code_info_offset;
                self.bytecode_size = self.bytecode_offset;
                return false;
            }
            // overflow surfacing — caller decides what to do. Vendor
            // longjmps; we expose the flag via emit.overflow for C7 to
            // turn into the right Python-level error.
        }
        return true;
    }

    /// Vendor mp_emit_bc_adjust_stack_size — public API for compile.zig.
    pub fn adjustStackSize(self: *Emit, delta: i32) void {
        adjustStack(self, delta);
    }

    /// Source-line tracking is disabled in nano config (ENABLE_SOURCE_LINE
    /// = 0). Kept on the API surface so compile.zig (C7) doesn't need
    /// source-line-aware branches.
    pub fn setSourceLine(self: *Emit, line: usize) void {
        _ = self;
        _ = line;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Opcode emitters — verbatim port of vendor emitbc.zig.
    // Each writes bytes, possibly adjusts stack, possibly toggles
    // suppress (after unconditional control flow).
    // ─────────────────────────────────────────────────────────────────────

    pub fn labelAssign(self: *Emit, label: usize) void {
        self.suppress = false;
        if (self.pass == .scope) return;
        self.label_offsets[label] = self.bytecode_offset;
    }

    pub fn import(self: *Emit, q: Qstr, kind: u8) void {
        const stack_adj: i32 = if (kind == MP_EMIT_IMPORT_FROM) 1 else -1;
        if (kind == MP_EMIT_IMPORT_STAR) {
            writeBytecodeByte(self, stack_adj, MP_BC_IMPORT_STAR);
        } else {
            writeBytecodeByteQstr(self, stack_adj, MP_BC_IMPORT_NAME + kind, q);
        }
    }

    pub fn loadConstTok(self: *Emit, tok: u8) void {
        if (tok == MP_TOKEN_ELLIPSIS) {
            // Vendor uses LOAD_CONST_OBJ + mp_const_ellipsis_obj. We
            // route through the const-obj table with a dedicated
            // ConstObj.ellipsis value.
            writeBytecodeByteObj(self, 1, MP_BC_LOAD_CONST_OBJ, .ellipsis);
        } else {
            // FALSE/NONE/TRUE map to the contiguous LOAD_CONST_FALSE+N.
            writeBytecodeByte(
                self,
                1,
                MP_BC_LOAD_CONST_FALSE + (tok - MP_TOKEN_KW_FALSE),
            );
        }
    }

    pub fn loadConstSmallInt(self: *Emit, arg: isize) void {
        if (-MP_BC_LOAD_CONST_SMALL_INT_MULTI_EXCESS <= arg and
            arg < MP_BC_LOAD_CONST_SMALL_INT_MULTI_NUM -
                MP_BC_LOAD_CONST_SMALL_INT_MULTI_EXCESS)
        {
            const opcode_val: isize = @as(isize, MP_BC_LOAD_CONST_SMALL_INT_MULTI) +
                MP_BC_LOAD_CONST_SMALL_INT_MULTI_EXCESS + arg;
            writeBytecodeByte(self, 1, @intCast(opcode_val));
        } else {
            writeBytecodeByteInt(self, 1, MP_BC_LOAD_CONST_SMALL_INT, arg);
        }
    }

    pub fn loadConstStr(self: *Emit, q: Qstr) void {
        writeBytecodeByteQstr(self, 1, MP_BC_LOAD_CONST_STRING, q);
    }

    pub fn loadConstObj(
        self: *Emit,
        obj: ConstObj,
    ) std.mem.Allocator.Error!void {
        try writeBytecodeByteObjErr(self, 1, MP_BC_LOAD_CONST_OBJ, obj);
    }

    pub fn loadNull(self: *Emit) void {
        writeBytecodeByte(self, 1, MP_BC_LOAD_NULL);
    }

    pub fn loadLocal(self: *Emit, local_num: u16, kind: u8) void {
        if (kind == MP_EMIT_IDOP_LOCAL_FAST and local_num <= 15) {
            writeBytecodeByte(self, 1, MP_BC_LOAD_FAST_MULTI + @as(u8, @intCast(local_num)));
        } else {
            writeBytecodeByteUint(self, 1, MP_BC_LOAD_FAST_N + kind, local_num);
        }
    }

    pub fn loadGlobal(self: *Emit, q: Qstr, kind: u8) void {
        writeBytecodeByteQstr(self, 1, MP_BC_LOAD_NAME + kind, q);
    }

    pub fn loadMethod(self: *Emit, q: Qstr, is_super: bool) void {
        const stack_adj: i32 = 1 - 2 * @as(i32, @intFromBool(is_super));
        const op: u8 = if (is_super) MP_BC_LOAD_SUPER_METHOD else MP_BC_LOAD_METHOD;
        writeBytecodeByteQstr(self, stack_adj, op, q);
    }

    pub fn loadBuildClass(self: *Emit) void {
        writeBytecodeByte(self, 1, MP_BC_LOAD_BUILD_CLASS);
    }

    pub fn subscr(self: *Emit, kind: u8) void {
        if (kind == MP_EMIT_SUBSCR_LOAD) {
            writeBytecodeByte(self, -1, MP_BC_LOAD_SUBSCR);
        } else {
            if (kind == MP_EMIT_SUBSCR_DELETE) {
                self.loadNull();
                self.rotThree();
            }
            writeBytecodeByte(self, -3, MP_BC_STORE_SUBSCR);
        }
    }

    pub fn attr(self: *Emit, q: Qstr, kind: u8) void {
        if (kind == MP_EMIT_ATTR_LOAD) {
            writeBytecodeByteQstr(self, 0, MP_BC_LOAD_ATTR, q);
        } else {
            if (kind == MP_EMIT_ATTR_DELETE) {
                self.loadNull();
                self.rotTwo();
            }
            writeBytecodeByteQstr(self, -2, MP_BC_STORE_ATTR, q);
        }
    }

    pub fn storeLocal(self: *Emit, local_num: u16, kind: u8) void {
        if (kind == MP_EMIT_IDOP_LOCAL_FAST and local_num <= 15) {
            writeBytecodeByte(self, -1, MP_BC_STORE_FAST_MULTI + @as(u8, @intCast(local_num)));
        } else {
            writeBytecodeByteUint(self, -1, MP_BC_STORE_FAST_N + kind, local_num);
        }
    }

    pub fn storeGlobal(self: *Emit, q: Qstr, kind: u8) void {
        writeBytecodeByteQstr(self, -1, MP_BC_STORE_NAME + kind, q);
    }

    pub fn deleteLocal(self: *Emit, local_num: u16, kind: u8) void {
        writeBytecodeByteUint(self, 0, MP_BC_DELETE_FAST + kind, local_num);
    }

    pub fn deleteGlobal(self: *Emit, q: Qstr, kind: u8) void {
        writeBytecodeByteQstr(self, 0, MP_BC_DELETE_NAME + kind, q);
    }

    pub fn dupTop(self: *Emit) void {
        writeBytecodeByte(self, 1, MP_BC_DUP_TOP);
    }

    pub fn dupTopTwo(self: *Emit) void {
        writeBytecodeByte(self, 2, MP_BC_DUP_TOP_TWO);
    }

    pub fn popTop(self: *Emit) void {
        writeBytecodeByte(self, -1, MP_BC_POP_TOP);
    }

    pub fn rotTwo(self: *Emit) void {
        writeBytecodeByte(self, 0, MP_BC_ROT_TWO);
    }

    pub fn rotThree(self: *Emit) void {
        writeBytecodeByte(self, 0, MP_BC_ROT_THREE);
    }

    pub fn jump(self: *Emit, label: usize) void {
        writeBytecodeByteLabel(self, 0, MP_BC_JUMP, label);
        self.suppress = true;
    }

    pub fn popJumpIf(self: *Emit, cond: bool, label: usize) void {
        const op: u8 = if (cond) MP_BC_POP_JUMP_IF_TRUE else MP_BC_POP_JUMP_IF_FALSE;
        writeBytecodeByteLabel(self, -1, op, label);
    }

    pub fn jumpIfOrPop(self: *Emit, cond: bool, label: usize) void {
        const op: u8 = if (cond) MP_BC_JUMP_IF_TRUE_OR_POP else MP_BC_JUMP_IF_FALSE_OR_POP;
        writeBytecodeByteLabel(self, -1, op, label);
    }

    pub fn unwindJump(self: *Emit, label: usize, except_depth: usize) void {
        const BREAK = MP_EMIT_BREAK_FROM_FOR;
        if (except_depth == 0) {
            if ((label & BREAK) != 0) {
                // Pop the iterator's stack slots before jumping.
                writeBytecodeRawByte(self, MP_BC_POP_TOP);
                var i: usize = 0;
                while (i < MP_OBJ_ITER_BUF_NSLOTS - 1) : (i += 1) {
                    writeBytecodeRawByte(self, MP_BC_POP_TOP);
                }
            }
            writeBytecodeByteLabel(self, 0, MP_BC_JUMP, label & ~BREAK);
        } else {
            writeBytecodeByteLabel(self, 0, MP_BC_UNWIND_JUMP, label & ~BREAK);
            const extra: u8 = @intCast(
                (if ((label & BREAK) != 0) @as(usize, 0x80) else 0) | except_depth,
            );
            writeBytecodeRawByte(self, extra);
        }
        self.suppress = true;
    }

    pub fn setupBlock(self: *Emit, label: usize, kind: u8) void {
        const stack_adj: i32 = if (kind == MP_EMIT_SETUP_BLOCK_WITH) 2 else 0;
        writeBytecodeByteLabel(self, stack_adj, MP_BC_SETUP_WITH + kind, label);
    }

    pub fn withCleanup(self: *Emit, label: usize) void {
        self.loadConstTok(MP_TOKEN_KW_NONE);
        self.labelAssign(label);
        writeBytecodeByte(self, 2, MP_BC_WITH_CLEANUP);
        adjustStack(self, -4);
    }

    pub fn endFinally(self: *Emit) void {
        writeBytecodeByte(self, -1, MP_BC_END_FINALLY);
    }

    pub fn getIter(self: *Emit, use_stack: bool) void {
        const stack_adj: i32 = if (use_stack)
            @as(i32, @intCast(MP_OBJ_ITER_BUF_NSLOTS)) - 1
        else
            0;
        const op: u8 = if (use_stack) MP_BC_GET_ITER_STACK else MP_BC_GET_ITER;
        writeBytecodeByte(self, stack_adj, op);
    }

    pub fn forIter(self: *Emit, label: usize) void {
        writeBytecodeByteLabel(self, 1, MP_BC_FOR_ITER, label);
    }

    pub fn forIterEnd(self: *Emit) void {
        adjustStack(self, -@as(i32, @intCast(MP_OBJ_ITER_BUF_NSLOTS)));
    }

    pub fn popExceptJump(self: *Emit, label: usize) void {
        writeBytecodeByteLabel(self, 0, MP_BC_POP_EXCEPT_JUMP, label);
        self.suppress = true;
    }

    pub fn startExceptHandler(self: *Emit) void {
        adjustStack(self, 4);
    }

    pub fn endExceptHandler(self: *Emit) void {
        adjustStack(self, -3);
    }

    pub fn unaryOp(self: *Emit, op: u8) void {
        writeBytecodeByte(self, 0, MP_BC_UNARY_OP_MULTI + op);
    }

    pub fn binaryOp(self: *Emit, op_in: u8) void {
        var op = op_in;
        var invert = false;
        if (op == MP_BINARY_OP_NOT_IN) {
            invert = true;
            op = MP_BINARY_OP_IN;
        } else if (op == MP_BINARY_OP_IS_NOT) {
            invert = true;
            op = MP_BINARY_OP_IS;
        }
        writeBytecodeByte(self, -1, MP_BC_BINARY_OP_MULTI + op);
        if (invert) {
            writeBytecodeByte(self, 0, MP_BC_UNARY_OP_MULTI + MP_UNARY_OP_NOT);
        }
    }

    pub fn build(self: *Emit, n_args: usize, kind: u8) void {
        const stack_adj: i32 = if (kind == MP_EMIT_BUILD_MAP)
            1
        else
            1 - @as(i32, @intCast(n_args));
        writeBytecodeByteUint(self, stack_adj, MP_BC_BUILD_TUPLE + kind, n_args);
    }

    pub fn storeMap(self: *Emit) void {
        writeBytecodeByte(self, -2, MP_BC_STORE_MAP);
    }

    pub fn storeComp(
        self: *Emit,
        scope_kind: ScopeKind,
        collection_stack_index: usize,
    ) void {
        // LIST_COMP -> t=0; DICT_COMP -> t=1; SET_COMP -> t=2.
        var t: u8 = 0;
        var n: i32 = 0;
        switch (scope_kind) {
            .list_comp => {
                n = 0;
                t = 0;
            },
            .dict_comp => {
                n = 1;
                t = 1;
            },
            .set_comp => {
                n = 0;
                t = 2;
            },
            else => unreachable,
        }
        const arg: usize =
            ((collection_stack_index + @as(usize, @intCast(n))) << 2) | @as(usize, t);
        writeBytecodeByteUint(self, -1 - n, MP_BC_STORE_COMP, arg);
    }

    pub fn unpackSequence(self: *Emit, n_args: usize) void {
        writeBytecodeByteUint(
            self,
            -1 + @as(i32, @intCast(n_args)),
            MP_BC_UNPACK_SEQUENCE,
            n_args,
        );
    }

    pub fn unpackEx(self: *Emit, n_left: usize, n_right: usize) void {
        writeBytecodeByteUint(
            self,
            -1 + @as(i32, @intCast(n_left)) + @as(i32, @intCast(n_right)) + 1,
            MP_BC_UNPACK_EX,
            n_left | (n_right << 8),
        );
    }

    pub fn makeFunction(
        self: *Emit,
        child: *Scope,
        n_pos_def: usize,
        n_kw_def: usize,
    ) std.mem.Allocator.Error!void {
        if (n_pos_def == 0 and n_kw_def == 0) {
            try writeBytecodeByteChild(self, 1, MP_BC_MAKE_FUNCTION, child);
        } else {
            try writeBytecodeByteChild(self, -1, MP_BC_MAKE_FUNCTION_DEFARGS, child);
        }
    }

    pub fn makeClosure(
        self: *Emit,
        child: *Scope,
        n_closed_over: u8,
        n_pos_def: usize,
        n_kw_def: usize,
    ) std.mem.Allocator.Error!void {
        if (n_pos_def == 0 and n_kw_def == 0) {
            const stack_adj: i32 = -@as(i32, n_closed_over) + 1;
            try writeBytecodeByteChild(self, stack_adj, MP_BC_MAKE_CLOSURE, child);
            writeBytecodeRawByte(self, n_closed_over);
        } else {
            const stack_adj: i32 = -2 - @as(i32, n_closed_over) + 1;
            try writeBytecodeByteChild(
                self,
                stack_adj,
                MP_BC_MAKE_CLOSURE_DEFARGS,
                child,
            );
            writeBytecodeRawByte(self, n_closed_over);
        }
    }

    pub fn callFunction(
        self: *Emit,
        n_pos: usize,
        n_kw: usize,
        star_flags: u8,
    ) void {
        callHelper(self, 0, MP_BC_CALL_FUNCTION, n_pos, n_kw, star_flags);
    }

    pub fn callMethod(
        self: *Emit,
        n_pos: usize,
        n_kw: usize,
        star_flags: u8,
    ) void {
        callHelper(self, -1, MP_BC_CALL_METHOD, n_pos, n_kw, star_flags);
    }

    pub fn returnValue(self: *Emit) void {
        writeBytecodeByte(self, -1, MP_BC_RETURN_VALUE);
        self.suppress = true;
    }

    pub fn raiseVarargs(self: *Emit, n_args: u8) void {
        writeBytecodeByte(
            self,
            -@as(i32, n_args),
            MP_BC_RAISE_LAST + n_args,
        );
        self.suppress = true;
    }

    pub fn yield(self: *Emit, kind: u8) void {
        writeBytecodeByte(self, -@as(i32, kind), MP_BC_YIELD_VALUE + kind);
        self.scope.?.scope_flags |= scope_mod.SCOPE_FLAG_GENERATOR;
    }
};

// ─────────────────────────────────────────────────────────────────────────
// Buffer writers (file-scope, take *Emit) — vendor emitbc.c equivalents.
// ─────────────────────────────────────────────────────────────────────────

fn getCurToWriteCodeInfo(emit: *Emit, num: usize) []u8 {
    if (@intFromEnum(emit.pass) < @intFromEnum(Pass.emit)) {
        emit.code_info_offset += num;
        return emit.dummy_data[0..num];
    }
    const start = emit.code_info_offset;
    emit.code_info_offset += num;
    return emit.code_base[start .. start + num];
}

fn writeCodeInfoByte(emit: *Emit, b: u8) void {
    const slot = getCurToWriteCodeInfo(emit, 1);
    slot[0] = b;
}

fn writeCodeInfoUint(emit: *Emit, val: usize) void {
    var buf: [DUMMY_DATA_SIZE]u8 = undefined;
    const enc = encodeUint(buf[0..], val);
    const slot = getCurToWriteCodeInfo(emit, enc.len);
    @memcpy(slot, enc);
}

fn writeCodeInfoQstr(emit: *Emit, q: Qstr) void {
    const short_idx = emit.emit_common.useQstr(q) catch return;
    writeCodeInfoUint(emit, short_idx);
}

fn getCurToWriteBytecode(emit: *Emit, num: usize) []u8 {
    if (emit.suppress) return emit.dummy_data[0..num];
    if (@intFromEnum(emit.pass) < @intFromEnum(Pass.emit)) {
        emit.bytecode_offset += num;
        return emit.dummy_data[0..num];
    }
    const start = emit.code_info_size + emit.bytecode_offset;
    emit.bytecode_offset += num;
    return emit.code_base[start .. start + num];
}

fn adjustStack(emit: *Emit, delta: i32) void {
    if (emit.pass == .scope) return;
    emit.stack_size += delta;
    const sc = emit.scope.?;
    if (emit.stack_size > sc.stack_size) {
        // Vendor narrowing: scope.stack_size is u16. We clamp during the
        // STACK_SIZE pass; downstream passes only read it.
        sc.stack_size = @intCast(emit.stack_size);
    }
}

fn writeBytecodeRawByte(emit: *Emit, b: u8) void {
    const slot = getCurToWriteBytecode(emit, 1);
    slot[0] = b;
}

fn writeBytecodeByte(emit: *Emit, stack_adj: i32, b: u8) void {
    adjustStack(emit, stack_adj);
    const slot = getCurToWriteBytecode(emit, 1);
    slot[0] = b;
}

fn writeBytecodeByteInt(
    emit: *Emit,
    stack_adj: i32,
    b: u8,
    val: isize,
) void {
    writeBytecodeByte(emit, stack_adj, b);
    var buf: [DUMMY_DATA_SIZE]u8 = undefined;
    const enc = encodeInt(buf[0..], val);
    const slot = getCurToWriteBytecode(emit, enc.len);
    @memcpy(slot, enc);
}

fn writeBytecodeUintRaw(emit: *Emit, val: usize) void {
    var buf: [DUMMY_DATA_SIZE]u8 = undefined;
    const enc = encodeUint(buf[0..], val);
    const slot = getCurToWriteBytecode(emit, enc.len);
    @memcpy(slot, enc);
}

fn writeBytecodeByteUint(
    emit: *Emit,
    stack_adj: i32,
    b: u8,
    val: usize,
) void {
    writeBytecodeByte(emit, stack_adj, b);
    writeBytecodeUintRaw(emit, val);
}

fn writeBytecodeByteQstr(
    emit: *Emit,
    stack_adj: i32,
    b: u8,
    q: Qstr,
) void {
    const short_idx = emit.emit_common.useQstr(q) catch {
        // OOM during a pass — surface as overflow so the driver can
        // recover. Better than dropping the byte silently.
        emit.overflow = true;
        writeBytecodeByte(emit, stack_adj, b);
        writeBytecodeUintRaw(emit, 0);
        return;
    };
    writeBytecodeByteUint(emit, stack_adj, b, short_idx);
}

fn writeBytecodeByteObjErr(
    emit: *Emit,
    stack_adj: i32,
    b: u8,
    obj: ConstObj,
) std.mem.Allocator.Error!void {
    const idx = try emit.emit_common.useConstObj(obj);
    writeBytecodeByteUint(emit, stack_adj, b, idx);
}

fn writeBytecodeByteObj(
    emit: *Emit,
    stack_adj: i32,
    b: u8,
    obj: ConstObj,
) void {
    writeBytecodeByteObjErr(emit, stack_adj, b, obj) catch {
        emit.overflow = true;
    };
}

fn writeBytecodeByteChild(
    emit: *Emit,
    stack_adj: i32,
    b: u8,
    child: *Scope,
) std.mem.Allocator.Error!void {
    const idx = try emit.emit_common.allocConstChild(child);
    writeBytecodeByteUint(emit, stack_adj, b, idx);
}

fn writeBytecodeByteLabel(
    emit: *Emit,
    stack_adj: i32,
    b1: u8,
    label: usize,
) void {
    adjustStack(emit, stack_adj);
    if (emit.suppress) return;

    const is_signed = b1 <= MP_BC_POP_JUMP_IF_FALSE;
    var jump_encoding_size: isize = 1;
    var bytecode_offset: isize = 0;

    if (@intFromEnum(emit.pass) >= @intFromEnum(Pass.code_size)) {
        bytecode_offset = @as(isize, @intCast(emit.label_offsets[label])) -
            @as(isize, @intCast(emit.bytecode_offset)) - 2;
        if ((is_signed and -64 <= bytecode_offset and bytecode_offset <= 63) or
            (!is_signed and bytecode_offset >= 0 and bytecode_offset <= 127))
        {
            jump_encoding_size = 0;
        }
        bytecode_offset -= jump_encoding_size;
    }

    const total: usize = @intCast(2 + jump_encoding_size);
    const cp = getCurToWriteBytecode(emit, total);
    cp[0] = b1;
    if (jump_encoding_size == 0) {
        if (is_signed) bytecode_offset += 0x40;
        cp[1] = @intCast(bytecode_offset & 0xff);
    } else {
        if (is_signed) bytecode_offset += 0x4000;
        if (emit.pass == .emit and
            !(0 <= bytecode_offset and bytecode_offset <= 0x7fff))
        {
            emit.overflow = true;
        }
        cp[1] = @intCast(0x80 | (@as(usize, @bitCast(bytecode_offset)) & 0x7f));
        cp[2] = @intCast(@as(usize, @bitCast(bytecode_offset)) >> 7 & 0xff);
    }
}

fn callHelper(
    emit: *Emit,
    stack_adj_in: i32,
    bytecode_base: u8,
    n_positional: usize,
    n_keyword: usize,
    star_flags: u8,
) void {
    var stack_adj = stack_adj_in;
    if (star_flags != 0) {
        stack_adj -=
            @as(i32, @intCast(n_positional)) +
            2 * @as(i32, @intCast(n_keyword)) + 1;
        writeBytecodeByteUint(
            emit,
            stack_adj,
            bytecode_base + 1,
            (n_keyword << 8) | n_positional,
        );
    } else {
        stack_adj -=
            @as(i32, @intCast(n_positional)) +
            2 * @as(i32, @intCast(n_keyword));
        writeBytecodeByteUint(
            emit,
            stack_adj,
            bytecode_base,
            (n_keyword << 8) | n_positional,
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Prelude bit-packing — verbatim port of py/bc.h MP_BC_PRELUDE_SIG_ENCODE
// and MP_BC_PRELUDE_SIZE_ENCODE.
// ─────────────────────────────────────────────────────────────────────────

fn preludeSigEncode(
    emit: *Emit,
    s_in: usize,
    e_in: usize,
    scope: *Scope,
) void {
    var f: usize = scope.scope_flags & scope_mod.SCOPE_FLAG_ALL_SIG;
    var a: usize = scope.num_pos_args;
    var k: usize = scope.num_kwonly_args;
    var d: usize = scope.num_def_pos_args;
    var s = s_in - 1;
    var e = e_in;
    var z: u8 = @intCast(((s & 0xf) << 3) | ((e & 1) << 2) | (a & 3));
    s >>= 4;
    e >>= 1;
    a >>= 2;
    while ((s | e | f | a | k | d) != 0) {
        writeCodeInfoByte(emit, 0x80 | z);
        z = @intCast(
            ((f & 1) << 6) | ((s & 3) << 4) | ((k & 1) << 3) |
                ((a & 1) << 2) | ((e & 1) << 1) | (d & 1),
        );
        s >>= 2;
        e >>= 1;
        f >>= 1;
        a >>= 1;
        k >>= 1;
        d >>= 1;
    }
    writeCodeInfoByte(emit, z);
}

fn preludeSizeEncode(emit: *Emit, i_in: usize, cc_in: usize) void {
    var i = i_in;
    var cc = cc_in;
    var z: u8 = 0;
    while (true) {
        z = @intCast(((i & 0x3f) << 1) | (cc & 1));
        cc >>= 1;
        i >>= 6;
        if ((cc | i) != 0) z |= 0x80;
        writeCodeInfoByte(emit, z);
        if ((cc | i) == 0) break;
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Driver helpers — run the 3-pass loop, package the result for the writer.
//
// C7's compile.zig wraps these to walk the parse tree depth-first, then
// stitch the resulting RawCodes into mpy.zig's serialization layer.
// ─────────────────────────────────────────────────────────────────────────

/// Run SCOPE → STACK_SIZE → CODE_SIZE → EMIT (re-loop EMIT if sizes
/// shifted). `emit_body` is the per-scope walker that issues the
/// Emit.* opcode calls. On success returns the finalized code_base
/// slice (borrowed from Emit) and the number of children allocated.
pub fn compileScope(
    emit: *Emit,
    scope: *Scope,
    emit_body: *const fn (*Emit, *Scope) anyerror!void,
) anyerror!struct { code: []const u8, n_children: u16 } {
    inline for (.{ Pass.scope, Pass.stack_size, Pass.code_size }) |p| {
        emit.emit_common.startPass(p);
        try emit.startPass(p, scope);
        try emit_body(emit, scope);
        _ = try emit.endPass();
    }
    // EMIT may need re-running if sizes shifted.
    while (true) {
        emit.emit_common.startPass(.emit);
        try emit.startPass(.emit, scope);
        try emit_body(emit, scope);
        if (try emit.endPass()) break;
    }
    // Vendor emitbc.c:404-411 — mp_emit_glue_assign_bytecode is called
    // with bytecode_len = code_info_size + bytecode_size (the FINAL
    // EMIT-pass sizes). If EMIT shrank below CODE_SIZE's estimate (e.g.
    // a jump that CODE_SIZE encoded as 2 bytes resolved to 1 in EMIT),
    // the code_base buffer is still the larger CODE_SIZE allocation
    // with trailing zero-init bytes. Slice to the actual used length
    // so the .mpy doesn't carry a phantom trailing 0x00.
    const used: usize = @as(usize, emit.code_info_size) + @as(usize, emit.bytecode_size);
    return .{
        .code = emit.code_base[0..used],
        .n_children = emit.emit_common.ct_cur_child,
    };
}

/// Wrap an Emit's finalized state into an mpy.RawCode. `children` are
/// shallow — populate them recursively from outside. Kind is fixed to
/// 0 = BYTECODE (vendor MP_CODE_BYTECODE - MP_CODE_BYTECODE).
pub fn toMpyRawCode(
    code: []const u8,
    children: []const mpy.RawCode,
) mpy.RawCode {
    return .{ .kind = 0, .fun_data = code, .children = children };
}

// ─────────────────────────────────────────────────────────────────────────
// Unit tests — guard the algorithmic core; full corpus diff is C7.
// ─────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "encodeUint: small and multi-byte boundaries" {
    var buf: [DUMMY_DATA_SIZE]u8 = undefined;

    // 0 → single byte 0x00
    try testing.expectEqualSlices(u8, &.{0x00}, encodeUint(buf[0..], 0));
    // 127 → single byte 0x7f
    try testing.expectEqualSlices(u8, &.{0x7f}, encodeUint(buf[0..], 127));
    // 128 → 0x81 0x00 (big-endian 7-bit chunks: 1, 0)
    try testing.expectEqualSlices(u8, &.{ 0x81, 0x00 }, encodeUint(buf[0..], 128));
    // 16383 (== 0x3fff) → 0xff 0x7f
    try testing.expectEqualSlices(u8, &.{ 0xff, 0x7f }, encodeUint(buf[0..], 16383));
    // 16384 (== 0x4000) → 0x81 0x80 0x00
    try testing.expectEqualSlices(u8, &.{ 0x81, 0x80, 0x00 }, encodeUint(buf[0..], 16384));
}

test "encodeInt: small positive single byte" {
    var buf: [DUMMY_DATA_SIZE]u8 = undefined;
    // 0 → 0x00 (single byte, high bit clear, sign bit 0x40 also clear → no padding)
    try testing.expectEqualSlices(u8, &.{0x00}, encodeInt(buf[0..], 0));
    // -1 → 0x7f (all-ones, single byte; num shifts to -1, byte bit 0x40 is set → no extra pad)
    try testing.expectEqualSlices(u8, &.{0x7f}, encodeInt(buf[0..], -1));
}

test "ConstObj.strictlyEqual: type mismatch + tuple recursion" {
    // True != 1 (different union tags, even if both "truthy").
    try testing.expect(!ConstObj.strictlyEqual(.bool_true, .{ .int_big = "1" }));
    try testing.expect(ConstObj.strictlyEqual(.bool_true, .bool_true));
    try testing.expect(!ConstObj.strictlyEqual(.bool_true, .bool_false));

    // Floats: "0.0" vs "-0.0" → text differs → not equal (preserves ±0).
    try testing.expect(!ConstObj.strictlyEqual(
        .{ .float = "0.0" },
        .{ .float = "-0.0" },
    ));
    try testing.expect(ConstObj.strictlyEqual(
        .{ .float = "0.0" },
        .{ .float = "0.0" },
    ));

    // Tuple recursion + nested element comparison.
    const inner_a = [_]ConstObj{ .bool_true, .{ .str = "x" } };
    const inner_b = [_]ConstObj{ .bool_true, .{ .str = "x" } };
    const inner_c = [_]ConstObj{ .bool_true, .{ .str = "y" } };
    try testing.expect(ConstObj.strictlyEqual(
        .{ .tuple = &inner_a },
        .{ .tuple = &inner_b },
    ));
    try testing.expect(!ConstObj.strictlyEqual(
        .{ .tuple = &inner_a },
        .{ .tuple = &inner_c },
    ));
}

test "EmitCommon.useQstr: dedup + stable index" {
    var ec = EmitCommon.init(testing.allocator);
    defer ec.deinit();

    const idx0 = try ec.useQstr(100);
    const idx1 = try ec.useQstr(200);
    const idx0b = try ec.useQstr(100);
    try testing.expectEqual(@as(u16, 0), idx0);
    try testing.expectEqual(@as(u16, 1), idx1);
    try testing.expectEqual(@as(u16, 0), idx0b);
    try testing.expectEqual(@as(usize, 2), ec.qstr_table.items.len);
}

test "EmitCommon.useConstObj: insertion order preserved on dup" {
    var ec = EmitCommon.init(testing.allocator);
    defer ec.deinit();

    const idx0 = try ec.useConstObj(.{ .str = "hello" });
    const idx1 = try ec.useConstObj(.bool_true);
    const idx0b = try ec.useConstObj(.{ .str = "hello" });
    try testing.expectEqual(@as(u16, 0), idx0);
    try testing.expectEqual(@as(u16, 1), idx1);
    try testing.expectEqual(@as(u16, 0), idx0b);
    try testing.expectEqual(@as(usize, 2), ec.const_obj_list.items.len);
}

test "EmitCommon.allocConstChild: counter + stable across passes" {
    const parser = @import("parser.zig");
    var ec = EmitCommon.init(testing.allocator);
    defer ec.deinit();

    const s1 = try Scope.new(testing.allocator, .module, parser.PN_NULL, 0);
    defer s1.destroy();
    const s2 = try Scope.new(testing.allocator, .module, parser.PN_NULL, 0);
    defer s2.destroy();

    // First pass: two distinct children.
    ec.startPass(.scope);
    try testing.expectEqual(@as(u16, 0), try ec.allocConstChild(s1));
    try testing.expectEqual(@as(u16, 1), try ec.allocConstChild(s2));
    try testing.expectEqual(@as(usize, 2), ec.children.items.len);

    // Second pass: counter resets; same scopes hit the same slots
    // (vendor invariant — the assert in allocConstChild fires otherwise).
    ec.startPass(.code_size);
    try testing.expectEqual(@as(u16, 0), try ec.allocConstChild(s1));
    try testing.expectEqual(@as(u16, 1), try ec.allocConstChild(s2));
    try testing.expectEqual(@as(usize, 2), ec.children.items.len);
}

// Test scaffolding: a minimal Scope built without parser machinery for
// driving Emit.startPass / endPass. We feed zero counts everywhere so
// the prelude_sig_encode loop terminates after one byte (n_state=1).
fn fakeModuleScope() !*Scope {
    const parser = @import("parser.zig");
    return Scope.new(testing.allocator, .module, parser.PN_NULL, 0);
}

test "loadConstTok: FALSE/NONE/TRUE map to BYTE_O+N" {
    var ec = EmitCommon.init(testing.allocator);
    defer ec.deinit();
    var emit = Emit.init(testing.allocator, &ec);
    defer emit.deinit();

    const scope = try fakeModuleScope();
    defer scope.destroy();

    // Drive minimal passes to allocate code_base.
    try emit.setMaxNumLabels(0);
    inline for (.{ Pass.scope, Pass.stack_size, Pass.code_size }) |p| {
        ec.startPass(p);
        try emit.startPass(p, scope);
        emit.loadConstTok(MP_TOKEN_KW_FALSE);
        emit.loadConstTok(MP_TOKEN_KW_NONE);
        emit.loadConstTok(MP_TOKEN_KW_TRUE);
        _ = try emit.endPass();
    }
    ec.startPass(.emit);
    try emit.startPass(.emit, scope);
    emit.loadConstTok(MP_TOKEN_KW_FALSE);
    emit.loadConstTok(MP_TOKEN_KW_NONE);
    emit.loadConstTok(MP_TOKEN_KW_TRUE);
    _ = try emit.endPass();

    // Bytecode region starts at code_info_size; first three bytes should
    // be FALSE/NONE/TRUE (0x50, 0x51, 0x52).
    const bc = emit.code_base[emit.code_info_size..];
    try testing.expectEqual(MP_BC_LOAD_CONST_FALSE, bc[0]);
    try testing.expectEqual(MP_BC_LOAD_CONST_NONE, bc[1]);
    try testing.expectEqual(MP_BC_LOAD_CONST_TRUE, bc[2]);
}

test "loadConstSmallInt: in-range uses MULTI; out-of-range uses VINT" {
    var ec = EmitCommon.init(testing.allocator);
    defer ec.deinit();
    var emit = Emit.init(testing.allocator, &ec);
    defer emit.deinit();

    const scope = try fakeModuleScope();
    defer scope.destroy();

    try emit.setMaxNumLabels(0);
    inline for (.{ Pass.scope, Pass.stack_size, Pass.code_size, Pass.emit }) |p| {
        ec.startPass(p);
        try emit.startPass(p, scope);
        emit.loadConstSmallInt(0); // in-range → MULTI byte
        emit.loadConstSmallInt(100); // out-of-range → 1 + VLI
        _ = try emit.endPass();
    }

    const bc = emit.code_base[emit.code_info_size..];
    // 0 → MULTI(0x70) + EXCESS(16) + 0 == 0x80.
    try testing.expectEqual(@as(u8, 0x80), bc[0]);
    // 100 → LOAD_CONST_SMALL_INT opcode + VLI(100). encodeInt(100) is
    // 2 bytes (0x80, 0x64): bit 0x40 is set in 100, so a 0x00 pad-byte is
    // prepended to disambiguate from a negative number.
    try testing.expectEqual(MP_BC_LOAD_CONST_SMALL_INT, bc[1]);
    try testing.expectEqual(@as(u8, 0x80), bc[2]);
    try testing.expectEqual(@as(u8, 0x64), bc[3]);
    try testing.expectEqual(@as(usize, 4), bc.len);
}

test "binaryOp: NOT_IN emits IN + UNARY_NOT" {
    var ec = EmitCommon.init(testing.allocator);
    defer ec.deinit();
    var emit = Emit.init(testing.allocator, &ec);
    defer emit.deinit();

    const scope = try fakeModuleScope();
    defer scope.destroy();

    try emit.setMaxNumLabels(0);
    inline for (.{ Pass.scope, Pass.stack_size, Pass.code_size, Pass.emit }) |p| {
        ec.startPass(p);
        try emit.startPass(p, scope);
        emit.binaryOp(MP_BINARY_OP_NOT_IN);
        _ = try emit.endPass();
    }

    const bc = emit.code_base[emit.code_info_size..];
    try testing.expectEqual(
        MP_BC_BINARY_OP_MULTI + MP_BINARY_OP_IN,
        bc[0],
    );
    try testing.expectEqual(
        MP_BC_UNARY_OP_MULTI + MP_UNARY_OP_NOT,
        bc[1],
    );
}

test "returnValue: sets suppress, subsequent ops go to scratch" {
    var ec = EmitCommon.init(testing.allocator);
    defer ec.deinit();
    var emit = Emit.init(testing.allocator, &ec);
    defer emit.deinit();

    const scope = try fakeModuleScope();
    defer scope.destroy();

    try emit.setMaxNumLabels(0);
    inline for (.{ Pass.scope, Pass.stack_size, Pass.code_size, Pass.emit }) |p| {
        ec.startPass(p);
        try emit.startPass(p, scope);
        emit.returnValue();
        // Suppressed: this dup_top must not extend the bytecode region.
        emit.dupTop();
        _ = try emit.endPass();
    }

    try testing.expect(emit.suppress);
    const bc = emit.code_base[emit.code_info_size..];
    try testing.expectEqual(@as(usize, 1), bc.len);
    try testing.expectEqual(MP_BC_RETURN_VALUE, bc[0]);
}

test "3-pass consistency: load_const_small_int + return_value stable size" {
    var ec = EmitCommon.init(testing.allocator);
    defer ec.deinit();
    var emit = Emit.init(testing.allocator, &ec);
    defer emit.deinit();

    const scope = try fakeModuleScope();
    defer scope.destroy();

    try emit.setMaxNumLabels(0);

    var code_size_bc: usize = 0;
    inline for (.{ Pass.scope, Pass.stack_size, Pass.code_size, Pass.emit }) |p| {
        ec.startPass(p);
        try emit.startPass(p, scope);
        emit.loadConstSmallInt(1);
        emit.returnValue();
        const ok = try emit.endPass();
        try testing.expect(ok);
        if (p == .code_size) code_size_bc = emit.bytecode_size;
    }
    try testing.expectEqual(code_size_bc, emit.bytecode_offset);
    try testing.expectEqual(@as(usize, 2), code_size_bc); // MULTI(0x71) + RETURN_VALUE
}

test "label_assign + jump: short forward jump after CODE_SIZE" {
    var ec = EmitCommon.init(testing.allocator);
    defer ec.deinit();
    var emit = Emit.init(testing.allocator, &ec);
    defer emit.deinit();

    const scope = try fakeModuleScope();
    defer scope.destroy();

    try emit.setMaxNumLabels(1);
    inline for (.{ Pass.scope, Pass.stack_size, Pass.code_size, Pass.emit }) |p| {
        ec.startPass(p);
        try emit.startPass(p, scope);
        emit.jump(0); // jump to label 0
        emit.labelAssign(0);
        emit.popTop(); // a single byte op
        _ = try emit.endPass();
    }

    try testing.expect(!emit.overflow);
    // JUMP encodes 2 bytes (opcode + offset) in the short form. After
    // CODE_SIZE the label resolves to offset 0 — fits the 1-byte form.
    const bc = emit.code_base[emit.code_info_size..];
    try testing.expectEqual(MP_BC_JUMP, bc[0]);
    // bytecode_offset at jump emit = 0; label_offset = 2; offset = 2 - 0 - 2 = 0;
    // is_signed → +0x40 → 0x40.
    try testing.expectEqual(@as(u8, 0x40), bc[1]);
    try testing.expectEqual(MP_BC_POP_TOP, bc[2]);
}
