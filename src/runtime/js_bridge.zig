//! ADR-006 J1 — JS interop bridge (sync host calls).
//!
//! Defines the wasm imports + Python-facing builtin module `_nanopython_js`.
//! Python code (typically nanopython-lib/js.py) imports `_nanopython_js`
//! and calls into the wasm imports via thin shims defined here.
//!
//! Gated on `build_options.feature_js`. When OFF the entire body is `else
//! struct {}` so nothing is exported, nothing is linked, and `import
//! _nanopython_js` raises ModuleNotFoundError from the Python side
//! (which `js.py` converts to ImportError per ADR-006 D5).
//!
//! The wasm import contract (matching web/lib/js-bridge.js):
//!   js_get_global(name_ptr, name_len) -> u32 (handle)
//!   js_get_attr(handle, name_ptr, name_len) -> u32
//!   js_set_attr(handle, name_ptr, name_len, value_handle) -> void
//!   js_call(handle, args_ptr, args_count) -> u32
//!   js_release(handle) -> void
//!   js_create_string(ptr, len) -> u32
//!   js_create_int(value) -> u32
//!   js_to_string_len(handle) -> usize
//!   js_to_string(handle, out_ptr, out_max) -> usize
//!   js_to_int(handle) -> i32
//!   js_bridge_present() -> u8  (sentinel for `js.is_browser()`)
//!   js_create_callback(callback_id: u32) -> u32   (J5a)
//!
//! Plus one wasm-side export (J5a) so JS can fire a registered Python
//! callback when an event arrives:
//!   npy_dispatch_callback(callback_id: u32, args_ptr: [*]const u32,
//!                         args_count: usize) -> u32
//!
//! __qstr_shadow_begin__
//! MP_QSTR__nanopython_js
//! MP_QSTR__bridge_present
//! MP_QSTR__get_global
//! MP_QSTR__get_attr
//! MP_QSTR__set_attr
//! MP_QSTR__call
//! MP_QSTR__release
//! MP_QSTR__create_string
//! MP_QSTR__create_int
//! MP_QSTR__to_string
//! MP_QSTR__to_int
//! MP_QSTR__create_callback
//! MP_QSTR__set_dispatcher
//! MP_REGISTER_MODULE(MP_QSTR__nanopython_js, mp_module_nanopython_js);
//! __qstr_shadow_end__

const build_options = @import("build_options");
const gc = @import("../memory/gc.zig");
const mirrors = @import("../mp_mirrors.zig");
const pyerr = @import("../pyerr.zig");

const Obj = mirrors.Obj;
const Qstr = usize;

const RomEntry = extern struct {
    key: Obj,
    value: *const anyopaque,
};

const enabled = build_options.feature_js;

const Body = if (enabled) struct {
    const mp = @cImport({
        @cInclude("py/qstr.h");
    });

    // ── wasm imports (provided by the JS host via web/lib/js-bridge.js) ─
    //
    // These are declared `extern fn` so the linker produces wasm imports
    // under the default `env` module name. The JS host registers them as
    // `nanopython_js: { js_get_global, ... }` and our wasm shim merges
    // both `nanopython_js` and `env` namespaces during instantiation —
    // see web/lib/js-bridge.js + web/playground/app.js.
    extern fn js_get_global(name_ptr: [*]const u8, name_len: usize) callconv(.c) u32;
    extern fn js_get_attr(handle: u32, name_ptr: [*]const u8, name_len: usize) callconv(.c) u32;
    extern fn js_set_attr(handle: u32, name_ptr: [*]const u8, name_len: usize, value: u32) callconv(.c) void;
    extern fn js_call(handle: u32, args_ptr: [*]const u32, args_count: usize) callconv(.c) u32;
    extern fn js_release(handle: u32) callconv(.c) void;
    extern fn js_create_string(ptr: [*]const u8, len: usize) callconv(.c) u32;
    extern fn js_create_int(value: i32) callconv(.c) u32;
    extern fn js_to_string_len(handle: u32) callconv(.c) usize;
    extern fn js_to_string(handle: u32, out_ptr: [*]u8, out_max: usize) callconv(.c) usize;
    extern fn js_to_int(handle: u32) callconv(.c) i32;
    extern fn js_bridge_present() callconv(.c) u8;
    extern fn js_create_callback(callback_id: u32) callconv(.c) u32;

    // ── MicroPython ABI extern fns we need ────────────────────────────
    extern const mp_type_module: anyopaque;
    extern const mp_type_dict: anyopaque;
    extern const mp_type_fun_builtin_0: anyopaque;
    extern const mp_type_fun_builtin_1: anyopaque;
    extern const mp_type_fun_builtin_2: anyopaque;
    extern const mp_type_fun_builtin_3: anyopaque;
    extern const mp_type_fun_builtin_var: anyopaque;
    extern const mp_type_TypeError: anyopaque;

    extern fn mp_obj_get_int(o: Obj) callconv(.c) isize;
    extern fn mp_obj_new_int(v: isize) callconv(.c) Obj;
    extern fn mp_obj_new_str(data: [*]const u8, len: usize) callconv(.c) Obj;
    extern fn mp_obj_new_str_via_qstr(data: [*]const u8, len: usize) callconv(.c) Obj;
    extern fn mp_obj_str_get_data(o: Obj, len_out: *usize) callconv(.c) [*]const u8;
    extern fn mp_obj_get_array(o: Obj, n: *usize, items: *[*]Obj) callconv(.c) void;
    extern fn mp_obj_new_exception_msg(t: *const anyopaque, msg: [*:0]const u8) callconv(.c) Obj;
    extern fn mp_obj_new_list(n: usize, items: [*c]const Obj) callconv(.c) Obj;
    extern fn mp_call_function_n_kw(fun: Obj, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj;

    // ── Python-callable shims ─────────────────────────────────────────

    fn raiseTypeError(msg: [*:0]const u8) Obj {
        pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_TypeError, msg);
        return mirrors.OBJ_NULL;
    }

    // _bridge_present() -> int (0 if the JS host did not register js_*).
    //
    // The wasm runtime *will* call js_bridge_present at link time; under
    // wasmtime CLI (which doesn't supply the nanopython_js imports) the
    // module fails to instantiate, so we never reach this. To make the
    // ImportError path actually work under wasmtime, we wrap the call
    // in @hasDecl-style protection — but Zig has no FFI-resolve probe.
    // The pragmatic split: the predicate distinguishes "host registered
    // bridge but it's dead" from "host registered bridge that works"
    // (a future asyncify migration). Native + wasmtime simply can't
    // instantiate the binary if the imports aren't there — that's a
    // different error path (the WASI runtime reports the missing
    // import). The Python `js.py` module catches ImportError around
    // the `from _nanopython_js import _bridge_present` line, which
    // covers both: missing module (feature off) and missing wasm
    // import (host hasn't supplied it).
    fn py_bridge_present() callconv(.c) Obj {
        const v: u8 = js_bridge_present();
        return mp_obj_new_int(@intCast(v));
    }

    fn py_get_global(name_in: Obj) callconv(.c) Obj {
        var len: usize = undefined;
        const data = mp_obj_str_get_data(name_in, &len);
        const h: u32 = js_get_global(data, len);
        return mp_obj_new_int(@intCast(h));
    }

    fn py_get_attr(handle_in: Obj, name_in: Obj) callconv(.c) Obj {
        const h: u32 = @intCast(mp_obj_get_int(handle_in));
        var len: usize = undefined;
        const data = mp_obj_str_get_data(name_in, &len);
        const r: u32 = js_get_attr(h, data, len);
        return mp_obj_new_int(@intCast(r));
    }

    fn py_set_attr(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
        if (n_args != 3) return raiseTypeError("_set_attr expects 3 args");
        const h: u32 = @intCast(mp_obj_get_int(args[0]));
        var len: usize = undefined;
        const data = mp_obj_str_get_data(args[1], &len);
        const v: u32 = @intCast(mp_obj_get_int(args[2]));
        js_set_attr(h, data, len, v);
        return mirrors.OBJ_NONE;
    }

    // _call(handle, args_list) — args_list is a Python list of int handles.
    fn py_call(handle_in: Obj, args_list: Obj) callconv(.c) Obj {
        const h: u32 = @intCast(mp_obj_get_int(handle_in));
        var n: usize = undefined;
        var items: [*]Obj = undefined;
        mp_obj_get_array(args_list, &n, &items);
        // Marshal Python list[int] -> u32 buffer on the wasm stack.
        var buf: [16]u32 = undefined;
        if (n > buf.len) return raiseTypeError("_call: too many args (max 16)");
        var i: usize = 0;
        while (i < n) : (i += 1) {
            buf[i] = @intCast(mp_obj_get_int(items[i]));
        }
        const r: u32 = js_call(h, &buf, n);
        return mp_obj_new_int(@intCast(r));
    }

    fn py_release(handle_in: Obj) callconv(.c) Obj {
        const h: u32 = @intCast(mp_obj_get_int(handle_in));
        js_release(h);
        return mirrors.OBJ_NONE;
    }

    fn py_create_string(s_in: Obj) callconv(.c) Obj {
        var len: usize = undefined;
        const data = mp_obj_str_get_data(s_in, &len);
        const r: u32 = js_create_string(data, len);
        return mp_obj_new_int(@intCast(r));
    }

    fn py_create_int(v_in: Obj) callconv(.c) Obj {
        const v: i32 = @intCast(mp_obj_get_int(v_in));
        const r: u32 = js_create_int(v);
        return mp_obj_new_int(@intCast(r));
    }

    // _to_string(handle) — query length, allocate, fill, build Python str.
    fn py_to_string(handle_in: Obj) callconv(.c) Obj {
        const h: u32 = @intCast(mp_obj_get_int(handle_in));
        const len: usize = js_to_string_len(h);
        // Cap at a reasonable stack budget for the first cut.
        if (len > 4096) return raiseTypeError("_to_string: result exceeds 4096 bytes");
        var buf: [4096]u8 = undefined;
        const actual: usize = js_to_string(h, &buf, len);
        return mp_obj_new_str(&buf, actual);
    }

    fn py_to_int(handle_in: Obj) callconv(.c) Obj {
        const h: u32 = @intCast(mp_obj_get_int(handle_in));
        const v: i32 = js_to_int(h);
        return mp_obj_new_int(@intCast(v));
    }

    // ── J5a: Python callback marshaling ───────────────────────────────
    //
    // Python's `js.py` keeps a `_CALLBACKS` dict mapping integer ids to
    // Python callables (the GC anchor). To dispatch from JS we need a
    // single Python function — `js._dispatch_callback(id, args_list)` —
    // and Zig holds a single Obj reference to it, registered once at
    // `js.py` import time via `_set_dispatcher`. The reference is in a
    // static var (`dispatcher`); we deliberately do NOT root it via the
    // GC scan list because `_dispatch_callback` is reachable from
    // `sys.modules["js"].__dict__` for as long as the `js` module is
    // imported — which is the same lifetime as wasm itself. Cleanup is
    // not modelled; once registered, it lives until wasm tear-down.
    var dispatcher: Obj = mirrors.OBJ_NULL;

    fn py_create_callback(id_in: Obj) callconv(.c) Obj {
        const id: u32 = @intCast(mp_obj_get_int(id_in));
        const h: u32 = js_create_callback(id);
        return mp_obj_new_int(@intCast(h));
    }

    fn py_set_dispatcher(fn_in: Obj) callconv(.c) Obj {
        dispatcher = fn_in;
        return mirrors.OBJ_NONE;
    }

    // npy_dispatch_callback — called from JS when a registered Python
    // callback fires (e.g. addEventListener("click", py_fn) firing on
    // user click). Marshals the (already-JS-allocated) handle args into
    // a Python list[int] of handles and dispatches to the Python
    // `_dispatch_callback(id, args_list)`. Returns the JS handle of the
    // callback's return value, or 0 (= null/undefined) on error or if
    // no dispatcher is registered.
    pub export fn npy_dispatch_callback(
        callback_id: u32,
        args_handles_ptr: [*]const u32,
        args_count: usize,
    ) callconv(.c) u32 {
        if (dispatcher == mirrors.OBJ_NULL) return 0;
        gc.enterPython();
        defer gc.leavePython(); // a safe point on wasm (memory/gc.zig)
        // Build Python list of handle ints.
        var items: [16]Obj = undefined;
        if (args_count > items.len) return 0;
        var i: usize = 0;
        while (i < args_count) : (i += 1) {
            items[i] = mp_obj_new_int(@intCast(args_handles_ptr[i]));
        }
        const args_list: Obj = mp_obj_new_list(args_count, &items);
        const id_obj: Obj = mp_obj_new_int(@intCast(callback_id));
        var call_args: [2]Obj = .{ id_obj, args_list };
        const result: Obj = mp_call_function_n_kw(dispatcher, 2, 0, &call_args);
        if (result == mirrors.OBJ_NULL) return 0;
        // Result is a Python int handle (or None → 0).
        if (result == mirrors.OBJ_NONE) return 0;
        const h: isize = mp_obj_get_int(result);
        return @intCast(h);
    }

    // ── Builtin fun-obj definitions ───────────────────────────────────

    pub export const mp_nanopython_js_bridge_present_obj: mirrors.MpObjFunBuiltinFixed = .{
        .base = .{ .type = &mp_type_fun_builtin_0 },
        .fun = @ptrCast(&py_bridge_present),
    };
    pub export const mp_nanopython_js_get_global_obj: mirrors.MpObjFunBuiltinFixed = .{
        .base = .{ .type = &mp_type_fun_builtin_1 },
        .fun = @ptrCast(&py_get_global),
    };
    pub export const mp_nanopython_js_get_attr_obj: mirrors.MpObjFunBuiltinFixed = .{
        .base = .{ .type = &mp_type_fun_builtin_2 },
        .fun = @ptrCast(&py_get_attr),
    };
    pub export const mp_nanopython_js_set_attr_obj: mirrors.MpObjFunBuiltinVar = .{
        .base = .{ .type = &mp_type_fun_builtin_var },
        .sig = mirrors.makeFunSig(3, 3, false),
        .fun = @ptrCast(&py_set_attr),
    };
    pub export const mp_nanopython_js_call_obj: mirrors.MpObjFunBuiltinFixed = .{
        .base = .{ .type = &mp_type_fun_builtin_2 },
        .fun = @ptrCast(&py_call),
    };
    pub export const mp_nanopython_js_release_obj: mirrors.MpObjFunBuiltinFixed = .{
        .base = .{ .type = &mp_type_fun_builtin_1 },
        .fun = @ptrCast(&py_release),
    };
    pub export const mp_nanopython_js_create_string_obj: mirrors.MpObjFunBuiltinFixed = .{
        .base = .{ .type = &mp_type_fun_builtin_1 },
        .fun = @ptrCast(&py_create_string),
    };
    pub export const mp_nanopython_js_create_int_obj: mirrors.MpObjFunBuiltinFixed = .{
        .base = .{ .type = &mp_type_fun_builtin_1 },
        .fun = @ptrCast(&py_create_int),
    };
    pub export const mp_nanopython_js_to_string_obj: mirrors.MpObjFunBuiltinFixed = .{
        .base = .{ .type = &mp_type_fun_builtin_1 },
        .fun = @ptrCast(&py_to_string),
    };
    pub export const mp_nanopython_js_to_int_obj: mirrors.MpObjFunBuiltinFixed = .{
        .base = .{ .type = &mp_type_fun_builtin_1 },
        .fun = @ptrCast(&py_to_int),
    };
    pub export const mp_nanopython_js_create_callback_obj: mirrors.MpObjFunBuiltinFixed = .{
        .base = .{ .type = &mp_type_fun_builtin_1 },
        .fun = @ptrCast(&py_create_callback),
    };
    pub export const mp_nanopython_js_set_dispatcher_obj: mirrors.MpObjFunBuiltinFixed = .{
        .base = .{ .type = &mp_type_fun_builtin_1 },
        .fun = @ptrCast(&py_set_dispatcher),
    };

    // ── Module globals dict ───────────────────────────────────────────

    const mp_module_nanopython_js_globals_table = [_]RomEntry{
        .{
            .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR___name__)),
            .value = @ptrFromInt(mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR__nanopython_js))),
        },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR__bridge_present)), .value = &mp_nanopython_js_bridge_present_obj },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR__get_global)), .value = &mp_nanopython_js_get_global_obj },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR__get_attr)), .value = &mp_nanopython_js_get_attr_obj },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR__set_attr)), .value = &mp_nanopython_js_set_attr_obj },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR__call)), .value = &mp_nanopython_js_call_obj },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR__release)), .value = &mp_nanopython_js_release_obj },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR__create_string)), .value = &mp_nanopython_js_create_string_obj },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR__create_int)), .value = &mp_nanopython_js_create_int_obj },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR__to_string)), .value = &mp_nanopython_js_to_string_obj },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR__to_int)), .value = &mp_nanopython_js_to_int_obj },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR__create_callback)), .value = &mp_nanopython_js_create_callback_obj },
        .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR__set_dispatcher)), .value = &mp_nanopython_js_set_dispatcher_obj },
    };

    pub export const mp_module_nanopython_js_globals: mirrors.MpObjDict = .{
        .base = .{ .type = &mp_type_dict },
        .map = .{
            .bits = .{
                .all_keys_are_qstrs = 1,
                .is_fixed = 1,
                .is_ordered = 1,
                .used = mp_module_nanopython_js_globals_table.len,
            },
            .alloc = mp_module_nanopython_js_globals_table.len,
            .table = @ptrCast(@constCast(&mp_module_nanopython_js_globals_table)),
        },
    };

    pub export const mp_module_nanopython_js: mirrors.MpObjModule = .{
        .base = .{ .type = &mp_type_module },
        .globals = @ptrCast(@constCast(&mp_module_nanopython_js_globals)),
    };
} else struct {};

comptime {
    if (enabled) {
        _ = &Body.mp_module_nanopython_js;
        _ = &Body.mp_module_nanopython_js_globals;
        _ = &Body.mp_nanopython_js_bridge_present_obj;
        _ = &Body.mp_nanopython_js_get_global_obj;
        _ = &Body.mp_nanopython_js_get_attr_obj;
        _ = &Body.mp_nanopython_js_set_attr_obj;
        _ = &Body.mp_nanopython_js_call_obj;
        _ = &Body.mp_nanopython_js_release_obj;
        _ = &Body.mp_nanopython_js_create_string_obj;
        _ = &Body.mp_nanopython_js_create_int_obj;
        _ = &Body.mp_nanopython_js_to_string_obj;
        _ = &Body.mp_nanopython_js_to_int_obj;
        _ = &Body.mp_nanopython_js_create_callback_obj;
        _ = &Body.mp_nanopython_js_set_dispatcher_obj;
        _ = &Body.npy_dispatch_callback;
    }
}
