//! petitpy — full Zig port of py/objclosure.c (including
//! mp_type_closure ROM). Nano: ERROR_REPORTING=TERSE ⇒ closure_print
//! dead; FUNCTION_ATTRS=1 ⇒ attr slot live. n_total = n_closed +
//! n_args + 2*n_kw; stack≤5 else heap-alloc via m_malloc.

const mp = @cImport({
    @cInclude("py/qstr.h");
});
const mirrors = @import("../../mp_mirrors.zig");
const types = @import("../../mp_type_roms.zig");

const Obj = mirrors.Obj;

extern const mp_type_type: anyopaque;
extern fn mp_call_function_n_kw(fun: Obj, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj;
extern fn mp_obj_malloc_helper(num_bytes: usize, type_in: ?*const anyopaque) callconv(.c) ?*anyopaque;
extern fn mp_load_method_maybe(base: Obj, attr: usize, dest: [*]Obj) callconv(.c) void;
extern fn m_malloc(num_bytes: usize) callconv(.c) ?*anyopaque;
extern fn m_free(ptr: ?*anyopaque) callconv(.c) void;

export fn npy_clos_fn_call(self_in: Obj, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    const self = mirrors.MpObjClosure.fromObj(self_in);
    const fun = self.fun;
    const n_closed = self.n_closed;
    const closed = self.closedPtr();
    const n_extra = n_args + 2 * n_kw;
    const n_total = n_closed + n_extra;
    if (n_total <= 5) {
        var args2: [5]Obj = undefined;
        if (n_closed != 0) @memcpy(args2[0..n_closed], closed[0..n_closed]);
        if (n_extra != 0) @memcpy(args2[n_closed .. n_closed + n_extra], args[0..n_extra]);
        return mp_call_function_n_kw(fun, n_closed + n_args, n_kw, &args2);
    } else {
        const args2: [*]Obj = @ptrCast(@alignCast(m_malloc(n_total * @sizeOf(Obj)).?));
        if (n_closed != 0) @memcpy(args2[0..n_closed], closed[0..n_closed]);
        if (n_extra != 0) @memcpy(args2[n_closed .. n_closed + n_extra], args[0..n_extra]);
        const res = mp_call_function_n_kw(fun, n_closed + n_args, n_kw, args2);
        m_free(args2);
        return res;
    }
}
export fn mp_obj_new_closure(fun: Obj, n_closed_over: usize, closed: [*c]const Obj) callconv(.c) Obj {
    const total_bytes = @sizeOf(mirrors.MpObjClosure) + n_closed_over * @sizeOf(Obj);
    const raw = mp_obj_malloc_helper(total_bytes, &mp_type_closure);
    const o: *mirrors.MpObjClosure = @ptrCast(@alignCast(raw));
    o.fun = fun;
    o.n_closed = n_closed_over;
    const dst = o.closedPtr();
    if (n_closed_over != 0) @memcpy(dst[0..n_closed_over], closed[0..n_closed_over]);
    return @intFromPtr(o);
}

// MICROPY_PY_FUNCTION_ATTRS is on under nano — keep the slot live.
export fn mp_obj_closure_attr(self_in: Obj, attr: u16, dest: [*]Obj) callconv(.c) void {
    const o = mirrors.MpObjClosure.fromObj(self_in);
    mp_load_method_maybe(o.fun, attr, dest);
}

// MP_TYPE_FLAG_BINDS_SELF = 0x0020. ERROR_REPORTING=TERSE → no print slot.
pub export const mp_type_closure: types.MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = 0x0020,
        .name = mp.MP_QSTR_closure,
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
        @ptrCast(&mp_obj_closure_attr),
        @ptrCast(&npy_clos_fn_call),
        null, null, null, null, null, null, null, null, null,
    },
};

comptime {
    _ = &npy_clos_fn_call;
    _ = &mp_obj_new_closure;
    _ = &mp_obj_closure_attr;
    _ = &mp_type_closure;
}
