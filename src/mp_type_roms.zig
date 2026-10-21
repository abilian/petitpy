// zigonly Phase 2 — core type singletons (merged: scaffolding + smoke-test).
//
// Each `const mp_obj_type_t` was previously emitted by vendor C
// (objtype.c, objnone.c, objint.c, objstr.c, objbool.c, objtuple.c,
// objdict.c, objfun.c, objmodule.c). Phase 1 either stubbed them as
// @panic functions (link-time fake) or left them as undefined symbols.
// This file emits the real ROM data, wired to the existing Zig slot impls.
//
// IMPORTANT — fix Phase-1 landmine: mp_layout_check.zig wrongly declared
//   mp_type_str, mp_type_dict, mp_type_fun_bc, … as noreturn FUNCTIONS.
// These MUST be CONST DATA exports. Callers do `&mp_type_str`, then
// read flags / name / slots through the struct. Once this file is
// integrated, the matching `pub export fn mp_type_*() noreturn …`
// lines must be DELETED from src/mp_layout_check.zig — duplicate-symbol
// link errors will otherwise break the build (see `stubs_to_delete`).
//
// Layout note: vendor `mp_obj_type_t` ends in `const void *slots[]`
// (flexible array). We mirror the *fixed-size* form `mp_obj_full_type_t`
// (slots[11]); the C side reads it through a `mp_obj_type_t *` and
// only ever indexes `slots[slot_index_X - 1]` where `slot_index_X`
// is one of the small uints we set below. Slots we don't fill are
// left zero — vendor convention treats slot_index_X == 0 as "unset".
//
// Naming: we don't use MP_DEFINE_CONST_OBJ_TYPE; we expand it inline
// as Zig struct literals. The macro just sets `.slot_index_##f = i+1`
// and `.slots[i] = v` for each (f, v) pair in declaration order.
//
// On `mp_const_none / mp_const_true / mp_const_false`: under nano's
// REPR_A + MICROPY_OBJ_IMMEDIATE_OBJS=1 these are *not* data symbols —
// they're CPP macros that expand to immediate-encoded `mp_obj_t`
// values (`(0<<3)|6`, `(1<<3)|6`, `(3<<3)|6`). Nothing to export.
// Same goes for `mp_const_empty_bytes_obj` (still a data symbol but
// not referenced on the print(1+1) smoke path — defer until objstr
// boot-time needs it). `mp_const_empty_tuple_obj` IS exported here
// because tuple/argpack paths can reach it before any tuple is built.

// ── qstr enum values (compile-time constants from generated header) ──
const mp = @cImport({
    @cInclude("py/qstr.h");
});
const mirrors = @import("mp_mirrors.zig");

// ── layout mirror of mp_obj_full_type_t (py/obj.h) ──────────────────
// Stage 5a: `MpObjTypeFull` now composes `mirrors.MpObjType` (the
// canonical 24B prefix mirror) + a fixed `slots[11]` array, eliminating
// a duplicate definition of the same vendor struct. Layout asserts for
// the prefix + slots-offset live in `mp_mirrors.zig::assertLayout`.
// mp_type_type is now provided by src/objects/objtype/objtype.zig (Zig).
// Declare it extern so this file's refs to &mp_type_type resolve via linker.
extern const mp_type_type: opaque {};
// mp_type_NoneType — ported from objnone_shim.c.
//   MP_DEFINE_CONST_OBJ_TYPE(mp_type_NoneType, MP_QSTR_NoneType,
//       MP_TYPE_FLAG_NONE, print, none_print);
// `none_print` is defined in this file as a pub export fn below.
pub export const mp_type_NoneType: MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = FLAG_NONE,
        .name = mp.MP_QSTR_NoneType,
        .slot_index_make_new = 0,
        .slot_index_print = 1,
        .slot_index_call = 0,
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
        @ptrCast(&none_print),
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
extern const mp_type_int: opaque {};
extern const mp_type_str: opaque {};
extern const mp_type_bool: opaque {};
extern const mp_type_tuple: opaque {};
extern const mp_type_dict: opaque {};
extern const mp_type_list: opaque {};
extern const mp_type_fun_bc: opaque {};
extern const mp_const_empty_tuple_obj: opaque {};
extern const mp_type_AttributeError: opaque {};
extern const mp_type_GeneratorExit: opaque {};
extern const mp_type_ImportError: opaque {};
extern const mp_type_IndentationError: opaque {};
extern const mp_type_KeyError: opaque {};
extern const mp_type_MemoryError: opaque {};
extern const mp_type_NameError: opaque {};
extern const mp_type_NotImplementedError: opaque {};
extern const mp_type_OSError: opaque {};
extern const mp_type_RuntimeError: opaque {};
extern const mp_type_StopIteration: opaque {};
extern const mp_type_SyntaxError: opaque {};
extern const mp_type_SystemExit: opaque {};
extern const mp_type_TypeError: opaque {};
extern const mp_type_ValueError: opaque {};
extern const mp_type_ZeroDivisionError: opaque {};
extern const mp_type_classmethod: opaque {};
extern const mp_type_fun_builtin_0: opaque {};
extern const mp_type_fun_builtin_1: opaque {};
extern const mp_type_fun_builtin_2: opaque {};
extern const mp_type_fun_builtin_3: opaque {};
extern const mp_type_fun_builtin_var: opaque {};
extern const mp_type_gen_instance: opaque {};
extern const mp_type_gen_wrap: opaque {};
extern const mp_type_staticmethod: opaque {};

pub const MpObjTypeFull = extern struct {
    header: mirrors.MpObjType,
    // Fixed 11 slots (matches vendor mp_obj_full_type_t).
    slots: [11]?*const anyopaque,
};

// Helper: cast any function pointer to an opaque pointer for the slots array.
inline fn slot(fn_ptr: anytype) ?*const anyopaque {
    return @ptrCast(fn_ptr);
}

// ── extern slot implementations (already exported by Zig elsewhere) ──

// type slots — src/objects/objtype/objtype.zig
extern fn type_make_new(type_in: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const usize) callconv(.c) usize;
extern fn type_print(print: ?*const anyopaque, self_in: usize, kind: c_int) callconv(.c) void;
extern fn type_call(self_in: usize, n_args: usize, n_kw: usize, args: [*c]const usize) callconv(.c) usize;
extern fn type_attr(self_in: usize, attr: u32, dest: [*c]usize) callconv(.c) void;

// print primitive (used inline by none_print below).
extern fn mp_print_str(print: ?*const anyopaque, str: [*:0]const u8) callconv(.c) c_int;

// int slots — src/objects/primitives/objint.zig
extern fn mp_obj_int_make_new(type_in: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const usize) callconv(.c) usize;
extern fn mp_obj_int_print(print: ?*anyopaque, self_in: usize, kind: c_int) callconv(.c) void;
extern fn mp_obj_int_unary_op(op: c_int, o_in: usize) callconv(.c) usize;
extern fn mp_obj_int_binary_op(op: c_int, lhs: usize, rhs: usize) callconv(.c) usize;

// str slots — src/objects/strings/objstr.zig
extern fn mp_obj_str_make_new(type_in: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const usize) callconv(.c) usize;
extern fn str_print(print: ?*anyopaque, self_in: usize, kind: c_int) callconv(.c) void;
extern fn mp_obj_str_binary_op(op: c_int, lhs: usize, rhs: usize) callconv(.c) usize;
extern fn bytes_subscr(self_in: usize, index: usize, value: usize) callconv(.c) usize;
extern fn mp_obj_new_str_iterator(s: usize, iter_buf: ?*anyopaque) callconv(.c) usize;
extern fn mp_obj_str_get_buffer(self_in: usize, bufinfo: ?*anyopaque, flags: usize) callconv(.c) isize;

// bool slots — src/objects/primitives/objbool.zig (nano-prefixed names)
extern fn npy_bool_fn_make_new(type_in: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const usize) callconv(.c) usize;
extern fn npy_bool_fn_print(print: ?*anyopaque, self_in: usize, kind: c_int) callconv(.c) void;
extern fn npy_bool_fn_unary_op(op: c_int, o_in: usize) callconv(.c) usize;
extern fn npy_bool_fn_binary_op(op: c_int, lhs: usize, rhs: usize) callconv(.c) usize;

// tuple slots — src/objects/containers/objtuple.zig
extern fn mp_obj_tuple_make_new(type_in: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const usize) callconv(.c) usize;
extern fn mp_obj_tuple_print(print: ?*anyopaque, o_in: usize, kind: c_int) callconv(.c) void;
extern fn mp_obj_tuple_unary_op(op: c_int, self_in: usize) callconv(.c) usize;
extern fn mp_obj_tuple_binary_op(op: c_int, lhs: usize, rhs: usize) callconv(.c) usize;
extern fn mp_obj_tuple_subscr(self_in: usize, index: usize, value: usize) callconv(.c) usize;
extern fn mp_obj_tuple_getiter(o_in: usize, iter_buf: ?*anyopaque) callconv(.c) usize;

// dict slots — src/objects/containers/objdict.zig (nano-prefixed names)
extern fn mp_obj_dict_make_new(type_in: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const usize) callconv(.c) usize;
extern fn npy_dt_print(print: ?*anyopaque, self_in: usize, kind: c_int) callconv(.c) void;
extern fn npy_dt_unary_op(op: c_int, self_in: usize) callconv(.c) usize;
extern fn npy_dt_binary_op(op: c_int, lhs: usize, rhs: usize) callconv(.c) usize;
extern fn npy_dt_subscr(self_in: usize, index: usize, value: usize) callconv(.c) usize;
extern fn npy_dt_getiter(self_in: usize, iter_buf: ?*anyopaque) callconv(.c) usize;

// bytecode-function slot — src/objects/callables/objfun.zig
extern fn fun_bc_call(self_in: usize, n_args: usize, n_kw: usize, args: [*c]const usize) callconv(.c) usize;

// built-in C-function call slots — src/objects/callables/objfun.zig
extern fn fun_builtin_0_call(self_in: usize, n_args: usize, n_kw: usize, args: [*c]const usize) callconv(.c) usize;
extern fn fun_builtin_1_call(self_in: usize, n_args: usize, n_kw: usize, args: [*c]const usize) callconv(.c) usize;
extern fn fun_builtin_2_call(self_in: usize, n_args: usize, n_kw: usize, args: [*c]const usize) callconv(.c) usize;
extern fn fun_builtin_3_call(self_in: usize, n_args: usize, n_kw: usize, args: [*c]const usize) callconv(.c) usize;
extern fn fun_builtin_var_call(self_in: usize, n_args: usize, n_kw: usize, args: [*c]const usize) callconv(.c) usize;

// module slots — src/objects/objtype/objmodule.zig
extern fn module_print(print: ?*const anyopaque, self_in: usize, kind: c_int) callconv(.c) void;
extern fn module_attr(self_in: usize, attr: u16, dest: [*c]usize) callconv(.c) void;

// ── MP_TYPE_FLAG_* (mirror py/obj.h numeric values) ─────────────────
const FLAG_NONE: u16 = 0x0000;
const FLAG_EQ_CHECKS_OTHER_TYPE: u16 = 0x0008;
const FLAG_BINDS_SELF: u16 = 0x0020;
const FLAG_BUILTIN_FUN: u16 = 0x0040;
const FLAG_ITER_IS_GETITER: u16 = 0x0000;

// ── NoneType inline print (objnone.c not compiled in zigonly) ───────
// Vendor: none_print emits "None" (or "null" for PRINT_JSON; nano lacks
// MICROPY_PY_JSON so the branch is dead). Inlined here to keep the
// type-singleton file self-contained; will move to a dedicated
// src/objects/primitives/objnone.zig when that subsystem ports.
const PRINT_JSON: c_int = 0x18;

export fn none_print(print: ?*const anyopaque, self_in: usize, kind: c_int) callconv(.c) void {
    _ = self_in;
    _ = kind; // MICROPY_PY_JSON==0 → JSON branch dead
    _ = mp_print_str(print, "None");
}

// ── mp_type_type ────────────────────────────────────────────────────
// Self-referential: base_type points to itself (the metatype's metatype
// is itself). Vendor objtype.c:
//   MP_DEFINE_CONST_OBJ_TYPE(mp_type_type, MP_QSTR_type, MP_TYPE_FLAG_NONE,
//       make_new, type_make_new, print, type_print,
//       call, type_call, attr, type_attr);

// ── mp_type_NoneType ────────────────────────────────────────────────
// Vendor objnone.c:
//   MP_DEFINE_CONST_OBJ_TYPE(mp_type_NoneType, MP_QSTR_NoneType,
//       MP_TYPE_FLAG_NONE, print, none_print);

// ── singletons ──────────────────────────────────────────────────────
// Locals dicts are omitted: nano smoke path doesn't call methods on
// these instances (only the operator slots). When method dispatch is
// wired we'll fill `slot_index_locals_dict` + `slots[n]`.

// int: make_new, print, unary_op, binary_op

// str: make_new, print, binary_op, subscr, iter, buffer

// bool: make_new, print, unary_op, binary_op (matches numeric types via EQ_CHECKS_OTHER_TYPE)

// tuple: make_new, print, unary_op, binary_op, subscr, iter

// dict: make_new, print, unary_op, binary_op, subscr, iter

// fun_bc: bytecode function. Only the call slot is needed for the
// nano smoke path (no __repr__, no `.attr` introspection).

// fun_builtin_0..3 + fun_builtin_var: built-in C functions. Just call.

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

// ── mp_type_module ──────────────────────────────────────────────────
// Vendor objmodule.c:
//   MP_DEFINE_CONST_OBJ_TYPE(mp_type_module, MP_QSTR_module,
//       MP_TYPE_FLAG_NONE, print, module_print, attr, module_attr);
// `module_print` / `module_attr` are exported by objmodule.zig.
pub export const mp_type_module: MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = FLAG_NONE,
        .name = mp.MP_QSTR_module,
        .slot_index_make_new = 0,
        .slot_index_print = 1,
        .slot_index_call = 0,
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
        @ptrCast(&module_print),
        @ptrCast(&module_attr),
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

// ── ROM singleton objects ───────────────────────────────────────────
// `mp_const_empty_tuple_obj` — used by argpack paths (e.g. *args=() when
// no positional args). Vendor objtuple.c:238 literal:
//   const mp_obj_tuple_t mp_const_empty_tuple_obj = {{&mp_type_tuple}, 0};
//
// Layout: { base.type=&mp_type_tuple, len=0 }. The flexible `items[]`
// member contributes no bytes when zero-length, so the literal sizeof
// is exactly @sizeOf(MpObjTupleHeader) = 16 on 64-bit.
const MpObjTupleHeader = extern struct {
    base_type: ?*const anyopaque,
    len: usize,
};

comptime {
    // Force the linker to keep these data symbols even though no Zig
    // module @imports this file directly — main.zig only does `_ = @import(...)`.
    _ = &mp_type_type;
    _ = &mp_type_NoneType;
    _ = &mp_type_int;
    _ = &mp_type_str;
    _ = &mp_type_bool;
    _ = &mp_type_tuple;
    // _ = &mp_type_dict; (now provided by map_shim.c)
    _ = &mp_type_fun_bc;
    _ = &mp_type_fun_builtin_0;
    _ = &mp_type_fun_builtin_1;
    _ = &mp_type_fun_builtin_2;
    _ = &mp_type_fun_builtin_3;
    _ = &mp_type_fun_builtin_var;
    _ = &mp_type_module;
    _ = &mp_const_empty_tuple_obj;
    _ = &none_print;
}

// ── Exception type placeholders ─────────────────────────────────────
// Only the *address* is used (identity check by mp_obj_is_subclass_fast
// from nlr_trampoline.c). Slots/fields aren't read unless an exception
// of that class is actually raised, which doesn't happen on the smoke
// test path.

// ── mp_type_singleton + mp_const_ellipsis_obj ──────────────────
// Ported from objsingleton_shim.c.
const MpObjSingleton = extern struct {
    base_type: ?*const anyopaque,
    name: u16,
    _pad: [6]u8 = .{0} ** 6, // pad to align next obj (struct is 16B total)
};
extern fn mp_printf(print: ?*const anyopaque, fmt: [*:0]const u8, ...) callconv(.c) c_int;
extern fn npy_objs_obj_to_ptr_helper(o: usize) callconv(.c) ?*anyopaque;

export fn singleton_print(print_in: ?*const anyopaque, self_in: usize, kind: c_int) callconv(.c) void {
    _ = kind;
    // MP_OBJ_TO_PTR under REPR_A is just (void*)self_in.
    const self: *const MpObjSingleton = @ptrFromInt(self_in);
    _ = mp_printf(print_in, "%q", @as(usize, self.name));
}

pub export const mp_type_singleton: MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = FLAG_NONE,
        .name = mp.MP_QSTR_,
        .slot_index_make_new = 0,
        .slot_index_print = 1,
        .slot_index_call = 0,
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
        @ptrCast(&singleton_print),
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

pub export const mp_const_ellipsis_obj: MpObjSingleton = .{
    .base_type = &mp_type_singleton,
    .name = mp.MP_QSTR_Ellipsis,
};

// (Old placeholder ellipsis const removed — real one is above.)
const MpConstObj = extern struct {
    type_ptr: ?*const anyopaque,
};

// Additional exception + method types — placeholder data symbols.
const EMPTY_TYPE = MpObjTypeFull{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = FLAG_NONE,
        .name = 0,
        .slot_index_make_new = 0,
        .slot_index_print = 0,
        .slot_index_call = 0,
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
    .slots = .{ null, null, null, null, null, null, null, null, null, null, null },
};

// mp_const_GeneratorExit_obj — singleton exception instance
const MpObjBase = extern struct { type_ptr: ?*const anyopaque };

// mp_module_builtins_globals: data symbol — vendor uses an mp_obj_dict_t.
// 32-byte zero-init placeholder; not actually used by smoke test (which
// resolves 'print' through a different path).

// mp_type_float retired — vendor py/objfloat.c provides the real symbol
// via the float-arm carveout (build.zig). The EMPTY_TYPE stub used to
// satisfy linker references from runtime.zig + objstr.zig + objint.zig
// (all just take &mp_type_float for isExactType checks).
// pub export const mp_type_float: MpObjTypeFull = EMPTY_TYPE;
