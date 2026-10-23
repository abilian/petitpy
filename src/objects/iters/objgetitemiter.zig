//! petitpy — Zig port of py/objgetitemiter.c's it_iternext.
//!
//! NX-3 N4 (2026-06-05): npy_nlr_run wrap dropped. m_malloc_fail is
//! polled and no other Zig code longjmps under nano, so the setjmp
//! landing pad is dead code. The polled-sentinel pyerr.pending_exc
//! check now solely carries raise propagation.
//!
//! Translates StopIteration/IndexError to MP_OBJ_STOP_ITERATION
//! and re-raises others.

const mp = @cImport({
    @cInclude("py/qstr.h");
});
const mirrors = @import("../../mp_mirrors.zig");
const types = @import("../../mp_type_roms.zig");
const pyerr = @import("../../pyerr.zig");
const PyError = pyerr.PyError;

const Obj = mirrors.Obj;

extern fn mp_call_method_n_kw(n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj;
extern const mp_type_StopIteration: anyopaque;
extern const mp_type_IndexError: anyopaque;
extern const mp_type_type: anyopaque;

// mp_obj_getitem_iter_t: { base, args[3] }. args[0]=method, args[1]=self, args[2]=index.
const MpObjGetitemIterFull = extern struct {
    base: mirrors.MpObjBase,
    args: [3]Obj,
};

inline fn argsPtr(self_in: Obj) [*]Obj {
    const o: *MpObjGetitemIterFull = @ptrFromInt(self_in);
    return @ptrCast(&o.args);
}

inline fn excIsStopOrIndex(exc: Obj) bool {
    const exc_type_ptr = mirrors.objBaseType(exc) orelse return false;
    return exc_type_ptr == @as(?*const anyopaque, &mp_type_StopIteration)
        or exc_type_ptr == @as(?*const anyopaque, &mp_type_IndexError);
}

fn ogiIternextImpl(self_in: Obj) PyError!Obj {
    const args = argsPtr(self_in);
    const ret = mp_call_method_n_kw(1, 0, args);
    if (pyerr.pending_exc != 0) {
        const ev = pyerr.pending_exc;
        pyerr.pending_exc = 0;
        if (excIsStopOrIndex(ev)) return mirrors.OBJ_STOP_ITERATION;
        pyerr.pending_exc = ev;
        return error.PyRaise;
    }
    // self->args[2] += 1. args[2] is a small-int Obj.
    args[2] = mirrors.newSmallInt(mirrors.smallIntValue(args[2]) + 1);
    return ret;
}

export fn npy_ogi_iternext(self_in: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, ogiIternextImpl(self_in));
}

// mp_type_it — ROM type singleton ported from the C shim:
//   MP_DEFINE_CONST_OBJ_TYPE(mp_type_it, MP_QSTR_iterator,
//       MP_TYPE_FLAG_ITER_IS_ITERNEXT, iter, npy_ogi_iternext);
pub export const mp_type_it: types.MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = 0x0080, // MP_TYPE_FLAG_ITER_IS_ITERNEXT
        .name = mp.MP_QSTR_iterator,
        .slot_index_make_new = 0,
        .slot_index_print = 0,
        .slot_index_call = 0,
        .slot_index_unary_op = 0,
        .slot_index_binary_op = 0,
        .slot_index_attr = 0,
        .slot_index_subscr = 0,
        .slot_index_iter = 1,
        .slot_index_buffer = 0,
        .slot_index_protocol = 0,
        .slot_index_parent = 0,
        .slot_index_locals_dict = 0,
    },
    .slots = .{
        @ptrCast(&npy_ogi_iternext),
        null, null, null, null, null, null, null, null, null, null,
    },
};

export fn mp_obj_new_getitem_iter(args: [*c]const Obj, iter_buf: ?*anyopaque) callconv(.c) Obj {
    const o: *MpObjGetitemIterFull = @ptrCast(@alignCast(iter_buf));
    o.base.type = &mp_type_it;
    o.args[0] = args[0];
    o.args[1] = args[1];
    o.args[2] = mirrors.newSmallInt(0);
    return @intFromPtr(o);
}

comptime {
    _ = &npy_ogi_iternext;
    _ = &mp_obj_new_getitem_iter;
}
