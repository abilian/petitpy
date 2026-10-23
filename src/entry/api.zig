//! The embedding API (ADR 022), declared in include/petitpy.h.
//!
//! Every function that touches Python objects runs its body through `run`,
//! which takes the interpreter's lock, records the stack top for the
//! collector on the outermost entry, brackets the body as an entry into
//! Python (a safe point on wasm), runs it under the ADR 013 trampoline,
//! and turns a pending exception into the returned status.
//!
//! The host holds handles: indexes into `slots`, a GC block reached from
//! the global table `interps`, so the collector's data-segment scan keeps
//! every held object alive. A free slot holds MP_OBJ_NULL.
//!
//! The interpreter state is still a set of process-wide variables, listed
//! in `globals`. Each interpreter keeps a saved copy of them, and `run`
//! loads it when a call enters an interpreter other than the current one;
//! the copies are outside the data segment, and need no scan, because the
//! collector only ever collects the current interpreter's own heap. Calls
//! take turns behind one lock for the process.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const mirrors = @import("../mp_mirrors.zig");
const pyerr = @import("../pyerr.zig");
const gc = @import("../memory/gc.zig");
const state = @import("../runtime/mpstate.zig");
const nlr = @import("../runtime/nlr_trampoline.zig");
const systemexit = @import("systemexit.zig");
const output = @import("../support/output.zig");
const qstr_pool = @import("../runtime/qstr.zig");
const scheduler = @import("../runtime/scheduler.zig");
const objmodule = @import("../objects/objtype/objmodule.zig");
const modsignal = @import("../modules/modsignal.zig");

const Obj = mirrors.Obj;
const Handle = u32;
const Qstr = usize;

const OK: c_int = 0;
const ERROR: c_int = 1;
const EXIT: c_int = 2;

const API_VERSION: c_int = 1;

// mp_parse_input_kind_t (py/parse.h) and mp_print_kind_t (py/obj.h).
const MP_PARSE_FILE_INPUT: c_int = 1;
const MP_PARSE_EVAL_INPUT: c_int = 2;
const PRINT_STR: c_int = 0;
const PRINT_REPR: c_int = 1;

const Config = extern struct {
    path: ?[*]const [*:0]const u8,
    path_len: usize,
    argv: ?[*]const [*:0]const u8,
    argc: usize,
    write: ?*const fn (userdata: ?*anyopaque, fd: c_int, data: [*]const u8, len: usize) callconv(.c) void,
    write_userdata: ?*anyopaque,
};

const HostFn = *const fn (py: *Interp, userdata: ?*anyopaque, argc: usize, argv: [*]const Handle, result: *Handle) callconv(.c) c_int;

const Interp = struct {
    live: bool = false,
    slots: ?[*]Obj = null,
    n_slots: u32 = 0, // slots in use or freed; slot 0 is never handed out
    cap: u32 = 0,
    free: std.ArrayListUnmanaged(u32) = .empty,
    hosts: std.ArrayListUnmanaged(Host) = .empty,
    err: Obj = 0, // the exception of the last call that failed
    fetched: Obj = 0, // ppy_fetch_error's exception, between py.err and its handle
    exit_code: c_int = 0,
    depth: u32 = 0, // nesting of API calls on the stack
    saved: ?*State = null, // its globals while another interpreter is current
};

const Host = struct { fun: HostFn, userdata: ?*anyopaque };

// ponytail: a fixed table, since the collector finds `slots` through the
// data segment; grow it if a host needs more interpreters. wasm keeps one
// per module instance: the `js` module's callbacks enter Python without
// naming an interpreter.
const MAX_INTERPS = if (is_wasm) 1 else 64;
var interps: [MAX_INTERPS]Interp = @splat(.{});
var current: ?*Interp = null; // the interpreter whose state the globals hold

// ── interpreter state ───────────────────────────────────────────────────

/// Every process-wide variable that belongs to one interpreter. A new
/// global that holds interpreter state belongs in this list.
const globals = .{ &state.mp_state_ctx, &scheduler.pending_exception, &objmodule.mp_module_builtins_override_dict, &output.sink } ++
    gc.interp_state ++ qstr_pool.interp_state ++ modsignal.interp_state;

const State = [
    blk: {
        var n: usize = 0;
        for (globals) |p| n += @sizeOf(@TypeOf(p.*));
        break :blk n;
    }
]u8;

/// The globals as the process starts, which a new interpreter starts from.
var pristine: ?*State = null;

fn save(s: *State) void {
    var off: usize = 0;
    inline for (globals) |p| {
        const b = std.mem.asBytes(p);
        @memcpy(s[off..][0..b.len], b);
        off += b.len;
    }
}

fn load(s: *const State) void {
    var off: usize = 0;
    inline for (globals) |p| {
        const b = std.mem.asBytes(p);
        @memcpy(b, s[off..][0..b.len]);
        off += b.len;
    }
}

fn switchTo(py: *Interp) void {
    if (current == py) return;
    if (current) |cur| save(cur.saved.?);
    load(py.saved.?);
    current = py;
}

/// Makes `py` current, and returns the interpreter to switch back to
/// afterwards: the previous one, when a call into it is still running.
fn enter(py: *Interp) ?*Interp {
    const prev = current;
    switchTo(py);
    return if (prev != null and prev != py and prev.?.depth > 0) prev else null;
}

fn leave(back: ?*Interp) void {
    if (back) |p| switchTo(p);
}

// ── lock ────────────────────────────────────────────────────────────────

const is_wasm = builtin.target.cpu.arch.isWasm();
const pthread = if (is_wasm) struct {} else @cImport(@cInclude("pthread.h"));
var mutex: if (is_wasm) void else pthread.pthread_mutex_t = undefined;
var mutex_state = std.atomic.Value(u8).init(0); // 0 none, 1 initialising, 2 ready

/// Initialises the mutex once, even when threads race into ppy_new.
fn initLock() void {
    if (is_wasm) return;
    if (mutex_state.cmpxchgStrong(0, 1, .acquire, .acquire) == null) {
        var attr: pthread.pthread_mutexattr_t = undefined;
        _ = pthread.pthread_mutexattr_init(&attr);
        _ = pthread.pthread_mutexattr_settype(&attr, pthread.PTHREAD_MUTEX_RECURSIVE);
        _ = pthread.pthread_mutex_init(&mutex, &attr);
        _ = pthread.pthread_mutexattr_destroy(&attr);
        mutex_state.store(2, .release);
    } else while (mutex_state.load(.acquire) != 2) std.atomic.spinLoopHint();
}
fn lock() void {
    if (!is_wasm) _ = pthread.pthread_mutex_lock(&mutex);
}
fn unlock() void {
    if (!is_wasm) _ = pthread.pthread_mutex_unlock(&mutex);
}

// ── runtime functions ───────────────────────────────────────────────────

extern fn mp_embed_init(heap: ?*anyopaque, heap_size: usize, stack_top: ?*anyopaque) void;
extern fn mp_embed_deinit() void;
extern fn qstr_init() void;
extern fn npy_file_io_init() void;
extern fn fflush(stream: ?*anyopaque) c_int;
extern fn m_realloc(ptr: ?*anyopaque, n: usize) ?*anyopaque;
extern fn qstr_from_strn(s: [*]const u8, n: usize) Qstr;
extern fn npy_zig_eval_exec(src: [*c]const u8, len: usize, file: Qstr, kind: c_int, globals: ?*anyopaque, locals: ?*anyopaque) Obj;
extern fn mp_import_name(name: Qstr, fromlist: Obj, level: Obj) Obj;
extern fn mp_load_attr(base: Obj, attr: Qstr) Obj;
extern fn mp_store_attr(base: Obj, attr: Qstr, value: Obj) void;
extern fn mp_call_function_n_kw(fun: Obj, n_args: usize, n_kw: usize, args: [*c]const Obj) Obj;
extern fn mp_obj_new_int_from_ll(v: c_longlong) Obj;
extern fn mp_obj_new_float(v: f64) Obj;
extern fn mp_obj_new_str(data: [*]const u8, len: usize) Obj;
extern fn mp_obj_new_bytes(data: [*]const u8, len: usize) Obj;
extern fn mp_obj_new_list(n: usize, items: [*c]const Obj) Obj;
extern fn mp_obj_list_append(list: Obj, item: Obj) Obj;
extern fn mp_obj_list_set_len(list: Obj, len: usize) void;
extern fn mp_obj_new_tuple(n: usize, items: [*c]const Obj) Obj;
extern fn mp_obj_new_dict(n: usize) Obj;
extern fn mp_obj_new_module(name: Qstr) Obj;
extern fn mp_obj_new_bound_meth(meth: Obj, self: Obj) Obj;
extern fn mp_obj_new_exception_msg(t: *const anyopaque, msg: [*:0]const u8) Obj;
extern fn mp_obj_new_str_from_vstr(vstr: *Vstr) Obj;
extern fn mp_obj_is_true(o: Obj) bool;
extern fn mp_obj_is_subclass_fast(t: Obj, classinfo: Obj) bool;
extern fn mp_obj_get_type(o: Obj) ?*const anyopaque;
extern fn mp_obj_get_type_str(o: Obj) [*:0]const u8;
extern fn mp_obj_get_int_maybe(o: Obj, value: *isize) bool;
extern fn mp_obj_get_float_maybe(o: Obj, value: *f64) bool;
extern fn mp_obj_str_get_data(o: Obj, len: *usize) ?[*]const u8;
extern fn mp_obj_len(o: Obj) Obj;
extern fn mp_obj_subscr(base: Obj, index: Obj, value: Obj) Obj;
extern fn mp_obj_print_helper(print: *const mirrors.MpPrint, o: Obj, kind: c_int) void;
extern fn mp_obj_print_exception(print: *const mirrors.MpPrint, exc: Obj) void;
extern fn vstr_init_print(vstr: *Vstr, alloc: usize, print: *mirrors.MpPrint) void;
extern const mp_module_builtins: anyopaque;
extern const mp_type_type: anyopaque;
extern const mp_type_str: anyopaque;
extern const mp_type_bytes: anyopaque;
extern const mp_type_BaseException: anyopaque;
extern const mp_type_TypeError: anyopaque;
extern const mp_type_ValueError: anyopaque;
extern const mp_type_RuntimeError: anyopaque;
extern const mp_type_fun_builtin_var: anyopaque;

/// vstr_t (py/misc.h).
const Vstr = extern struct { alloc: usize, len: usize, buf: ?[*]u8, fixed_buf: bool };

// ── the bracket ─────────────────────────────────────────────────────────

const Body = *const fn (?*anyopaque) callconv(.c) void;

/// The C-callable form of `Ctx.body`, for `run`.
fn bodyOf(comptime Ctx: type) Body {
    return struct {
        fn f(p: ?*anyopaque) callconv(.c) void {
            Ctx.body(@ptrCast(@alignCast(p.?)));
        }
    }.f;
}

/// Runs `body(ctx)` as one API call; see the file comment. `ctx` holds
/// handles and host pointers only: it lives in the caller's frame, above
/// the recorded stack top, where the collector does not look. Not generic,
/// so its code exists once.
noinline fn run(py: *Interp, body: Body, ctx: *anyopaque) c_int {
    lock();
    defer unlock();
    const back = enter(py);
    defer leave(back);
    var anchor: usize = 0;
    const outer = py.depth == 0;
    if (outer) state.threadState().stack_top = @ptrCast(&anchor);
    py.depth += 1;
    gc.enterPython();
    py.err = 0;
    pyerr.pending_exc = 0;
    nlr.callCtx(body, ctx);
    py.err = pyerr.pending_exc; // a root before leavePython can collect
    pyerr.pending_exc = 0;
    gc.leavePython();
    py.depth -= 1;
    if (outer) state.threadState().stack_top = null;
    if (py.err == 0) return OK;
    if (systemexit.isSystemExit(@ptrFromInt(py.err))) {
        py.exit_code = systemexit.exitCode(@ptrFromInt(py.err));
        return EXIT;
    }
    return ERROR;
}

/// Runs `f(py, args...)`, which returns an object (MP_OBJ_NULL with an
/// exception pending on failure), and stores a handle to it in `out`.
fn produce(py: *Interp, out: ?*Handle, comptime f: anytype, args: anytype) c_int {
    if (out) |o| o.* = 0;
    var ctx: struct {
        py: *Interp,
        out: ?*Handle,
        args: @TypeOf(args),
        fn body(c: *@This()) void {
            const o = @call(.auto, f, .{c.py} ++ c.args);
            if (pyerr.pending_exc != 0) return;
            if (c.out) |h| h.* = newHandle(c.py, o);
        }
    } = .{ .py = py, .out = out, .args = args };
    return run(py, bodyOf(@TypeOf(ctx)), &ctx);
}

fn raise(t: *const anyopaque, msg: [*:0]const u8) Obj {
    if (pyerr.pending_exc == 0) pyerr.pending_exc = mp_obj_new_exception_msg(t, msg);
    return mirrors.OBJ_NULL;
}

// ── handles ─────────────────────────────────────────────────────────────

// A handle holds the interpreter's index in `interps` above its slot
// number, so that a handle passed to another interpreter is an error.
const SLOT_BITS = 26;
const SLOT_MASK: Handle = (1 << SLOT_BITS) - 1;
comptime {
    std.debug.assert(MAX_INTERPS <= 1 << (32 - SLOT_BITS));
}

fn tag(py: *const Interp) Handle {
    return @intCast((@intFromPtr(py) - @intFromPtr(&interps)) / @sizeOf(Interp) << SLOT_BITS);
}

/// The slot `h` names, if it is `py`'s and holds a value.
fn slotOf(py: *Interp, h: Handle) ?u32 {
    const slot = h & SLOT_MASK;
    if (h & ~SLOT_MASK != tag(py) or slot == 0 or slot >= py.n_slots or py.slots.?[slot] == mirrors.OBJ_NULL) return null;
    return slot;
}

fn newHandle(py: *Interp, o: Obj) Handle {
    if (py.free.pop()) |slot| {
        py.slots.?[slot] = o;
        return tag(py) | slot;
    }
    if (py.n_slots == SLOT_MASK) return 0;
    if (py.n_slots == py.cap) {
        const cap = @max(16, py.cap * 2);
        const p = m_realloc(py.slots, cap * @sizeOf(Obj)) orelse return 0;
        py.slots = @ptrCast(@alignCast(p));
        py.cap = cap;
        if (py.n_slots == 0) {
            py.slots.?[0] = mirrors.OBJ_NULL;
            py.n_slots = 1;
        }
    }
    const slot = py.n_slots;
    py.slots.?[slot] = o;
    py.n_slots += 1;
    return tag(py) | slot;
}

/// The object `h` names, or MP_OBJ_NULL (and a pending ValueError).
fn obj(py: *Interp, h: Handle) Obj {
    const slot = slotOf(py, h) orelse return raise(&mp_type_ValueError, "invalid handle");
    return py.slots.?[slot];
}

fn qstr(name: [*:0]const u8) Qstr {
    return qstr_from_strn(name, std.mem.len(name));
}

/// A list of the objects `items` names, or MP_OBJ_NULL.
fn listOf(py: *Interp, n: usize, items: ?[*]const Handle) Obj {
    const list = mp_obj_new_list(0, null);
    for (0..n) |i| {
        const o = obj(py, items.?[i]);
        if (o == mirrors.OBJ_NULL) return o;
        _ = mp_obj_list_append(list, o);
    }
    return list;
}

fn dictMain() Obj {
    return @intFromPtr(&mirrors.mp_state_ctx.vm.dict_main);
}

// ── lifetime ────────────────────────────────────────────────────────────

export fn ppy_api_version() c_int {
    return API_VERSION;
}

export fn ppy_new(config: ?*const Config) ?*Interp {
    initLock();
    lock();
    defer unlock();
    const py = for (&interps) |*p| {
        if (!p.live) break p;
    } else return null;
    const saved = std.heap.c_allocator.create(State) catch return null;
    if (pristine == null) {
        pristine = std.heap.c_allocator.create(State) catch {
            std.heap.c_allocator.destroy(saved);
            return null;
        };
        save(pristine.?); // no interpreter yet: the globals are untouched
    }
    saved.* = pristine.?.*;
    py.* = .{ .live = true, .saved = saved };
    var ctx: struct {
        config: ?*const Config,
        fn body(c: *@This()) void {
            mp_embed_init(null, 0, state.threadState().stack_top);
            if (build_options.is_full) npy_file_io_init();
            // sys.path holds only what the host asks for; standard modules
            // are frozen in and found before sys.path is searched.
            const sys_path = mirrors.mp_state_ctx.vm.sys_mutable[0];
            mp_obj_list_set_len(sys_path, 0);
            const cfg = c.config orelse return;
            if (cfg.write) |w| output.sink = .{ .write = w, .userdata = cfg.write_userdata };
            for (0..cfg.path_len) |i| _ = mp_obj_list_append(sys_path, newStr(cfg.path.?[i]));
            const argv = mirrors.objFromPtr(&mirrors.mp_state_ctx.vm.mp_sys_argv_obj);
            for (0..cfg.argc) |i| _ = mp_obj_list_append(argv, newStr(cfg.argv.?[i]));
        }
    } = .{ .config = config };
    if (run(py, bodyOf(@TypeOf(ctx)), &ctx) != OK) {
        ppy_free(py);
        return null;
    }
    return py;
}

fn newStr(s: [*:0]const u8) Obj {
    return mp_obj_new_str(s, std.mem.len(s));
}

export fn ppy_free(py: *Interp) void {
    lock();
    defer unlock();
    const back = enter(py);
    _ = fflush(null);
    mp_embed_deinit();
    qstr_init(); // frees the interned strings
    gc.freeAreas(); // and the heap, slots included
    load(pristine.?);
    current = null;
    std.heap.c_allocator.destroy(py.saved.?);
    py.free.deinit(std.heap.c_allocator);
    py.hosts.deinit(std.heap.c_allocator);
    py.* = .{};
    leave(back);
}

// ── running code ────────────────────────────────────────────────────────

fn evalExec(py: *Interp, src: [*]const u8, len: usize, file: [*:0]const u8, kind: c_int) Obj {
    _ = py;
    const d: ?*anyopaque = @ptrFromInt(dictMain());
    return npy_zig_eval_exec(src, len, qstr(file), kind, d, d);
}

export fn ppy_exec(py: *Interp, src: [*]const u8, len: usize, filename: ?[*:0]const u8) c_int {
    return produce(py, null, evalExec, .{ src, len, filename orelse "<string>", MP_PARSE_FILE_INPUT });
}

export fn ppy_eval(py: *Interp, src: [*]const u8, len: usize, result: ?*Handle) c_int {
    return produce(py, result, evalExec, .{ src, len, "<string>", MP_PARSE_EVAL_INPUT });
}

fn import(py: *Interp, name: [*:0]const u8) Obj {
    _ = py;
    const full = std.mem.span(name);
    var mod = mp_import_name(qstr_from_strn(full.ptr, full.len), mirrors.OBJ_NONE, mirrors.newSmallInt(0));
    // mp_import_name returns the top-level package; walk down to the leaf.
    var it = std.mem.splitScalar(u8, full, '.');
    _ = it.next();
    while (it.next()) |part| {
        if (mod == mirrors.OBJ_NULL) break;
        mod = mp_load_attr(mod, qstr_from_strn(part.ptr, part.len));
    }
    return mod;
}

export fn ppy_import(py: *Interp, name: [*:0]const u8, module: ?*Handle) c_int {
    return produce(py, module, import, .{name});
}

// ── creating values ─────────────────────────────────────────────────────

fn constant(py: *Interp, o: Obj) Obj {
    _ = py;
    return o;
}
fn newInt(py: *Interp, v: i64) Obj {
    _ = py;
    return mp_obj_new_int_from_ll(v);
}
fn newFloat(py: *Interp, v: f64) Obj {
    _ = py;
    return mp_obj_new_float(v);
}
fn newStrN(py: *Interp, s: [*]const u8, n: usize) Obj {
    _ = py;
    return mp_obj_new_str(s, n);
}
fn newBytes(py: *Interp, s: [*]const u8, n: usize) Obj {
    _ = py;
    return mp_obj_new_bytes(s, n);
}
fn newTuple(py: *Interp, n: usize, items: ?[*]const Handle) Obj {
    const list = listOf(py, n, items);
    if (list == mirrors.OBJ_NULL) return list;
    return mp_obj_new_tuple(n, mirrors.MpObjList.fromObj(list).items);
}
fn newDict(py: *Interp) Obj {
    _ = py;
    return mp_obj_new_dict(0);
}

export fn ppy_new_none(py: *Interp, result: ?*Handle) c_int {
    return produce(py, result, constant, .{mirrors.OBJ_NONE});
}
export fn ppy_new_bool(py: *Interp, value: bool, result: ?*Handle) c_int {
    return produce(py, result, constant, .{if (value) mirrors.OBJ_TRUE else mirrors.OBJ_FALSE});
}
export fn ppy_new_int(py: *Interp, value: i64, result: ?*Handle) c_int {
    return produce(py, result, newInt, .{value});
}
export fn ppy_new_float(py: *Interp, value: f64, result: ?*Handle) c_int {
    return produce(py, result, newFloat, .{value});
}
export fn ppy_new_str(py: *Interp, utf8: [*]const u8, len: usize, result: ?*Handle) c_int {
    return produce(py, result, newStrN, .{ utf8, len });
}
export fn ppy_new_bytes(py: *Interp, data: [*]const u8, len: usize, result: ?*Handle) c_int {
    return produce(py, result, newBytes, .{ data, len });
}
export fn ppy_new_list(py: *Interp, n: usize, items: ?[*]const Handle, result: ?*Handle) c_int {
    return produce(py, result, listOf, .{ n, items });
}
export fn ppy_new_tuple(py: *Interp, n: usize, items: ?[*]const Handle, result: ?*Handle) c_int {
    return produce(py, result, newTuple, .{ n, items });
}
export fn ppy_new_dict(py: *Interp, result: ?*Handle) c_int {
    return produce(py, result, newDict, .{});
}

// ── reading values ──────────────────────────────────────────────────────

fn toBool(py: *Interp, h: Handle, value: *bool) Obj {
    const o = obj(py, h);
    if (o == mirrors.OBJ_NULL) return o;
    value.* = mp_obj_is_true(o);
    return mirrors.OBJ_NONE;
}
fn toInt(py: *Interp, h: Handle, value: *i64) Obj {
    const o = obj(py, h);
    if (o == mirrors.OBJ_NULL) return o;
    var v: isize = 0;
    if (!mp_obj_get_int_maybe(o, &v)) return raise(&mp_type_TypeError, "expected an int");
    value.* = v;
    return mirrors.OBJ_NONE;
}
fn toFloat(py: *Interp, h: Handle, value: *f64) Obj {
    const o = obj(py, h);
    if (o == mirrors.OBJ_NULL) return o;
    if (!mp_obj_get_float_maybe(o, value)) return raise(&mp_type_TypeError, "expected a float");
    return mirrors.OBJ_NONE;
}
fn toData(py: *Interp, h: Handle, t: *const anyopaque, data: *?[*]const u8, len: *usize) Obj {
    const o = obj(py, h);
    if (o == mirrors.OBJ_NULL) return o;
    const is_str = t == @as(*const anyopaque, &mp_type_str);
    if (!(is_str and mirrors.isQstr(o)) and !mirrors.isExactType(o, t))
        return raise(&mp_type_TypeError, if (is_str) "expected a str" else "expected bytes");
    data.* = mp_obj_str_get_data(o, len);
    return mirrors.OBJ_NONE;
}
fn printed(py: *Interp, h: Handle, kind: c_int) Obj {
    const o = obj(py, h);
    if (o == mirrors.OBJ_NULL) return o;
    var vstr: Vstr = undefined;
    var print: mirrors.MpPrint = undefined;
    vstr_init_print(&vstr, 16, &print);
    mp_obj_print_helper(&print, o, kind);
    return mp_obj_new_str_from_vstr(&vstr);
}

export fn ppy_to_bool(py: *Interp, h: Handle, value: *bool) c_int {
    return produce(py, null, toBool, .{ h, value });
}
export fn ppy_to_int(py: *Interp, h: Handle, value: *i64) c_int {
    return produce(py, null, toInt, .{ h, value });
}
export fn ppy_to_float(py: *Interp, h: Handle, value: *f64) c_int {
    return produce(py, null, toFloat, .{ h, value });
}
export fn ppy_to_str(py: *Interp, h: Handle, utf8: *?[*]const u8, len: *usize) c_int {
    return produce(py, null, toData, .{ h, @as(*const anyopaque, &mp_type_str), utf8, len });
}
export fn ppy_to_bytes(py: *Interp, h: Handle, data: *?[*]const u8, len: *usize) c_int {
    return produce(py, null, toData, .{ h, @as(*const anyopaque, &mp_type_bytes), data, len });
}
export fn ppy_str(py: *Interp, h: Handle, result: ?*Handle) c_int {
    return produce(py, result, printed, .{ h, PRINT_STR });
}
export fn ppy_repr(py: *Interp, h: Handle, result: ?*Handle) c_int {
    return produce(py, result, printed, .{ h, PRINT_REPR });
}

export fn ppy_type_name(py: *Interp, h: Handle) ?[*:0]const u8 {
    lock();
    defer unlock();
    // A class name may be one of the interpreter's own interned strings.
    const back = enter(py);
    defer leave(back);
    const slot = slotOf(py, h) orelse return null;
    return mp_obj_get_type_str(py.slots.?[slot]);
}

// ── containers ──────────────────────────────────────────────────────────

fn length(py: *Interp, h: Handle, len: *usize) Obj {
    const o = obj(py, h);
    if (o == mirrors.OBJ_NULL) return o;
    const n = mp_obj_len(o);
    if (n == mirrors.OBJ_NULL) return n;
    len.* = @intCast(mirrors.smallIntValue(n));
    return mirrors.OBJ_NONE;
}
fn getItem(py: *Interp, c: Handle, k: Handle) Obj {
    const co = obj(py, c);
    const ko = obj(py, k);
    if (pyerr.pending_exc != 0) return mirrors.OBJ_NULL;
    return mp_obj_subscr(co, ko, mirrors.OBJ_SENTINEL);
}
fn setItem(py: *Interp, c: Handle, k: Handle, v: Handle) Obj {
    const co = obj(py, c);
    const ko = obj(py, k);
    const vo = obj(py, v);
    if (pyerr.pending_exc != 0) return mirrors.OBJ_NULL;
    return mp_obj_subscr(co, ko, vo);
}

export fn ppy_len(py: *Interp, c: Handle, len: *usize) c_int {
    return produce(py, null, length, .{ c, len });
}
export fn ppy_getitem(py: *Interp, c: Handle, key: Handle, result: ?*Handle) c_int {
    return produce(py, result, getItem, .{ c, key });
}
export fn ppy_setitem(py: *Interp, c: Handle, key: Handle, value: Handle) c_int {
    return produce(py, null, setItem, .{ c, key, value });
}

// ── calls, attributes, globals ──────────────────────────────────────────

fn call(py: *Interp, f: Handle, n: usize, items: ?[*]const Handle) Obj {
    const fo = obj(py, f);
    const args = listOf(py, n, items);
    if (pyerr.pending_exc != 0) return mirrors.OBJ_NULL;
    return mp_call_function_n_kw(fo, n, 0, mirrors.MpObjList.fromObj(args).items);
}
fn getAttr(py: *Interp, h: Handle, name: [*:0]const u8) Obj {
    const o = obj(py, h);
    if (o == mirrors.OBJ_NULL) return o;
    return mp_load_attr(o, qstr(name));
}
fn setAttr(py: *Interp, h: Handle, name: [*:0]const u8, v: Handle) Obj {
    const o = obj(py, h);
    const vo = obj(py, v);
    if (pyerr.pending_exc != 0) return mirrors.OBJ_NULL;
    mp_store_attr(o, qstr(name), vo);
    return mirrors.OBJ_NONE;
}
fn getGlobal(py: *Interp, name: [*:0]const u8) Obj {
    _ = py;
    const map = &mirrors.MpObjDict.fromObj(dictMain()).map;
    const o = map.lookupQstr(@intCast(qstr(name)));
    if (o == mirrors.OBJ_NULL) return raise(&mp_type_ValueError, "name is not defined in __main__");
    return o;
}
fn setGlobal(py: *Interp, name: [*:0]const u8, v: Handle) Obj {
    const vo = obj(py, v);
    if (vo == mirrors.OBJ_NULL) return vo;
    return mp_obj_subscr(dictMain(), mirrors.objFromQstr(qstr(name)), vo);
}

export fn ppy_call(py: *Interp, f: Handle, argc: usize, argv: ?[*]const Handle, result: ?*Handle) c_int {
    return produce(py, result, call, .{ f, argc, argv });
}
export fn ppy_getattr(py: *Interp, h: Handle, name: [*:0]const u8, result: ?*Handle) c_int {
    return produce(py, result, getAttr, .{ h, name });
}
export fn ppy_setattr(py: *Interp, h: Handle, name: [*:0]const u8, value: Handle) c_int {
    return produce(py, null, setAttr, .{ h, name, value });
}
export fn ppy_get_global(py: *Interp, name: [*:0]const u8, result: ?*Handle) c_int {
    return produce(py, result, getGlobal, .{name});
}
export fn ppy_set_global(py: *Interp, name: [*:0]const u8, value: Handle) c_int {
    return produce(py, null, setGlobal, .{ name, value });
}

export fn ppy_dup(py: *Interp, h: Handle, copy: ?*Handle) c_int {
    return produce(py, copy, obj, .{h});
}

export fn ppy_release(py: *Interp, h: Handle) void {
    lock();
    defer unlock();
    const slot = slotOf(py, h) orelse return;
    py.slots.?[slot] = mirrors.OBJ_NULL;
    py.free.append(std.heap.c_allocator, slot) catch {}; // ken: a lost slot only leaks one word
}

// ── host functions ──────────────────────────────────────────────────────

/// The Python side of every host function: a bound method of this
/// builtin, whose `self` is the host function's index in `hosts`.
fn hostCall(n_args: usize, args: [*]const Obj) callconv(.c) Obj {
    const py = current.?;
    const host = py.hosts.items[@intCast(mirrors.smallIntValue(args[0]))];
    const argc = n_args - 1;
    // The arguments are handles for the length of the call; the array that
    // names them is host memory, released before returning.
    const argv = std.heap.c_allocator.alloc(Handle, argc) catch return raise(&mp_type_RuntimeError, "out of memory");
    defer std.heap.c_allocator.free(argv);
    for (argv, args[1..n_args]) |*h, a| h.* = newHandle(py, a);
    defer for (argv) |h| ppy_release(py, h);
    if (pyerr.pending_exc != 0) return mirrors.OBJ_NULL;

    var result: Handle = 0;
    const status = host.fun(py, host.userdata, argc, argv.ptr, &result);
    if (status != OK) {
        // The exception from ppy_raise() or from the API call that failed.
        pyerr.pending_exc = if (py.err != 0) py.err else mp_obj_new_exception_msg(&mp_type_RuntimeError, "host function failed");
        py.err = 0;
        return mirrors.OBJ_NULL;
    }
    if (result == 0) return mirrors.OBJ_NONE;
    const o = obj(py, result);
    ppy_release(py, result);
    return o;
}

const host_call_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(1, std.math.maxInt(u16), false),
    .fun = @ptrCast(&hostCall),
};

fn defineFunction(py: *Interp, module: [*:0]const u8, name: [*:0]const u8, f: HostFn, userdata: ?*anyopaque) Obj {
    py.hosts.append(std.heap.c_allocator, .{ .fun = f, .userdata = userdata }) catch
        return raise(&mp_type_RuntimeError, "out of memory");
    const index = mirrors.newSmallInt(@intCast(py.hosts.items.len - 1));
    const m = mp_obj_new_module(qstr(module));
    mp_store_attr(m, qstr(name), mp_obj_new_bound_meth(mirrors.objFromPtr(&host_call_obj), index));
    return mirrors.OBJ_NONE;
}

export fn ppy_define_function(py: *Interp, module: [*:0]const u8, name: [*:0]const u8, f: HostFn, userdata: ?*anyopaque) c_int {
    return produce(py, null, defineFunction, .{ module, name, f, userdata });
}

// ── errors ──────────────────────────────────────────────────────────────

fn raiseNamed(py: *Interp, type_name: [*:0]const u8, message: [*:0]const u8) Obj {
    _ = py;
    const t = mp_load_attr(mirrors.objFromPtr(&mp_module_builtins), qstr(type_name));
    if (t == mirrors.OBJ_NULL) return t;
    const is_exc_type = mp_obj_get_type(t) == @as(*const anyopaque, &mp_type_type) and
        mp_obj_is_subclass_fast(t, mirrors.objFromPtr(&mp_type_BaseException));
    if (!is_exc_type) return raise(&mp_type_TypeError, "not an exception type");
    return raise(@ptrFromInt(t), message);
}

export fn ppy_raise(py: *Interp, type_name: [*:0]const u8, message: [*:0]const u8) c_int {
    // The raise is the expected outcome: leave it in py.err for the host
    // function's caller, and report ERROR either way.
    _ = produce(py, null, raiseNamed, .{ type_name, message });
    return ERROR;
}

/// Moves the exception out of `py.err` inside the bracket, where the
/// body's frame holds it until the handle does.
fn takeError(py: *Interp) Obj {
    const exc = py.fetched;
    py.fetched = 0;
    return exc;
}

fn raiseObject(py: *Interp, h: Handle) Obj {
    const o = obj(py, h);
    if (o == mirrors.OBJ_NULL) return o;
    const t = mp_obj_get_type(o) orelse return mirrors.OBJ_NULL;
    if (!mp_obj_is_subclass_fast(mirrors.objFromPtr(t), mirrors.objFromPtr(&mp_type_BaseException)))
        return raise(&mp_type_TypeError, "not an exception");
    pyerr.pending_exc = o;
    return mirrors.OBJ_NULL;
}

export fn ppy_raise_exception(py: *Interp, exception: Handle) c_int {
    _ = produce(py, null, raiseObject, .{exception});
    return ERROR;
}

export fn ppy_fetch_error(py: *Interp, exception: ?*Handle) c_int {
    lock();
    defer unlock();
    if (exception) |e| e.* = 0;
    if (py.err == 0) return OK;
    py.fetched = py.err; // `run` clears py.err on entry
    return produce(py, exception, takeError, .{});
}

fn formatException(py: *Interp, h: Handle) Obj {
    const o = obj(py, h);
    if (o == mirrors.OBJ_NULL) return o;
    var vstr: Vstr = undefined;
    var print: mirrors.MpPrint = undefined;
    vstr_init_print(&vstr, 64, &print);
    mp_obj_print_exception(&print, o);
    return mp_obj_new_str_from_vstr(&vstr);
}

export fn ppy_format_exception(py: *Interp, exception: Handle, text: ?*Handle) c_int {
    return produce(py, text, formatException, .{exception});
}

export fn ppy_exit_code(py: *Interp) c_int {
    return py.exit_code;
}
