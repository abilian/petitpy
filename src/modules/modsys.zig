//! nanopython — Zig port of py/modsys.c (the `sys` builtin module).
//!
//! Under nano: PY_SYS=1, PY_SYS_PATH/ARGV/MAXSIZE/EXIT/MODULES/PS1_PS2=1,
//!   PY_SYS_TRACEBACKLIMIT=1, PY_SYS_ATTR_DELEGATION=1 (cascade), all other
//!   PY_SYS_* (STDFILES/INTERN/EXC_INFO/ATEXIT/SETTRACE/GETSIZEOF/EXECUTABLE)
//!   default to 0. PY_ATTRTUPLE=0 (so implementation is a plain tuple).
//!   LONGINT_IMPL=NONE → maxsize is a small-int constant.
//!
//! Under full: PY_SYS_STDFILES=1, PY_SYS_INTERN=1, PY_SYS_EXC_INFO=1,
//!   PY_SYS_TRACEBACKLIMIT=0 (override), PY_ATTRTUPLE=1, LONGINT=MPZ →
//!   maxsize uses the `mp_sys_maxsize_obj` int constant.
//!
//! ROOT_POINTER and MODULE_DELEGATION markers stay in src/modules/modsys.c
//! (a thin tombstone) because `makemoduledefs.py` and the qstr scanner walk
//! .c sources only.

const build_options = @import("build_options");
const std = @import("std");
const mp = @cImport({
    @cInclude("py/qstr.h");
});
const mirrors = @import("../mp_mirrors.zig");
const pyerr = @import("../pyerr.zig");
const PyError = pyerr.PyError;

const Obj = mirrors.Obj;
const Qstr = usize;

// ── extern type / fn / data symbols (provided by vendor C) ───────────
extern const mp_type_module: anyopaque;
extern const mp_type_dict: anyopaque;
extern const mp_type_tuple: anyopaque;
extern const mp_type_str: anyopaque;
extern const mp_type_attrtuple: anyopaque;
extern const mp_type_int: anyopaque;
extern const mp_type_fun_builtin_1: anyopaque;
extern const mp_type_fun_builtin_0: anyopaque;
extern const mp_type_fun_builtin_var: anyopaque;
extern const mp_type_SystemExit: anyopaque;

// Stream / print plumbing (full only).
extern const mp_plat_print: anyopaque;
extern fn mp_obj_print_exception(print: *const anyopaque, exc: Obj) callconv(.c) void;
extern fn mp_obj_get_type(o: Obj) callconv(.c) *const anyopaque;
extern fn mp_obj_new_tuple(n: usize, items: ?[*]const Obj) callconv(.c) Obj;
// NX-3 N1: raise via PyError convention — construct exceptions inline,
// stash in pyerr.pending_exc, return error.PyRaise. Vendor `mp_raise_type`
// (under TERSE) is `mp_raise_msg(t, NULL)` = `mp_obj_new_exception(t)`;
// vendor `mp_raise_type_arg(t, arg)` = `mp_obj_new_exception_arg1(t, arg)`
// = `mp_obj_exception_make_new(t, 1, 0, &arg)` (arg1 is static-inline).
extern fn mp_obj_new_exception(exc_type: *const anyopaque) callconv(.c) Obj;
extern fn mp_obj_exception_make_new(exc_type: *const anyopaque, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) Obj;
extern fn mp_obj_str_intern_checked(o: Obj) callconv(.c) Obj;
extern fn mp_module_generic_attr(
    attr: Qstr,
    dest: [*c]Obj,
    keys: [*]const u16,
    values: [*]Obj,
) callconv(.c) void;
extern fn mp_get_stream_raise(self_in: Obj, flags: c_int) callconv(.c) *const anyopaque;
extern fn mp_stream_write_adaptor(self_obj: ?*anyopaque, buf: [*]const u8, len: usize) callconv(.c) void;

const MP_STREAM_OP_WRITE: c_int = 2;

// Full-only: vendor mp_sys_maxsize_obj (MPZ-backed int).
extern const mp_sys_maxsize_obj: anyopaque;

// Full-only: file-like stdin/stdout/stderr live in src/modules/file_io.c.
// Declared in both arms because `&X` is referenced in the dict; under nano
// the ROM entries are not built so these are link-time dead.
extern const mp_sys_stdin_obj: anyopaque;
extern const mp_sys_stdout_obj: anyopaque;
extern const mp_sys_stderr_obj: anyopaque;

// ── version / implementation ROM constants ───────────────────────────
//
// mp_obj_str_t storage for the `sys.version` string. Vendor `MP_DEFINE_STR_OBJ`
// expands to `{{&mp_type_str}, 0, len, data}`. The string itself bakes the
// mpversion.h-derived banner; we re-derive it via comptime concatenation.
const VERSION_STR = "3.4.0; MicroPython (with v2.0 preview) v1.28.0-preview.80.gb14d129a16 on 2026-06-04";

const StrObj = extern struct {
    base: mirrors.MpObjBase,
    hash: usize,
    len: usize,
    data: [*]const u8,
};

pub export const mp_sys_version_obj: StrObj = .{
    .base = .{ .type = &mp_type_str },
    .hash = 0,
    .len = VERSION_STR.len,
    .data = VERSION_STR.ptr,
};

// version_info: (3, 4, 0). A 3-element ROM tuple, items inlined past `len`.
const VersionInfoTuple = extern struct {
    base: mirrors.MpObjBase,
    len: usize,
    items: [3]Obj,
};

pub export const mp_sys_version_info_obj: VersionInfoTuple = .{
    .base = .{ .type = &mp_type_tuple },
    .len = 3,
    .items = .{ mirrors.newSmallInt(3), mirrors.newSmallInt(4), mirrors.newSmallInt(0) },
};

// implementation.version: 4-tuple (1, 28, 0, "preview"). Constants pulled
// from vendor py/mpconfig.h MICROPY_VERSION_{MAJOR,MINOR,MICRO} +
// MICROPY_VERSION_PRERELEASE.
const ImplVersionTuple = extern struct {
    base: mirrors.MpObjBase,
    len: usize,
    items: [4]Obj,
};

pub export const mp_sys_implementation_version_info_obj: ImplVersionTuple = .{
    .base = .{ .type = &mp_type_tuple },
    .len = 4,
    .items = .{
        mirrors.newSmallInt(1),
        mirrors.newSmallInt(28),
        mirrors.newSmallInt(0),
        mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_preview)),
    },
};

// implementation._machine: "nanopython [<compiler>] version"
// (per MICROPY_BANNER_MACHINE in mpconfig.h:2229; we hard-code the result
// for the host build).
const MACHINE_STR = "nanopython [GCC 4.2.1 (Apple Inc. build 5658) (LLVM build)] version";

pub export const mp_sys_implementation_machine_obj: StrObj = .{
    .base = .{ .type = &mp_type_str },
    .hash = 0,
    .len = MACHINE_STR.len,
    .data = MACHINE_STR.ptr,
};

// MPY_FILE_HEADER_INT (vendor persistentcode.h) — MPY file format magic
// for the version-6 .mpy header. Encodes the format constants used by
// MICROPY_PERSISTENT_CODE_LOAD readers.
const MPY_FILE_HEADER_INT: isize = 'M' | ('P' << 8) | (6 << 16);

// sys.platform — "petitpy" (per MICROPY_PY_SYS_PLATFORM in port config).
const PLATFORM_STR = "petitpy";

pub export const mp_sys_platform_obj: StrObj = .{
    .base = .{ .type = &mp_type_str },
    .hash = 0,
    .len = PLATFORM_STR.len,
    .data = PLATFORM_STR.ptr,
};

// implementation tuple. Under nano (PY_ATTRTUPLE=0) it's a plain tuple
// with 4 items (name, version, _machine, _mpy). Under full it's an
// attrtuple with the same 4 fields, with a trailing fields-array slot.
//
// 4 items in both configs: BASE (3) + MPY (1, since PERSISTENT_CODE_LOAD=1).
const IMPL_N_ITEMS: usize = 4;

// Items in the implementation tuple. Mix of pointer-to-ROM and tagged-int
// immediates: store as `*const anyopaque` so the linker resolves the
// pointer values (Zig forbids `@intFromPtr(&extern_const)` at comptime).
// Tagged immediates use `@ptrFromInt(obj_int_value)` — a no-op cast that
// passes Zig's comptime check.
const ImplItem = *const anyopaque;

// Plain-tuple variant (nano): 4 items inlined, no extra slot.
const ImplTuplePlain = extern struct {
    base: mirrors.MpObjBase,
    len: usize,
    items: [IMPL_N_ITEMS]ImplItem,
};

// Attrtuple variant (full): 4 items + 1 trailing pointer slot holding the
// fields qstr-array address. Vendor's MP_DEFINE_ATTRTUPLE allocates
// `items[nitems]` (one extra), and stores `MP_ROM_PTR((void *)fields)`
// at the last slot. `len` is still `nitems` (4).
const ImplTupleAttr = extern struct {
    base: mirrors.MpObjBase,
    len: usize,
    items: [IMPL_N_ITEMS]ImplItem,
    fields_ptr: *const anyopaque, // = &impl_fields
};

// Under full, the fields-array drives the attrtuple's attribute lookup.
// Element type MUST be Qstr (= usize, 8B on 64-bit) — the reader at
// src/objects/containers/objattrtuple.zig:31 + objattrtuple.zig:88 reads
// this as `[*]const Qstr`. The prior `[IMPL_N_ITEMS]u16` declaration
// gave a 2-byte stride and the reader walked into garbage (qstr_str
// panic on out-of-range qstr). ADR 012 Phase 3.5 step 5 — sys.implementation
// attrtuple now works under full, unblocking the 3 async_*2 tests
// that gate on `sys.implementation.name`.
pub export const impl_fields: [IMPL_N_ITEMS]Qstr = .{
    mp.MP_QSTR_name,
    mp.MP_QSTR_version,
    mp.MP_QSTR__machine,
    mp.MP_QSTR__mpy,
};

const IMPL_ITEMS: [IMPL_N_ITEMS]ImplItem = .{
    @ptrFromInt(mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_micropython))),
    &mp_sys_implementation_version_info_obj,
    &mp_sys_implementation_machine_obj,
    @ptrFromInt(mirrors.newSmallInt(MPY_FILE_HEADER_INT)),
};

pub export const mp_sys_implementation_obj_plain: ImplTuplePlain = .{
    .base = .{ .type = &mp_type_tuple },
    .len = IMPL_N_ITEMS,
    .items = IMPL_ITEMS,
};

pub export const mp_sys_implementation_obj_attr: ImplTupleAttr = .{
    .base = .{ .type = &mp_type_attrtuple },
    .len = IMPL_N_ITEMS,
    .items = IMPL_ITEMS,
    .fields_ptr = &impl_fields,
};

// ── fn-obj definitions ────────────────────────────────────────────────

// NX-3 N1 raise helpers (PyError convention; notes/41, /42). One per
// distinct exception+message. Sets pyerr.pending_exc + returns
// error.PyRaise.
fn raiseSystemExitNoArg() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception(&mp_type_SystemExit);
    return error.PyRaise;
}

fn raiseSystemExitArg(arg: Obj) PyError!void {
    pyerr.pending_exc = mp_obj_exception_make_new(&mp_type_SystemExit, 1, 0, @ptrCast(&arg));
    return error.PyRaise;
}

fn pySysExitImpl(n_args: usize, args: [*c]const Obj) PyError!Obj {
    if (n_args == 0) {
        try raiseSystemExitNoArg();
    } else {
        try raiseSystemExitArg(args[0]);
    }
    unreachable;
}

// C-ABI shim — preserves the @ptrCast(&py_sys_exit) target in
// mp_sys_exit_obj.fun. Real work in pySysExitImpl.
fn py_sys_exit(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    return pyerr.bridge(Obj, pySysExitImpl(n_args, args));
}

pub export const mp_sys_exit_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(0, 1, false),
    .fun = @ptrCast(&py_sys_exit),
};

// sys.getrecursionlimit() — returns a fixed value (we don't enforce a
// recursion limit at the Python level; running out of C-stack just
// traps, but the API placates programs that probe sys for capability
// information without actually depending on the limit).
// sys.setrecursionlimit(n) — accepts any int, no-op (same rationale).
fn py_sys_getrecursionlimit() callconv(.c) Obj {
    return mirrors.newSmallInt(1000); // CPython default
}
fn py_sys_setrecursionlimit(_: Obj) callconv(.c) Obj {
    return mirrors.OBJ_NONE;
}

pub export const mp_sys_getrecursionlimit_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_0 },
    .fun = @ptrCast(&py_sys_getrecursionlimit),
};
pub export const mp_sys_setrecursionlimit_obj: mirrors.MpObjFunBuiltinFixed = .{
    .base = .{ .type = &mp_type_fun_builtin_1 },
    .fun = @ptrCast(&py_sys_setrecursionlimit),
};

// __qstr_shadow_begin__
// MP_QSTR_getrecursionlimit
// MP_QSTR_setrecursionlimit
// __qstr_shadow_end__

// mp_print_t layout (mpprint.h:50): { void *data; mp_print_strn_t print_strn; }
const MpPrintT = extern struct {
    data: ?*anyopaque,
    print_strn: ?*const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void,
};

fn py_sys_print_exception(n_args: usize, args: [*c]const Obj) callconv(.c) Obj {
    if (comptime build_options.is_full) {
        // PY_IO + PY_SYS_STDFILES — route to sys.stdout (default) or args[1].
        var stream_obj: ?*anyopaque = @ptrCast(@constCast(&mp_sys_stdout_obj));
        if (n_args > 1) {
            _ = mp_get_stream_raise(args[1], MP_STREAM_OP_WRITE);
            stream_obj = mirrors.objToPtr(args[1]);
        }
        const print: MpPrintT = .{ .data = stream_obj, .print_strn = @ptrCast(&mp_stream_write_adaptor) };
        mp_obj_print_exception(@ptrCast(&print), args[0]);
        return mirrors.OBJ_NONE;
    }
    // Nano: PY_IO=0 → route to mp_plat_print.
    mp_obj_print_exception(&mp_plat_print, args[0]);
    return mirrors.OBJ_NONE;
}

pub export const mp_sys_print_exception_obj: mirrors.MpObjFunBuiltinVar = .{
    .base = .{ .type = &mp_type_fun_builtin_var },
    .sig = mirrors.makeFunSig(1, 2, false),
    .fun = @ptrCast(&py_sys_print_exception),
};

// exc_info / intern fn-objs — full only.
// Under nano, MICROPY_PY_SYS_EXC_INFO=0 → no `cur_exception` root pointer
// is registered in vendor's root_pointers.h. The FullOnly struct wraps
// all symbols that reference cur_exception so they're never analyzed
// under nano (Zig lazily evaluates unaccessed struct decls).
const FullOnly = struct {
    extern var cur_exception: ?*mirrors.MpObjBase; // MP_STATE_VM root pointer

    fn py_sys_exc_info() callconv(.c) Obj {
        const cur_exc_ptr = cur_exception;
        const t_obj = mp_obj_new_tuple(3, null);
        const t: *mirrors.MpObjTuple = mirrors.MpObjTuple.fromObj(t_obj);
        const items = t.itemsPtr();
        if (cur_exc_ptr == null) {
            items[0] = mirrors.OBJ_NONE;
            items[1] = mirrors.OBJ_NONE;
            items[2] = mirrors.OBJ_NONE;
            return t_obj;
        }
        const cur_exc_obj: Obj = @intFromPtr(cur_exc_ptr);
        items[0] = @intFromPtr(mp_obj_get_type(cur_exc_obj));
        items[1] = cur_exc_obj;
        items[2] = mirrors.OBJ_NONE;
        return t_obj;
    }

    pub const mp_sys_exc_info_obj: mirrors.MpObjFunBuiltinFixed = .{
        .base = .{ .type = &mp_type_fun_builtin_0 },
        .fun = @ptrCast(&py_sys_exc_info),
    };

    pub const mp_sys_intern_obj: mirrors.MpObjFunBuiltinFixed = .{
        .base = .{ .type = &mp_type_fun_builtin_1 },
        .fun = @ptrCast(&mp_obj_str_intern_checked),
    };
};

// ── module attr delegation ───────────────────────────────────────────
// Kept in sync with the dict entry layout for `sys.path`, `sys.ps1`,
// `sys.ps2`. Ends in a MP_QSTRnull (= MP_QSTR_) sentinel.
//
// Under both nano and full, TRACEBACKLIMIT is OFF — nano because
// MICROPY_CONFIG_ROM_LEVEL=MINIMUM (and the default is EVERYTHING-gated),
// full because mpconfigport.h explicitly `#undef`s it to (0) at line 180.
// So the key set is identical: [path, ps1, ps2, null].

pub export const sys_mutable_keys: [4]u16 = .{
    mp.MP_QSTR_path,
    mp.MP_QSTR_ps1,
    mp.MP_QSTR_ps2,
    mp.MP_QSTR_,
};

// `attr` must be `Qstr` (= `usize`) to match the C `qstr` type used in
// mp_attr_fun_t (py/obj.h:603). On wasm32 a u16 parameter here causes
// the wasm engine to trap when the C delegation table calls us with a
// size_t-width argument (signature mismatch becomes a hard trap, not a
// silent truncation as on register-based arm64).
pub export fn mp_module_sys_attr(self_in: Obj, attr: Qstr, dest: [*c]Obj) callconv(.c) void {
    _ = self_in;
    mp_module_generic_attr(
        attr,
        dest,
        &sys_mutable_keys,
        @ptrCast(&mirrors.mp_state_ctx.vm.sys_mutable),
    );
}

// ── globals dict (config-parametric) ──────────────────────────────────

const RomEntry = extern struct {
    key: Obj,
    value: *const anyopaque,
};

const BYTEORDER_QSTR: u16 = mp.MP_QSTR_little; // host is little-endian.

// Under nano, maxsize is a small-int (LONGINT_IMPL=NONE). Under full it's
// the mpz-backed mp_sys_maxsize_obj.
const MAXSIZE_ENTRY: RomEntry = if (build_options.is_full) .{
    .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_maxsize)),
    .value = &mp_sys_maxsize_obj,
} else .{
    .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_maxsize)),
    .value = @ptrFromInt(mirrors.newSmallInt(mirrors.SMALL_INT_MAX)),
};

const IMPL_ENTRY: RomEntry = if (build_options.is_full) .{
    .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_implementation)),
    .value = &mp_sys_implementation_obj_attr,
} else .{
    .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_implementation)),
    .value = &mp_sys_implementation_obj_plain,
};

// Build the globals table at comptime. Under nano: 13 entries
// (11 + getrecursionlimit + setrecursionlimit). Under full: adds
// stdin/stdout/stderr + intern + exc_info = 18 entries.
const N_GLOBALS: usize = if (build_options.is_full) 18 else 13;

const mp_module_sys_globals_table: [N_GLOBALS]RomEntry = blk: {
    var t: [N_GLOBALS]RomEntry = undefined;
    var i: usize = 0;
    t[i] = .{
        .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR___name__)),
        .value = @ptrFromInt(mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_sys))),
    };
    i += 1;
    t[i] = .{
        .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_argv)),
        .value = @ptrCast(&mirrors.mp_state_ctx.vm.mp_sys_argv_obj),
    };
    i += 1;
    t[i] = .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_version)), .value = &mp_sys_version_obj };
    i += 1;
    t[i] = .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_version_info)), .value = &mp_sys_version_info_obj };
    i += 1;
    t[i] = IMPL_ENTRY;
    i += 1;
    t[i] = .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_platform)), .value = &mp_sys_platform_obj };
    i += 1;
    t[i] = .{
        .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_byteorder)),
        .value = @ptrFromInt(mirrors.objFromQstr(@as(Qstr, BYTEORDER_QSTR))),
    };
    i += 1;
    t[i] = MAXSIZE_ENTRY;
    i += 1;
    if (build_options.is_full) {
        t[i] = .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_intern)), .value = &FullOnly.mp_sys_intern_obj };
        i += 1;
    }
    t[i] = .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_exit)), .value = &mp_sys_exit_obj };
    i += 1;
    if (build_options.is_full) {
        t[i] = .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_stdin)), .value = &mp_sys_stdin_obj };
        i += 1;
        t[i] = .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_stdout)), .value = &mp_sys_stdout_obj };
        i += 1;
        t[i] = .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_stderr)), .value = &mp_sys_stderr_obj };
        i += 1;
    }
    t[i] = .{
        .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_modules)),
        .value = @ptrCast(&mirrors.mp_state_ctx.vm.mp_loaded_modules_dict),
    };
    i += 1;
    if (build_options.is_full) {
        t[i] = .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_exc_info)), .value = &FullOnly.mp_sys_exc_info_obj };
        i += 1;
    }
    t[i] = .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_print_exception)), .value = &mp_sys_print_exception_obj };
    i += 1;
    t[i] = .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_getrecursionlimit)), .value = &mp_sys_getrecursionlimit_obj };
    i += 1;
    t[i] = .{ .key = mirrors.objFromQstr(@as(Qstr, mp.MP_QSTR_setrecursionlimit)), .value = &mp_sys_setrecursionlimit_obj };
    i += 1;
    std.debug.assert(i == N_GLOBALS);
    break :blk t;
};

pub export const mp_module_sys_globals: mirrors.MpObjDict = .{
    .base = .{ .type = &mp_type_dict },
    .map = .{
        .bits = .{
            .all_keys_are_qstrs = 1,
            .is_fixed = 1,
            .is_ordered = 1,
            .used = N_GLOBALS,
        },
        .alloc = N_GLOBALS,
        .table = @ptrCast(@constCast(&mp_module_sys_globals_table)),
    },
};

pub export const mp_module_sys: mirrors.MpObjModule = .{
    .base = .{ .type = &mp_type_module },
    .globals = @ptrCast(@constCast(&mp_module_sys_globals)),
};

comptime {
    _ = &mp_module_sys;
    _ = &mp_module_sys_globals;
    _ = &mp_sys_exit_obj;
    _ = &mp_sys_print_exception_obj;
    _ = &mp_sys_version_obj;
    _ = &mp_sys_version_info_obj;
    _ = &mp_sys_implementation_version_info_obj;
    _ = &mp_sys_implementation_machine_obj;
    _ = &mp_sys_implementation_obj_plain;
    _ = &mp_sys_implementation_obj_attr;
    _ = &mp_sys_platform_obj;
    _ = &sys_mutable_keys;
    _ = &mp_module_sys_attr;
    _ = &impl_fields;
    if (build_options.is_full) {
        _ = &FullOnly.mp_sys_exc_info_obj;
        _ = &FullOnly.mp_sys_intern_obj;
    }
}
