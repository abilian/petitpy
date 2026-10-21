//! nanopython WASM entry point (Phase 1).
//!
//! Thin Zig harness around the MicroPython embed C core. As the strangler
//! progresses, C subsystems behind `mp_embed_*` get replaced by Zig; this
//! entry point stays put.
//!
//! Usage (under a WASI runtime with a preopened dir):
//!   wasmtime --dir=. nanopython.wasm script.py

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

// Pull strangled subsystems into the link; their `export fn`s replace the
// excluded C sources (see `strangled` in build.zig). Grouped by layer.
comptime {
    // Layout cross-check (validates Zig packed-struct mirrors of C bitfield structs)
    _ = @import("mp_mirrors.zig");
    // Frontend
    _ = @import("frontend/parsenumbase.zig");
    _ = @import("frontend/parsenum.zig");
    _ = @import("frontend/reader.zig");
    _ = @import("frontend/emitglue.zig");
    // Runtime
    _ = @import("runtime/vm.zig");
    _ = @import("runtime/runtime.zig");
    _ = @import("runtime/raise.zig");
    _ = @import("runtime/nlr_trampoline.zig"); // ADR 013 — exports npy_nlr_top_get/set; no-op under non-exception_unwind builds
    _ = @import("objects/primitives/objcell.zig");
    _ = @import("objects/iters/objpolyiter.zig");
    _ = @import("runtime/runtime_utils.zig");
    _ = @import("runtime/bc.zig");
    _ = @import("runtime/argcheck.zig");
    _ = @import("runtime/opmethods.zig");
    _ = @import("runtime/builtinevex.zig");
    _ = @import("runtime/builtinimport.zig");
    // ADR-003 L1+L2 — import_search + frozen-tiny table.
    _ = &@import("runtime/import_search.zig");
    _ = &@import("runtime/frozen_modules.zig");
    _ = @import("runtime/scheduler.zig");
    _ = &@import("runtime/persistentcode.zig");
    _ = &@import("runtime/zig_compile_bridge.zig");
    // Objects
    _ = @import("objects/obj.zig");
    _ = @import("objects/objtype/objtype.zig");
    _ = @import("objects/objtype/objmodule.zig");
    _ = @import("objects/objtype/objexcept.zig");
    _ = @import("objects/objtype/objobject.zig");
    _ = @import("objects/primitives/objbool.zig");
    _ = @import("objects/primitives/objint.zig");
    _ = @import("objects/strings/objstr.zig");
    _ = @import("objects/strings/vstr.zig");
    _ = @import("objects/strings/mpprint.zig");
    _ = @import("objects/containers/objtuple.zig");
    _ = @import("objects/containers/objlist.zig");
    _ = @import("objects/containers/objarray.zig");
    _ = @import("objects/containers/objdict.zig");
    _ = @import("objects/containers/objset.zig");
    _ = @import("objects/containers/objrange.zig");
    _ = @import("objects/containers/map.zig");
    _ = @import("objects/containers/sequence.zig");
    _ = @import("objects/containers/objattrtuple.zig");
    _ = @import("objects/containers/objslice.zig");
    _ = @import("objects/containers/objproperty.zig");
    _ = @import("objects/containers/binary.zig");
    _ = @import("objects/iters/objgetitemiter.zig");
    _ = @import("objects/iters/objmap.zig");
    _ = @import("objects/iters/objzip.zig");
    _ = @import("objects/iters/objfilter.zig");
    _ = @import("objects/iters/objreversed.zig");
    _ = @import("objects/iters/objenumerate.zig");
    _ = @import("objects/iters/objnamedtuple.zig");
    _ = @import("objects/iters/objdeque.zig");
    _ = @import("objects/callables/objfun.zig");
    _ = @import("objects/callables/objgenerator.zig");
    _ = @import("objects/callables/objboundmeth.zig");
    _ = @import("objects/callables/objclosure.zig");
    // Modules
    _ = @import("modules/modbuiltins.zig");
    _ = @import("modules/modgc.zig");
    _ = @import("modules/modarray.zig");
    _ = @import("modules/modcollections.zig");
    _ = @import("modules/moderrno.zig");
    _ = @import("modules/file_io.zig");
    _ = @import("modules/modos.zig");
    _ = @import("modules/modtime.zig");
    _ = @import("modules/modsocket.zig");
    _ = @import("modules/modselect.zig");
    _ = @import("modules/modsignal.zig");
    _ = @import("modules/modpwd.zig");
    _ = @import("modules/modgrp.zig");
    _ = @import("modules/mod_subprocess.zig");
    _ = @import("modules/modmicropython.zig");
    _ = @import("modules/modmath.zig");
    _ = @import("modules/modsys.zig");
    _ = @import("modules/modstruct.zig");
    _ = @import("modules/modjson.zig");
    _ = @import("modules/modmain.zig");
    // ADR-006 J1 — JS interop builtin module (`_nanopython_js`).
    // Gated on build_options.feature_js; when off, the module body is `else
    // struct {}` and nothing is compiled. Force-analyze with `_ = &…` so
    // the export survives DCE under -Dfeature-js=true.
    _ = &@import("runtime/js_bridge.zig");
    // Memory
    _ = @import("memory/pairheap.zig");
    _ = @import("memory/ringbuf.zig");
    _ = @import("memory/alloc.zig");
    _ = @import("memory/gc.zig");
    // Support
    _ = @import("support/smallint.zig");
    _ = @import("support/unicode.zig");
    _ = @import("support/readline.zig");
    _ = @import("support/stream.zig");
    // Entry
    _ = @import("entry/embed_exec.zig");
    _ = @import("entry/embed.zig");
    // Runtime (state, NLR glue, qstr, stack control)
    _ = @import("runtime/mpstate.zig");
    _ = @import("runtime/stackctrl.zig");
    _ = @import("runtime/qstr.zig");
    _ = @import("runtime/nlr_glue.zig");
    _ = @import("runtime/jcb_glue.zig");
    // Phase F0 — full-arm rehab stubs (notes/40-full-arm-rehab.md).
    _ = &@import("runtime/full_stubs.zig");
    // Cross-cutting shared
    _ = @import("mp_type_roms.zig");
    _ = @import("vendor_stubs.zig");
    // Layout asserts LAST so any new real export takes precedence at link time.
    _ = @import("mp_layout_check.zig");

    // Force-analyze the bridge that exports npy_zig_compile_to_mpy.
    // src/runtime/zig_compile_bridge.c calls into it from
    // npy_zig_compile_source (the script-exec entry). Without `_ = &…`,
    // Zig's dead-code pass drops the export before the linker sees it.
    _ = @import("compiler/bridge.zig");
}

extern fn npy_mirror_layout_check() callconv(.c) void;
extern fn mp_embed_init(heap: ?*anyopaque, heap_size: usize, stack_top: ?*anyopaque) void;
extern fn npy_file_io_init() void;
extern fn npy_embed_exec_str_zig(src: [*:0]const u8) c_int;
extern fn npy_repl_exec_line(src: [*:0]const u8) c_int;
extern fn npy_repl_read_line(line_buf: [*:0]u8, buf_max: c_int, prompt: [*:0]const u8) c_int;
extern fn npy_zig_compile_to_mpy(src: [*]const u8, src_len: usize, src_name: [*:0]const u8, kind: c_int, out_buf: *[*]u8, out_len: *usize) c_int;
extern fn npy_repl_continue(input: [*:0]const u8) c_int;
extern fn mp_embed_deinit() void;

// ADR-003 L1 polish — PYTHONPATH / PETITPY_LIB → sys.path.
const mirrors = @import("mp_mirrors.zig");
// MP_QSTR___file__ is config-gated (MICROPY_MODULE___FILE__=0 in our
// port) so the qstr isn't pre-generated. Intern it dynamically via
// qstr_from_strn — the qstr pool accepts new entries at runtime.
extern fn qstr_from_strn(s: [*]const u8, n: usize) callconv(.c) usize;
extern fn mp_obj_new_str(data: [*]const u8, len: usize) callconv(.c) mirrors.Obj;
extern fn mp_obj_list_append(l: mirrors.Obj, it: mirrors.Obj) callconv(.c) mirrors.Obj;

// Append each colon-separated entry from `value` to sys.path. Empty entries
// (consecutive ':') are skipped (matching CPython behavior — empty would mean
// CWD which sys.path[0] already covers via the empty-qstr entry).
fn appendPathEntries(value: []const u8) void {
    const sys_path = mirrors.mp_state_ctx.vm.sys_mutable[0];
    if (sys_path == 0) return;
    var it = std.mem.tokenizeScalar(u8, value, ':');
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        const s = mp_obj_new_str(entry.ptr, entry.len);
        _ = mp_obj_list_append(sys_path, s);
    }
}

// Populate sys.argv with the script path + script args (matches CPython:
// sys.argv[0] = script, sys.argv[1:] = args). Skips host argv[0] (the
// interpreter name itself).
/// Compile `in_path` and print the `.mpy` to stdout as base64. Returns a
/// process exit status: 0 compiled, 1 could not read the input, 2 the
/// compiler refused (it has already reported what it refused).
///
/// The runtime has to be initialised first: the compiler interns qstrs
/// into the VM's pool.
fn emitMpy(io: std.Io, gpa: std.mem.Allocator, in_path: []const u8) u8 {
    const src = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        in_path,
        gpa,
        .unlimited,
        .of(u8),
        0,
    ) catch {
        std.Io.File.stderr().writeStreamingAll(io, "petitpy: cannot read input\n") catch {};
        return 1;
    };
    defer gpa.free(src);

    var buf: [*]u8 = undefined;
    var len: usize = 0;
    if (npy_zig_compile_to_mpy(src.ptr, src.len, "<emit-mpy>", 1, &buf, &len) != 0) {
        // The bridge collapses the compiler's SyntaxErrorInfo into an error
        // code, so the message is not reachable from here. Re-running the
        // source through the normal exec path prints the diagnostic the
        // build is capable of — and cannot execute anything, because the
        // compile that just failed fails there too.
        _ = npy_embed_exec_str_zig(src.ptr);
        return 2;
    }
    defer std.c.free(buf);

    const enc = std.base64.standard.Encoder;
    const b64 = gpa.alloc(u8, enc.calcSize(len)) catch return 1;
    defer gpa.free(b64);
    _ = enc.encode(b64, buf[0..len]);

    std.Io.File.stdout().writeStreamingAll(io, b64) catch return 1;
    std.Io.File.stdout().writeStreamingAll(io, "\n") catch return 1;
    return 0;
}

fn wireSysArgv(argv: []const [:0]const u8) void {
    if (argv.len < 2) return;
    const argv_obj = mirrors.objFromPtr(&mirrors.mp_state_ctx.vm.mp_sys_argv_obj);
    for (argv[1..]) |arg| {
        const slice: []const u8 = arg;
        const s = mp_obj_new_str(slice.ptr, slice.len);
        _ = mp_obj_list_append(argv_obj, s);
    }
}

// Set __main__.__file__ = script_path and replace sys.path[0] (the
// empty-qstr placeholder seeded at runtime.zig:268) with dirname(script).
// Mirrors vendor MP unix port; the test sys_path.py inspects both.
// Compile-side source_file stays as <stdin> (changing it would cascade
// many traceback-format goldens that hard-code File "<stdin>").
extern fn mp_obj_dict_store(d: usize, k: usize, v: usize) callconv(.c) usize;
extern fn mp_obj_list_store(list: usize, index: usize, v: usize) callconv(.c) usize;
fn wireScriptFileAndPath(script: [:0]const u8) void {
    const slice: []const u8 = script;
    // __file__ in __main__ globals dict.
    const script_obj = mp_obj_new_str(slice.ptr, slice.len);
    const file_qstr = qstr_from_strn("__file__", 8);
    _ = mp_obj_dict_store(
        @intFromPtr(&mirrors.mp_state_ctx.vm.dict_main),
        mirrors.objFromQstr(file_qstr),
        script_obj,
    );
    // sys.path[0] := dirname(script). The placeholder empty-qstr entry
    // from runtime.zig:268 gets overwritten in-place.
    const sys_path = mirrors.mp_state_ctx.vm.sys_mutable[0];
    if (sys_path == 0) return;
    const dir = std.fs.path.dirname(slice) orelse "";
    const dir_obj = mp_obj_new_str(dir.ptr, dir.len);
    _ = mp_obj_list_store(sys_path, mirrors.newSmallInt(0), dir_obj);
}

// Read PYTHONPATH (CPython convention) + PETITPY_LIB (default install dir
// for `zpip install`) and push their entries onto sys.path, then the stdlib
// installed next to the binary.
fn wireEnvSysPath(io: std.Io, env: *std.process.Environ.Map, arena: std.mem.Allocator) void {
    if (env.get("PYTHONPATH")) |val| appendPathEntries(val);

    // PETITPY_LIB overrides; falls back to ~/.petitpy/lib.
    if (env.get("PETITPY_LIB")) |val| {
        appendPathEntries(val);
    } else if (env.get("HOME")) |home| {
        const lib = std.fmt.allocPrint(arena, "{s}/.petitpy/lib", .{home}) catch return;
        appendPathEntries(lib);
    }

    // <exe dir>/../share/petitpy/lib: where a wheel's shared data and a
    // Homebrew keg put the stdlib (ADR 016 §3). Absent in a dev build.
    if (comptime builtin.target.os.tag != .wasi) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = std.process.executableDirPath(io, &buf) catch return;
        const lib = std.fmt.allocPrint(arena, "{s}/../share/petitpy/lib", .{buf[0..n]}) catch return;
        std.Io.Dir.cwd().access(io, lib, .{}) catch return;
        appendPathEntries(lib);
    }
}

// The MicroPython GC heap. Static so it lives in wasm linear memory and is
// scannable by the conservative collector.
var mp_gc_heap: [512 * 1024]u8 align(16) = undefined;

fn printUsage(io: std.Io) void {
    const msg =
        \\petitpy — a small Python runtime, MicroPython-compatible, written in Zig.
        \\
        \\Usage:
        \\  petitpy <script.py>       run a Python script (`ppy` is the same command)
        \\  petitpy -c CODE           run CODE (sys.argv[0] is '-c')
        \\  petitpy --emit-mpy F.py   compile only; print the .mpy as base64
        \\  petitpy --version         print version
        \\  petitpy --help            this message
        \\
    ;
    std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
}

pub fn main(init: std.process.Init) !void {
    // zigonly Phase 1: layout check disabled — it compares against C constants
    // that are now stubbed. The mirrors infrastructure goes away in Phase 4.
    // npy_mirror_layout_check();

    const io = init.io;
    const gpa = init.gpa;

    // Best-effort stack top: the address of a local high in the call tree.
    // Good enough for the conservative GC's stack scan on wasm.
    var stack_anchor: usize = 0;
    stack_anchor = @intFromPtr(&stack_anchor);

    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len >= 2 and (std.mem.eql(u8, argv[1], "--version") or std.mem.eql(u8, argv[1], "-V"))) {
        const banner = "petitpy " ++ build_options.version ++ "\n";
        try std.Io.File.stdout().writeStreamingAll(io, banner);
        return;
    }
    if (argv.len >= 2 and (std.mem.eql(u8, argv[1], "--help") or std.mem.eql(u8, argv[1], "-h"))) {
        printUsage(io);
        return;
    }

    // `--emit-mpy IN.py` — compile and print the .mpy as base64, without
    // running the program. The playground reads it back off stdout.
    //
    // base64 on stdout rather than a file because the browser's WASI shim
    // and wasmtime disagree about write capability on a preopened dir,
    // and stdout is captured identically by both. It also keeps the
    // output text-safe through `ConsoleStdout`.
    //
    // `zigpy-compile` already compiles .py to .mpy as a standalone CLI.
    // The overlap is deliberate: the web artifact ships one wasm binary,
    // and a second one for the playground would cost ~300 KB against a
    // ≤285 KB budget. See notes/plans/adr-018-playground.md.
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "--emit-mpy")) {
        if (argv.len < 3) {
            try std.Io.File.stderr().writeStreamingAll(io, "usage: petitpy --emit-mpy IN.py\n");
            std.process.exit(2);
        }
        mp_embed_init(&mp_gc_heap, mp_gc_heap.len, &stack_anchor);
        defer mp_embed_deinit();
        const status = emitMpy(io, gpa, argv[2]);
        if (status != 0) std.process.exit(status);
        return;
    }

    // No args → interactive REPL.
    if (argv.len < 2) {
        mp_embed_init(&mp_gc_heap, mp_gc_heap.len, &stack_anchor);
        if (build_options.is_full) npy_file_io_init();
        wireEnvSysPath(init.io, init.environ_map, init.arena.allocator());
        defer mp_embed_deinit();
        const banner = "petitpy " ++ build_options.version ++ " — interactive REPL (Ctrl-D to exit)\n";
        std.Io.File.stderr().writeStreamingAll(io, banner) catch {};
        var line_buf: [4096:0]u8 = undefined;
        var accum: [16384:0]u8 = undefined;
        while (true) {
            // Read the first line of a statement.
            const n = npy_repl_read_line(&line_buf, line_buf.len, ">>> ");
            if (n == 0) {
                std.Io.File.stderr().writeStreamingAll(io, "\n") catch {};
                return;
            }
            // Copy into the accumulator buffer.
            var acc_len: usize = 0;
            var i: usize = 0;
            while (line_buf[i] != 0 and acc_len + 1 < accum.len) : (i += 1) {
                accum[acc_len] = line_buf[i];
                acc_len += 1;
            }
            accum[acc_len] = 0;
            // Multi-line: while vendor mp_repl_continue_with_input says we need
            // more, read a continuation line with the ... prompt.
            while (npy_repl_continue(&accum) != 0) {
                if (acc_len + 1 >= accum.len) break; // buffer full; bail
                accum[acc_len] = '\n';
                acc_len += 1;
                accum[acc_len] = 0;
                const m = npy_repl_read_line(&line_buf, line_buf.len, "... ");
                if (m == 0) break; // EOF mid-statement
                var j: usize = 0;
                while (line_buf[j] != 0 and acc_len + 1 < accum.len) : (j += 1) {
                    accum[acc_len] = line_buf[j];
                    acc_len += 1;
                }
                accum[acc_len] = 0;
            }
            _ = npy_repl_exec_line(&accum);
        }
    }

    // `-c CODE [ARG...]`: sys.argv is ['-c', ARG...], as in CPython.
    if (std.mem.eql(u8, argv[1], "-c")) {
        if (argv.len < 3) {
            try std.Io.File.stderr().writeStreamingAll(io, "petitpy: argument expected for the -c option\n");
            std.process.exit(2);
        }
        const sys_argv = try std.mem.concat(init.arena.allocator(), [:0]const u8, &.{ argv[0..2], argv[3..] });
        runSource(init, argv[2].ptr, sys_argv, null, &stack_anchor);
        return;
    }

    // Read the script as a NUL-terminated buffer (mp_embed_exec_str wants C str).
    const src = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        argv[1],
        gpa,
        .unlimited,
        .of(u8),
        0,
    ) catch |err| {
        const msg = try std.fmt.allocPrint(init.arena.allocator(), "petitpy: can't open file '{s}': {s}\n", .{ argv[1], @errorName(err) });
        try std.Io.File.stderr().writeStreamingAll(io, msg);
        std.process.exit(2);
    };
    defer gpa.free(src);
    runSource(init, src.ptr, argv, argv[1], &stack_anchor);
}

/// Run `src` as `__main__` and exit with its status. `script` is the file
/// it came from (sets `__file__` and `sys.path[0]`), null for `-c`.
fn runSource(init: std.process.Init, src: [*:0]const u8, sys_argv: []const [:0]const u8, script: ?[:0]const u8, stack_anchor: *usize) void {
    mp_embed_init(&mp_gc_heap, mp_gc_heap.len, stack_anchor);
    if (build_options.is_full) npy_file_io_init();
    wireEnvSysPath(init.io, init.environ_map, init.arena.allocator());
    wireSysArgv(sys_argv);
    if (script) |path| wireScriptFileAndPath(path);
    const status = npy_embed_exec_str_zig(src);
    mp_embed_deinit();
    if (status != 0) std.process.exit(@intCast(status));
}
