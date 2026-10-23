//! nanopython — Zig partial port of py/objtype.c (Axis-B B1.5 W4; seam 1).
//!
//! objtype.c is the metaclass machinery: 967 LOC live under nano, 14 live
//! raises, 7 exports + 33 statics. **Multi-session port.** This first seam
//! moves 2 small self-contained public utilities that other ported files
//! already call through the shim — removes one ABI hop.
//!
//! __qstr_shadow_begin__
//! MP_QSTR___missing__
//! MP_QSTR___args__
//! MP_QSTR___origin__
//! __qstr_shadow_end__
//!
//! Fns ported here:
//!   - mp_obj_is_subclass_fast: tail-recursive walk up the parent chain.
//!     MI=0 under nano → the tuple-parent branch is dead; single-parent walk.
//!   - mp_obj_cast_to_native_base: cast an instance back to its native base
//!     type via subobj[0]. Uses is_subclass_fast.
//!
//! Remaining (future seams): mp_obj_new_instance, mp_obj_instance_is_callable,
//! mp_obj_instance_call (1 live raise), mp_obj_instance_getiter,
//! mp_load_super_method, plus the 33 statics (instance attr lookup, MRO,
//! method binding, super, type_make_new). 0 live raises in this seam.

const build_options = @import("build_options");
const mp = @cImport({
    @cInclude("py/obj.h");
    @cInclude("py/runtime0.h");
});
const pyerr = @import("../../pyerr.zig");
const mirrors = @import("../../mp_mirrors.zig");
const PyError = pyerr.PyError;

const Obj = mirrors.Obj;
const MP_OBJ_NULL: Obj = 0;
// Immediate-obj constants and qstr-obj encoding via mp_mirrors (replaces
// the npy_ty_const_*/npy_ty_sentinel/npy_ty_qstr_obj shim trampolines).
const MP_OBJ_SENTINEL: Obj = mirrors.OBJ_SENTINEL;
const MP_OBJ_NONE: Obj = mirrors.OBJ_NONE;
const MP_OBJ_TRUE: Obj = mirrors.OBJ_TRUE;
const MP_OBJ_FALSE: Obj = mirrors.OBJ_FALSE;
inline fn qstrObj(q: u32) Obj {
    return mirrors.objFromQstr(q);
}
// ROM type singletons referenced for short-circuit pointer compares.
extern const mp_type_object: anyopaque;
extern const mp_type_tuple: anyopaque;
extern const mp_type_property: anyopaque;
extern fn mp_obj_get_type(o: Obj) callconv(.c) ?*const anyopaque;
// property proxy accessor (objproperty.zig export). Returns a `[*]const Obj`
// — a 3-element array of [fget, fset, fdel].
extern fn mp_obj_property_get(self_in: Obj) callconv(.c) [*]const Obj;

// ── Inline mirror helpers (replace the npy_ty_* C trampolines). ────
//
// All trivial slot/flag/parent accessors funnel through mp_mirrors.MpObjType
// so the C shim's hand-written wrappers can be deleted. Calls and refs are
// `*const anyopaque` to keep ABI parity with the existing call sites.
inline fn typeFromPtr(t: ?*const anyopaque) *const mirrors.MpObjType {
    return mirrors.MpObjType.fromPtr(t);
}
inline fn isTypeType(o: Obj) bool {
    return mirrors.isExactType(o, &mp_type_type);
}
inline fn isTypeTuple(o: Obj) bool {
    return mirrors.isExactType(o, &mp_type_tuple);
}
inline fn objToTypePtr(o: Obj) ?*const anyopaque {
    return @ptrFromInt(o);
}
inline fn typeHasParent(t: ?*const anyopaque) bool {
    return typeFromPtr(t).hasSlot(.parent);
}
inline fn typeParent(t: ?*const anyopaque) ?*const anyopaque {
    return typeFromPtr(t).getSlot(.parent);
}
inline fn typeIsNative(t: ?*const anyopaque) bool {
    return !typeFromPtr(t).flagInstanceType();
}
inline fn typeHasLocalsDict(t: ?*const anyopaque) bool {
    return typeFromPtr(t).hasSlot(.locals_dict);
}
inline fn typeLocalsMap(t: ?*const anyopaque) *mirrors.MpMap {
    const ld_ptr = typeFromPtr(t).getSlot(.locals_dict).?;
    const dict: *mirrors.MpObjDict = @ptrCast(@alignCast(@constCast(ld_ptr)));
    return &dict.map;
}
inline fn typeFlagIterIsStream(t: ?*const anyopaque) bool {
    return typeFromPtr(t).iterIsStream();
}
inline fn typeFlagIterIsIternext(t: ?*const anyopaque) bool {
    return typeFromPtr(t).iterIsIterNext();
}
inline fn typeHasSlotMakeNew(t: ?*const anyopaque) bool {
    return typeFromPtr(t).hasSlot(.make_new);
}
inline fn typeFlagHasSpecialAccessors(t: ?*const anyopaque) bool {
    return (typeFromPtr(t).flags & mirrors.FLAG_HAS_SPECIAL_ACCESSORS) != 0;
}
inline fn typeFlagSpecialAccessorsValue(t: ?*const anyopaque) u16 {
    return typeFromPtr(t).flags & mirrors.FLAG_HAS_SPECIAL_ACCESSORS;
}
inline fn typeHasSlotByOffset(t: ?*const anyopaque, off: usize) bool {
    const bytes: [*]const u8 = @ptrCast(t);
    return bytes[off] != 0;
}
// `MP_OBJ_TYPE_GET_SLOT_OR_NULL(t, protocol)`.
inline fn typeProtocolOrNull(t: ?*const anyopaque) ?*const anyopaque {
    return typeFromPtr(t).getSlot(.protocol);
}
// Write `slot_index_X = slot_idx + 1` at byte offset `off`, and set the slot
// pointer at `slots[slot_idx]`. Mirrors the C `MP_OBJ_TYPE_SET_SLOT(t, X, v, slot_idx)`
// macro fan-out used by mp_obj_new_type. Caller has already verified `t` is a
// freshly-allocated mp_obj_type_t with enough slots[] flex-storage.
inline fn typeSetSlotByOffset(t: ?*anyopaque, off: usize, slot_idx: usize, value: ?*const anyopaque) void {
    const bytes: [*]u8 = @ptrCast(t.?);
    bytes[off] = @intCast(slot_idx + 1);
    const tm: *mirrors.MpObjType = @ptrCast(@alignCast(t.?));
    const slots = tm.slotsPtr();
    const slots_mut: [*]?*const anyopaque = @constCast(slots);
    slots_mut[slot_idx] = value;
}
// MI helpers: under nano (MI=0) these are unreachable (the caller gates them
// with `comptime build_options.is_full`). Under full, the parent slot may
// hold either a single type ptr or a tuple of types.
inline fn parentIsTuple(t: ?*const anyopaque) bool {
    const parent_slot = typeFromPtr(t).getSlot(.parent) orelse return false;
    const base: *align(1) const mirrors.MpObjBase = @ptrCast(parent_slot);
    return base.type == @as(?*const anyopaque, &mp_type_tuple);
}
inline fn parentTupleItems(t: ?*const anyopaque, n_out: *usize, items_out: *[*c]const Obj) void {
    const parent_slot = typeFromPtr(t).getSlot(.parent).?;
    const tup: *mirrors.MpObjTuple = @ptrCast(@alignCast(@constCast(parent_slot)));
    n_out.* = tup.len;
    items_out.* = @ptrCast(tup.itemsPtr());
}
// `MP_OBJ_TYPE_GET_SLOT(t, iter)(self, iter_buf)` — non-CUSTOM iter dispatch.
inline fn typeCallIterSlot(t: ?*const anyopaque, self_in: Obj, iter_buf: ?*anyopaque) Obj {
    const raw = typeFromPtr(t).getSlot(.iter).?;
    const fn_ptr: mirrors.MpGetiterFun = @ptrCast(@alignCast(raw));
    return fn_ptr(self_in, iter_buf);
}
// `MP_OBJ_TYPE_GET_SLOT(t, buffer)(self, bufinfo, flags)`.
inline fn typeCallBufferSlot(t: ?*const anyopaque, self_in: Obj, bufinfo: ?*anyopaque, flags: usize) isize {
    const raw = typeFromPtr(t).getSlot(.buffer).?;
    const fn_ptr: mirrors.MpBufferFun = @ptrCast(@alignCast(raw));
    return fn_ptr(self_in, bufinfo.?, flags);
}
// `MP_OBJ_TYPE_GET_SLOT(t, make_new)(t, n_args, n_kw, args)`.
inline fn typeCallMakeNewSlot(t: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const Obj) Obj {
    const raw = typeFromPtr(t).getSlot(.make_new).?;
    const fn_ptr: mirrors.MpMakeNewFun = @ptrCast(@alignCast(raw));
    return fn_ptr(typeFromPtr(t), n_args, n_kw, args);
}
// `mp_obj_is_type(member, &mp_type_property)` — only meaningful when
// MICROPY_PY_BUILTINS_PROPERTY=1, which holds in both nano + full.
inline fn memberIsProperty(member: Obj) bool {
    return mirrors.isExactType(member, &mp_type_property);
}

// ── Special-accessor helpers (v0.3; replaces the C shim's
// check_for_special_accessors + scan_special_accessors_flag). Both nano
// and full have PROPERTY=1 and DESCRIPTORS=1; DELATTR_SETATTR is full-only.
// Mirror vendor objtype.c:1138-1147 (check_for_special_accessors) and
// the locals_dict scan loop in mp_obj_new_type.
extern fn mp_load_method_protected(obj: Obj, attr: usize, dest: [*c]Obj, catch_all_exc: bool) callconv(.c) void;

// `mp_obj_is_instance_type` macro: type->flags & MP_TYPE_FLAG_INSTANCE_TYPE.
inline fn typeIsInstanceType(t: ?*const anyopaque) bool {
    return typeFromPtr(t).flagInstanceType();
}

inline fn attrValueIsSpecialAccessor(key: usize, value: Obj) bool {
    if (build_options.delattr_setattr) {
        // DELATTR_SETATTR: __setattr__ / __delattr__ keys.
        // Flipped from is_full to its own flag in v0.7.
        if (key == mp.MP_QSTR___setattr__ or key == mp.MP_QSTR___delattr__) {
            return true;
        }
    }
    // PROPERTY: value is a property object.
    if (mirrors.isExactType(value, &mp_type_property)) {
        return true;
    }
    // DESCRIPTORS: value exposes any of __get__ / __set__ / __delete__.
    const descriptor_qstrs = [_]usize{ mp.MP_QSTR___get__, mp.MP_QSTR___set__, mp.MP_QSTR___delete__ };
    for (descriptor_qstrs) |q| {
        var dest_temp: [2]Obj = .{ MP_OBJ_NULL, MP_OBJ_NULL };
        mp_load_method_protected(value, q, &dest_temp, true);
        if (dest_temp[0] != MP_OBJ_NULL) return true;
    }
    return false;
}

export fn npy_ty_attr_value_is_special_accessor(key: usize, value: Obj) callconv(.c) c_int {
    return if (attrValueIsSpecialAccessor(key, value)) 1 else 0;
}

export fn npy_ty_scan_special_accessors_flag(locals_dict: Obj) callconv(.c) u16 {
    const dict = mirrors.MpObjDict.fromObj(locals_dict);
    var i: usize = 0;
    while (i < dict.map.alloc) : (i += 1) {
        if (!dict.map.slotFilled(i)) continue;
        const value = dict.map.valueAt(i);
        // PROPERTY: any property value flags the type.
        if (mirrors.isExactType(value, &mp_type_property)) {
            return mirrors.FLAG_HAS_SPECIAL_ACCESSORS;
        }
        if (build_options.delattr_setattr) {
            // DELATTR_SETATTR: __setattr__ / __delattr__ keys.
            const key = dict.map.keyAt(i);
            if (key == mirrors.objFromQstr(mp.MP_QSTR___setattr__) or
                key == mirrors.objFromQstr(mp.MP_QSTR___delattr__))
            {
                return mirrors.FLAG_HAS_SPECIAL_ACCESSORS;
            }
        }
        // DESCRIPTORS: only USER (instance) types carry __get__ as a descriptor.
        const value_type = mp_obj_get_type(value);
        if (typeIsInstanceType(value_type)) {
            var dest: [2]Obj = .{ MP_OBJ_NULL, MP_OBJ_NULL };
            mp_load_method_maybe(value, mp.MP_QSTR___get__, &dest);
            if (dest[0] != MP_OBJ_NULL) {
                return mirrors.FLAG_HAS_SPECIAL_ACCESSORS;
            }
        }
    }
    return 0;
}

// ── CPython-compat readonly accessors (full only). Mirror vendor
// objtype.c:1077-1119: `type.__dict__` (locals copy) and `type.__bases__`
// (parent tuple); `instance.__dict__` (members copy).
inline fn typeLocalsDictReadonly(t: ?*const anyopaque) Obj {
    const ld = typeFromPtr(t).getSlot(.locals_dict);
    const dict_ptr: ?*const anyopaque = ld orelse @ptrCast(&mp_const_empty_dict_obj);
    const d: *const mirrors.MpObjDict = @ptrCast(@alignCast(dict_ptr.?));
    var out: Obj = undefined;
    if (d.map.bits.is_fixed != 0) {
        out = @intFromPtr(d);
    } else {
        out = mp_obj_dict_copy(@intFromPtr(d));
        const od: *mirrors.MpObjDict = @ptrFromInt(out);
        od.map.bits.is_fixed = 1;
    }
    return out;
}
inline fn instanceDictReadonly(self_in: Obj) Obj {
    const inst = mirrors.MpObjInstance.fromObj(self_in);
    var dict: mirrors.MpObjDict = .{
        .base = .{ .type = &mp_type_dict },
        .map = inst.members,
    };
    const out = mp_obj_dict_copy(@intFromPtr(&dict));
    const od: *mirrors.MpObjDict = @ptrFromInt(out);
    od.map.bits.is_fixed = 1;
    return out;
}
inline fn typeBasesTuple(t: ?*const anyopaque) Obj {
    if (t == @as(?*const anyopaque, &mp_type_object)) {
        return @intFromPtr(&mp_const_empty_tuple_obj);
    }
    const parent_obj: Obj = if (typeHasParent(t))
        @intFromPtr(typeParent(t))
    else
        @intFromPtr(&mp_type_object);
    if (comptime build_options.multiple_inheritance) {
        if (mirrors.isExactType(parent_obj, &mp_type_tuple)) {
            return parent_obj;
        }
    }
    var items: [1]Obj = .{parent_obj};
    return mp_obj_new_tuple(1, &items);
}
// Slot-index byte offsets (MP_OBJ_TYPE_OFFSETOF_SLOT(f) = offsetof(t, slot_index_f)).
const SLOT_OFFSET_MAKE_NEW: usize = @offsetOf(mirrors.MpObjType, "slot_index_make_new");
const SLOT_OFFSET_PRINT: usize = @offsetOf(mirrors.MpObjType, "slot_index_print");
const SLOT_OFFSET_CALL: usize = @offsetOf(mirrors.MpObjType, "slot_index_call");
const SLOT_OFFSET_UNARY_OP: usize = @offsetOf(mirrors.MpObjType, "slot_index_unary_op");
const SLOT_OFFSET_BINARY_OP: usize = @offsetOf(mirrors.MpObjType, "slot_index_binary_op");
const SLOT_OFFSET_ATTR: usize = @offsetOf(mirrors.MpObjType, "slot_index_attr");
const SLOT_OFFSET_SUBSCR: usize = @offsetOf(mirrors.MpObjType, "slot_index_subscr");
const SLOT_OFFSET_ITER: usize = @offsetOf(mirrors.MpObjType, "slot_index_iter");
const SLOT_OFFSET_BUFFER: usize = @offsetOf(mirrors.MpObjType, "slot_index_buffer");
const SLOT_OFFSET_PROTOCOL: usize = @offsetOf(mirrors.MpObjType, "slot_index_protocol");
const SLOT_OFFSET_PARENT: usize = @offsetOf(mirrors.MpObjType, "slot_index_parent");
const SLOT_OFFSET_LOCALS_DICT: usize = @offsetOf(mirrors.MpObjType, "slot_index_locals_dict");

// Already-Zig: mp_call_function_n_kw (runtime.zig).
extern fn mp_call_function_n_kw(fun: Obj, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj;
// Still-C: mp_call_method_self_n_kw (npy_objboundmeth_shim.c).
extern fn mp_call_method_self_n_kw(meth: Obj, self: Obj, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj;

// Exception types + factories — already exported from Zig (objexcept.zig).
extern const mp_type_TypeError: anyopaque;
extern const mp_type_NotImplementedError: anyopaque;
extern fn mp_obj_new_exception(t: *const anyopaque) callconv(.c) Obj;
extern fn mp_obj_new_exception_msg(t: *const anyopaque, msg: [*:0]const u8) callconv(.c) Obj;
inline fn typeErrorMsg(msg: [*:0]const u8) Obj {
    return mp_obj_new_exception_msg(&mp_type_TypeError, msg);
}
inline fn notImplementedMsg(msg: [*:0]const u8) Obj {
    return mp_obj_new_exception_msg(&mp_type_NotImplementedError, msg);
}

// `mp_const_notimplemented` is only defined when MICROPY_PY_BUILTINS_NOTIMPLEMENTED;
// guard the extern with the same comptime predicate the call sites use.
extern const mp_const_notimplemented_obj: anyopaque;
inline fn constNotImplemented() Obj {
    if (comptime build_options.is_full) return @intFromPtr(&mp_const_notimplemented_obj);
    return MP_OBJ_NULL;
}

// `mp_obj_super_t.type` / `.obj` field accesses via mp_mirrors.
inline fn superTypeOf(super_obj: Obj) Obj {
    return mirrors.MpObjSuper.fromObj(super_obj).type;
}
inline fn superObjOf(super_obj: Obj) Obj {
    return mirrors.MpObjSuper.fromObj(super_obj).obj;
}

// CPython-compat externs (full only — gated by `comptime build_options.is_full`).
extern fn mp_obj_dict_copy(self_in: Obj) callconv(.c) Obj;
extern fn mp_obj_new_tuple(n: usize, items: [*c]const Obj) callconv(.c) Obj;
extern const mp_const_empty_tuple_obj: anyopaque;
extern const mp_const_empty_dict_obj: anyopaque;

extern fn mp_obj_malloc_helper(num_bytes: usize, type_in: ?*const anyopaque) callconv(.c) ?*anyopaque;
extern fn m_malloc(num_bytes: usize) callconv(.c) ?*anyopaque;
extern fn m_malloc0(num_bytes: usize) callconv(.c) ?*anyopaque;
extern fn m_free(ptr: ?*anyopaque) callconv(.c) void;
extern fn mp_obj_is_native_exception_instance(o: Obj) callconv(.c) bool;
extern fn mp_map_init(map: *mirrors.MpMap, n: usize) callconv(.c) void;
extern fn mp_obj_is_dict_or_ordereddict(o: Obj) callconv(.c) bool;
extern fn mp_printf(print: ?*const anyopaque, fmt: [*:0]const u8, ...) callconv(.c) c_int;
extern const mp_type_int: anyopaque;
extern const mp_type_dict: anyopaque;

// `mp_obj_is_int` (obj.h macro): smallint OR exact-type mp_type_int.
inline fn isInt(o: Obj) bool {
    return mirrors.isSmallInt(o) or mirrors.isExactType(o, &mp_type_int);
}
// `mp_obj_is_fun` (obj.h macro): heap obj AND base.type.name == MP_QSTR_function.
inline fn isFun(o: Obj) bool {
    if (!mirrors.isObj(o)) return false;
    const t = mirrors.objBaseType(o);
    return mirrors.MpObjType.fromPtr(t).name == mp.MP_QSTR_function;
}
inline fn newSuper(type_obj: Obj, obj: Obj) Obj {
    const o: *mirrors.MpObjSuper = @ptrCast(@alignCast(mp_obj_malloc_helper(@sizeOf(mirrors.MpObjSuper), &mp_type_super).?));
    o.base = .{ .type = &mp_type_super };
    o.type = type_obj;
    o.obj = obj;
    return @intFromPtr(o);
}

// `mp_obj_instance_t.subobj[0]` and `.base.type` accessors via mp_mirrors.
inline fn instanceSubobj0(self_in: Obj) Obj {
    return mirrors.MpObjInstance.fromObj(self_in).subobjPtr()[0];
}
inline fn instancePtrSubobj0(obj_ptr: ?*const anyopaque) Obj {
    const inst: *mirrors.MpObjInstance = @ptrCast(@alignCast(@constCast(obj_ptr.?)));
    return inst.subobjPtr()[0];
}
inline fn instancePtrType(obj_ptr: ?*const anyopaque) ?*const anyopaque {
    const inst: *const mirrors.MpObjInstance = @ptrCast(@alignCast(obj_ptr.?));
    return inst.base.type;
}
inline fn instancePtrAsObj(obj_ptr: ?*const anyopaque) Obj {
    return @intFromPtr(obj_ptr);
}
inline fn instancePtrSetSubobj0(obj_ptr: ?*anyopaque, value: Obj) void {
    const inst: *mirrors.MpObjInstance = @ptrCast(@alignCast(obj_ptr.?));
    inst.subobjPtr()[0] = value;
}

inline fn newStaticClassMethod(self_type: ?*const anyopaque, arg: Obj) Obj {
    const o: *mirrors.MpObjStaticClassMethod = @ptrCast(@alignCast(m_malloc(@sizeOf(mirrors.MpObjStaticClassMethod)).?));
    o.base = .{ .type = self_type };
    o.fun = @ptrFromInt(arg);
    return @intFromPtr(o);
}

// `mp_obj_type_t.name` qstr accessor.
inline fn typeNameQstr(type_ptr: ?*const anyopaque) u32 {
    return mirrors.MpObjType.fromPtr(type_ptr).name;
}

// `mp_map_t.used` accessor for kw_args.
inline fn mapUsed(map_ptr: ?*const anyopaque) usize {
    const m: *const mirrors.MpMap = @ptrCast(@alignCast(map_ptr.?));
    return m.bits.used;
}

// `mp_obj_new_type` base-flags constant (vendor objtype.c:929).
const TYPE_BASE_FLAGS: u16 = mirrors.FLAG_EQ_NOT_REFLEXIVE |
    mirrors.FLAG_EQ_CHECKS_OTHER_TYPE |
    mirrors.FLAG_EQ_HAS_NEQ_TEST |
    mirrors.FLAG_ITER_IS_GETITER |
    mirrors.FLAG_INSTANCE_TYPE;

// Tail-recursive walk up the parent chain. MI=0 → the multiple-inheritance
// tuple branch is dead; only the single-parent rewrite is live.
export fn mp_obj_is_subclass_fast(object_in: Obj, classinfo: Obj) callconv(.c) bool {
    var object = object_in;
    while (true) {
        if (object == classinfo) return true;
        // object should always be a type Obj; fail gracefully if not.
        if (!isTypeType(object)) return false;
        const self_type = objToTypePtr(object);
        if (!typeHasParent(self_type)) return false;
        if (comptime build_options.multiple_inheritance) {
            // MI=1: parent may be a tuple of types. Iterate items, recurse;
            // tail-fall-through into the last for single-parent fast path.
            if (parentIsTuple(self_type)) {
                var n: usize = 0;
                var items: [*c]const Obj = undefined;
                parentTupleItems(self_type, &n, &items);
                if (n == 0) return false;
                var i: usize = 0;
                while (i + 1 < n) : (i += 1) {
                    if (mp_obj_is_subclass_fast(items[i], classinfo)) return true;
                }
                // tail: continue with last parent
                object = items[n - 1];
                continue;
            }
        }
        // Single parent (nano-only, or full with single parent).
        object = mirrors.objFromPtr(typeParent(self_type));
    }
}

export fn mp_obj_cast_to_native_base(self_in: Obj, native_type: Obj) callconv(.c) Obj {
    const self_type = mp_obj_get_type(self_in);
    const self_type_obj = mirrors.objFromPtr(self_type);
    if (self_type_obj == native_type) {
        return self_in;
    } else if (!mp_obj_is_subclass_fast(self_type_obj, native_type)) {
        return MP_OBJ_NULL;
    } else {
        return instanceSubobj0(self_in);
    }
}

// ── seam 2: is_callable + load_super_method ────────────────────────

// C: mp_obj_t member[2] = {NULL, NULL}; return get_call(self_in, member) != NULL;
export fn mp_obj_instance_is_callable(self_in: Obj) callconv(.c) bool {
    var member: [2]Obj = .{ MP_OBJ_NULL, MP_OBJ_NULL };
    return mp_obj_instance_get_call(self_in, &member) != MP_OBJ_NULL;
}

// C: mp_obj_super_t super = {{&mp_type_super}, dest[1], dest[2]};
//    mp_load_method(MP_OBJ_FROM_PTR(&super), attr, dest);
extern fn mp_load_method(base: Obj, attr: usize, dest: [*c]Obj) callconv(.c) void;

export fn mp_load_super_method(attr: usize, dest: [*c]Obj) callconv(.c) void {
    var super: mirrors.MpObjSuper = .{
        .base = .{ .type = &mp_type_super },
        .type = dest[1],
        .obj = dest[2],
    };
    mp_load_method(@intFromPtr(&super), attr, dest);
}

// ── seam 3: instance_call (the only public objtype fn with a live raise) ──
fn raiseNotCallable() PyError!void {
    pyerr.pending_exc = typeErrorMsg("object not callable");
    return error.PyRaise;
}

fn instanceCallImpl(self_in: Obj, n_args: usize, n_kw: usize, args: [*c]const Obj) PyError!Obj {
    var member: [2]Obj = .{ MP_OBJ_NULL, MP_OBJ_NULL };
    const call = mp_obj_instance_get_call(self_in, &member);
    if (call == MP_OBJ_NULL) {
        try raiseNotCallable();
        unreachable;
    }
    if (call == MP_OBJ_SENTINEL) {
        // Built-in native base callable via subobj[0].
        return mp_call_function_n_kw(instanceSubobj0(self_in), n_args, n_kw, args);
    }
    return mp_call_method_self_n_kw(member[0], member[1], n_args, n_kw, args);
}
export fn mp_obj_instance_call(self_in: Obj, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, instanceCallImpl(self_in, n_args, n_kw, args));
}

// ── seam 4: mp_obj_is_subclass + mp_builtin_issubclass + mp_builtin_isinstance ──
//
// mp_obj_is_subclass was static in the C source but is also called by the
// still-C super_attr. Exporting it lets the still-C caller resolve through
// the standard extern symbol. Public mp_builtin_{issubclass,isinstance} are
// the targets of MP_DEFINE_CONST_FUN_OBJ_2 in the shim.

// Already-Zig: mp_obj_tuple_get (objtuple.zig).
extern fn mp_obj_tuple_get(self_in: Obj, len_out: *usize, items_out: *[*c]Obj) callconv(.c) void;

fn raiseIssubclassArg1() PyError!void {
    pyerr.pending_exc = typeErrorMsg("issubclass() arg 1 must be a class");
    return error.PyRaise;
}
fn raiseIssubclassArg2() PyError!void {
    pyerr.pending_exc = typeErrorMsg("issubclass() arg 2 must be a class or a tuple of classes");
    return error.PyRaise;
}

/// The `__args__` tuple of a typing.UnionType, or null. A GenericAlias
/// such as `list[int]` also has `__args__`, and `__origin__` besides.
fn unionArgs(o: Obj) Obj {
    var dest: [2]Obj = .{ MP_OBJ_NULL, MP_OBJ_NULL };
    mp_load_method_maybe(o, mp.MP_QSTR___origin__, &dest);
    if (dest[0] != MP_OBJ_NULL) return MP_OBJ_NULL;
    mp_load_method_maybe(o, mp.MP_QSTR___args__, &dest);
    return if (dest[0] != MP_OBJ_NULL and isTypeTuple(dest[0])) dest[0] else MP_OBJ_NULL;
}

fn isSubclassImpl(object: Obj, classinfo_in: Obj) PyError!Obj {
    var classinfo = classinfo_in;
    var len: usize = 0;
    var items: [*c]Obj = undefined;
    if (isTypeType(classinfo)) {
        len = 1;
        items = @ptrCast(&classinfo);
    } else if (isTypeTuple(classinfo)) {
        mp_obj_tuple_get(classinfo, &len, &items);
    } else if (build_options.is_full and unionArgs(classinfo) != MP_OBJ_NULL) {
        // `int | None`, as the tuple of its members.
        mp_obj_tuple_get(unionArgs(classinfo), &len, &items);
    } else {
        try raiseIssubclassArg2();
        unreachable;
    }

    const object_type_obj = mirrors.objFromPtr(&mp_type_object);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        // Explicit short-circuit for &mp_type_object (no class derives from it explicitly).
        if (items[i] == object_type_obj or mp_obj_is_subclass_fast(object, items[i])) {
            return MP_OBJ_TRUE;
        }
    }
    return MP_OBJ_FALSE;
}
export fn mp_obj_is_subclass(object: Obj, classinfo: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, isSubclassImpl(object, classinfo));
}

fn builtinIssubclassImpl(object: Obj, classinfo: Obj) PyError!Obj {
    if (!isTypeType(object)) {
        try raiseIssubclassArg1();
        unreachable;
    }
    return try isSubclassImpl(object, classinfo);
}
export fn mp_builtin_issubclass(object: Obj, classinfo: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, builtinIssubclassImpl(object, classinfo));
}

fn builtinIsinstanceImpl(object: Obj, classinfo: Obj) PyError!Obj {
    return try isSubclassImpl(mirrors.objFromPtr(mp_obj_get_type(object)), classinfo);
}
export fn mp_builtin_isinstance(object: Obj, classinfo: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, builtinIsinstanceImpl(object, classinfo));
}

// MP_DEFINE_CONST_FUN_OBJ_2(mp_builtin_issubclass_obj, mp_builtin_issubclass);
// MP_DEFINE_CONST_FUN_OBJ_2(mp_builtin_isinstance_obj, mp_builtin_isinstance);
// mp_type_fun_builtin_2 is provided by vendor objfun.c (still C).
extern const mp_type_fun_builtin_2: opaque {};
pub export const mp_builtin_issubclass_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&mp_builtin_issubclass),
};
pub export const mp_builtin_isinstance_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_2 },
    .fun = @ptrCast(&mp_builtin_isinstance),
};

// ── ROM type singletons (mp_type_type, mp_type_super, mp_type_staticmethod,
//    mp_type_classmethod) ──
// Vendor objtype.c defines these via MP_DEFINE_CONST_OBJ_TYPE macros; we
// expand them inline as Zig struct literals (the same pattern as
// mp_type_roms.zig). Slot order matches the macro's argument order.
const mp_type_roms = @import("../../mp_type_roms.zig");
const MpObjTypeFull = mp_type_roms.MpObjTypeFull;
const TYPE_FLAG_NONE: u16 = 0x0000;

// mp_type_type — the meta-type. Self-referential: base.type = &mp_type_type.
// Slots: make_new=1, print=2, call=3, attr=4.
pub export const mp_type_type: MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = @ptrCast(&mp_type_type) },
        .flags = TYPE_FLAG_NONE,
        .name = mp.MP_QSTR_type,
        .slot_index_make_new = 1,
        .slot_index_print = 2,
        .slot_index_call = 3,
        .slot_index_unary_op = 0,
        .slot_index_binary_op = 0,
        .slot_index_attr = 4,
        .slot_index_subscr = 0,
        .slot_index_iter = 0,
        .slot_index_buffer = 0,
        .slot_index_protocol = 0,
        .slot_index_parent = 0,
        .slot_index_locals_dict = 0,
    },
    .slots = .{
        @ptrCast(&type_make_new),
        @ptrCast(&type_print),
        @ptrCast(&type_call),
        @ptrCast(&type_attr),
        null,
        null,
        null,
        null,
        null,
        null,
        null,
    },
};

// mp_type_super — slots: make_new=1, print=2, attr=3.
pub export const mp_type_super: MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = TYPE_FLAG_NONE,
        .name = mp.MP_QSTR_super,
        .slot_index_make_new = 1,
        .slot_index_print = 2,
        .slot_index_call = 0,
        .slot_index_unary_op = 0,
        .slot_index_binary_op = 0,
        .slot_index_attr = 3,
        .slot_index_subscr = 0,
        .slot_index_iter = 0,
        .slot_index_buffer = 0,
        .slot_index_protocol = 0,
        .slot_index_parent = 0,
        .slot_index_locals_dict = 0,
    },
    .slots = .{
        @ptrCast(&super_make_new),
        @ptrCast(&super_print),
        @ptrCast(&super_attr),
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

// mp_type_staticmethod / mp_type_classmethod — same make_new slot;
// the runtime distinguishes them by their type pointer identity.
pub export const mp_type_staticmethod: MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = TYPE_FLAG_NONE,
        .name = mp.MP_QSTR_staticmethod,
        .slot_index_make_new = 1,
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
    .slots = .{
        @ptrCast(&static_class_method_make_new),
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
pub export const mp_type_classmethod: MpObjTypeFull = .{
    .header = .{
        .base = .{ .type = &mp_type_type },
        .flags = TYPE_FLAG_NONE,
        .name = mp.MP_QSTR_classmethod,
        .slot_index_make_new = 1,
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
    .slots = .{
        @ptrCast(&static_class_method_make_new),
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

// native_base_init_wrapper_obj: MP_DEFINE_CONST_FUN_OBJ_KW(name, n_args_min=1, fun)
// Expands to mp_obj_fun_builtin_var_t with sig = MAKE_SIG(1, ARGS_MAX, true).
extern const mp_type_fun_builtin_var: opaque {};
pub export const native_base_init_wrapper_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(1, 0xffff, true),
    .fun = @ptrCast(&native_base_init_wrapper),
};

// ── byte tables: special-method qstr lookup keyed by op enum ───────
// Vendor objtype.c lines 104-195. Public exports used by py/runtime.c and
// py/emitnative.c (the latter is nano-disabled). All entries that are
// non-zero have config-dependent presence; nano + full both enable
// ALL_SPECIAL_METHODS + ALL_INPLACE_SPECIAL_METHODS + REVERSE_SPECIAL_METHODS
// + BUILTINS_FLOAT, so those flag-gated entries are always populated.
// COMPLEX (full-only) and SYS_GETSIZEOF (full-only) follow build_options.is_full.
pub export const mp_unary_op_method_name = blk: {
    var tbl: [mp.MP_UNARY_OP_NUM_RUNTIME]u8 = .{0} ** mp.MP_UNARY_OP_NUM_RUNTIME;
    tbl[@intCast(mp.MP_UNARY_OP_BOOL)] = mp.MP_QSTR___bool__;
    tbl[@intCast(mp.MP_UNARY_OP_LEN)] = mp.MP_QSTR___len__;
    tbl[@intCast(mp.MP_UNARY_OP_HASH)] = mp.MP_QSTR___hash__;
    tbl[@intCast(mp.MP_UNARY_OP_INT_MAYBE)] = mp.MP_QSTR___int__;
    // MICROPY_PY_ALL_SPECIAL_METHODS=1 in both nano + full.
    tbl[@intCast(mp.MP_UNARY_OP_POSITIVE)] = mp.MP_QSTR___pos__;
    tbl[@intCast(mp.MP_UNARY_OP_NEGATIVE)] = mp.MP_QSTR___neg__;
    tbl[@intCast(mp.MP_UNARY_OP_INVERT)] = mp.MP_QSTR___invert__;
    tbl[@intCast(mp.MP_UNARY_OP_ABS)] = mp.MP_QSTR___abs__;
    // MICROPY_PY_BUILTINS_FLOAT=1 in both.
    tbl[@intCast(mp.MP_UNARY_OP_FLOAT_MAYBE)] = mp.MP_QSTR___float__;
    // MICROPY_PY_BUILTINS_COMPLEX: nano=0, full=1. Use @hasDecl to detect
    // whether the qstr exists in the generated header for this config.
    if (@hasDecl(mp, "MP_QSTR___complex__")) {
        tbl[@intCast(mp.MP_UNARY_OP_COMPLEX_MAYBE)] = mp.MP_QSTR___complex__;
    }
    // MICROPY_PY_SYS_GETSIZEOF: off in both nano and full (ROM_LEVEL_MINIMUM).
    if (@hasDecl(mp, "MP_QSTR___sizeof__")) {
        tbl[@intCast(mp.MP_UNARY_OP_SIZEOF)] = mp.MP_QSTR___sizeof__;
    }
    break :blk tbl;
};

pub export const mp_binary_op_method_name = blk: {
    var tbl: [mp.MP_BINARY_OP_NUM_RUNTIME]u8 = .{0} ** mp.MP_BINARY_OP_NUM_RUNTIME;
    tbl[@intCast(mp.MP_BINARY_OP_LESS)] = mp.MP_QSTR___lt__;
    tbl[@intCast(mp.MP_BINARY_OP_MORE)] = mp.MP_QSTR___gt__;
    tbl[@intCast(mp.MP_BINARY_OP_EQUAL)] = mp.MP_QSTR___eq__;
    tbl[@intCast(mp.MP_BINARY_OP_LESS_EQUAL)] = mp.MP_QSTR___le__;
    tbl[@intCast(mp.MP_BINARY_OP_MORE_EQUAL)] = mp.MP_QSTR___ge__;
    tbl[@intCast(mp.MP_BINARY_OP_NOT_EQUAL)] = mp.MP_QSTR___ne__;
    tbl[@intCast(mp.MP_BINARY_OP_CONTAINS)] = mp.MP_QSTR___contains__;
    tbl[@intCast(mp.MP_BINARY_OP_INPLACE_ADD)] = mp.MP_QSTR___iadd__;
    tbl[@intCast(mp.MP_BINARY_OP_INPLACE_SUBTRACT)] = mp.MP_QSTR___isub__;
    // MICROPY_PY_ALL_INPLACE_SPECIAL_METHODS=1 in both.
    tbl[@intCast(mp.MP_BINARY_OP_INPLACE_MULTIPLY)] = mp.MP_QSTR___imul__;
    tbl[@intCast(mp.MP_BINARY_OP_INPLACE_MAT_MULTIPLY)] = mp.MP_QSTR___imatmul__;
    tbl[@intCast(mp.MP_BINARY_OP_INPLACE_FLOOR_DIVIDE)] = mp.MP_QSTR___ifloordiv__;
    tbl[@intCast(mp.MP_BINARY_OP_INPLACE_TRUE_DIVIDE)] = mp.MP_QSTR___itruediv__;
    tbl[@intCast(mp.MP_BINARY_OP_INPLACE_MODULO)] = mp.MP_QSTR___imod__;
    tbl[@intCast(mp.MP_BINARY_OP_INPLACE_POWER)] = mp.MP_QSTR___ipow__;
    tbl[@intCast(mp.MP_BINARY_OP_INPLACE_OR)] = mp.MP_QSTR___ior__;
    tbl[@intCast(mp.MP_BINARY_OP_INPLACE_XOR)] = mp.MP_QSTR___ixor__;
    tbl[@intCast(mp.MP_BINARY_OP_INPLACE_AND)] = mp.MP_QSTR___iand__;
    tbl[@intCast(mp.MP_BINARY_OP_INPLACE_LSHIFT)] = mp.MP_QSTR___ilshift__;
    tbl[@intCast(mp.MP_BINARY_OP_INPLACE_RSHIFT)] = mp.MP_QSTR___irshift__;
    tbl[@intCast(mp.MP_BINARY_OP_ADD)] = mp.MP_QSTR___add__;
    tbl[@intCast(mp.MP_BINARY_OP_SUBTRACT)] = mp.MP_QSTR___sub__;
    // MICROPY_PY_ALL_SPECIAL_METHODS=1 in both.
    tbl[@intCast(mp.MP_BINARY_OP_MULTIPLY)] = mp.MP_QSTR___mul__;
    tbl[@intCast(mp.MP_BINARY_OP_MAT_MULTIPLY)] = mp.MP_QSTR___matmul__;
    tbl[@intCast(mp.MP_BINARY_OP_FLOOR_DIVIDE)] = mp.MP_QSTR___floordiv__;
    tbl[@intCast(mp.MP_BINARY_OP_TRUE_DIVIDE)] = mp.MP_QSTR___truediv__;
    tbl[@intCast(mp.MP_BINARY_OP_MODULO)] = mp.MP_QSTR___mod__;
    tbl[@intCast(mp.MP_BINARY_OP_DIVMOD)] = mp.MP_QSTR___divmod__;
    tbl[@intCast(mp.MP_BINARY_OP_POWER)] = mp.MP_QSTR___pow__;
    tbl[@intCast(mp.MP_BINARY_OP_OR)] = mp.MP_QSTR___or__;
    tbl[@intCast(mp.MP_BINARY_OP_XOR)] = mp.MP_QSTR___xor__;
    tbl[@intCast(mp.MP_BINARY_OP_AND)] = mp.MP_QSTR___and__;
    tbl[@intCast(mp.MP_BINARY_OP_LSHIFT)] = mp.MP_QSTR___lshift__;
    tbl[@intCast(mp.MP_BINARY_OP_RSHIFT)] = mp.MP_QSTR___rshift__;
    // MICROPY_PY_REVERSE_SPECIAL_METHODS=1 in both.
    tbl[@intCast(mp.MP_BINARY_OP_REVERSE_ADD)] = mp.MP_QSTR___radd__;
    tbl[@intCast(mp.MP_BINARY_OP_REVERSE_SUBTRACT)] = mp.MP_QSTR___rsub__;
    tbl[@intCast(mp.MP_BINARY_OP_REVERSE_MULTIPLY)] = mp.MP_QSTR___rmul__;
    tbl[@intCast(mp.MP_BINARY_OP_REVERSE_MAT_MULTIPLY)] = mp.MP_QSTR___rmatmul__;
    tbl[@intCast(mp.MP_BINARY_OP_REVERSE_FLOOR_DIVIDE)] = mp.MP_QSTR___rfloordiv__;
    tbl[@intCast(mp.MP_BINARY_OP_REVERSE_TRUE_DIVIDE)] = mp.MP_QSTR___rtruediv__;
    tbl[@intCast(mp.MP_BINARY_OP_REVERSE_MODULO)] = mp.MP_QSTR___rmod__;
    tbl[@intCast(mp.MP_BINARY_OP_REVERSE_POWER)] = mp.MP_QSTR___rpow__;
    tbl[@intCast(mp.MP_BINARY_OP_REVERSE_OR)] = mp.MP_QSTR___ror__;
    tbl[@intCast(mp.MP_BINARY_OP_REVERSE_XOR)] = mp.MP_QSTR___rxor__;
    tbl[@intCast(mp.MP_BINARY_OP_REVERSE_AND)] = mp.MP_QSTR___rand__;
    tbl[@intCast(mp.MP_BINARY_OP_REVERSE_LSHIFT)] = mp.MP_QSTR___rlshift__;
    tbl[@intCast(mp.MP_BINARY_OP_REVERSE_RSHIFT)] = mp.MP_QSTR___rrshift__;
    break :blk tbl;
};

// ── seam 5: mp_obj_class_lookup ──
//
// Central MRO walker. Under nano: MI=0 (parent is always a single type),
// BUILTIN_METHOD_CHECK_SELF_ARG=0 (the AttributeError raise is dead),
// DEBUG_PRINT=0 (the trace printfs compile out). 0 live raises.
//
// Called from the shim via a static-C trampoline that preserves the
// struct-based ABI; this fn takes its 5 lookup fields plus the starting
// type as flat parameters.

extern fn mp_load_method_maybe(base: Obj, attr: usize, dest: [*c]Obj) callconv(.c) void;
extern fn mp_convert_member_lookup(obj: Obj, type_in: ?*const anyopaque, member: Obj, dest: [*c]Obj) callconv(.c) void;

export fn npy_ty_class_lookup(
    obj_in: ?*const anyopaque,
    attr: usize,
    slot_offset: usize,
    dest: [*c]Obj,
    is_type: c_int,
    type_in: ?*const anyopaque,
) callconv(.c) void {
    const object_type_ptr = @as(?*const anyopaque, &mp_type_object);
    var t: ?*const anyopaque = type_in;
    while (true) {
        // 1. Native-type slot fast path: special-method lookup via slot offset.
        if (slot_offset != 0 and typeIsNative(t)) {
            if (typeHasSlotByOffset(t, slot_offset) or
                (slot_offset == SLOT_OFFSET_ITER and typeFlagIterIsStream(t)))
            {
                dest[0] = MP_OBJ_SENTINEL;
                return;
            }
        }

        // 2. locals_dict (methods/attrs) search.
        if (typeHasLocalsDict(t)) {
            const locals_map = typeLocalsMap(t);
            const elem = mirrors.mp_map_lookup(locals_map, mirrors.objFromQstr(attr), mirrors.MP_MAP_LOOKUP);
            if (elem) |e| {
                const elem_value = e.value;
                if (is_type != 0) {
                    // Class method: return the *original* type, not the (base) type the
                    // method was found in. lookup->obj is the original type ptr here.
                    mp_convert_member_lookup(MP_OBJ_NULL, obj_in, elem_value, dest);
                } else {
                    var obj_obj: Obj = MP_OBJ_NULL;
                    if (obj_in != null and typeIsNative(t) and t != object_type_ptr) {
                        // Native base class: applies to the native subobj.
                        obj_obj = instancePtrSubobj0(obj_in);
                        // MICROPY_BUILTIN_METHOD_CHECK_SELF_ARG=0 under nano → no init-check raise.
                    } else {
                        obj_obj = instancePtrAsObj(obj_in);
                    }
                    mp_convert_member_lookup(obj_obj, t, elem_value, dest);
                }
                return;
            }
        }

        // 3. Native load_attr fallback for attributes not in locals_dict.
        if (obj_in != null and is_type == 0 and typeIsNative(t) and t != object_type_ptr) {
            mp_load_method_maybe(instancePtrSubobj0(obj_in), attr, dest);
            if (dest[0] != MP_OBJ_NULL) return;
        }

        // 4. Parent walk.
        if (!typeHasParent(t)) return;
        if (comptime build_options.multiple_inheritance) {
            // MI: if parent is a tuple, recurse into each base.
            if (parentIsTuple(t)) {
                var n: usize = 0;
                var items: [*c]const Obj = undefined;
                parentTupleItems(t, &n, &items);
                if (n == 0) return;
                var i: usize = 0;
                // Recurse into all but the last; tail-fall the last.
                while (i + 1 < n) : (i += 1) {
                    const parent_t = objToTypePtr(items[i]);
                    if (parent_t != object_type_ptr) {
                        npy_ty_class_lookup(obj_in, attr, slot_offset, dest, is_type, parent_t);
                        if (dest[0] != MP_OBJ_NULL) return;
                    }
                }
                t = objToTypePtr(items[n - 1]);
                if (t == object_type_ptr) return;
                continue;
            }
        }
        // Single parent.
        t = typeParent(t);
        if (t == object_type_ptr) return;
    }
}

// ── seam 6: mp_obj_instance_getiter (public; 0 live raises) ──
//
// Look up __iter__ via class_lookup, then either:
//   - SENTINEL: dispatch the native type's iter slot (or return subobj[0]
//     directly for MP_TYPE_FLAG_ITER_IS_ITERNEXT classes)
//   - non-NULL: call the bound method
//   - NULL: return NULL (no iter support)

extern fn mp_call_method_n_kw(n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj;

export fn mp_obj_instance_getiter(self_in: Obj, iter_buf_in: ?*anyopaque) callconv(.c) Obj {
    var iter_buf = iter_buf_in;
    const self_ptr: ?*const anyopaque = @ptrFromInt(self_in);
    var member: [2]Obj = .{ MP_OBJ_NULL, MP_OBJ_NULL };
    npy_ty_class_lookup(
        self_ptr,
        mp.MP_QSTR___iter__,
        SLOT_OFFSET_ITER,
        @ptrCast(&member),
        0,
        instancePtrType(self_ptr),
    );
    if (member[0] == MP_OBJ_NULL) {
        return MP_OBJ_NULL;
    } else if (member[0] == MP_OBJ_SENTINEL) {
        const subobj0 = instanceSubobj0(self_in);
        const native_type = mp_obj_get_type(subobj0);
        if (typeFlagIterIsIternext(native_type)) {
            return subobj0;
        }
        if (iter_buf == null) {
            // mp_obj_iter_buf_t = base + 3*Obj = 4 ptr-sized words.
            iter_buf = m_malloc(4 * @sizeOf(usize));
        }
        return typeCallIterSlot(native_type, subobj0, iter_buf);
    } else {
        return mp_call_method_n_kw(0, 0, &member);
    }
}

// ── seam 7: instance_unary_op + instance_binary_op ──
//
// Under nano:
// - MICROPY_PY_SYS_GETSIZEOF=0 → SIZEOF block in unary is dead
// - MICROPY_PY_BUILTINS_NOTIMPLEMENTED=0 → notimplemented check in binary is dead
// instance_unary_op carries 1 live raise (TypeError() on INT_MAYBE non-int).
// instance_binary_op has 0 live raises.

extern fn mp_call_function_1(fun: Obj, arg: Obj) callconv(.c) Obj;
extern fn mp_obj_get_int_truncated(arg: Obj) callconv(.c) isize;
extern fn mp_obj_is_true(arg: Obj) callconv(.c) bool;
extern fn mp_binary_op(op: c_int, lhs: Obj, rhs: Obj) callconv(.c) Obj;
extern fn mp_unary_op(op: c_int, arg: Obj) callconv(.c) Obj;

fn raiseTypeErrorNull() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception(&mp_type_TypeError);
    return error.PyRaise;
}

fn instanceUnaryOpImpl(op: c_int, self_in: Obj) PyError!Obj {
    const self_ptr: ?*const anyopaque = @ptrFromInt(self_in);
    const op_name: u32 = mp_unary_op_method_name[@intCast(op)];
    var member: [2]Obj = .{ MP_OBJ_NULL, MP_OBJ_NULL };
    npy_ty_class_lookup(
        self_ptr,
        op_name,
        SLOT_OFFSET_UNARY_OP,
        @ptrCast(&member),
        0,
        instancePtrType(self_ptr),
    );
    if (member[0] == MP_OBJ_SENTINEL) {
        return mp_unary_op(op, instanceSubobj0(self_in));
    } else if (member[0] != MP_OBJ_NULL) {
        var val = mp_call_function_1(member[0], self_in);
        if (pyerr.pending_exc != 0) return error.PyRaise; // B2: propagate
        if (op == mp.MP_UNARY_OP_HASH) {
            // __hash__ must return a small int.
            val = mirrors.newSmallInt(mp_obj_get_int_truncated(val));
        } else if (op == mp.MP_UNARY_OP_INT_MAYBE) {
            // Must return int.
            if (!isInt(val)) {
                try raiseTypeErrorNull();
                unreachable;
            }
        }
        return val;
    } else {
        if (op == mp.MP_UNARY_OP_HASH) {
            // Reuse member[2] buffer; re-lookup with __eq__.
            member[0] = MP_OBJ_NULL;
            member[1] = MP_OBJ_NULL;
            npy_ty_class_lookup(
                self_ptr,
                mp.MP_QSTR___eq__,
                SLOT_OFFSET_UNARY_OP,
                @ptrCast(&member),
                0,
                instancePtrType(self_ptr),
            );
            if (member[0] == MP_OBJ_NULL) {
                // Default hash: identity-based small int (the object's address).
                return mirrors.newSmallInt(@bitCast(self_in));
            }
        }
        return MP_OBJ_NULL; // op not supported
    }
}
export fn instance_unary_op(op: c_int, self_in: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, instanceUnaryOpImpl(op, self_in));
}

export fn instance_binary_op(op: c_int, lhs_in: Obj, rhs_in: Obj) callconv(.c) Obj {
    // Note: For ducktyping, CPython does not look in the instance members or use
    // __getattr__/__getattribute__. Only the class dictionary.
    const lhs_ptr: ?*const anyopaque = @ptrFromInt(lhs_in);
    const op_name: u32 = mp_binary_op_method_name[@intCast(op)];
    var dest: [3]Obj = .{ MP_OBJ_NULL, MP_OBJ_NULL, MP_OBJ_NULL };
    npy_ty_class_lookup(
        lhs_ptr,
        op_name,
        SLOT_OFFSET_BINARY_OP,
        @ptrCast(&dest),
        0,
        instancePtrType(lhs_ptr),
    );
    var res: Obj = undefined;
    if (dest[0] == MP_OBJ_SENTINEL) {
        res = mp_binary_op(op, instanceSubobj0(lhs_in), rhs_in);
    } else if (dest[0] != MP_OBJ_NULL) {
        dest[2] = rhs_in;
        res = mp_call_method_n_kw(1, 0, &dest);
        if (op == mp.MP_BINARY_OP_CONTAINS) {
            res = if (mp_obj_is_true(res)) MP_OBJ_TRUE else MP_OBJ_FALSE;
        }
    } else {
        return MP_OBJ_NULL; // op not supported
    }
    // MICROPY_PY_BUILTINS_NOTIMPLEMENTED: NotImplemented means "try other
    // fallbacks (e.g. __rop__) and if nothing works, raise TypeError".
    if (build_options.is_full and res == constNotImplemented()) {
        return MP_OBJ_NULL;
    }
    return res;
}

// ── seam 8: instance_subscr + mp_obj_instance_get_call + instance_get_buffer (0 raises) ──

extern fn mp_obj_subscr(base: Obj, index: Obj, value: Obj) callconv(.c) Obj;

export fn instance_subscr(self_in: Obj, index: Obj, value: Obj) callconv(.c) Obj {
    const self_ptr: ?*const anyopaque = @ptrFromInt(self_in);
    var member: [4]Obj = .{ MP_OBJ_NULL, MP_OBJ_NULL, index, value };
    var attr: u32 = undefined;
    if (value == MP_OBJ_NULL) {
        attr = mp.MP_QSTR___delitem__;
    } else if (value == MP_OBJ_SENTINEL) {
        attr = mp.MP_QSTR___getitem__;
    } else {
        attr = mp.MP_QSTR___setitem__;
    }
    npy_ty_class_lookup(
        self_ptr,
        attr,
        SLOT_OFFSET_SUBSCR,
        @ptrCast(&member),
        0,
        instancePtrType(self_ptr),
    );
    if (member[0] == MP_OBJ_SENTINEL) {
        const ret = mp_obj_subscr(instanceSubobj0(self_in), index, value);
        // ADR 010 §C1 — CPython __missing__ protocol on dict subclasses.
        // When the subobj's __getitem__ raises KeyError and the subclass
        // defines __missing__, call __missing__(self, key) and return
        // its result instead. This is what makes
        // `class D(dict): def __missing__(self, k): ...` work, including
        // the equivalent `class C(Counter)` and `defaultdict` idioms.
        if (value == MP_OBJ_SENTINEL and ret == MP_OBJ_NULL and pyerr.pending_exc != 0) {
            const exc = pyerr.pending_exc;
            if (mp_obj_is_subclass_fast(mirrors.objFromPtr(mirrors.objBaseType(exc)), mirrors.objFromPtr(&mp_type_KeyError))) {
                var miss_member: [3]Obj = .{ MP_OBJ_NULL, MP_OBJ_NULL, index };
                npy_ty_class_lookup(
                    self_ptr,
                    mp.MP_QSTR___missing__,
                    0,
                    @ptrCast(&miss_member),
                    0,
                    instancePtrType(self_ptr),
                );
                if (miss_member[0] != MP_OBJ_NULL and miss_member[0] != MP_OBJ_SENTINEL) {
                    // Clear the KeyError and call __missing__.
                    pyerr.pending_exc = 0;
                    return mp_call_method_n_kw(1, 0, &miss_member);
                }
            }
        }
        return ret;
    } else if (member[0] != MP_OBJ_NULL) {
        const n_args: usize = if (value == MP_OBJ_NULL or value == MP_OBJ_SENTINEL) 1 else 2;
        const ret = mp_call_method_n_kw(n_args, 0, &member);
        if (value == MP_OBJ_SENTINEL) return ret;
        return MP_OBJ_NONE;
    }
    return MP_OBJ_NULL;
}

extern const mp_type_KeyError: anyopaque;

export fn mp_obj_instance_get_call(self_in: Obj, member: [*c]Obj) callconv(.c) Obj {
    const self_ptr: ?*const anyopaque = @ptrFromInt(self_in);
    npy_ty_class_lookup(
        self_ptr,
        mp.MP_QSTR___call__,
        SLOT_OFFSET_CALL,
        member,
        0,
        instancePtrType(self_ptr),
    );
    return member[0];
}

export fn instance_get_buffer(self_in: Obj, bufinfo: ?*anyopaque, flags: usize) callconv(.c) isize {
    const self_ptr: ?*const anyopaque = @ptrFromInt(self_in);
    var member: [2]Obj = .{ MP_OBJ_NULL, MP_OBJ_NULL };
    npy_ty_class_lookup(
        self_ptr,
        mp.MP_QSTR_,
        SLOT_OFFSET_BUFFER,
        @ptrCast(&member),
        0,
        instancePtrType(self_ptr),
    );
    if (member[0] == MP_OBJ_SENTINEL) {
        const subobj0 = instanceSubobj0(self_in);
        const native_type = mp_obj_get_type(subobj0);
        return typeCallBufferSlot(native_type, subobj0, bufinfo, flags);
    }
    return 1; // op not supported
}

// ── seam 9: mp_obj_instance_load_attr / store_attr / instance_attr ──
//
// Under nano: PROPERTY=0, DESCRIPTORS=0, DELATTR_SETATTR=0, CPYTHON_COMPAT=0
// — all special-accessor branches are dead. The HAS_SPECIAL_ACCESSORS flag
// is only set by check_for_special_accessors (which is config-dead too), so
// the flag check below is preserved for faithfulness; the inner block has
// no live content under nano. 0 live raises.

export fn mp_obj_instance_load_attr(self_in: Obj, attr: u32, dest: [*c]Obj) callconv(.c) void {
    const self_ptr: ?*const anyopaque = @ptrFromInt(self_in);
    // Note: This is fast-path'ed in the VM for MP_BC_LOAD_ATTR.
    const inst: *mirrors.MpObjInstance = @ptrCast(@alignCast(@constCast(self_ptr.?)));
    if (mirrors.mp_map_lookup(&inst.members, mirrors.objFromQstr(attr), mirrors.MP_MAP_LOOKUP)) |elem| {
        dest[0] = elem.value;
        return;
    }
    // CPython-compat: instance.__dict__ → read-only copy of members map.
    if (build_options.is_full and attr == @as(u32, @intCast(mp.MP_QSTR___dict__))) {
        dest[0] = instanceDictReadonly(self_in);
        return;
    }
    npy_ty_class_lookup(
        self_ptr,
        attr,
        0,
        dest,
        0,
        instancePtrType(self_ptr),
    );
    const member = dest[0];
    if (member != MP_OBJ_NULL) {
        // v0.3: PROPERTY + DESCRIPTORS dispatch.
        const self_type = mp_obj_get_type(self_in);
        if (!typeFlagHasSpecialAccessors(self_type)) {
            return;
        }
        // PROPERTY: if member is a property, call its fget(self).
        if (memberIsProperty(member)) {
            const proxy = mp_obj_property_get(member);
            if (proxy[0] == MP_OBJ_NONE) {
                // unreadable attribute — leave dest[0] = MP_OBJ_NULL signalling fail.
                // (Upstream raises AttributeError; B2 polled would set pending_exc.)
                dest[0] = MP_OBJ_NULL;
                return;
            }
            var args1: [1]Obj = .{self_in};
            dest[0] = mp_call_function_n_kw(proxy[0], 1, 0, &args1);
            return;
        }
        // DESCRIPTORS: if member has __get__, call it with (self, type).
        var attr_get: [4]Obj = .{ MP_OBJ_NULL, MP_OBJ_NULL, MP_OBJ_NULL, MP_OBJ_NULL };
        const get_qstr_obj = mirrors.objFromQstr(mp.MP_QSTR___get__);
        mp_load_method_maybe(member, @intCast(get_qstr_obj >> 3), @ptrCast(&attr_get));
        if (attr_get[0] != MP_OBJ_NULL) {
            attr_get[2] = self_in;
            attr_get[3] = mirrors.objFromPtr(self_type);
            dest[0] = mp_call_method_n_kw(2, 0, &attr_get);
        }
        return;
    }
    // try __getattr__
    const getattr_qstr = mp.MP_QSTR___getattr__;
    if (attr != getattr_qstr) {
        // Vendor py/objtype.c:664-669 (MICROPY_PY_DESCRIPTORS, on for nano +
        // full). Don't delegate descriptor-protocol dunders to __getattr__:
        // outer descriptor probes at :220 / :1193 / :1246 / :1253 recurse
        // here with attr ∈ {__get__,__set__,__delete__,__set_name__}. Without
        // this guard, a class member whose type defines __getattr__ but no
        // __get__ etc. would have __getattr__ synthesize a phantom descriptor
        // method (printed "getattr __get__" / "getattr __set_name__" in
        // class_descriptor test). Pure correctness fix.
        if (attr == @as(u32, @intCast(mp.MP_QSTR___get__)) or
            attr == @as(u32, @intCast(mp.MP_QSTR___set__)) or
            attr == @as(u32, @intCast(mp.MP_QSTR___delete__)) or
            attr == @as(u32, @intCast(mp.MP_QSTR___set_name__)))
        {
            return;
        }
        // Vendor py/objtype.c:671-678 (MICROPY_PY_DELATTR_SETATTR — flipped
        // on for nano in v0.6.1 via build_options.delattr_setattr). The
        // store-attr __setattr__/__delattr__ probes at :1266 / :1273 recurse
        // through this same fallback; same guard shape.
        if (build_options.delattr_setattr) {
            if (attr == @as(u32, @intCast(mp.MP_QSTR___setattr__)) or
                attr == @as(u32, @intCast(mp.MP_QSTR___delattr__)))
            {
                return;
            }
        }
        var dest2: [3]Obj = .{ MP_OBJ_NULL, MP_OBJ_NULL, MP_OBJ_NULL };
        mp_load_method_maybe(self_in, getattr_qstr, &dest2);
        if (dest2[0] != MP_OBJ_NULL) {
            dest2[2] = qstrObj(attr);
            dest[0] = mp_call_method_n_kw(1, 0, &dest2);
            return;
        }
    }
}

export fn mp_obj_instance_store_attr(self_in: Obj, attr: u32, value: Obj) callconv(.c) bool {
    const self_ptr: ?*const anyopaque = @ptrFromInt(self_in);
    // Vendor objtype.c:691-810. Gating, per nano's MICROPY_* config:
    //   - HAS_SPECIAL_ACCESSORS early-out: unconditional (vendor has no #if).
    //   - property + descriptor block: PROPERTY || DESCRIPTORS, both = 1 on
    //     nano. Must be unconditional here too — gating on is_full silently
    //     no-ops property setters under nano, which is the bug the prior
    //     MI fix (e2f2c24) closed for load_attr but missed for store_attr.
    //   - __setattr__ / __delattr__ hooks: DELATTR_SETATTR, full only.
    const self_type = mp_obj_get_type(self_in);
    if (typeFlagHasSpecialAccessors(self_type)) {
        var member: [2]Obj = .{ MP_OBJ_NULL, MP_OBJ_NULL };
        npy_ty_class_lookup(self_ptr, attr, 0, @ptrCast(&member), 0, self_type);
        if (member[0] != MP_OBJ_NULL) {
            // property: explicit setter/deleter slot.
            if (memberIsProperty(member[0])) {
                const proxy = mp_obj_property_get(member[0]);
                if (value == MP_OBJ_NULL) {
                    if (proxy[2] == MP_OBJ_NONE) return false;
                    var args1: [1]Obj = .{self_in};
                    _ = mp_call_function_n_kw(proxy[2], 1, 0, &args1);
                    return true;
                } else {
                    if (proxy[1] == MP_OBJ_NONE) return false;
                    var args2: [2]Obj = .{ self_in, value };
                    _ = mp_call_function_n_kw(proxy[1], 2, 0, &args2);
                    return true;
                }
            }
            // descriptor __set__ / __delete__.
            var meth: [4]Obj = .{ MP_OBJ_NULL, MP_OBJ_NULL, MP_OBJ_NULL, MP_OBJ_NULL };
            if (value == MP_OBJ_NULL) {
                mp_load_method_maybe(member[0], @intCast(mp.MP_QSTR___delete__), @ptrCast(&meth));
                if (meth[0] != MP_OBJ_NULL) {
                    meth[2] = self_in;
                    _ = mp_call_method_n_kw(1, 0, &meth);
                    return true;
                }
            } else {
                mp_load_method_maybe(member[0], @intCast(mp.MP_QSTR___set__), @ptrCast(&meth));
                if (meth[0] != MP_OBJ_NULL) {
                    meth[2] = self_in;
                    meth[3] = value;
                    _ = mp_call_method_n_kw(2, 0, &meth);
                    return true;
                }
            }
        }
        if (build_options.delattr_setattr) {
            // MICROPY_PY_DELATTR_SETATTR: try user __setattr__/__delattr__.
            var hmeth: [4]Obj = .{ MP_OBJ_NULL, MP_OBJ_NULL, MP_OBJ_NULL, MP_OBJ_NULL };
            if (value == MP_OBJ_NULL) {
                mp_load_method_maybe(self_in, @intCast(mp.MP_QSTR___delattr__), @ptrCast(&hmeth));
                if (hmeth[0] != MP_OBJ_NULL) {
                    hmeth[2] = qstrObj(attr);
                    _ = mp_call_method_n_kw(1, 0, &hmeth);
                    return true;
                }
            } else {
                mp_load_method_maybe(self_in, @intCast(mp.MP_QSTR___setattr__), @ptrCast(&hmeth));
                if (hmeth[0] != MP_OBJ_NULL) {
                    hmeth[2] = qstrObj(attr);
                    hmeth[3] = value;
                    _ = mp_call_method_n_kw(2, 0, &hmeth);
                    return true;
                }
            }
        }
    }
    // skip_special_accessors:
    const inst: *mirrors.MpObjInstance = @ptrCast(@alignCast(@constCast(self_ptr.?)));
    if (value == MP_OBJ_NULL) {
        return mirrors.mp_map_lookup(&inst.members, mirrors.objFromQstr(attr), mirrors.MP_MAP_LOOKUP_REMOVE_IF_FOUND) != null;
    } else {
        const e = mirrors.mp_map_lookup(&inst.members, mirrors.objFromQstr(attr), mirrors.MP_MAP_LOOKUP_ADD_IF_NOT_FOUND).?;
        e.value = value;
        return true;
    }
}

export fn mp_obj_instance_attr(self_in: Obj, attr: u32, dest: [*c]Obj) callconv(.c) void {
    if (dest[0] == MP_OBJ_NULL) {
        mp_obj_instance_load_attr(self_in, attr, dest);
    } else {
        if (mp_obj_instance_store_attr(self_in, attr, dest[1])) {
            dest[0] = MP_OBJ_NULL; // indicate success
        }
    }
}

// ── seam 10: type_make_new + type_call (2 raises bridged) ──
//
// Both are slot fns of mp_type_type. Under nano (TERSE error reporting),
// only the short-form raises are live; the %q-varg branches are dead.

extern fn mp_obj_str_get_qstr(self_in: Obj) callconv(.c) usize;
extern fn mp_arg_check_num_sig(n_args: usize, n_kw: usize, sig: u32) callconv(.c) void;

fn raiseTypeArgs() PyError!void {
    pyerr.pending_exc = typeErrorMsg("type takes 1 or 3 arguments");
    return error.PyRaise;
}
fn raiseCantCreateInstance() PyError!void {
    pyerr.pending_exc = typeErrorMsg("can't create instance");
    return error.PyRaise;
}

fn typeMakeNewImpl(n_args: usize, n_kw: usize, args: [*c]const Obj) PyError!Obj {
    // type() with 0 or >3 args is invalid; type() with 1 returns the arg's type;
    // type(name, bases, dict) creates a new class.
    // (mp_arg_check_num with min=1, max=3, takes_kw=false — the static-inline
    // sig is (n_min << 17) | (n_max << 1) | takes_kw.)
    const sig: u32 = (@as(u32, 1) << 17) | (@as(u32, 3) << 1) | 0;
    mp_arg_check_num_sig(n_args, n_kw, sig);

    if (n_args == 1) {
        return @intFromPtr(mp_obj_get_type(args[0]));
    } else if (n_args == 3) {
        return mp_obj_new_type(mp_obj_str_get_qstr(args[0]), args[1], args[2]);
    } else {
        try raiseTypeArgs();
        unreachable;
    }
}
export fn type_make_new(type_in: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    _ = type_in;
    return pyerr.bridge(Obj, typeMakeNewImpl(n_args, n_kw, args));
}

fn typeCallImpl(self_in: Obj, n_args: usize, n_kw: usize, args: [*c]const Obj) PyError!Obj {
    const self_type: ?*const anyopaque = @ptrFromInt(self_in); // self IS a type (it's mp_type_type's call)
    if (!typeHasSlotMakeNew(self_type)) {
        try raiseCantCreateInstance();
        unreachable;
    }
    return typeCallMakeNewSlot(self_type, n_args, n_kw, args);
}
export fn type_call(self_in: Obj, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, typeCallImpl(self_in, n_args, n_kw, args));
}

// ── seam 11: super_print + super_make_new + super_attr (1 raise) ──
//
// Under nano (MI=0): super_attr's tuple-parent branch is dead; single-parent
// walk only. super_make_new validates that args[1] is a subclass of args[0],
// raising TypeError() on mismatch.

extern fn mp_print_str(print: ?*const anyopaque, str: [*:0]const u8) callconv(.c) c_int;
extern fn mp_obj_print_helper(print: ?*const anyopaque, o_in: Obj, kind: c_int) callconv(.c) void;

export fn super_print(print: ?*const anyopaque, self_in: Obj, kind: c_int) callconv(.c) void {
    _ = kind;
    _ = mp_print_str(print, "<super: ");
    mp_obj_print_helper(print, superTypeOf(self_in), 0); // PRINT_STR = 0
    _ = mp_print_str(print, ", ");
    mp_obj_print_helper(print, superObjOf(self_in), 0);
    _ = mp_print_str(print, ">");
}

fn superMakeNewImpl(type_in: Obj, n_args: usize, n_kw: usize, args: [*c]const Obj) PyError!Obj {
    _ = type_in;
    // 0 args become 2 in the compiler; 1 arg not yet implemented.
    const sig: u32 = (@as(u32, 2) << 17) | (@as(u32, 2) << 1) | 0;
    mp_arg_check_num_sig(n_args, n_kw, sig);

    // CPython: if args[1] is an object, isinstance(obj, type) must hold;
    // if args[1] is a type, issubclass(type2, type) must hold.
    // C: `second_arg_type == &mp_type_type ? args[1] : MP_OBJ_FROM_PTR(second_arg_type)`
    // The check `T(args[1]) == &mp_type_type` is equivalent to `mp_obj_is_type(args[1], &mp_type_type)`.
    const second_arg_obj: Obj = if (isTypeType(args[1]))
        args[1]
    else
        @intFromPtr(mp_obj_get_type(args[1]));
    if (mp_obj_is_subclass(second_arg_obj, args[0]) == MP_OBJ_FALSE) {
        try raiseTypeErrorNull();
        unreachable;
    }
    return newSuper(args[0], args[1]);
}
export fn super_make_new(type_in: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, superMakeNewImpl(@intFromPtr(type_in), n_args, n_kw, args));
}

export fn super_attr(self_in: Obj, attr: u32, dest: [*c]Obj) callconv(.c) void {
    if (dest[0] != MP_OBJ_NULL) {
        // not a load attribute
        return;
    }
    const self_type = superTypeOf(self_in);
    const self_obj = superObjOf(self_in);
    const type_ptr = objToTypePtr(self_type);
    const obj_ptr: ?*const anyopaque = @ptrFromInt(self_obj);

    // Allow `super().__init__()` to reach native base classes via the
    // make_new slot (which they use instead of __init__).
    const slot_offset: usize = if (attr == mp.MP_QSTR___init__)
        SLOT_OFFSET_MAKE_NEW
    else
        0;

    // Parent walk: single-parent direct lookup, or MI tuple-walk.
    if (typeHasParent(type_ptr)) {
        var did_tuple_walk = false;
        if (comptime build_options.multiple_inheritance) {
            if (parentIsTuple(type_ptr)) {
                did_tuple_walk = true;
                var n: usize = 0;
                var items: [*c]const Obj = undefined;
                parentTupleItems(type_ptr, &n, &items);
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const base_t = objToTypePtr(items[i]);
                    if (base_t == @as(?*const anyopaque, &mp_type_object)) {
                        // object is searched at the end of this function;
                        // skip it here to avoid double-lookup of native methods.
                        continue;
                    }
                    npy_ty_class_lookup(obj_ptr, attr, slot_offset, dest, 0, base_t);
                    if (dest[0] != MP_OBJ_NULL) break;
                }
            }
        }
        if (!did_tuple_walk) {
            const parent_ptr = typeParent(type_ptr);
            if (parent_ptr != @as(?*const anyopaque, &mp_type_object)) {
                npy_ty_class_lookup(obj_ptr, attr, slot_offset, dest, 0, parent_ptr);
            }
        }
    }

    if (dest[0] != MP_OBJ_NULL) {
        if (dest[0] == MP_OBJ_SENTINEL) {
            // Looked up a native __init__; defer to the wrapper.
            dest[0] = mirrors.objFromPtr(&native_base_init_wrapper_obj);
            dest[1] = self_obj;
        }
        return;
    }

    // Last resort: lookup in `object` (with slot_offset=0 so we don't probe
    // native methods; object never occupies the native base-class slot).
    npy_ty_class_lookup(obj_ptr, attr, 0, dest, 0, @as(?*const anyopaque, &mp_type_object));
}

// ── seam 12: instance_print + type_print (0 raises) ──

extern fn mp_obj_get_type_str(o: Obj) callconv(.c) [*:0]const u8;

export fn instance_print(print: ?*const anyopaque, self_in: Obj, kind: c_int) callconv(.c) void {
    const self_ptr: ?*const anyopaque = @ptrFromInt(self_in);
    var meth: u32 = if (kind == 0) mp.MP_QSTR___str__ else mp.MP_QSTR___repr__; // PRINT_STR = 0
    var member: [2]Obj = .{ MP_OBJ_NULL, MP_OBJ_NULL };
    npy_ty_class_lookup(
        self_ptr,
        meth,
        SLOT_OFFSET_PRINT,
        @ptrCast(&member),
        0,
        instancePtrType(self_ptr),
    );
    if (member[0] == MP_OBJ_NULL and kind == 0) {
        // No __str__, fall back to __repr__
        meth = mp.MP_QSTR___repr__;
        npy_ty_class_lookup(
            self_ptr,
            meth,
            0,
            @ptrCast(&member),
            0,
            instancePtrType(self_ptr),
        );
    }

    if (member[0] == MP_OBJ_SENTINEL) {
        // Handle Exception subclasses specially.
        const subobj0 = instanceSubobj0(self_in);
        if (mp_obj_is_native_exception_instance(subobj0)) {
            if (kind != 0) {
                _ = mp_print_str(print, qstr_str(typeNameQstr(instancePtrType(self_ptr))));
            }
            mp_obj_print_helper(print, subobj0, kind | mp.PRINT_EXC_SUBCLASS);
        } else {
            mp_obj_print_helper(print, subobj0, kind);
        }
        return;
    }

    if (member[0] != MP_OBJ_NULL) {
        const r = mp_call_function_1(member[0], self_in);
        mp_obj_print_helper(print, r, 0); // PRINT_STR
        return;
    }

    _ = mp_printf(print, "<%s object at %p>", mp_obj_get_type_str(self_in), self_ptr);
}

extern fn qstr_str(q: usize) callconv(.c) [*:0]const u8;

export fn type_print(print: ?*const anyopaque, self_in: Obj, kind: c_int) callconv(.c) void {
    _ = kind;
    const type_ptr = objToTypePtr(self_in);
    _ = mp_printf(print, "<class '%q'>", typeNameQstr(type_ptr));
}

// ── seam 13: type_attr (0 live raises under nano) ──
//
// Under nano: CPYTHON_COMPAT=0 → __name__/__dict__/__bases__ blocks dead;
// MI=0 → tuple parent branch dead; ENABLE_SPECIAL_ACCESSORS=0 → the
// "can't add special method" AttributeError is dead. Pure body: load is
// a class_lookup (with is_type=true); delete/store mutates the locals map.

export fn type_attr(self_in: Obj, attr: usize, dest: [*c]Obj) callconv(.c) void {
    const type_ptr = objToTypePtr(self_in);
    if (dest[0] == MP_OBJ_NULL) {
        // CPython-compat: __name__ ungated for nano too (the vendor
        // gating was MICROPY_CPYTHON_COMPAT which IS 1 under nano in
        // our mpconfigport.h:91; the is_full check was bug-for-bug
        // compat with the frozen nano-C reference, but type(X).__name__
        // is a basic Python idiom and the user-experience cost of
        // leaving it broken is huge). __dict__ + __bases__ stay gated
        // because they require the multiple-inheritance scaffolding
        // (bases_tuple slot) that only the full arm wires.
        if (attr == @as(usize, @intCast(mp.MP_QSTR___name__))) {
            dest[0] = mirrors.objFromQstr(typeNameQstr(type_ptr));
            return;
        }
        if (build_options.is_full) {
            if (attr == @as(usize, @intCast(mp.MP_QSTR___dict__))) {
                dest[0] = typeLocalsDictReadonly(type_ptr);
                return;
            }
            if (attr == @as(usize, @intCast(mp.MP_QSTR___bases__))) {
                dest[0] = typeBasesTuple(type_ptr);
                return;
            }
        }
        // load attribute — class_lookup with is_type=true, passing the
        // (original) type itself as the "obj" so class methods return
        // the original type, not the (base) type the method was found in.
        npy_ty_class_lookup(type_ptr, attr, 0, dest, 1, type_ptr);
    } else {
        // delete/store attribute via the locals_dict map.
        if (!typeHasLocalsDict(type_ptr)) return;
        const locals_map = @as(?*anyopaque, @ptrCast(typeLocalsMap(type_ptr)));
        if (mirrors.MpMap.fromPtr(locals_map).bits.is_fixed != 0) return; // fixed map — can't mutate
        if (dest[1] == MP_OBJ_NULL) {
            // delete
            if (mirrors.mp_map_lookup(mirrors.MpMap.fromPtr(locals_map), mirrors.objFromQstr(attr), mirrors.MP_MAP_LOOKUP_REMOVE_IF_FOUND) != null) {
                dest[0] = MP_OBJ_NULL; // indicate success
            }
        } else {
            // ENABLE_SPECIAL_ACCESSORS: if the new attr value is a special
            // accessor (property/__set__-descriptor/...) and the type isn't
            // already flagged, set HAS_SPECIAL_ACCESSORS — needed so future
            // instance lookups go through the descriptor dispatch. Vendor
            // objtype.c:1138-1147. Vendor's gate is `ENABLE_SPECIAL_ACCESSORS
            // = PROPERTY || DESCRIPTORS || DELATTR_SETATTR`, which is true
            // under nano too (PROPERTY=1, DESCRIPTORS=1). Same v0.3 bug as
            // the inherited-accessor flag propagation a few hundred lines
            // below; surfaced via the property dynamic-assignment path in
            // builtin_property_inherit when MI enablement let the test
            // progress past `class E(C, D)`.
            if (!typeFlagHasSpecialAccessors(type_ptr)) {
                if (attrValueIsSpecialAccessor(attr, dest[1])) {
                    const tm: *mirrors.MpObjType = @ptrCast(@alignCast(@constCast(type_ptr.?)));
                    tm.flags |= mirrors.FLAG_HAS_SPECIAL_ACCESSORS;
                }
            }
            // store
            const elem = mirrors.mp_map_lookup(mirrors.MpMap.fromPtr(locals_map), mirrors.objFromQstr(attr), mirrors.MP_MAP_LOOKUP_ADD_IF_NOT_FOUND).?;
            elem.value = dest[1];
            dest[0] = MP_OBJ_NULL; // indicate success
        }
    }
}

const std = @import("std");

comptime {
    _ = &mp_obj_is_subclass_fast;
    _ = &mp_obj_cast_to_native_base;
    _ = &mp_obj_instance_is_callable;
    _ = &mp_load_super_method;
    _ = &mp_obj_instance_call;
    _ = &mp_obj_is_subclass;
    _ = &mp_builtin_issubclass;
    _ = &mp_builtin_isinstance;
    _ = &npy_ty_class_lookup;
    _ = &mp_obj_instance_getiter;
    _ = &instance_unary_op;
    _ = &instance_binary_op;
    _ = &instance_subscr;
    _ = &mp_obj_instance_get_call;
    _ = &instance_get_buffer;
    _ = &mp_obj_instance_load_attr;
    _ = &mp_obj_instance_store_attr;
    _ = &mp_obj_instance_attr;
    _ = &type_make_new;
    _ = &type_call;
    _ = &super_print;
    _ = &super_make_new;
    _ = &super_attr;
    _ = &instance_print;
    _ = &type_print;
    _ = &type_attr;
    _ = &instance_count_native_bases;
    _ = &native_base_init_wrapper;
    _ = &mp_obj_new_instance;
    _ = &static_class_method_make_new;
    _ = &mp_obj_instance_make_new;
    _ = &mp_obj_new_type;
    _ = &mp_builtin_issubclass_obj;
    _ = &mp_builtin_isinstance_obj;
    _ = &mp_unary_op_method_name;
    _ = &mp_binary_op_method_name;
    _ = &mp_type_type;
    _ = &mp_type_super;
    _ = &mp_type_staticmethod;
    _ = &mp_type_classmethod;
    _ = &native_base_init_wrapper_obj;
    _ = &npy_ty_attr_value_is_special_accessor;
    _ = &npy_ty_scan_special_accessors_flag;
}

// ── seam 16: mp_obj_new_type — the class/type constructor (6 raises) ──
//
// Under nano: ENABLE_SPECIAL_ACCESSORS=0 → the special-accessor scan loop is
// dead; MICROPY_PY_DESCRIPTORS=0 → the setname_list machinery is dead;
// MI=0 → the bases_len >= 2 path raises NotImplementedError (the SET_SLOT
// branch is dead); TERSE → the %q-varg "type '%q' isn't an acceptable base"
// raise is dead. 6 live raises (5 TypeError + 1 NotImplementedError).

fn raiseNotAcceptableBase() PyError!void {
    pyerr.pending_exc = typeErrorMsg("type isn't an acceptable base type");
    return error.PyRaise;
}
fn raiseMI() PyError!void {
    pyerr.pending_exc = notImplementedMsg("multiple inheritance not supported");
    return error.PyRaise;
}
fn raiseLayoutConflict() PyError!void {
    pyerr.pending_exc = typeErrorMsg("multiple bases have instance lay-out conflict");
    return error.PyRaise;
}

fn newTypeImpl(name: usize, bases_tuple: Obj, locals_dict: Obj) PyError!Obj {
    // Verify bases is a tuple, locals is a dict.
    if (!isTypeTuple(bases_tuple)) {
        try raiseTypeErrorNull();
        unreachable;
    }
    if (!mp_obj_is_dict_or_ordereddict(locals_dict)) {
        try raiseTypeErrorNull();
        unreachable;
    }

    // v0.3: scan locals_dict for property/setattr/delattr/__get__ to set
    // HAS_SPECIAL_ACCESSORS flag, so instance_load_attr triggers the
    // descriptor dispatch.
    const accessor_flag = npy_ty_scan_special_accessors_flag(locals_dict);
    var inherited_accessor_flag: u16 = 0;
    var bases_len: usize = 0;
    var bases_items: [*c]Obj = undefined;
    mp_obj_tuple_get(bases_tuple, &bases_len, &bases_items);
    var i: usize = 0;
    while (i < bases_len) : (i += 1) {
        if (!isTypeType(bases_items[i])) {
            try raiseTypeErrorNull();
            unreachable;
        }
        const base_t = objToTypePtr(bases_items[i]);
        if (!typeHasSlotMakeNew(base_t)) {
            try raiseNotAcceptableBase();
            unreachable;
        }
        // ENABLE_SPECIAL_ACCESSORS — propagate parent's HAS_SPECIAL_ACCESSORS
        // flag so subclass.x dispatches through an inherited @property/
        // @descriptor. Vendor's gate is `ENABLE_SPECIAL_ACCESSORS =
        // PROPERTY || DESCRIPTORS || DELATTR_SETATTR`, which is true under
        // both nano (PROPERTY=1, DESCRIPTORS=1) and full. The previous
        // is_full gate was a bug carried since v0.3 — it surfaced the
        // moment MI was enabled and builtin_property_inherit started
        // progressing past `class E(C, D)`. ADR 010 §A3b follow-up.
        inherited_accessor_flag |= typeFlagSpecialAccessorsValue(base_t);
    }
    const base_flags: u16 = TYPE_BASE_FLAGS | accessor_flag | inherited_accessor_flag;

    // Capture base[0]'s protocol slot (if any), to be inherited. MI doesn't
    // inherit protocol (vendor doesn't either) — only single-base classes.
    var base_protocol: ?*const anyopaque = null;
    if (bases_len == 1) {
        const base0_t = objToTypePtr(bases_items[0]);
        base_protocol = typeProtocolOrNull(base0_t);
    }

    // Allocate variable-sized mp_obj_type_t: 10 base slots + 1 for parent
    // (if any base) + 1 for protocol (if inherited).
    const n_slots: usize = 10 + (if (bases_len != 0) @as(usize, 1) else 0) +
        (if (base_protocol != null) @as(usize, 1) else 0);
    const o = m_malloc0(@sizeOf(mirrors.MpObjType) + n_slots * @sizeOf(?*const anyopaque));
    const ot: *mirrors.MpObjType = @ptrCast(@alignCast(o.?));
    ot.base = .{ .type = &mp_type_type };
    ot.flags = base_flags;
    ot.name = @intCast(name);

    // Set the 9 instance-protocol slots (idx 0..8) — fn ptrs from objtype.zig.
    typeSetSlotByOffset(o, SLOT_OFFSET_MAKE_NEW, 0, @ptrCast(&mp_obj_instance_make_new));
    typeSetSlotByOffset(o, SLOT_OFFSET_PRINT, 1, @ptrCast(&instance_print));
    typeSetSlotByOffset(o, SLOT_OFFSET_CALL, 2, @ptrCast(&mp_obj_instance_call));
    typeSetSlotByOffset(o, SLOT_OFFSET_UNARY_OP, 3, @ptrCast(&instance_unary_op));
    typeSetSlotByOffset(o, SLOT_OFFSET_BINARY_OP, 4, @ptrCast(&instance_binary_op));
    typeSetSlotByOffset(o, SLOT_OFFSET_ATTR, 5, @ptrCast(&mp_obj_instance_attr));
    typeSetSlotByOffset(o, SLOT_OFFSET_SUBSCR, 6, @ptrCast(&instance_subscr));
    typeSetSlotByOffset(o, SLOT_OFFSET_ITER, 7, @ptrCast(&mp_obj_instance_getiter));
    typeSetSlotByOffset(o, SLOT_OFFSET_BUFFER, 8, @ptrCast(&instance_get_buffer));

    // Slot 9: locals_dict (pointer to the underlying mp_obj_dict_t).
    const locals_ptr: ?*const anyopaque = @ptrFromInt(locals_dict);
    typeSetSlotByOffset(o, SLOT_OFFSET_LOCALS_DICT, 9, locals_ptr);

    // Slot 10: parent. Single parent: store the type ptr. MI (full only):
    // store the bases_tuple object itself; is_subclass_fast +
    // class_lookup + super_attr + instance_count_native_bases all detect
    // tuple parents via parent_is_tuple and walk parent_tuple_items.
    if (bases_len > 0) {
        const parent_slot: ?*const anyopaque = blk: {
            if (bases_len >= 2) {
                if (comptime !build_options.multiple_inheritance) {
                    try raiseMI();
                    unreachable;
                }
                // MI: store the tuple obj as the parent slot.
                break :blk @ptrFromInt(bases_tuple);
            }
            break :blk objToTypePtr(bases_items[0]);
        };
        typeSetSlotByOffset(o, SLOT_OFFSET_PARENT, 10, parent_slot);

        // Slot 11: inherit base's protocol (single-parent only — see above).
        if (base_protocol != null) {
            typeSetSlotByOffset(o, SLOT_OFFSET_PROTOCOL, 11, base_protocol);
        }
    }

    // Native-base count: > 1 means lay-out conflict.
    var native_base: ?*const anyopaque = null;
    const num_native_bases = instance_count_native_bases(o, &native_base);
    if (num_native_bases > 1) {
        try raiseLayoutConflict();
        unreachable;
    }

    // If locals defines __new__ as a function, wrap it in a staticmethod
    // decorator so it doesn't get an implicit self injection.
    const locals_dict_ptr: *mirrors.MpObjDict = @ptrCast(@alignCast(@constCast(locals_ptr.?)));
    const locals_map: *mirrors.MpMap = &locals_dict_ptr.map;
    if (mirrors.mp_map_lookup(locals_map, mirrors.objFromQstr(mp.MP_QSTR___new__), mirrors.MP_MAP_LOOKUP)) |new_elem| {
        if (isFun(new_elem.value)) {
            new_elem.value = newStaticClassMethod(&mp_type_staticmethod, new_elem.value);
        }
    }

    // PEP 487 / MICROPY_PY_DESCRIPTORS — call `__set_name__(owner, name)`
    // on every locals_map value that defines it. Vendor objtype.c:1009-1017
    // uses a linked list (NLR safety); we iterate inline since no NLR.
    // Must run AFTER locals_map is finalized (incl. __new__ wrap above).
    //
    // Gated on `is_full` to preserve nano-C corpus discipline: the original
    // nano-C reference binary didn't have __set_name__ dispatch (vendor
    // gates the collector on MICROPY_PY_DESCRIPTORS — on under nano-C too,
    // but the corpus was frozen before this collector was active in
    // nano-Zig). Enabling under nano would refresh corpus/nano/basics/
    // class_descriptor.out etc. Defer that to a later cycle.
    // Pairs with the descriptor-probe-fallthrough fix at :1201-1239.
    if (comptime build_options.is_full) {
        // Vendor py/objtype.c:1256-1287 CAPTURES bound __set_name__ methods
        // into a linked-list snapshot during the locals_map walk, THEN
        // invokes them. This is load-bearing, not stylistic: a __set_name__
        // body may mutate sibling slots via setattr/delattr (see
        // tests/basics/class_setname_hazard.py SetReplaceTest/DelReplaceTest).
        // A naive single-pass re-read would miss any descriptor whose slot
        // was overwritten by an earlier __set_name__ call.
        //
        // Use a flat heap buffer instead of vendor's linked list — same upper
        // bound (locals_map.alloc) and simpler in Zig.
        const owner_obj: Obj = @intFromPtr(o);
        const cap = locals_map.alloc;
        if (cap != 0) {
            const buf_raw = m_malloc(cap * @sizeOf([4]Obj)).?;
            const buf: [*][4]Obj = @ptrCast(@alignCast(buf_raw));
            var n_captured: usize = 0;
            var sn_i: usize = 0;
            while (sn_i < cap) : (sn_i += 1) {
                if (!locals_map.slotFilled(sn_i)) continue;
                const key = locals_map.keyAt(sn_i);
                const value = locals_map.valueAt(sn_i);
                var dest: [4]Obj = .{ 0, 0, 0, 0 };
                mp_load_method_maybe(value, mp.MP_QSTR___set_name__, @ptrCast(&dest));
                if (dest[1] == 0) continue; // no __set_name__ bound
                dest[2] = owner_obj;
                dest[3] = key;
                buf[n_captured] = dest;
                n_captured += 1;
            }
            var ci: usize = 0;
            while (ci < n_captured) : (ci += 1) {
                _ = mp_call_method_n_kw(2, 0, @ptrCast(&buf[ci]));
                if (pyerr.pending_exc != 0) return error.PyRaise;
            }
        }
    }

    return @intFromPtr(o);
}
export fn mp_obj_new_type(name: usize, bases_tuple: Obj, locals_dict: Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, newTypeImpl(name, bases_tuple, locals_dict));
}

// ── seam 14: native-base instance helpers (0 raises) ──
//
// instance_count_native_bases: walk the parent chain counting native bases.
// MI=0 under nano → no tuple branch; single-parent walk, recursion-dead.
//
// native_base_init_wrapper: invokes the native base type's make_new when a
// subclass of a native type calls super().__init__(). The const-fn-obj
// wrapper around it (native_base_init_wrapper_obj) stays in the shim.
//
// mp_obj_new_instance: allocates an mp_obj_instance_t with N native-base
// slots, inits the members map, primes subobj[0] to the wrapper-obj.
// Static under nano (CPYTHON_COMPAT=0) — exporting from Zig under that
// name doesn't widen the ABI in any harmful way; the symbol is internal
// to the objtype.c/zig translation unit pair.

export fn instance_count_native_bases(type_in: ?*const anyopaque, last_native_base: *?*const anyopaque) callconv(.c) c_int {
    var t = type_in;
    while (true) {
        if (t == @as(?*const anyopaque, &mp_type_object)) {
            // object is not a "real" type — end search.
            return 0;
        }
        if (typeIsNative(t)) {
            // Native types have no parents (from our perspective) — end here.
            last_native_base.* = t;
            return 1;
        }
        if (!typeHasParent(t)) {
            // No parents — end search.
            return 0;
        }
        if (comptime build_options.multiple_inheritance) {
            // MI: tuple parent → sum recursive counts over each base.
            if (parentIsTuple(t)) {
                var n: usize = 0;
                var items: [*c]const Obj = undefined;
                parentTupleItems(t, &n, &items);
                var count: c_int = 0;
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const base_t = objToTypePtr(items[i]);
                    count += instance_count_native_bases(base_t, last_native_base);
                }
                return count;
            }
        }
        // Single-parent walk.
        t = typeParent(t);
    }
}

export fn native_base_init_wrapper(n_args: usize, args: [*c]const Obj, kw_args: ?*const anyopaque) callconv(.c) Obj {
    const self_ptr: ?*const anyopaque = @ptrFromInt(args[0]);
    var native_base: ?*const anyopaque = null;
    _ = instance_count_native_bases(instancePtrType(self_ptr), &native_base);
    const new_obj = typeCallMakeNewSlot(
        native_base,
        n_args - 1,
        mapUsed(kw_args),
        args + 1,
    );
    instancePtrSetSubobj0(@constCast(self_ptr), new_obj);
    return MP_OBJ_NONE;
}

export fn mp_obj_new_instance(class_in: ?*const anyopaque, native_base_out: *?*const anyopaque) callconv(.c) ?*anyopaque {
    const num_native_bases = instance_count_native_bases(class_in, native_base_out);
    std.debug.assert(num_native_bases < 2);
    const alloc_bytes = @sizeOf(mirrors.MpObjInstance) + @as(usize, @intCast(num_native_bases)) * @sizeOf(Obj);
    const o = mp_obj_malloc_helper(alloc_bytes, class_in);
    const inst: *mirrors.MpObjInstance = @ptrCast(@alignCast(o.?));
    mp_map_init(&inst.members, 0);
    // Prime subobj[0] with the wrapper-obj sentinel so we can distinguish
    // an uninstantiated native base from a real one. The choice of object
    // doesn't matter — it just needs to be uniquely identifiable.
    if (num_native_bases != 0) {
        inst.subobjPtr()[0] = mirrors.objFromPtr(&native_base_init_wrapper_obj);
    }
    return o;
}

// ── seam 15: static_class_method_make_new + mp_obj_instance_make_new ──
//
// static_class_method_make_new: trivial alloc + init of a static/classmethod
// wrapper object. 0 raises.
//
// mp_obj_instance_make_new: the instance constructor. Looks up __new__ via
// class_lookup (slot_offset=make_new — NULL/SENTINEL → blank native alloc;
// otherwise call Python __new__). Then looks up __init__ and calls it
// (PyError-bridges the "should return None" TypeError when init_ret isn't
// None). Finally, if a native base was not initialised by Python __init__,
// constructs it now via the native make_new slot.

export fn static_class_method_make_new(self_type: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    // self is &mp_type_staticmethod or &mp_type_classmethod (assert dropped under nano).
    const sig: u32 = (@as(u32, 1) << 17) | (@as(u32, 1) << 1) | 0;
    mp_arg_check_num_sig(n_args, n_kw, sig);
    return newStaticClassMethod(self_type, args[0]);
}

fn raiseInitReturn() PyError!void {
    pyerr.pending_exc = typeErrorMsg("__init__() should return None");
    return error.PyRaise;
}

fn instanceMakeNewImpl(self_type: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const Obj) PyError!Obj {
    // Look up __new__ via the make_new slot offset.
    var init_fn: [2]Obj = .{ MP_OBJ_NULL, MP_OBJ_NULL };
    npy_ty_class_lookup(
        null,
        mp.MP_QSTR___new__,
        SLOT_OFFSET_MAKE_NEW,
        @ptrCast(&init_fn),
        0,
        self_type,
    );

    var native_base: ?*const anyopaque = null;
    var o: ?*anyopaque = null;
    if (init_fn[0] == MP_OBJ_NULL or init_fn[0] == MP_OBJ_SENTINEL) {
        // No Python __new__, or there is a native constructor — create blank
        // instance. Defer the native ctor call to give __init__ a chance to
        // do it via super().__init__().
        o = mp_obj_new_instance(self_type, &native_base);
    } else {
        // Python __new__: call with (self, *args, **kwargs); allocate args
        // buffer when there are args.
        var new_ret: Obj = undefined;
        if (n_args == 0 and n_kw == 0) {
            var args2: [1]Obj = .{@intFromPtr(self_type)};
            new_ret = mp_call_function_n_kw(init_fn[0], 1, 0, &args2);
        } else {
            const total: usize = 1 + n_args + 2 * n_kw;
            const args2: [*]Obj = @ptrCast(@alignCast(m_malloc(total * @sizeOf(Obj)).?));
            args2[0] = @intFromPtr(self_type);
            @memcpy(args2[1..total], args[0..(n_args + 2 * n_kw)]);
            new_ret = mp_call_function_n_kw(init_fn[0], n_args + 1, n_kw, args2);
            m_free(args2);
        }
        // CPython: if __new__ returns a non-cls instance, __init__ isn't run.
        if (mp_obj_get_type(new_ret) != self_type) {
            return new_ret;
        }
        o = @ptrFromInt(new_ret);
    }

    // Look up __init__ (no slot_offset — pure attribute search).
    init_fn[0] = MP_OBJ_NULL;
    init_fn[1] = MP_OBJ_NULL;
    npy_ty_class_lookup(
        o,
        mp.MP_QSTR___init__,
        0,
        @ptrCast(&init_fn),
        0,
        self_type,
    );
    if (init_fn[0] != MP_OBJ_NULL) {
        var init_ret: Obj = undefined;
        if (n_args == 0 and n_kw == 0) {
            init_ret = mp_call_method_n_kw(0, 0, &init_fn);
        } else {
            const total: usize = 2 + n_args + 2 * n_kw;
            const args2: [*]Obj = @ptrCast(@alignCast(m_malloc(total * @sizeOf(Obj)).?));
            args2[0] = init_fn[0];
            args2[1] = init_fn[1];
            @memcpy(args2[2..total], args[0..(n_args + 2 * n_kw)]);
            init_ret = mp_call_method_n_kw(n_args, n_kw, args2);
            m_free(args2);
        }
        // If __init__ raised, mp_call_method_n_kw returns OBJ_NULL with
        // pyerr.pending_exc set. Propagate that exception rather than
        // overwriting it with "__init__() should return None" — the
        // OBJ_NULL is not the same as a non-None return and the
        // user-raised exception is the real signal.
        if (pyerr.pending_exc != 0) {
            return error.PyRaise;
        }
        if (init_ret != MP_OBJ_NONE) {
            try raiseInitReturn();
            unreachable;
        }
    }

    // If the type had a native base that wasn't initialised by Python
    // __init__, construct it now.
    if (native_base != null and instancePtrSubobj0(o) == mirrors.objFromPtr(&native_base_init_wrapper_obj)) {
        const new_subobj0 = typeCallMakeNewSlot(native_base, n_args, n_kw, args);
        instancePtrSetSubobj0(o, new_subobj0);
    }

    return @intFromPtr(o);
}
export fn mp_obj_instance_make_new(self_type: ?*const anyopaque, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, instanceMakeNewImpl(self_type, n_args, n_kw, args));
}
