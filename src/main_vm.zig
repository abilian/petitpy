//! nanopython-vm — VM-only entry point.
//!
//! Reads argv[1] as a .mpy file and executes it. The compiler track
//! (`src/compiler/*`, `src/runtime/zig_compile_bridge.zig`,
//! `src/entry/embed_exec.zig`) is deliberately NOT imported here, so
//! Zig's dead-code pass + the linker drop those symbols from the
//! binary. The few extern call sites that survive in the runtime —
//! `npy_zig_eval_exec` (from `mp_builtin_eval`/`exec`) and
//! `npy_zig_compile_to_code` (from FULL-only `mp_builtin_compile`) —
//! are stubbed below to raise NotImplementedError-style at runtime if
//! ever invoked from .mpy code that calls `eval()` / `exec()`.

const std = @import("std");
const build_options = @import("build_options");
const pyerr = @import("pyerr.zig");

// Same strangler imports as main.zig EXCEPT the three compiler-track
// modules. Order/grouping mirrors main.zig for review symmetry.
comptime {
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
    _ = @import("objects/primitives/objcell.zig");
    _ = @import("objects/iters/objpolyiter.zig");
    _ = @import("runtime/runtime_utils.zig");
    _ = @import("runtime/bc.zig");
    _ = @import("runtime/argcheck.zig");
    _ = @import("runtime/opmethods.zig");
    _ = @import("runtime/builtinevex.zig");
    _ = @import("runtime/builtinimport.zig");
    _ = @import("runtime/scheduler.zig");
    _ = &@import("runtime/persistentcode.zig");
    // NB: runtime/zig_compile_bridge.zig is NOT imported — that's the
    // whole point of the VM-only build.
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
    // ADR-006 J1 — JS interop builtin module (force-analyzed under -Dfeature-js).
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
    // Entry — embed.zig only (init/deinit). embed_exec.zig is the
    // compile-then-exec path, deliberately NOT imported.
    _ = @import("entry/embed.zig");
    _ = &@import("entry/embed_run_mpy.zig");
    // Runtime (state, NLR glue, qstr, stack control)
    _ = @import("runtime/mpstate.zig");
    _ = @import("runtime/stackctrl.zig");
    _ = @import("runtime/qstr.zig");
    _ = @import("runtime/nlr_glue.zig");
    _ = @import("runtime/jcb_glue.zig");
    _ = &@import("runtime/full_stubs.zig");
    // Cross-cutting shared
    _ = @import("mp_type_roms.zig");
    _ = @import("vendor_stubs.zig");
}

// ── Compiler-bridge stubs ────────────────────────────────────────────
//
// The builtins ROM (modbuiltins.zig) references mp_builtin_eval_obj +
// mp_builtin_exec_obj unconditionally. Their bodies in builtinevex.zig
// call npy_zig_eval_exec, which lives in zig_compile_bridge.zig (NOT
// linked here). Provide a runtime-raise stub so the linker resolves
// the extern; if user code in the loaded .mpy ever calls eval() or
// exec(), we raise NotImplementedError instead of segfaulting.

extern fn mp_obj_new_exception_msg(t: *const anyopaque, msg: [*:0]const u8) callconv(.c) usize;
extern const mp_type_NotImplementedError: anyopaque;

export fn npy_zig_eval_exec(
    src: [*c]const u8,
    src_len: usize,
    source_file: usize,
    parse_input_kind: c_int,
    globals: ?*anyopaque,
    locals: ?*anyopaque,
) callconv(.c) usize {
    _ = .{ src, src_len, source_file, parse_input_kind, globals, locals };
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_NotImplementedError, "compiler not linked in nanopython-vm");
    return 0;
}

export fn npy_zig_compile_to_code(
    src: [*c]const u8,
    src_len: usize,
    source_file: usize,
    parse_input_kind: c_int,
) callconv(.c) usize {
    _ = .{ src, src_len, source_file, parse_input_kind };
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_NotImplementedError, "compiler not linked in nanopython-vm");
    return 0;
}

// ADR-003 L1 — import_search.zig calls npy_zig_compile_to_mpy for the
// .py filesystem path. Under the VM-only binary no compiler is linked,
// so .py files can't be imported; .mpy files still can (the persistent
// loader is in the runtime, not the compiler).
export fn npy_zig_compile_to_mpy(
    src: [*]const u8,
    src_len: usize,
    src_name: [*:0]const u8,
    parse_input_kind: c_int,
    out_buf: *?[*]u8,
    out_len: *usize,
) callconv(.c) c_int {
    _ = .{ src, src_len, src_name, parse_input_kind, out_buf, out_len };
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_NotImplementedError, "compiler not linked in nanopython-vm");
    return 2; // NPY_ZIG_SYNTAX (any non-zero suffices)
}

// ── main ─────────────────────────────────────────────────────────────

extern fn mp_embed_init(heap: ?*anyopaque, heap_size: usize, stack_top: ?*anyopaque) void;
extern fn mp_embed_deinit() void;
extern fn npy_file_io_init() void;
extern fn npy_embed_run_mpy(buf: [*]const u8, len: usize) c_int;

// Same GC heap layout as main.zig.
var mp_gc_heap: [512 * 1024]u8 align(16) = undefined;

fn printUsage(io: std.Io) void {
    const msg =
        \\nanopython-vm — VM-only runtime (loads pre-compiled .mpy files).
        \\
        \\Usage:
        \\  nanopython-vm <script.mpy>   run a compiled bytecode file
        \\  nanopython-vm --version      print version
        \\  nanopython-vm --help         this message
        \\
    ;
    std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var stack_anchor: usize = 0;
    stack_anchor = @intFromPtr(&stack_anchor);

    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len < 2 or std.mem.eql(u8, argv[1], "--help") or std.mem.eql(u8, argv[1], "-h")) {
        printUsage(io);
        return;
    }
    if (std.mem.eql(u8, argv[1], "--version") or std.mem.eql(u8, argv[1], "-V")) {
        const banner = "nanopython-vm " ++ build_options.version ++ "\n";
        try std.Io.File.stdout().writeStreamingAll(io, banner);
        return;
    }

    const buf = try std.Io.Dir.cwd().readFileAlloc(
        io,
        argv[1],
        gpa,
        .unlimited,
    );
    defer gpa.free(buf);

    mp_embed_init(&mp_gc_heap, mp_gc_heap.len, &stack_anchor);
    if (build_options.is_full) npy_file_io_init();
    defer mp_embed_deinit();
    const rc = npy_embed_run_mpy(buf.ptr, buf.len);
    if (rc != 0) std.process.exit(@intCast(rc));
}
