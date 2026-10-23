//! petitpy build.
//!
//! Native-first strangler. Compiles the generated
//! MicroPython embed C package (vendor/micropython_embed) for the host,
//! linked behind a thin Zig entry point. As the strangler progresses,
//! individual C sources are dropped here and replaced by Zig modules.
//!
//! WASM is deferred to Phase 2b: MicroPython's C core needs setjmp, which
//! Zig 0.16 cannot build for wasm32-wasi. The setjmp dependency disappears
//! as nlr + gchelper become Zig, at which point we retarget.

const std = @import("std");

const embed_root = "vendor/micropython_embed";

pub const version = "0.8.0";

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    // Config preset: "nano" (today's frozen slice) or "full" (everything
    // available). Drives both C-side flag selection in mpconfigport.h and
    // Zig-side comptime branch selection in src/*.zig.
    //
    // Default is "nano" — it's the frozen reference + the WASM-clean path.
    // "full" is the in-progress superset.
    const ConfigPreset = enum { nano, full };
    const config_preset = b.option(ConfigPreset, "config", "Config preset: full (default, all features) or nano (frozen slice for shipping)") orelse .full;

    // ADR-002 F1 — per-feature `-D` flags (proof of concept with 2 features).
    //
    // Each `-Dfeature-X=on/off` overrides the preset default. The preset
    // defaults are:
    //   nano: math=on  (matches the frozen nano slice), warning=off
    //   full: math=on, warning=on
    // When the user explicitly supplies `-Dfeature-X=...` that deviates
    // from the preset default, we emit a build-time warning (the
    // override-mode signal — the corpus invariant is implicitly relaxed
    // for that build because the nano default is what `corpus/basics/`
    // is frozen against).
    const Features = struct {
        math: bool,
        warning: bool,
        collections: bool,
        struct_mod: bool,
        array: bool,
        errno: bool,
        micropython: bool,
        gc_module: bool,
        // ADR-006 J1 — JS interop. Default ON for wasm builds, OFF for native.
        // The runtime extern fns (js_get_global, etc.) only exist when a JS
        // host registers them; under native or wasmtime-CLI they're unresolved
        // imports. Gated entirely behind this flag so a non-wasm build never
        // sees the extern declarations.
        js: bool,
        // ADR 010 §A3a slice 2 — `re` regex module via vendor extmod/modre.c
        // + lib/re1.5/ engine. ~1100 LOC of vendor C. Default ON for both
        // nano + full. Turning it off saves ~12 KB on wasm; the runtime
        // surface (`import re`) disappears and re-using code traps with
        // ImportError.
        re: bool,
        // Zig-native `os` module
        // for native POSIX (`os.sep`, `os.environ`, `os.urandom`, `os.chmod`
        // etc.). Default ON for full, OFF for nano (nano stays the byte-exact
        // 541/541 reference). Never on for wasm — no POSIX surface there.
        os: bool,
        // Zig-native `time`
        // module. Same shape as `os`: full-native default on, nano+wasm off.
        time_mod: bool,
        // Zig-native `socket`
        // module (BSD sockets subset). Same shape.
        socket_mod: bool,
        // Zig-native `select`
        // module. Same shape.
        select_mod: bool,
        // Zig-native `signal`
        // MVP (store-but-don't-dispatch). Same shape.
        signal_mod: bool,
        // Zig-native `pwd` +
        // `grp` (libc getpwnam/getgrnam wrappers). Same shape, one flag.
        pwd_grp: bool,
        // Zig-native low-level
        // `_subprocess` module (fork+exec+wait+pipes). Python `subprocess`
        // wrapper lives in petitpy-lib/subprocess.py (frozen).
        subprocess_mod: bool,
    };
    const is_wasm_target = target.result.cpu.arch.isWasm();
    const feature_defaults: Features = switch (config_preset) {
        .nano => .{
            .math = true,
            .warning = false,
            .collections = true,
            .struct_mod = true,
            .array = true,
            .errno = true,
            .micropython = true,
            .gc_module = true,
            .js = is_wasm_target,
            // ADR 010 §A3a slice 2 — `re` ships on both arms. The wasm
            // trap that appeared while the MpObjFunBuiltinVar mirror had
            // a phantom `_pad: u32` is closed (the padding was correct
            // on 64-bit hosts and wrong on wasm32); the mirror now
            // carries layout asserts so the bug can't return silently.
            .re = true,
            // nano stays lean: no POSIX `os` module. Byte-exact 541/541
            // reference is preserved.
            .os = false,
            .time_mod = false,
            .socket_mod = false,
            .select_mod = false,
            .signal_mod = false,
            .pwd_grp = false,
            .subprocess_mod = false,
        },
        .full => .{
            .math = true,
            .warning = true,
            .collections = true,
            .struct_mod = true,
            .array = true,
            .errno = true,
            .micropython = true,
            .gc_module = true,
            .js = is_wasm_target,
            .re = true,
            // full on native gets `os`. Coerced OFF on wasm below
            // (POSIX surface has no wasm implementation).
            .os = !is_wasm_target,
            .time_mod = !is_wasm_target,
            .socket_mod = !is_wasm_target,
            .select_mod = !is_wasm_target,
            .signal_mod = !is_wasm_target,
            .pwd_grp = !is_wasm_target,
            .subprocess_mod = !is_wasm_target,
        },
    };
    const feature_math_user = b.option(bool, "feature-math", "Enable the math module (default: on for nano + full)");
    const feature_warning_user = b.option(bool, "feature-warning", "Enable the warning subsystem (default: off for nano, on for full)");
    const feature_collections_user = b.option(bool, "feature-collections", "Enable the collections module — namedtuple/OrderedDict/deque (default: on)");
    const feature_struct_user = b.option(bool, "feature-struct", "Enable the struct module — binary struct packing (default: on)");
    const feature_array_user = b.option(bool, "feature-array", "Enable the array module — array.array (default: on)");
    const feature_errno_user = b.option(bool, "feature-errno", "Enable the errno module — Unix errno constants (default: on)");
    const feature_micropython_user = b.option(bool, "feature-micropython", "Enable the micropython module — heap_lock/opt_level (default: on)");
    const feature_gc_module_user = b.option(bool, "feature-gc-module", "Enable the gc module — collect/disable/enable/mem_free etc. (default: on). Note: independent of the GC subsystem itself.");
    const feature_js_user = b.option(bool, "feature-js", "Enable the JS interop bridge (default: on for wasm, off for native). ADR-006.");
    const feature_re_user = b.option(bool, "feature-re", "Enable the `re` regex module — vendor extmod/modre.c + lib/re1.5/ (default: on). ADR 010 §A3a slice 2.");
    const feature_os_user = b.option(bool, "feature-os", "Enable the Zig-native `os` module — POSIX surface for full-native (default: on for full-native, off elsewhere).");
    const feature_time_user = b.option(bool, "feature-time", "Enable the Zig-native `time` module — POSIX clock/sleep wrappers for full-native (default: on for full-native, off elsewhere).");
    const feature_socket_user = b.option(bool, "feature-socket", "Enable the Zig-native `socket` module — BSD sockets subset for full-native (default: on for full-native, off elsewhere).");
    const feature_select_user = b.option(bool, "feature-select", "Enable the Zig-native `select` module — select(2) wrapper for full-native (default: on for full-native, off elsewhere).");
    const feature_signal_user = b.option(bool, "feature-signal", "Enable the Zig-native `signal` module MVP (store-but-don't-dispatch).");
    const feature_pwd_grp_user = b.option(bool, "feature-pwd-grp", "Enable the Zig-native `pwd` + `grp` modules (libc getpwnam/getgrnam).");
    const feature_subprocess_user = b.option(bool, "feature-subprocess", "Enable the Zig-native low-level `_subprocess` module (fork+exec).");
    const features: Features = .{
        .math = feature_math_user orelse feature_defaults.math,
        .warning = feature_warning_user orelse feature_defaults.warning,
        .collections = feature_collections_user orelse feature_defaults.collections,
        .struct_mod = feature_struct_user orelse feature_defaults.struct_mod,
        .array = feature_array_user orelse feature_defaults.array,
        .errno = feature_errno_user orelse feature_defaults.errno,
        .micropython = feature_micropython_user orelse feature_defaults.micropython,
        .gc_module = feature_gc_module_user orelse feature_defaults.gc_module,
        // ADR-006 Q3: feature-js is only meaningful for wasm targets.
        // The wasm imports (js_get_global etc.) have no native implementation;
        // -Dfeature-js=true on a non-wasm target would fail to link. Coerce
        // to false on non-wasm regardless of user input.
        .js = is_wasm_target and (feature_js_user orelse feature_defaults.js),
        .re = feature_re_user orelse feature_defaults.re,
        // Never on for wasm regardless of user input — the module calls
        // libc functions (getenv, chmod, open, ...) that don't exist under
        // WASI in any usable form.
        .os = !is_wasm_target and (feature_os_user orelse feature_defaults.os),
        .time_mod = !is_wasm_target and (feature_time_user orelse feature_defaults.time_mod),
        .socket_mod = !is_wasm_target and (feature_socket_user orelse feature_defaults.socket_mod),
        .select_mod = !is_wasm_target and (feature_select_user orelse feature_defaults.select_mod),
        .signal_mod = !is_wasm_target and (feature_signal_user orelse feature_defaults.signal_mod),
        .pwd_grp = !is_wasm_target and (feature_pwd_grp_user orelse feature_defaults.pwd_grp),
        .subprocess_mod = !is_wasm_target and (feature_subprocess_user orelse feature_defaults.subprocess_mod),
    };
    if (feature_math_user) |v| {
        if (v != feature_defaults.math) {
            std.log.warn("non-default feature-math={} for config={s}; corpus invariant NOT enforced for this build", .{ v, @tagName(config_preset) });
        }
    }
    if (feature_warning_user) |v| {
        if (v != feature_defaults.warning) {
            std.log.warn("non-default feature-warning={} for config={s}; corpus invariant NOT enforced for this build", .{ v, @tagName(config_preset) });
        }
    }
    if (feature_collections_user) |v| {
        if (v != feature_defaults.collections) {
            std.log.warn("non-default feature-collections={} for config={s}; corpus invariant NOT enforced for this build", .{ v, @tagName(config_preset) });
        }
    }
    if (feature_struct_user) |v| {
        if (v != feature_defaults.struct_mod) {
            std.log.warn("non-default feature-struct={} for config={s}; corpus invariant NOT enforced for this build", .{ v, @tagName(config_preset) });
        }
    }
    if (feature_array_user) |v| {
        if (v != feature_defaults.array) {
            std.log.warn("non-default feature-array={} for config={s}; corpus invariant NOT enforced for this build", .{ v, @tagName(config_preset) });
        }
    }
    if (feature_errno_user) |v| {
        if (v != feature_defaults.errno) {
            std.log.warn("non-default feature-errno={} for config={s}; corpus invariant NOT enforced for this build", .{ v, @tagName(config_preset) });
        }
    }
    if (feature_micropython_user) |v| {
        if (v != feature_defaults.micropython) {
            std.log.warn("non-default feature-micropython={} for config={s}; corpus invariant NOT enforced for this build", .{ v, @tagName(config_preset) });
        }
    }
    if (feature_gc_module_user) |v| {
        if (v != feature_defaults.gc_module) {
            std.log.warn("non-default feature-gc-module={} for config={s}; corpus invariant NOT enforced for this build", .{ v, @tagName(config_preset) });
        }
    }
    if (feature_js_user) |v| {
        if (v and !is_wasm_target) {
            std.log.warn("feature-js=true requested on non-wasm target — coerced to false (the JS bridge has no native implementation)", .{});
        } else if (v != feature_defaults.js) {
            std.log.warn("non-default feature-js={} for config={s}; corpus invariant NOT enforced for this build", .{ v, @tagName(config_preset) });
        }
    }
    if (feature_os_user) |v| {
        if (v and is_wasm_target) {
            std.log.warn("feature-os=true requested on wasm target — coerced to false (no POSIX surface under WASI)", .{});
        } else if (v != feature_defaults.os) {
            std.log.warn("non-default feature-os={} for config={s}; corpus invariant NOT enforced for this build", .{ v, @tagName(config_preset) });
        }
    }
    if (feature_time_user) |v| {
        if (v and is_wasm_target) {
            std.log.warn("feature-time=true requested on wasm target — coerced to false (no clock_gettime/nanosleep under WASI)", .{});
        } else if (v != feature_defaults.time_mod) {
            std.log.warn("non-default feature-time={} for config={s}; corpus invariant NOT enforced for this build", .{ v, @tagName(config_preset) });
        }
    }
    if (feature_socket_user) |v| {
        if (v and is_wasm_target) {
            std.log.warn("feature-socket=true requested on wasm target — coerced to false (no BSD sockets under WASI)", .{});
        } else if (v != feature_defaults.socket_mod) {
            std.log.warn("non-default feature-socket={} for config={s}; corpus invariant NOT enforced for this build", .{ v, @tagName(config_preset) });
        }
    }
    if (feature_select_user) |v| {
        if (v and is_wasm_target) {
            std.log.warn("feature-select=true requested on wasm target — coerced to false (no select(2) under WASI)", .{});
        } else if (v != feature_defaults.select_mod) {
            std.log.warn("non-default feature-select={} for config={s}; corpus invariant NOT enforced for this build", .{ v, @tagName(config_preset) });
        }
    }
    if (feature_signal_user) |v| {
        if (v and is_wasm_target) {
            std.log.warn("feature-signal=true requested on wasm target — coerced to false (no sigaction under WASI)", .{});
        } else if (v != feature_defaults.signal_mod) {
            std.log.warn("non-default feature-signal={} for config={s}; corpus invariant NOT enforced for this build", .{ v, @tagName(config_preset) });
        }
    }
    if (feature_pwd_grp_user) |v| {
        if (v and is_wasm_target) {
            std.log.warn("feature-pwd-grp=true requested on wasm target — coerced to false (no /etc/passwd machinery under WASI)", .{});
        } else if (v != feature_defaults.pwd_grp) {
            std.log.warn("non-default feature-pwd-grp={} for config={s}; corpus invariant NOT enforced for this build", .{ v, @tagName(config_preset) });
        }
    }
    if (feature_subprocess_user) |v| {
        if (v and is_wasm_target) {
            std.log.warn("feature-subprocess=true requested on wasm target — coerced to false (no fork/exec under WASI)", .{});
        } else if (v != feature_defaults.subprocess_mod) {
            std.log.warn("non-default feature-subprocess={} for config={s}; corpus invariant NOT enforced for this build", .{ v, @tagName(config_preset) });
        }
    }

    // Build-time options exposed as @import("build_options") to the Zig modules.
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);
    build_options.addOption(ConfigPreset, "config", config_preset);
    build_options.addOption(bool, "is_full", config_preset == .full);
    // Effective longint backend at the Zig comptime layer (mirrors
    // port/mpconfigport.h's MICROPY_LONGINT_IMPL selection):
    //   - full → MPZ
    //   - nano + 32-bit pointers (wasm32) → LONGLONG via vendor
    //     py/objint_longlong.c carveout (added below)
    //   - nano + 64-bit pointers (native) → NONE (62-bit smallint)
    const longint_none = (config_preset == .nano) and !is_wasm_target;
    build_options.addOption(bool, "longint_none", longint_none);
    // Tri-valued mirror of MICROPY_LONGINT_IMPL — lets parsenum.zig and any
    // future bignum-aware Zig site distinguish MPZ (full) from LONGLONG
    // (nano-wasm). The legacy `longint_none` bool above stays as a derived
    // alias for existing callers; migrate next cycle.
    const LongintImpl = enum { none, longlong, mpz };
    const longint_impl: LongintImpl = if (config_preset == .full) .mpz else if (is_wasm_target) .longlong else .none;
    build_options.addOption(LongintImpl, "longint_impl", longint_impl);
    // ADR-002 F1 — expose feature flags to Zig comptime gates. The C side
    // gets the same information via PETITPY_FEATURE_<X> macros (below);
    // the Zig side needs build_options because translate-c macros aren't
    // visible to Zig's comptime branches in src/*.zig.
    build_options.addOption(bool, "feature_math", features.math);
    build_options.addOption(bool, "feature_warning", features.warning);
    build_options.addOption(bool, "feature_collections", features.collections);
    build_options.addOption(bool, "feature_struct", features.struct_mod);
    build_options.addOption(bool, "feature_array", features.array);
    build_options.addOption(bool, "feature_errno", features.errno);
    build_options.addOption(bool, "feature_micropython", features.micropython);
    build_options.addOption(bool, "feature_gc_module", features.gc_module);
    build_options.addOption(bool, "feature_js", features.js);
    build_options.addOption(bool, "feature_re", features.re);
    build_options.addOption(bool, "feature_os", features.os);
    build_options.addOption(bool, "feature_time", features.time_mod);
    build_options.addOption(bool, "feature_socket", features.socket_mod);
    build_options.addOption(bool, "feature_select", features.select_mod);
    build_options.addOption(bool, "feature_signal", features.signal_mod);
    build_options.addOption(bool, "feature_pwd_grp", features.pwd_grp);
    build_options.addOption(bool, "feature_subprocess", features.subprocess_mod);
    // ADR 010 §A3b — multiple inheritance. Tracks MICROPY_MULTIPLE_INHERITANCE
    // in port/mpconfigport.h (which is already (1) under nano + full). The
    // scaffolding in objtype.zig (parentIsTuple/parentTupleItems + the
    // is_subclass_fast / class_lookup / super_attr / count_native_bases
    // tuple-walk branches) was completed under `is_full` gates back at
    // Phase 3 #3 (2026-05-26 per mpconfigport.h:261); v0.6 just flips
    // the gates from is_full to multiple_inheritance.
    build_options.addOption(bool, "multiple_inheritance", true);

    // MICROPY_PY_DELATTR_SETATTR
    // on nano. Vendor MP gates user `__setattr__` / `__delattr__` dispatch
    // (plus the HAS_SPECIAL_ACCESSORS flag-set for those keys) on this
    // config. v0.6 kept the corresponding Zig sites under is_full because
    // the v0.6.0 property-setter fix was scoped to property descriptors;
    // the user-dunder path was a separate audit. v0.7 flips the gates so
    // user classes can override attribute writes — unblocks reactive
    // patterns (Score.value = 5 → DOM update) and lets JsProxy.__setattr__
    // fire on nano, so `canvas.fillStyle = X` works directly.
    build_options.addOption(bool, "delattr_setattr", true);

    // MICROPY_PY_REVERSE_SPECIAL_METHODS.
    // Vendor MP runs the reverse-op fallback (`__radd__` / `__rsub__` / …)
    // unconditionally; nano gated it on is_full because the frozen corpus
    // captured the broken behavior. Real CPython semantics — `1 + x` calls
    // `x.__radd__(1)` if `int.__add__` returns NotImplemented. v0.7 flips
    // the gate so reverse ops work on nano too. `class_reverse_op` golden
    // re-frozen against vendor MP byte-exact output.
    build_options.addOption(bool, "reverse_special_methods", true);

    // ADR 013 — exception unwinding across vendor-C frames. Enables a
    // local setjmp/longjmp trampoline (src/runtime/nlr_trampoline.zig)
    // around a small enumerable set of vendor C entry points (MPZ binary-op,
    // stream write/flush, pow3) so try/except can catch raises that
    // originate in vendor C. Native full only — wasm32-wasi's setjmp.h
    // #errors out (WasmEH spike 2026-06-13). Nano never uses it
    // (no vendor C reaches non-Zig raises under nano).
    const exception_unwind = (config_preset == .full) and !is_wasm_target;
    build_options.addOption(bool, "exception_unwind", exception_unwind);

    // STR_UNICODE — controls how the lexer encodes high-code-point
    // string escapes. With =true, `"\xff"` is encoded as UTF-8 (`c3 bf`,
    // 2 bytes) for one Unicode code point U+00FF; with =false, it's
    // stored as the raw byte `ff`.
    //
    // It is also the runtime's MICROPY_PY_BUILTINS_STR_UNICODE (passed as
    // PETITPY_STR_UNICODE to C and translate-c, read as
    // build_options.str_unicode in Zig): on, str indexes, slices and
    // iterates by code point (objstr.zig str_subscr); off, str is bytes.
    // One switch, because a mismatch makes the compiler reject `"\u20ac"`
    // and store `"\u00e9"` as a lone 0xe9 byte inside a UTF-8 str.
    // On by default for every config: with it, nano still matches the
    // vendor reference corpus byte for byte (541/541) and the wasm gate is
    // unchanged, for about 2 KB of wasm (2026-10-19).
    const str_unicode = b.option(bool, "str-unicode", "str as Unicode code points (UTF-8 encoded) vs raw bytes; default on") orelse true;
    build_options.addOption(bool, "str_unicode", str_unicode);

    // ADR-003 L2 — frozen-tiny module table. Default off so a fresh clone
    // can build before `make freeze` has populated `build-frozen/*.mpy`.
    // `make freeze` runs `tools/freeze_modules.py` and then re-invokes
    // `zig build -Dfrozen-tiny=true` which bakes the bytes via @embedFile.
    const frozen_tiny_enabled = b.option(bool, "frozen-tiny", "Bake the frozen-tiny module set (json/types/__future__/_thread); requires `make freeze` to have populated build-frozen/") orelse false;
    build_options.addOption(bool, "frozen_tiny_enabled", frozen_tiny_enabled);

    // Frozen-tiny wiring, shared between `petitpy` and `petitpy-vm`.
    //
    // tools/freeze_modules.py emits two artifacts:
    //   - build-frozen/frozen-bundle.bin — concatenated .mpy bytes
    //   - build-frozen/frozen-index.zig  — comptime table with
    //     `bundle[off..end]` slices per module
    //
    // frozen-index.zig does @embedFile("frozen_bundle"); to satisfy
    // that, frozen_bundle is added as an import of the frozen_index
    // module (NOT of the top-level `mod`, which never touches the
    // raw bundle). Consumers (mod, vm_mod) only import frozen_index;
    // src/runtime/frozen_modules.zig reads its `table` field.
    //
    // Left null when frozen-tiny is off so downstream setup skips
    // both imports cleanly.
    const frozen_index_mod: ?*std.Build.Module = if (frozen_tiny_enabled) blk: {
        const bundle_mod = b.createModule(.{
            .root_source_file = b.path("build-frozen/frozen-bundle.bin"),
        });
        const index_mod = b.createModule(.{
            .root_source_file = b.path("build-frozen/frozen-index.zig"),
        });
        index_mod.addImport("frozen_bundle", bundle_mod);
        break :blk index_mod;
    } else null;

    // Materialize the options as a reusable module. Each `addOptions(name, ...)`
    // call creates a fresh internal module instance pointing at the same
    // generated `options.zig` file — Zig 0.16 rejects this as "file exists in
    // modules 'build_options' and 'build_options0'" when one binary
    // transitively pulls the options through two distinct paths (e.g. compile_mod
    // + lexer_mod both addOptions). Sharing one module via createModule + addImport
    // avoids that collision.
    const build_options_mod = build_options.createModule();

    // Zig strips only ReleaseSmall by default; the wheel's ReleaseFast
    // binary would otherwise carry ~6 MB of debug info.
    const strip = b.option(bool, "strip", "Strip debug info from the petitpy binary (default: only under ReleaseSmall).");
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
    });
    mod.addImport("build_options", build_options_mod);

    // zigonly Phase 2: expose the vendor-generated qstrdefs header as an
    // anonymous Zig module so src/zigonly_qstr.zig can @embedFile it.
    // (Plain `@embedFile("../vendor/...")` is rejected as outside the
    // package root.)
    mod.addAnonymousImport("qstrdefs_h", .{
        .root_source_file = b.path("vendor/micropython_embed/genhdr/qstrdefs.generated.h"),
    });
    // ADR-003 L2 — frozen-tiny module set, baked into the binary via
    // a single blob + comptime index (see frozen_index_mod above).
    // Attaching the index module here is what puts frozen_index /
    // frozen_bundle into `mod`'s import graph so
    // src/runtime/frozen_modules.zig can @import("frozen_index") and
    // reach the .mpy bytes.
    if (frozen_index_mod) |fim| mod.addImport("frozen_index", fim);
    const exe = b.addExecutable(.{
        .name = "petitpy",
        .root_module = mod,
    });
    // ADR 010 §D1 P2: wasm export-section strip. rdynamic=true forces every
    // `pub export` visible to the JS host, inflating the Export section to
    // ~5.6 KB (1021 entries). The JS bridge only actually needs three
    // symbols: npy_dispatch_callback (the JS-side callback entry, only
    // reachable from `inst.exports`), plus m_malloc (used by the bridge
    // to allocate callback-arg arrays). The rest are noise from the
    // wasm-host perspective — they're called only from within the wasm
    // module itself, where the linker has already resolved the names.
    //
    // Strategy: keep rdynamic=false (the default), and explicitly preserve
    // the two JS-bridge entries via --export= flags. The standard WASI
    // entry (`_start`, `memory`) and the wasi-libc `malloc`/`free` fallbacks
    // remain implicitly exported.
    if (is_wasm_target) {
        // ADR-006 J5a (preserved): npy_dispatch_callback is the JS-bridge
        // callback entry. wasm-lld's --gc-sections would otherwise drop it
        // because nothing in Zig calls it directly — the JS host does.
        // m_malloc gets used by the bridge to allocate callback-arg arrays.
        // Both symbols only exist under feature-js=true.
        if (features.js) {
            exe.root_module.export_symbol_names = &.{
                "npy_dispatch_callback",
                "m_malloc",
            };
        } else {
            // No JS bridge — keep just the WASI entry implicit defaults.
            exe.root_module.export_symbol_names = &.{};
        }
    }

    // mpconfigport.h lives in port/; the package and its generated headers
    // live under vendor/micropython_embed/{,port}; src/ holds the strangler
    // Zig modules and their C shims, organised by layer (frontend, runtime,
    // objects, modules, memory, support, entry) — each subdir on the include
    // path so shims can #include "<x>_api.h" without relative paths.
    mod.addIncludePath(b.path("port"));
    mod.addIncludePath(b.path(embed_root));
    mod.addIncludePath(b.path(embed_root ++ "/port"));
    mod.addIncludePath(b.path("src"));
    mod.addIncludePath(b.path("src/frontend"));
    mod.addIncludePath(b.path("src/runtime"));
    mod.addIncludePath(b.path("src/objects"));
    mod.addIncludePath(b.path("src/objects/objtype"));
    mod.addIncludePath(b.path("src/objects/primitives"));
    mod.addIncludePath(b.path("src/objects/strings"));
    mod.addIncludePath(b.path("src/objects/containers"));
    mod.addIncludePath(b.path("src/objects/iters"));
    mod.addIncludePath(b.path("src/objects/callables"));
    mod.addIncludePath(b.path("src/modules"));
    mod.addIncludePath(b.path("src/memory"));
    mod.addIncludePath(b.path("src/support"));
    mod.addIncludePath(b.path("src/entry"));

    // B4 WASM: setjmp/longjmp require the WebAssembly exception-handling
    // proposal. -mllvm -wasm-enable-sjlj enables the emscripten-style
    // compile-time transformation that lowers setjmp to wasm exceptions.
    const is_wasm = target.result.cpu.arch.isWasm();
    const is_full = config_preset == .full;

    var cflags_list = std.ArrayList([]const u8).empty;
    cflags_list.appendSlice(b.allocator, &[_][]const u8{
        "-std=c99",
        "-DNDEBUG",
        // MicroPython relies on well-defined-in-practice pointer
        // arithmetic that trips zig cc's default UBSan.
        "-fno-sanitize=undefined",
        "-fno-common",
        "-Wno-unused-command-line-argument",
    }) catch @panic("OOM");
    if (is_wasm) {
        // Force-define the macro that gates setjmp.h's #error. The strangle
        // is converged on nano: no Zig path longjmps (m_malloc_fail is
        // polled), and the vendor C in the wasm carveouts (longint /
        // float) raises through the polled bridges in src/runtime/raise.zig
        // rather than through setjmp. The macro silences the compile-time
        // diagnostic without needing actual setjmp stubs.
        cflags_list.append(b.allocator, "-D__wasm_exception_handling__=1") catch @panic("OOM");
        // W1: @cImport / translate-c runs independently of cflags. Without
        // addCMacro the @cInclude("py/runtime.h") cascade transitively pulls
        // setjmp.h, which hits its #error on wasm and breaks ~26 Zig files.
        // Mirror the cflag at the module level so translate-c sees the same
        // exception-handling assertion the C compile gets.
        mod.addCMacro("__wasm_exception_handling__", "1");
    }
    if (exception_unwind) {
        // ADR 013 — the NLR trampoline's setjmp/longjmp pad is live only
        // where exception_unwind is. Everywhere else the Zig wrappers
        // comptime-collapse to direct calls, but nlr_trampoline.c still has
        // to compile so its extern symbols resolve (Zig emits references to
        // them even from comptime-dead branches). Keying the C bodies on the
        // same predicate keeps longjmp out of builds whose libc has none:
        // wasi-libc has no longjmp, and a Debug build has no DCE to strip
        // the reference the way ReleaseSmall does.
        cflags_list.append(b.allocator, "-DNPY_EXCEPTION_UNWIND=1") catch @panic("OOM");
    }
    if (is_full) {
        // Signals to port/mpconfigport.h that the full-features config arm
        // should be selected. Phase 1
        // wires the toggle, subsequent phases add the actual feature flips.
        cflags_list.append(b.allocator, "-DPETITPY_CONFIG_FULL=1") catch @panic("OOM");
        // Critical: Zig's @cImport runs translate-c separately from C source
        // compilation. Without addCMacro, lexer.h / parse.h etc. would be
        // translated WITHOUT the full define, leaving Zig with the wrong
        // (nano) enum values for MP_TOKEN_*. Mismatch breaks all parsing
        // under full once ASYNC_AWAIT shifts the keyword token enum.
        mod.addCMacro("PETITPY_CONFIG_FULL", "1");
    }
    // MICROPY_PY_BUILTINS_STR_UNICODE follows str_unicode, the lexer's switch.
    if (str_unicode) {
        cflags_list.append(b.allocator, "-DPETITPY_STR_UNICODE=1") catch @panic("OOM");
        mod.addCMacro("PETITPY_STR_UNICODE", "1");
    }
    // ADR-002 F1 — emit PETITPY_FEATURE_<X> per active feature. The
    // mpconfigport.h gates MICROPY_PY_MATH / MICROPY_WARNINGS on these.
    // Both cflag and addCMacro forms are required (cflag for the C
    // compile graph; addCMacro for Zig's translate-c).
    if (features.math) {
        cflags_list.append(b.allocator, "-DPETITPY_FEATURE_MATH=1") catch @panic("OOM");
        mod.addCMacro("PETITPY_FEATURE_MATH", "1");
    }
    if (features.warning) {
        cflags_list.append(b.allocator, "-DPETITPY_FEATURE_WARNING=1") catch @panic("OOM");
        mod.addCMacro("PETITPY_FEATURE_WARNING", "1");
    }
    if (features.collections) {
        cflags_list.append(b.allocator, "-DPETITPY_FEATURE_COLLECTIONS=1") catch @panic("OOM");
        mod.addCMacro("PETITPY_FEATURE_COLLECTIONS", "1");
    }
    if (features.struct_mod) {
        cflags_list.append(b.allocator, "-DPETITPY_FEATURE_STRUCT=1") catch @panic("OOM");
        mod.addCMacro("PETITPY_FEATURE_STRUCT", "1");
    }
    if (features.array) {
        cflags_list.append(b.allocator, "-DPETITPY_FEATURE_ARRAY=1") catch @panic("OOM");
        mod.addCMacro("PETITPY_FEATURE_ARRAY", "1");
    }
    if (features.errno) {
        cflags_list.append(b.allocator, "-DPETITPY_FEATURE_ERRNO=1") catch @panic("OOM");
        mod.addCMacro("PETITPY_FEATURE_ERRNO", "1");
    }
    if (features.micropython) {
        cflags_list.append(b.allocator, "-DPETITPY_FEATURE_MICROPYTHON=1") catch @panic("OOM");
        mod.addCMacro("PETITPY_FEATURE_MICROPYTHON", "1");
    }
    if (features.gc_module) {
        cflags_list.append(b.allocator, "-DPETITPY_FEATURE_GC_MODULE=1") catch @panic("OOM");
        mod.addCMacro("PETITPY_FEATURE_GC_MODULE", "1");
    }
    if (features.js) {
        cflags_list.append(b.allocator, "-DPETITPY_FEATURE_JS=1") catch @panic("OOM");
        mod.addCMacro("PETITPY_FEATURE_JS", "1");
    }
    if (features.re) {
        cflags_list.append(b.allocator, "-DPETITPY_FEATURE_RE=1") catch @panic("OOM");
        mod.addCMacro("PETITPY_FEATURE_RE", "1");
    }
    if (features.os) {
        cflags_list.append(b.allocator, "-DPETITPY_FEATURE_OS=1") catch @panic("OOM");
        mod.addCMacro("PETITPY_FEATURE_OS", "1");
    }
    if (features.time_mod) {
        cflags_list.append(b.allocator, "-DPETITPY_FEATURE_TIME=1") catch @panic("OOM");
        mod.addCMacro("PETITPY_FEATURE_TIME", "1");
    }
    if (features.socket_mod) {
        cflags_list.append(b.allocator, "-DPETITPY_FEATURE_SOCKET=1") catch @panic("OOM");
        mod.addCMacro("PETITPY_FEATURE_SOCKET", "1");
    }
    if (features.select_mod) {
        cflags_list.append(b.allocator, "-DPETITPY_FEATURE_SELECT=1") catch @panic("OOM");
        mod.addCMacro("PETITPY_FEATURE_SELECT", "1");
    }
    if (features.signal_mod) {
        cflags_list.append(b.allocator, "-DPETITPY_FEATURE_SIGNAL=1") catch @panic("OOM");
        mod.addCMacro("PETITPY_FEATURE_SIGNAL", "1");
    }
    if (features.pwd_grp) {
        cflags_list.append(b.allocator, "-DPETITPY_FEATURE_PWD_GRP=1") catch @panic("OOM");
        mod.addCMacro("PETITPY_FEATURE_PWD_GRP", "1");
    }
    if (features.subprocess_mod) {
        cflags_list.append(b.allocator, "-DPETITPY_FEATURE_SUBPROCESS=1") catch @panic("OOM");
        mod.addCMacro("PETITPY_FEATURE_SUBPROCESS", "1");
    }
    const cflags = cflags_list.toOwnedSlice(b.allocator) catch @panic("OOM");

    // C-source aggregation for the main `petitpy` binary.
    //
    // The strangle is converged. Files collected into a single
    // ArrayList across the feature-gated branches and handed to Zig
    // via ONE addCSourceFiles call (root = build root, files paths
    // include their "src/" or "vendor/micropython_embed/" prefix).
    // This keeps the compile command emitted by zig build to a
    // single `-cflags <17 defines> --` block per binary instead of
    // one per file group.
    //
    // Feature carveouts (longint / float / full) append specific
    // vendor .c files below.
    //
    // Vendor type implementations (mp_type_X + ctor) and
    // MP_REGISTER_MODULE / qstr anchors come from vendor py/mod*.c
    // (registers) + tools/zig_qstr_shadow.py (Zig-only qstrs); no
    // port-local module C files required beyond the two here.
    var mod_files = std.ArrayList([]const u8).empty;
    mod_files.appendSlice(b.allocator, &.{
        // objmodule_shim.c (86 LOC) — the only residual nano-side
        // .c file, exists because qstr-gen's makeqstrdefs.py scans
        // only .c sources for the MICROPY_REGISTERED_MODULES /
        // EXTENSIBLE_MODULES / MODULE_DELEGATIONS macros. Removing
        // it requires teaching qstr-gen to scan something else.
        "src/objects/objtype/objmodule_shim.c",
        // ADR 013 — NLR trampoline. Compiled unconditionally because
        // the Zig side declares its symbols via extern, and Zig
        // emits those refs even from comptime-dead branches. Under
        // non-exception_unwind builds (nano, wasm32 full) the C
        // functions exist but are never called — linker DCE strips
        // them. Setjmp/longjmp in C because Zig's "returns twice"
        // semantics are awkward; setjmp.h itself is unconditionally
        // available on native (under wasm32 too the include is
        // fine — the header just #error-guards the macro
        // implementations, which we don't expand under our
        // flag-gated callers).
        "src/runtime/nlr_trampoline.c",
        // va_list-touching functions (mp_vprintf, mp_printf,
        // vstr_printf/_vprintf, mp_obj_new_exception_msg_varg/_vlist)
        // live in C because Zig 0.16's std.builtin.VaList emits
        // @compileError on aarch64-Linux under the LLVM backend.
        "src/objects/strings/va_ops.c",
    }) catch @panic("OOM");

    if (is_full) {
        // Full-only vendor C carveout: the
        // arbitrary-precision integer engine. Replaces the 14
        // longint @panic stubs F0 installed in
        // src/runtime/full_stubs.zig (now deleted). Documented
        // trade-off: zero-vendor-C is preserved under nano; full
        // accepts ~2.8k LOC of vendor C compiled-back-in for the
        // arbitrary-precision integer subsystem until/unless a
        // dedicated F2b mpz→Zig port lands.
        mod_files.appendSlice(b.allocator, &.{
            embed_root ++ "/py/objint.c", // polymorphic int dispatcher (small + mpz)
            embed_root ++ "/py/objint_mpz.c", // mpz-flavored ops (gated on MICROPY_LONGINT_IMPL_MPZ)
            embed_root ++ "/py/mpz.c", // the bignum arithmetic engine itself
        }) catch @panic("OOM");
        // io module carveout: provides StringIO,
        // BytesIO, IOBase, BufferedWriter, and registers the io
        // module. Depends on src/support/stream.zig's exported ROM
        // objects (mp_stream_read_obj etc.) and
        // src/modules/file_io.zig's mp_builtin_open_obj. Replaces
        // the stub_mp_module_io zero-init that F0 installed.
        mod_files.appendSlice(b.allocator, &.{
            embed_root ++ "/py/modio.c", // IOBase + BufferedWriter + module registration
            embed_root ++ "/py/objstringio.c", // StringIO + BytesIO types
        }) catch @panic("OOM");
        // builtin_help carveout:
        // provides the real `mp_builtin_help_obj` function-obj.
        // Under nano the stub in vendor_stubs.zig satisfies the link
        // (test is in the 4-FAIL excluded list); under full the test
        // is expected to pass, so we need the real impl. Replaces
        // the [64]u8 zero-init shadow.
        //
        // Also adds py/warning.c — provides real `mp_warning` that
        // routes through &mp_stderr_print (defined in
        // src/objects/strings/mpprint.zig). Unblocks bytes_compare3
        // (the str/bytes comparison warning test).
        mod_files.appendSlice(b.allocator, &.{
            embed_root ++ "/py/builtinhelp.c",
            embed_root ++ "/py/warning.c",
        }) catch @panic("OOM");
    }
    // wasm32-nano LONGLONG arm: vendor objint.c (polymorphic
    // dispatcher) + objint_longlong.c (LONGLONG-flavored ops)
    // provide the real int ctors + numeric ops + print/formatted
    // dispatchers that handle heap mp_obj_int_t. Both files are
    // gated internally by
    //   #if MICROPY_LONGINT_IMPL == LONGLONG
    // so on the native-nano (NONE) build they compile to empty; on
    // full we still skip (objint.c is wired in the `if (is_full)`
    // block above).
    //
    // objint.c is otherwise replaced by src/objects/numerics/objint.zig
    // for nano-NONE (default). We pull it in here for the LONGLONG
    // carveout. The Zig stubs that would conflict (mp_obj_int_print,
    // mp_obj_int_formatted, mp_int_format_size,
    // mp_obj_new_int_from_float) are gated off under LONGLONG via
    // `if (build_options.longint_none)` in objint.zig.
    if (!is_full and !longint_none) {
        mod_files.appendSlice(b.allocator, &.{
            embed_root ++ "/py/objint.c",
            embed_root ++ "/py/objint_longlong.c",
        }) catch @panic("OOM");
    }
    // FLOAT arm: MICROPY_PY_BUILTINS_FLOAT=1 in both nano and full
    // configs. Vendor py/objfloat.c + py/formatfloat.c on both arms —
    // the prior "defer for full" comment was speculative; in practice
    // full needs the same float symbols as nano, and there's no
    // alternate implementation to conflict with.
    mod_files.appendSlice(b.allocator, &.{
        embed_root ++ "/py/objfloat.c",
        embed_root ++ "/py/formatfloat.c",
    }) catch @panic("OOM");
    // ADR 010 §A3a slice 2 — `re` module: vendor extmod/modre.c.
    // The 4 re1.5/ engine .c files (charclass, compilecode,
    // dumpcode, recursiveloop) are pulled in via #include in modre.c
    // itself, so only modre.c gets compiled. Copied into the embed
    // package by `make port`'s copy-extmod-extras step. Gated on
    // feature-re=true (the default for both nano and full).
    if (features.re) {
        mod_files.appendSlice(b.allocator, &.{
            embed_root ++ "/extmod/modre.c",
        }) catch @panic("OOM");
    }

    // Single addCSourceFiles → single `-cflags <flags> -- <files>`
    // block on the emitted zig build-exe command line. Root defaults
    // to the build root; files carry their own path prefix.
    mod.addCSourceFiles(.{
        .files = mod_files.items,
        .flags = cflags,
    });

    // NX-3 N3a (2026-06-05): `zig_compile_bridge.c` → ported to
    // `src/runtime/zig_compile_bridge.zig`. `defer mp_globals_set(saved)`
    // replaces `nlr_push_jump_callback`'s restore-on-unwind. Force-analyzed via
    // main.zig's comptime block. Persistent-code loader
    // (`mp_raw_code_load_mem`) is Zig-side as of NX-1.

    // ── Zig unit tests (pure shimless modules) — `zig build unittest` ──
    const unit_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{ .name = "vm-shimless", .root_module = unit_mod });
    const run_unit = b.addRunArtifact(unit_tests);
    b.step("unittest", "Run Zig unit tests for the pure-Zig modules")
        .dependOn(&run_unit.step);

    b.installArtifact(exe);

    // `zig build run -- script.py`
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run petitpy").dependOn(&run.step);

    // ── petitpy-vm — VM-only binary (loads .mpy, no compiler) ─────
    //
    // Same C sources + include paths as `petitpy`, but rooted at
    // `src/main_vm.zig` which deliberately does NOT comptime-import
    // `runtime/zig_compile_bridge.zig`, `entry/embed_exec.zig`, or
    // `compiler/bridge.zig`. The compiler-track Zig modules
    // (`compile.zig`, `parser.zig`, …) are also NOT added as imports,
    // so DCE drops the entire compiler track from the binary.
    //
    // The two extern symbols the runtime still references —
    // `npy_zig_eval_exec` (called from `mp_builtin_eval`/`exec`) and
    // `npy_zig_compile_to_code` (called from FULL-only
    // `mp_builtin_compile`) — are stubbed in `main_vm.zig` to raise
    // NotImplementedError if invoked.
    const vm_mod = b.createModule(.{
        .root_source_file = b.path("src/main_vm.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    vm_mod.addImport("build_options", build_options_mod);
    vm_mod.addAnonymousImport("qstrdefs_h", .{
        .root_source_file = b.path("vendor/micropython_embed/genhdr/qstrdefs.generated.h"),
    });
    // Same shared frozen-tiny index module as `mod` above.
    if (frozen_index_mod) |fim| vm_mod.addImport("frozen_index", fim);
    vm_mod.addIncludePath(b.path("port"));
    vm_mod.addIncludePath(b.path(embed_root));
    vm_mod.addIncludePath(b.path(embed_root ++ "/port"));
    vm_mod.addIncludePath(b.path("src"));
    vm_mod.addIncludePath(b.path("src/frontend"));
    vm_mod.addIncludePath(b.path("src/runtime"));
    vm_mod.addIncludePath(b.path("src/objects"));
    vm_mod.addIncludePath(b.path("src/objects/objtype"));
    vm_mod.addIncludePath(b.path("src/objects/primitives"));
    vm_mod.addIncludePath(b.path("src/objects/strings"));
    vm_mod.addIncludePath(b.path("src/objects/containers"));
    vm_mod.addIncludePath(b.path("src/objects/iters"));
    vm_mod.addIncludePath(b.path("src/objects/callables"));
    vm_mod.addIncludePath(b.path("src/modules"));
    vm_mod.addIncludePath(b.path("src/memory"));
    vm_mod.addIncludePath(b.path("src/support"));
    vm_mod.addIncludePath(b.path("src/entry"));
    if (is_wasm) vm_mod.addCMacro("__wasm_exception_handling__", "1");
    if (is_full) vm_mod.addCMacro("PETITPY_CONFIG_FULL", "1");
    if (str_unicode) vm_mod.addCMacro("PETITPY_STR_UNICODE", "1");
    // ADR-002 F1 — mirror the per-feature macros on vm_mod (same rationale
    // as the main mod: translate-c needs them, and the cflags also carry
    // the -D so the C compile sees them).
    if (features.math) vm_mod.addCMacro("PETITPY_FEATURE_MATH", "1");
    if (features.re) vm_mod.addCMacro("PETITPY_FEATURE_RE", "1");
    if (features.warning) vm_mod.addCMacro("PETITPY_FEATURE_WARNING", "1");
    if (features.collections) vm_mod.addCMacro("PETITPY_FEATURE_COLLECTIONS", "1");
    if (features.struct_mod) vm_mod.addCMacro("PETITPY_FEATURE_STRUCT", "1");
    if (features.array) vm_mod.addCMacro("PETITPY_FEATURE_ARRAY", "1");
    if (features.errno) vm_mod.addCMacro("PETITPY_FEATURE_ERRNO", "1");
    if (features.micropython) vm_mod.addCMacro("PETITPY_FEATURE_MICROPYTHON", "1");
    if (features.gc_module) vm_mod.addCMacro("PETITPY_FEATURE_GC_MODULE", "1");
    if (features.js) vm_mod.addCMacro("PETITPY_FEATURE_JS", "1");
    // C-source aggregation for the `petitpy-vm` variant. Same
    // single-list pattern as the main `petitpy` binary above;
    // see that block for per-file rationale. The only deliberate
    // divergence: vm_mod skips objfloat/formatfloat under is_full
    // (leaves the 10 float symbols unresolved — documented
    // pre-existing deferred work).
    var vm_files = std.ArrayList([]const u8).empty;
    vm_files.appendSlice(b.allocator, &.{
        "src/objects/objtype/objmodule_shim.c",
        "src/runtime/nlr_trampoline.c", // ADR 013 — see comment on main mod's same addition
        "src/objects/strings/va_ops.c", // va_list surface — see main mod
    }) catch @panic("OOM");

    if (is_full) {
        vm_files.appendSlice(b.allocator, &.{
            embed_root ++ "/py/objint.c",
            embed_root ++ "/py/objint_mpz.c",
            embed_root ++ "/py/mpz.c",
            embed_root ++ "/py/modio.c",
            embed_root ++ "/py/objstringio.c",
            embed_root ++ "/py/builtinhelp.c",
            embed_root ++ "/py/warning.c",
        }) catch @panic("OOM");
    }
    // Same LONGLONG carveout the main `petitpy` target gets —
    // vendor objint.c (polymorphic dispatcher) + objint_longlong.c
    // (LONGLONG ctors/ops + mp_type_int) must reach the vm-only
    // binary too, otherwise its compile unit references mp_type_int
    // with no provider.
    if (!is_full and !longint_none) {
        vm_files.appendSlice(b.allocator, &.{
            embed_root ++ "/py/objint.c",
            embed_root ++ "/py/objint_longlong.c",
        }) catch @panic("OOM");
    }
    // Float-arm carveout — differs from the main `petitpy` (which
    // includes float unconditionally). Under is_full the vm binary
    // deliberately omits float; the 10 unresolved float symbols are
    // documented pre-existing deferred work.
    vm_files.appendSlice(b.allocator, &.{
        embed_root ++ "/py/objfloat.c",
        embed_root ++ "/py/formatfloat.c",
    }) catch @panic("OOM");
    // Same re carveout as the main target.
    if (features.re) {
        vm_files.appendSlice(b.allocator, &.{
            embed_root ++ "/extmod/modre.c",
        }) catch @panic("OOM");
    }

    vm_mod.addCSourceFiles(.{
        .files = vm_files.items,
        .flags = cflags,
    });
    const vm_exe = b.addExecutable(.{
        .name = "petitpy-vm",
        .root_module = vm_mod,
    });
    b.installArtifact(vm_exe);
    const vm_run = b.addRunArtifact(vm_exe);
    if (b.args) |args| vm_run.addArgs(args);
    b.step("run-vm", "Run petitpy-vm").dependOn(&vm_run.step);

    // ── Compiler track — pure Zig, no C dependency ──
    // First milestone (C1): `.mpy` round-trip tool.
    // Second milestone (C2): pure-Zig qstr table + differential test.
    const qstrdefs_path = b.path("vendor/micropython_embed/genhdr/qstrdefs.generated.h");

    const mpy_rt_mod = b.createModule(.{
        .root_source_file = b.path("src/compiler/mpy_roundtrip.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const mpy_rt_exe = b.addExecutable(.{
        .name = "mpy-roundtrip",
        .root_module = mpy_rt_mod,
    });
    b.installArtifact(mpy_rt_exe);
    const mpy_rt_run = b.addRunArtifact(mpy_rt_exe);
    if (b.args) |args| mpy_rt_run.addArgs(args);
    b.step("mpy-roundtrip", "Run .mpy round-trip test (compiler-track C1)")
        .dependOn(&mpy_rt_run.step);

    // C2: qstr differential test
    const qstr_test_mod = b.createModule(.{
        .root_source_file = b.path("src/compiler/qstr_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    qstr_test_mod.addAnonymousImport("qstrdefs_h", .{ .root_source_file = qstrdefs_path });
    const qstr_test_exe = b.addExecutable(.{
        .name = "qstr-test",
        .root_module = qstr_test_mod,
    });
    b.installArtifact(qstr_test_exe);
    const qstr_test_run = b.addRunArtifact(qstr_test_exe);
    if (b.args) |args| qstr_test_run.addArgs(args);
    b.step("qstr-test", "Run compiler-track C2 qstr differential test")
        .dependOn(&qstr_test_run.step);

    // C2 unit tests in qstr.zig
    const qstr_unit_mod = b.createModule(.{
        .root_source_file = b.path("src/compiler/qstr.zig"),
        .target = target,
        .optimize = optimize,
    });
    qstr_unit_mod.addAnonymousImport("qstrdefs_h", .{ .root_source_file = qstrdefs_path });
    // qstr.zig imports mpy.zig — create that as an importable module too
    const mpy_mod = b.createModule(.{
        .root_source_file = b.path("src/compiler/mpy.zig"),
        .target = target,
        .optimize = optimize,
    });
    qstr_unit_mod.addImport("mpy.zig", mpy_mod);
    const qstr_unit_tests = b.addTest(.{ .name = "compiler-qstr", .root_module = qstr_unit_mod });
    const run_qstr_unit = b.addRunArtifact(qstr_unit_tests);
    b.step("qstr-unit", "Run qstr.zig comptime + unit tests")
        .dependOn(&run_qstr_unit.step);

    // C3: lexer unit tests + differential test
    const qstr_for_lexer = b.createModule(.{
        .root_source_file = b.path("src/compiler/qstr.zig"),
        .target = target,
        .optimize = optimize,
    });
    qstr_for_lexer.addAnonymousImport("qstrdefs_h", .{ .root_source_file = qstrdefs_path });
    qstr_for_lexer.addImport("mpy.zig", mpy_mod);

    const lexer_mod = b.createModule(.{
        .root_source_file = b.path("src/compiler/lexer.zig"),
        .target = target,
        .optimize = optimize,
    });
    lexer_mod.addImport("qstr.zig", qstr_for_lexer);
    lexer_mod.addImport("build_options", build_options_mod);
    const lexer_unit_tests = b.addTest(.{ .name = "compiler-lexer", .root_module = lexer_mod });
    const run_lexer_unit = b.addRunArtifact(lexer_unit_tests);
    b.step("lexer-unit", "Run lexer.zig comptime + unit tests")
        .dependOn(&run_lexer_unit.step);

    // lexer-test (differential vs vendor token_dump) deferred:
    // - requires a C harness `tools/token_dump.c` that links vendor lexer
    //   (not yet built)
    // - several std.fs / std.process Zig 0.16 API translations TBD
    // src/compiler/lexer_test.zig is committed as a draft; wiring re-enabled
    // when both are addressed.

    // ── bigint helper (used by parser fold layer + compile.zig int_big) ──
    const bigint_mod = b.createModule(.{
        .root_source_file = b.path("src/compiler/bigint.zig"),
        .target = target,
        .optimize = optimize,
    });
    const bigint_unit_tests = b.addTest(.{ .name = "compiler-bigint", .root_module = bigint_mod });
    const run_bigint_unit = b.addRunArtifact(bigint_unit_tests);
    b.step("bigint-unit", "Run bigint.zig comptime + unit tests")
        .dependOn(&run_bigint_unit.step);

    // ── C4: parser + grammar_data ──────────────────────────────────────────
    const grammar_data_mod = b.createModule(.{
        .root_source_file = b.path("src/compiler/grammar_data.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Extension grammar rules (match statement) — see grammar_ext.zig.
    // Sits above grammar_data so the generated table stays untouched.
    const grammar_ext_mod = b.createModule(.{
        .root_source_file = b.path("src/compiler/grammar_ext.zig"),
        .target = target,
        .optimize = optimize,
    });
    grammar_ext_mod.addImport("grammar_data.zig", grammar_data_mod);
    grammar_ext_mod.addImport("grammar_ext.zig", grammar_ext_mod);
    grammar_ext_mod.addImport("lexer.zig", lexer_mod);
    const parser_mod = b.createModule(.{
        .root_source_file = b.path("src/compiler/parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    parser_mod.addImport("grammar_ext.zig", grammar_ext_mod);
    parser_mod.addImport("lexer.zig", lexer_mod);
    parser_mod.addImport("qstr.zig", qstr_for_lexer);
    parser_mod.addImport("grammar_data.zig", grammar_data_mod);
    parser_mod.addImport("bigint.zig", bigint_mod);
    parser_mod.addImport("build_options", build_options_mod);
    const parser_unit_tests = b.addTest(.{ .name = "compiler-parser", .root_module = parser_mod });
    const run_parser_unit = b.addRunArtifact(parser_unit_tests);
    b.step("parser-unit", "Run parser.zig comptime + unit tests")
        .dependOn(&run_parser_unit.step);

    // ── C5: scope ──────────────────────────────────────────────────────────
    const scope_mod = b.createModule(.{
        .root_source_file = b.path("src/compiler/scope.zig"),
        .target = target,
        .optimize = optimize,
    });
    scope_mod.addImport("qstr.zig", qstr_for_lexer);
    scope_mod.addImport("parser.zig", parser_mod);
    const scope_unit_tests = b.addTest(.{ .name = "compiler-scope", .root_module = scope_mod });
    const run_scope_unit = b.addRunArtifact(scope_unit_tests);
    b.step("scope-unit", "Run scope.zig comptime + unit tests")
        .dependOn(&run_scope_unit.step);

    // ── C6: emit (bytecode emitter) ────────────────────────────────────────
    const emit_mod = b.createModule(.{
        .root_source_file = b.path("src/compiler/emit.zig"),
        .target = target,
        .optimize = optimize,
    });
    emit_mod.addImport("qstr.zig", qstr_for_lexer);
    emit_mod.addImport("scope.zig", scope_mod);
    emit_mod.addImport("parser.zig", parser_mod);
    emit_mod.addImport("mpy.zig", mpy_mod);
    const emit_unit_tests = b.addTest(.{ .name = "compiler-emit", .root_module = emit_mod });
    const run_emit_unit = b.addRunArtifact(emit_unit_tests);
    b.step("emit-unit", "Run emit.zig comptime + unit tests")
        .dependOn(&run_emit_unit.step);

    // ── C7: compiler driver ────────────────────────────────────────────────
    // Scaffold: structure + dispatch + 3-pass driver + unit tests land here.
    // Handler bodies that emit divergent bytecode are marked SCAFFOLD/deferred
    // and still to be completed.
    const compile_mod = b.createModule(.{
        .root_source_file = b.path("src/compiler/compile.zig"),
        .target = target,
        .optimize = optimize,
    });
    compile_mod.addImport("build_options", build_options_mod);
    compile_mod.addImport("qstr.zig", qstr_for_lexer);
    compile_mod.addImport("scope.zig", scope_mod);
    compile_mod.addImport("parser.zig", parser_mod);
    compile_mod.addImport("emit.zig", emit_mod);
    compile_mod.addImport("mpy.zig", mpy_mod);
    compile_mod.addImport("grammar_data.zig", grammar_data_mod);
    compile_mod.addImport("grammar_ext.zig", grammar_ext_mod);
    compile_mod.addImport("lexer.zig", lexer_mod);
    compile_mod.addImport("bigint.zig", bigint_mod);
    const compile_unit_tests = b.addTest(.{ .name = "compiler-driver", .root_module = compile_mod });
    const run_compile_unit = b.addRunArtifact(compile_unit_tests);
    b.step("compile-unit", "Run compile.zig comptime + unit tests")
        .dependOn(&run_compile_unit.step);

    // C7b-8: compile-test (differential vs vendor mpy-cross).
    // Builds a CLI that compiles a .py, serialises via mpy.write, and
    // byte-diffs against `mpy-cross <file>.mpy`. PATH must contain
    // `mpy-cross` (vendor build, MPY_VERSION 6).
    const compile_test_mod = b.createModule(.{
        .root_source_file = b.path("src/compiler/compile_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    compile_test_mod.addImport("build_options", build_options_mod);
    compile_test_mod.addImport("qstr.zig", qstr_for_lexer);
    compile_test_mod.addImport("scope.zig", scope_mod);
    compile_test_mod.addImport("parser.zig", parser_mod);
    compile_test_mod.addImport("emit.zig", emit_mod);
    compile_test_mod.addImport("mpy.zig", mpy_mod);
    compile_test_mod.addImport("grammar_data.zig", grammar_data_mod);
    compile_test_mod.addImport("grammar_ext.zig", grammar_ext_mod);
    compile_test_mod.addImport("lexer.zig", lexer_mod);
    compile_test_mod.addImport("bigint.zig", bigint_mod);
    compile_test_mod.addImport("compile.zig", compile_mod);
    const compile_test_exe = b.addExecutable(.{
        .name = "zigpy-compile-test",
        .root_module = compile_test_mod,
    });
    const compile_test_run = b.addRunArtifact(compile_test_exe);
    if (b.args) |args| compile_test_run.addArgs(args);
    b.step("compile-test", "Run compile-test differential vs mpy-cross")
        .dependOn(&compile_test_run.step);

    // C8: zigpy-compile (user-facing .py → .mpy CLI).
    // Same module wiring as compile_test_mod, but installed (lands in
    // zig-out/bin/zigpy-compile) and without the mpy-cross diffing path.
    const zigpy_compile_mod = b.createModule(.{
        .root_source_file = b.path("src/compiler/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // NOTE: deliberately NOT addOptions("build_options", ...) — main.zig
    // doesn't import build_options directly (it inlines VERSION), and
    // compile_mod brings its own addOptions via its transitive deps. If
    // we add it here too, Zig 0.16 sees the same options.zig file under
    // two distinct module names and rejects the build.
    zigpy_compile_mod.addImport("qstr.zig", qstr_for_lexer);
    zigpy_compile_mod.addImport("scope.zig", scope_mod);
    zigpy_compile_mod.addImport("parser.zig", parser_mod);
    zigpy_compile_mod.addImport("emit.zig", emit_mod);
    zigpy_compile_mod.addImport("mpy.zig", mpy_mod);
    zigpy_compile_mod.addImport("grammar_data.zig", grammar_data_mod);
    zigpy_compile_mod.addImport("grammar_ext.zig", grammar_ext_mod);
    zigpy_compile_mod.addImport("lexer.zig", lexer_mod);
    zigpy_compile_mod.addImport("bigint.zig", bigint_mod);
    zigpy_compile_mod.addImport("compile.zig", compile_mod);
    const zigpy_compile_exe = b.addExecutable(.{
        .name = "zigpy-compile",
        .root_module = zigpy_compile_mod,
    });
    b.installArtifact(zigpy_compile_exe);
    const zigpy_compile_run = b.addRunArtifact(zigpy_compile_exe);
    if (b.args) |args| zigpy_compile_run.addArgs(args);
    b.step("zigpy-compile", "Compile .py files to .mpy (compiler-track C8)")
        .dependOn(&zigpy_compile_run.step);

    // Wire the compiler-track modules into the main runtime binary so
    // src/compiler/bridge.zig (`npy_zig_compile_to_mpy` export) can
    // resolve its imports. Main mod's main.zig force-analyzes bridge.zig
    // in a comptime block.
    mod.addImport("qstr.zig", qstr_for_lexer);
    mod.addImport("scope.zig", scope_mod);
    mod.addImport("parser.zig", parser_mod);
    mod.addImport("emit.zig", emit_mod);
    mod.addImport("mpy.zig", mpy_mod);
    mod.addImport("grammar_data.zig", grammar_data_mod);
    mod.addImport("grammar_ext.zig", grammar_ext_mod);
    mod.addImport("lexer.zig", lexer_mod);
    mod.addImport("bigint.zig", bigint_mod);
    mod.addImport("compile.zig", compile_mod);

    // Two-executable testing split: the strangler has two halves that
    // can be tested in isolation — the compiler (src/compiler/*, also
    // shipped as the standalone `zigpy-compile` binary) and the VM
    // (src/runtime/* + src/objects/* + src/modules/*, integrated into
    // the `petitpy` binary). Per-module steps (qstr-unit, …) stay
    // as developer conveniences for narrowly targeted runs.
    const unit_compiler = b.step("unit-compiler", "Run compiler-track unit tests (qstr, lexer, bigint, parser, scope, emit, driver)");
    unit_compiler.dependOn(&run_qstr_unit.step);
    unit_compiler.dependOn(&run_lexer_unit.step);
    unit_compiler.dependOn(&run_bigint_unit.step);
    unit_compiler.dependOn(&run_parser_unit.step);
    unit_compiler.dependOn(&run_scope_unit.step);
    unit_compiler.dependOn(&run_emit_unit.step);
    unit_compiler.dependOn(&run_compile_unit.step);

    const unit_vm = b.step("unit-vm", "Run VM-track unit tests (the shimless runtime utilities)");
    unit_vm.dependOn(&run_unit.step);

    const unit_all = b.step("unit", "Run every Zig unit test (compiler + VM)");
    unit_all.dependOn(unit_compiler);
    unit_all.dependOn(unit_vm);
}
