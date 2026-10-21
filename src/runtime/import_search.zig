//! ADR-003 L1+L2 — `import X` (and `import X.Y.Z`) search past the
//! registered-modules table.
//!
//! Chain (in order, per dotted component): frozen-tiny → sys.path or
//! parent-package `__path__` filesystem.
//!
//! `builtinimport.zig` walks the dotted module name one component at a
//! time, calling `tryLoadComponent` for each. On hit we:
//!   1. Allocate a fresh module + register it in `sys.modules` under
//!      the full dotted name
//!   2. If the component resolved to a directory (package), store its
//!      filesystem path in `__path__` and execute `__init__.py` (if any)
//!   3. If the component resolved to a `.py`/`.mpy` file, read source
//!      bytes, compile (if .py) → load .mpy → execute under the
//!      module's globals
//!   4. Return the module object
//!
//! On miss, return `OBJ_NULL` and the caller raises ImportError.
//!
//! Package support: subpackages are located via the parent package's
//! `__path__` attribute (set when we load a directory). Top-level
//! components are searched against every entry of `sys.path`.

const std = @import("std");
const builtin = @import("builtin");
const mirrors = @import("../mp_mirrors.zig");
const pyerr = @import("../pyerr.zig");
const frozen = @import("frozen_modules.zig");

const PyError = pyerr.PyError;
const Obj = mirrors.Obj;

// libc — file I/O for `.py` / `.mpy` from sys.path. Path always C-NUL-terminated.
const libc = @cImport({
    @cInclude("stdio.h");
});
const FILE = opaque {};
extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) callconv(.c) ?*FILE;
extern fn fclose(stream: *FILE) callconv(.c) c_int;
extern fn fread(ptr: *anyopaque, size: usize, nmemb: usize, stream: *FILE) callconv(.c) usize;
extern fn fseek(stream: *FILE, offset: c_long, whence: c_int) callconv(.c) c_int;
extern fn ftell(stream: *FILE) callconv(.c) c_long;
const SEEK_END: c_int = 2;
const SEEK_SET: c_int = 0;

// stat(2) — distinguish files from directories so we can support
// packages (directory == package, file == module).
const stat_libc = @cImport({
    @cInclude("sys/stat.h");
});
const S_IFMT: c_uint = 0o170000;
const S_IFDIR: c_uint = 0o040000;
const S_IFREG: c_uint = 0o100000;

fn pathIsDir(path: [*:0]const u8) bool {
    var st: stat_libc.struct_stat = undefined;
    if (stat_libc.stat(path, &st) != 0) return false;
    return (st.st_mode & S_IFMT) == S_IFDIR;
}

fn pathIsFile(path: [*:0]const u8) bool {
    var st: stat_libc.struct_stat = undefined;
    if (stat_libc.stat(path, &st) != 0) return false;
    return (st.st_mode & S_IFMT) == S_IFREG;
}

// Vendor / Zig-side helpers we lean on.
extern fn mp_obj_new_module(module_name: usize) callconv(.c) Obj;
extern fn mp_obj_str_get_data(o: Obj, len_out: *usize) callconv(.c) [*c]const u8;
extern fn mp_obj_new_str(data: [*]const u8, len: usize) callconv(.c) Obj;
extern fn qstr_str(q: usize) callconv(.c) [*:0]const u8;
extern fn qstr_from_strn(str: [*]const u8, len: usize) callconv(.c) usize;
extern fn mp_make_function_from_proto_fun(proto: usize, ctx: ?*const anyopaque, defargs: [*c]const Obj) callconv(.c) Obj;
extern fn mp_call_function_0(fun: Obj) callconv(.c) Obj;
extern fn mp_raw_code_load_mem(buf: [*]const u8, len: usize, cm: *mirrors.MpCompiledModule) callconv(.c) void;
extern fn m_malloc(num_bytes: usize) callconv(.c) ?*anyopaque;
extern fn m_free(ptr: ?*anyopaque) callconv(.c) void;
extern fn mp_globals_get() callconv(.c) ?*anyopaque;
extern fn mp_locals_get() callconv(.c) ?*anyopaque;
extern fn mp_globals_set(d: ?*anyopaque) callconv(.c) void;
extern fn mp_locals_set(d: ?*anyopaque) callconv(.c) void;
extern fn mp_obj_dict_store(self_in: Obj, key: Obj, value: Obj) callconv(.c) Obj;
extern fn mp_map_lookup_remove(map: ?*anyopaque, index: Obj) callconv(.c) void;
extern fn mp_store_attr(base: Obj, attr: usize, value: Obj) callconv(.c) void;
extern fn mp_load_method_maybe(obj: Obj, attr: usize, dest: [*]Obj) callconv(.c) void;
extern fn mp_obj_exception_match(exc: Obj, exc_type: Obj) callconv(.c) bool;
extern const mp_type_AttributeError: anyopaque;

/// `getattr(obj, attr, None)` for the importer's probes: an AttributeError
/// from a module __getattr__ (PEP 562) means absent, not failure. Other
/// exceptions stay pending.
pub fn loadAttrMaybe(obj: Obj, attr: usize, dest: *[2]Obj) void {
    mp_load_method_maybe(obj, attr, dest);
    if (pyerr.pending_exc != 0 and mp_obj_exception_match(pyerr.pending_exc, @intFromPtr(&mp_type_AttributeError))) {
        pyerr.pending_exc = 0;
        dest.* = .{ 0, 0 };
    }
}

extern const mp_type_module: anyopaque;

// External-import bridge into the compiler. Defined inline below.
extern fn npy_zig_compile_to_mpy(
    src: [*]const u8,
    src_len: usize,
    src_name: [*:0]const u8,
    parse_input_kind: c_int,
    out_buf: *?[*]u8,
    out_len: *usize,
) callconv(.c) c_int;

const NPY_ZIG_OK: c_int = 0;
const MP_PARSE_FILE_INPUT: c_int = 1;

const PATH_MAX_LEN: usize = 1024;

// Compile + load + execute Python source bytes under the given module's
// globals dict.
fn execSourceInModule(
    src: [*]const u8,
    src_len: usize,
    source_file_qstr: usize,
    module_obj: Obj,
) PyError!void {
    var mpy_buf: ?[*]u8 = null;
    var mpy_len: usize = 0;
    const rc = npy_zig_compile_to_mpy(
        src,
        src_len,
        qstr_str(source_file_qstr),
        MP_PARSE_FILE_INPUT,
        &mpy_buf,
        &mpy_len,
    );
    if (rc != NPY_ZIG_OK) return error.PyRaise;

    const mod = mirrors.MpObjModule.fromObj(module_obj);
    const ctx: *mirrors.MpModuleContext = @ptrCast(@alignCast(m_malloc(@sizeOf(mirrors.MpModuleContext)).?));
    ctx.module.base.type = @ptrCast(&mp_type_module);
    ctx.module.globals = mod.globals;

    var cm: mirrors.MpCompiledModule = undefined;
    cm.context = ctx;
    mp_raw_code_load_mem(mpy_buf.?, mpy_len, &cm);
    std.c.free(@ptrCast(mpy_buf.?));
    if (pyerr.pending_exc != 0) return error.PyRaise;

    const module_fun = mp_make_function_from_proto_fun(@intFromPtr(cm.rc), cm.context, null);

    const saved_g = mp_globals_get();
    const saved_l = mp_locals_get();
    defer mp_globals_set(saved_g);
    defer mp_locals_set(saved_l);
    mp_globals_set(mod.globals);
    mp_locals_set(mod.globals);

    _ = mp_call_function_0(module_fun);
    if (pyerr.pending_exc != 0) return error.PyRaise;
}

// Load already-compiled .mpy bytes under the given module's globals.
fn execMpyInModule(
    mpy_bytes: [*]const u8,
    mpy_len: usize,
    module_obj: Obj,
) PyError!void {
    const mod = mirrors.MpObjModule.fromObj(module_obj);
    const ctx: *mirrors.MpModuleContext = @ptrCast(@alignCast(m_malloc(@sizeOf(mirrors.MpModuleContext)).?));
    ctx.module.base.type = @ptrCast(&mp_type_module);
    ctx.module.globals = mod.globals;

    var cm: mirrors.MpCompiledModule = undefined;
    cm.context = ctx;
    mp_raw_code_load_mem(mpy_bytes, mpy_len, &cm);
    if (pyerr.pending_exc != 0) return error.PyRaise;

    const module_fun = mp_make_function_from_proto_fun(@intFromPtr(cm.rc), cm.context, null);

    const saved_g = mp_globals_get();
    const saved_l = mp_locals_get();
    defer mp_globals_set(saved_g);
    defer mp_locals_set(saved_l);
    mp_globals_set(mod.globals);
    mp_locals_set(mod.globals);

    _ = mp_call_function_0(module_fun);
    if (pyerr.pending_exc != 0) return error.PyRaise;
}

// Read a file's full contents into a fresh m_malloc'd buffer. Caller frees.
// Returns null on open / size / read failure (treated as "not found").
fn readFileFull(path: [*:0]const u8, out_len: *usize) ?[*]u8 {
    const fp = fopen(path, "rb") orelse return null;
    if (fseek(fp, 0, SEEK_END) != 0) {
        _ = fclose(fp);
        return null;
    }
    const sz = ftell(fp);
    if (sz < 0) {
        _ = fclose(fp);
        return null;
    }
    if (fseek(fp, 0, SEEK_SET) != 0) {
        _ = fclose(fp);
        return null;
    }
    const usz: usize = @intCast(sz);
    const buf_raw = m_malloc(usz + 1) orelse {
        _ = fclose(fp);
        return null;
    };
    const buf: [*]u8 = @ptrCast(@alignCast(buf_raw));
    const got = fread(buf_raw, 1, usz, fp);
    _ = fclose(fp);
    if (got != usz) {
        m_free(buf_raw);
        return null;
    }
    buf[usz] = 0;
    out_len.* = usz;
    return buf;
}

// Build "<dir>/<name>" or "<dir>/<name><ext>" into `out`. Returns false
// if it doesn't fit. `ext` may be empty.
fn buildPath(out: *[PATH_MAX_LEN:0]u8, dir: []const u8, name: []const u8, ext: []const u8) bool {
    const sep_needed = dir.len > 0;
    const total = dir.len + (if (sep_needed) @as(usize, 1) else 0) + name.len + ext.len;
    if (total + 1 > PATH_MAX_LEN) return false;
    var i: usize = 0;
    @memcpy(out[i..][0..dir.len], dir);
    i += dir.len;
    if (sep_needed) {
        out[i] = '/';
        i += 1;
    }
    @memcpy(out[i..][0..name.len], name);
    i += name.len;
    @memcpy(out[i..][0..ext.len], ext);
    i += ext.len;
    out[i] = 0;
    return true;
}

// What a per-component filesystem search found.
const FoundKind = enum { not_found, file_py, file_mpy, dir_package };

const Found = struct {
    kind: FoundKind,
    // Absolute path to the file (for file_py/file_mpy) or to the
    // directory (for dir_package). Borrows a buffer the caller owns;
    // use `len` as the slice length.
    path_len: usize,
};

// Search a single directory for `component` as a module file or
// subpackage directory. Mirrors vendor's stat_module + stat_file_py_or_mpy.
fn statComponentIn(
    root: []const u8,
    component: []const u8,
    out_path: *[PATH_MAX_LEN:0]u8,
) Found {
    // Try .py first (vendor's stat_file_py_or_mpy precedence).
    if (buildPath(out_path, root, component, ".py")) {
        if (pathIsFile(out_path)) {
            return .{ .kind = .file_py, .path_len = root.len + (if (root.len > 0) @as(usize, 1) else 0) + component.len + 3 };
        }
    }
    // Then .mpy.
    if (buildPath(out_path, root, component, ".mpy")) {
        if (pathIsFile(out_path)) {
            return .{ .kind = .file_mpy, .path_len = root.len + (if (root.len > 0) @as(usize, 1) else 0) + component.len + 4 };
        }
    }
    // Then a directory (subpackage).
    if (buildPath(out_path, root, component, "")) {
        if (pathIsDir(out_path)) {
            return .{ .kind = .dir_package, .path_len = root.len + (if (root.len > 0) @as(usize, 1) else 0) + component.len };
        }
    }
    return .{ .kind = .not_found, .path_len = 0 };
}

// Search every sys.path entry for `component`. Writes the resolved
// path into `out_path` and returns the find result.
fn searchTopLevel(component: []const u8, out_path: *[PATH_MAX_LEN:0]u8) Found {
    const sys_path_obj = mirrors.mp_state_ctx.vm.sys_mutable[0];
    if (sys_path_obj == 0) return .{ .kind = .not_found, .path_len = 0 };
    const path_list = mirrors.MpObjList.fromObj(sys_path_obj);

    var i: usize = 0;
    while (i < path_list.len) : (i += 1) {
        const entry = path_list.items[i];
        var entry_len: usize = 0;
        const entry_data = mp_obj_str_get_data(entry, &entry_len);
        const entry_slice = entry_data[0..entry_len];
        const r = statComponentIn(entry_slice, component, out_path);
        if (r.kind != .not_found) return r;
    }
    return .{ .kind = .not_found, .path_len = 0 };
}

// Load whatever `statComponentIn` / `searchTopLevel` returned into
// `module_obj` (which has already been registered in sys.modules under
// `full_qstr`). For directories, set `__path__` and run `__init__.py`
// if present. For files, exec them.
fn loadFound(
    found: Found,
    path_buf: *[PATH_MAX_LEN:0]u8,
    full_qstr: usize,
    module_obj: Obj,
) PyError!void {
    switch (found.kind) {
        .not_found => unreachable,
        .file_py => {
            const path_c: [*:0]const u8 = @ptrCast(path_buf);
            var src_len: usize = 0;
            if (readFileFull(path_c, &src_len)) |src_buf| {
                defer m_free(src_buf);
                try execSourceInModule(src_buf, src_len, full_qstr, module_obj);
            } else {
                return error.PyRaise;
            }
        },
        .file_mpy => {
            const path_c: [*:0]const u8 = @ptrCast(path_buf);
            var src_len: usize = 0;
            if (readFileFull(path_c, &src_len)) |src_buf| {
                defer m_free(src_buf);
                try execMpyInModule(src_buf, src_len, module_obj);
            } else {
                return error.PyRaise;
            }
        },
        .dir_package => {
            const dir_slice = path_buf[0..found.path_len];

            // Store __path__ as a fresh string (heap-allocated for the
            // module's lifetime). Qstr is resolved dynamically — vendor
            // ensures MP_QSTR___path__ exists in any build that uses
            // builtinimport.c; we don't depend on it being baked into
            // our embed.
            const path_qstr = qstr_from_strn("__path__", 8);
            const path_str_obj = mp_obj_new_str(dir_slice.ptr, dir_slice.len);
            mp_store_attr(module_obj, path_qstr, path_str_obj);
            if (pyerr.pending_exc != 0) return error.PyRaise;

            // Try __init__.py, then __init__.mpy. Either is optional —
            // a namespace-style package with no __init__ is fine, just
            // a no-op load.
            var init_buf: [PATH_MAX_LEN:0]u8 = undefined;
            if (buildPath(&init_buf, dir_slice, "__init__", ".py")) {
                const init_c: [*:0]const u8 = @ptrCast(&init_buf);
                if (pathIsFile(init_c)) {
                    var src_len: usize = 0;
                    if (readFileFull(init_c, &src_len)) |src_buf| {
                        defer m_free(src_buf);
                        try execSourceInModule(src_buf, src_len, full_qstr, module_obj);
                    }
                    return;
                }
            }
            if (buildPath(&init_buf, dir_slice, "__init__", ".mpy")) {
                const init_c: [*:0]const u8 = @ptrCast(&init_buf);
                if (pathIsFile(init_c)) {
                    var src_len: usize = 0;
                    if (readFileFull(init_c, &src_len)) |src_buf| {
                        defer m_free(src_buf);
                        try execMpyInModule(src_buf, src_len, module_obj);
                    }
                }
            }
            // No __init__ — silent namespace package.
        },
    }
}

// Read the parent module's `__path__` attribute (if any). Returns the
// borrowed (data, len) slice on hit, or null if the parent is not a
// package.
fn parentPath(parent_obj: Obj, out_buf: *[PATH_MAX_LEN]u8) ?[]const u8 {
    var dest: [2]Obj = .{ 0, 0 };
    const path_qstr = qstr_from_strn("__path__", 8);
    loadAttrMaybe(parent_obj, path_qstr, &dest);
    if (dest[0] == 0) return null;
    var len: usize = 0;
    const data = mp_obj_str_get_data(dest[0], &len);
    // Empty: a frozen package (loadFrozen), with no directory to search.
    if (len == 0 or len > PATH_MAX_LEN) return null;
    @memcpy(out_buf[0..len], data[0..len]);
    return out_buf[0..len];
}

// Load a frozen module under `full_qstr`. A frozen package gets an empty
// `__path__`: it marks the module as a package for `from pkg import sub`
// (mp_import_from), and parentPath reads it as "no filesystem", so its
// submodules come only from the frozen table.
fn loadFrozen(bytes: []const u8, full_qstr: usize) PyError!Obj {
    const module_obj = mp_obj_new_module(full_qstr);
    errdefer removeFromLoaded(full_qstr);
    if (frozen.isPackage(full_qstr)) {
        mp_store_attr(module_obj, qstr_from_strn("__path__", 8), mp_obj_new_str("", 0));
        if (pyerr.pending_exc != 0) return error.PyRaise;
    }
    try execMpyInModule(bytes.ptr, bytes.len, module_obj);
    return module_obj;
}

// Public entry — called once per dotted component from builtinimport.zig.
//
// `full_qstr`   — the absolute dotted name up to this depth ("foo.bar")
// `level_slice` — just the current component name ("bar")
// `parent_obj`  — the parent module object (already loaded), or
//                 OBJ_NULL for the top-level component
//
// Returns the loaded module object, or `OBJ_NULL` if no source for the
// component was found anywhere. PyError propagates real load failures.
pub fn tryLoadComponent(
    full_qstr: usize,
    level_slice: []const u8,
    parent_obj: Obj,
) PyError!Obj {
    var path_buf: [PATH_MAX_LEN:0]u8 = undefined;
    var found: Found = .{ .kind = .not_found, .path_len = 0 };

    if (parent_obj == mirrors.OBJ_NULL) {
        // Top-level: frozen-tiny first, then sys.path.
        const level_qstr = qstr_from_strn(level_slice.ptr, level_slice.len);
        if (frozen.lookup(level_qstr)) |bytes| return loadFrozen(bytes, full_qstr);
        found = searchTopLevel(level_slice, &path_buf);
    } else {
        // Submodule: try frozen (by full dotted name) first — accepts
        // flat "pkg.sub" entries in the freezer without touching the
        // parent's __path__. Falls through to filesystem otherwise.
        if (frozen.lookup(full_qstr)) |bytes| return loadFrozen(bytes, full_qstr);
        // Then look in parent's __path__.
        var parent_buf: [PATH_MAX_LEN]u8 = undefined;
        if (parentPath(parent_obj, &parent_buf)) |parent_slice| {
            found = statComponentIn(parent_slice, level_slice, &path_buf);
        }
    }

    if (found.kind == .not_found) return mirrors.OBJ_NULL;

    // Create + register the module under its full dotted name.
    const module_obj = mp_obj_new_module(full_qstr);
    loadFound(found, &path_buf, full_qstr, module_obj) catch |e| {
        removeFromLoaded(full_qstr);
        return e;
    };
    return module_obj;
}

// Remove a partially-registered module from sys.modules. Used on
// not-found and on partial-init failure (vendor `unload_module`).
fn removeFromLoaded(modname_qstr: usize) void {
    const map_ptr: *mirrors.MpMap = &mirrors.mp_state_ctx.vm.mp_loaded_modules_dict.map;
    _ = mirrors.mp_map_lookup(map_ptr, mirrors.objFromQstr(modname_qstr), mirrors.MP_MAP_LOOKUP_REMOVE_IF_FOUND);
}

comptime {
    _ = &tryLoadComponent;
}
