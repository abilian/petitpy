/* petitpy — MicroPython configuration for the embed port.
 *
 * Two presets, selected at build time:
 *   default                    → frozen nano slice (the strangler corpus
 *                                is calibrated against this — changing
 *                                non-FULL-gated values invalidates goldens).
 *   -DPETITPY_CONFIG_FULL=1 → full features (everything available).
 *
 * The build.zig `-Dconfig=nano|full` option drives the define above.
 * Phase 1
 * wires the toggle, subsequent phases add the actual feature flips
 * inside the #ifdef PETITPY_CONFIG_FULL arm.
 */

// Common MicroPython embed configuration (types, alloca, mphalport path).
#include <port/mpconfigport_common.h>

// Pre-define MP_SSIZE_MAX using INTPTR_MAX (always available via
// <stdint.h>) so vendor mpconfig.h:2341's `#ifndef MP_SSIZE_MAX;
// #define MP_SSIZE_MAX SSIZE_MAX` is skipped. Otherwise SSIZE_MAX has
// to come from <limits.h> — reliably available on macOS clang but
// gated behind _POSIX_C_SOURCE on Linux glibc/musl and absent on
// wasi-libc. INTPTR_MAX matches ssize_t width on both LP64 (INT64_MAX)
// and ILP32 (INT32_MAX), so it's a correct portable substitute.
// The 32-bit nano wasm block further down redefines this to the same
// value via a numeric literal — guard with #ifndef so this doesn't
// collide.
#include <stdint.h>
#ifndef MP_SSIZE_MAX
#define MP_SSIZE_MAX INTPTR_MAX
#endif

// Start from the minimal ROM level (disables all optional features), then
// opt in to exactly the nano surface.
#define MICROPY_CONFIG_ROM_LEVEL                (MICROPY_CONFIG_ROM_LEVEL_MINIMUM)

// Core interpreter.
#define MICROPY_ENABLE_COMPILER                 (1)
#define MICROPY_ENABLE_GC                       (1)
// ADR-002 F2: MICROPY_PY_GC is the Python-facing `gc` module; gated on
// PETITPY_FEATURE_GC_MODULE. This is independent of MICROPY_ENABLE_GC
// (the GC subsystem itself, which stays on regardless).
#ifdef PETITPY_FEATURE_GC_MODULE
#define MICROPY_PY_GC                           (1)
#else
#define MICROPY_PY_GC                           (0)
#endif

// .mpy persistent-code loader: zig_compile_bridge.c hands vendor's
// runtime pre-serialized .mpy bytes from our Zig compile path, and
// mp_raw_code_load_mem populates the mp_compiled_module_t.
// Cascade: LOAD sets MICROPY_PERSISTENT_CODE which flips
// MICROPY_EMIT_BYTECODE_USES_QSTR_TABLE on (bytecode operands become
// table indices instead of qstr ids; both compiler and frontend emit
// in that shape now).
#define MICROPY_PERSISTENT_CODE_LOAD            (1)

// WASM has no architecture-specific non-local-return (nlr) implementation;
// force the portable setjmp/longjmp path. wasi-libc provides setjmp/longjmp.
// This is load-bearing for all exception handling — validated in Phase 1.
#define MICROPY_NLR_SETJMP                      (1)

// Likewise, WASM has no CPU registers to scan for the conservative GC; use
// the setjmp-based register spill in gchelper_generic.c.
#define MICROPY_GCREGS_SETJMP                   (1)

// 0.2 — opt-in features beyond nano-minimum.
#define MICROPY_PY_BUILTINS_ENUMERATE           (1)
#define MICROPY_PY_FUNCTION_ATTRS               (1)
#define MICROPY_PY_BUILTINS_SET                 (1)
#define MICROPY_PY_BUILTINS_FROZENSET           (1)
#define MICROPY_PY_BUILTINS_SLICE               (1)
#define MICROPY_PY_BUILTINS_SLICE_INDICES       (1)
#define MICROPY_PY_BUILTINS_MIN_MAX              (1)
#define MICROPY_PY_BUILTINS_REVERSED             (1)
#define MICROPY_PY_BUILTINS_FILTER               (1)
#define MICROPY_PY_ALL_SPECIAL_METHODS           (1)
#define MICROPY_PY_ALL_INPLACE_SPECIAL_METHODS   (1)
#define MICROPY_PY_REVERSE_SPECIAL_METHODS       (1)
#define MICROPY_PY_BUILTINS_BYTEARRAY            (1)
#define MICROPY_PY_SYS                           (1)
#define MICROPY_PY_SYS_PLATFORM                  "petitpy"
#define MICROPY_PY_SYS_PATH_DEFAULT              ".frozen"
#define MICROPY_PY_SYS_MAXSIZE                   (1)
#define MICROPY_PY_SYS_EXIT                      (1)
#define MICROPY_PY_SYS_MODULES                   (1)
#define MICROPY_PY_SYS_PS1_PS2                   (1)

// String / format extras
#define MICROPY_PY_ASSIGN_EXPR                   (1)
#define MICROPY_PY_ASYNC_AWAIT                   (1)
#define MICROPY_PY_FSTRINGS                      (1)
#define MICROPY_PY_BUILTINS_INPUT                (1)
#define MICROPY_HELPER_REPL                      (1)
// ADR-002 F2 — feature-gated modules. Same pattern as MICROPY_PY_MATH (F1):
// the PETITPY_FEATURE_<X> macro emitted by build.zig drives whether the
// vendor module compiles in. Preset defaults: on for both nano and full.
#ifdef PETITPY_FEATURE_ERRNO
#define MICROPY_PY_ERRNO                         (1)
#else
#define MICROPY_PY_ERRNO                         (0)
#endif
#ifdef PETITPY_FEATURE_STRUCT
#define MICROPY_PY_STRUCT                        (1)
#else
#define MICROPY_PY_STRUCT                        (0)
#endif
// ADR 010 §A3a slice 2 — `re` module via vendor extmod/modre.c +
// lib/re1.5/. The MATCH_GROUPS / SPAN / SUB sub-features ship
// together because turning them off saves only a few KB and the
// API contract docs them as part of `re`.
#ifdef PETITPY_FEATURE_RE
#define MICROPY_PY_RE                            (1)
#define MICROPY_PY_RE_MATCH_GROUPS               (1)
#define MICROPY_PY_RE_MATCH_SPAN_START_END       (1)
#define MICROPY_PY_RE_SUB                        (1)
#endif
#ifdef PETITPY_FEATURE_COLLECTIONS
#define MICROPY_PY_COLLECTIONS                   (1)
#define MICROPY_PY_COLLECTIONS_ORDEREDDICT         (1)
#define MICROPY_PY_COLLECTIONS_DEQUE              (1)
#define MICROPY_PY_COLLECTIONS_DEQUE_ITER         (1)
#define MICROPY_PY_COLLECTIONS_DEQUE_SUBSCR       (1)
#else
#define MICROPY_PY_COLLECTIONS                   (0)
#define MICROPY_PY_COLLECTIONS_ORDEREDDICT         (0)
#define MICROPY_PY_COLLECTIONS_DEQUE              (0)
#define MICROPY_PY_COLLECTIONS_DEQUE_ITER         (0)
#define MICROPY_PY_COLLECTIONS_DEQUE_SUBSCR       (0)
#endif
#ifdef PETITPY_FEATURE_MICROPYTHON
#define MICROPY_PY_MICROPYTHON                    (1)
#else
#define MICROPY_PY_MICROPYTHON                    (0)
#endif
// ADR-006 J1 — JS interop bridge. Gates the `_petitpy_js` builtin
// module (the wasm-imports + Python-callable shim that petitpy-lib/js.py
// fronts). Default: off (the scanner sees the qstrs unconditionally, but
// the gate keeps the module pointer out of moduledefs.h's table when
// the feature is off, so `import _petitpy_js` raises ImportError under
// native + wasmtime-CLI).
#ifdef PETITPY_FEATURE_JS
#define MICROPY_PY_PETITPY_JS                  (1)
#else
#define MICROPY_PY_PETITPY_JS                  (0)
#endif
// MICROPY_PY_IO requires open()/file builtins; deferred (needs mp_hal
// open/read/seek + a file type).
#define MICROPY_PY_BUILTINS_FLOAT                (1)
#define MICROPY_FLOAT_IMPL                       (MICROPY_FLOAT_IMPL_DOUBLE)
#define MICROPY_PY_BUILTINS_COMPLEX              (0)
// ADR-002 F1 — MICROPY_PY_MATH is now gated on the PETITPY_FEATURE_MATH
// macro emitted by build.zig (preset default: on for both nano and full).
#ifdef PETITPY_FEATURE_MATH
#define MICROPY_PY_MATH                          (1)
#else
#define MICROPY_PY_MATH                          (0)
#endif
#define MICROPY_PY_MATH_CONSTANTS                (1)
#define MICROPY_PY_BUILTINS_STR_OP_MODULO        (1)
#define MICROPY_PY_BUILTINS_STR_COUNT            (1)
#define MICROPY_PY_BUILTINS_STR_CENTER           (1)
#define MICROPY_PY_BUILTINS_STR_PARTITION        (1)
#define MICROPY_PY_BUILTINS_STR_SPLITLINES       (1)
#define MICROPY_PY_BUILTINS_NEXT2                (1)
#define MICROPY_PY_BUILTINS_PROPERTY             (1)
#define MICROPY_PY_DESCRIPTORS                   (1)
#define MICROPY_PY_BUILTINS_RANGE_BINOP          (1)
#define MICROPY_PY_BUILTINS_MEMORYVIEW           (1)
#ifdef PETITPY_FEATURE_ARRAY
#define MICROPY_PY_ARRAY                         (1)
#else
#define MICROPY_PY_ARRAY                         (0)
#endif
#define MICROPY_PY_BUILTINS_HELP                 (1)
#define MICROPY_PY_BUILTINS_BYTES_HEX            (1)
#define MICROPY_CPYTHON_COMPAT                   (1)
#define MICROPY_PY_DELATTR_SETATTR               (1)

// ─── CPython-compat helpers: enable for nano too ──────────────────────
//
// MICROPY_PY_ATTRTUPLE makes `sys.implementation.name` (etc.) work — the
// vendor default gates this on ROM_LEVEL >= CORE_FEATURES, which we
// use MINIMUM, so without an explicit nano enable the feature stays off
// and every `sys.implementation.X` access raises AttributeError.
//
// MICROPY_PY_BUILTINS_DICT_FROMKEYS makes `dict.fromkeys(iter)` work
// (a common CPython idiom; without it the call raises AttributeError).
// Vendor default is gated on ROM_LEVEL >= EXTRA_FEATURES.
//
// Both have ~zero binary-size impact and dramatic developer-experience
// impact. Enabled unconditionally — they were previously inside the
// FULL block which disabled them for nano.
#define MICROPY_PY_ATTRTUPLE                     (1)
#define MICROPY_PY_BUILTINS_DICT_FROMKEYS        (1)

// Force the APPROX float-format-impl. Vendor's default under wasm32 is
// EXACT because `long double > double` (16 vs 8 bytes), which would
// expect `mp_large_float_t = long double`. Our Zig port of
// mp_decimal_exp (src/frontend/parsenum.zig) uses double (f64). With
// EXACT, formatfloat.c calls mp_decimal_exp expecting a long double
// arg/return — under wasm the call_indirect signature check rejects
// the f64-signed implementation and traps with
//   wasm trap: signature_mismatch:mp_decimal_exp
// on every float-print path (print(5.0), %.2f, math.pi, etc.).
//
// Setting APPROX makes formatfloat.c use mp_decimal_exp with
// mp_float_t (= double = f64) — signatures match.
#undef  MICROPY_FLOAT_FORMAT_IMPL
#define MICROPY_FLOAT_FORMAT_IMPL                (MICROPY_FLOAT_FORMAT_IMPL_APPROX)
// range.start / range.stop / range.step — accessed on range objects via
// the type's attr slot. Previously inside the FULL block; ungated for
// nano so the common `r.start` idiom works without surprise. Pair
// with the slot-index restructure in objrange.zig.
#define MICROPY_PY_BUILTINS_RANGE_ATTRS          (1)

// ─── 32-bit-pointer arm (wasm32-nano) ─────────────────────────────────
//
// On 64-bit hosts, MICROPY_OBJ_REPR_A gives a 62-bit smallint — fits any
// practical Python integer for nano. On 32-bit hosts (wasm32), the same
// encoding gives only a 30-bit smallint (~1.07 billion). Without a
// longint backend, `print(1717977600)` (current Unix timestamp) raises
// `OverflowError: long int not supported in this build` — every modern
// web demo hits this on the first I/O timestamp.
//
// Default to LONGLONG on 32-bit pointer nano builds. Vendor
// py/objint_longlong.c (compiled into the build via build.zig carveout)
// provides the bignum int ctors + numeric ops + mp_type_int.
//
// On 64-bit nano targets, keep vendor's default (NONE) — corpus
// goldens were frozen there. Under -Dconfig=full the MPZ define in the
// full arm wins regardless.
#if __SIZEOF_POINTER__ == 4 && !defined(PETITPY_CONFIG_FULL)
#undef  MICROPY_LONGINT_IMPL
#define MICROPY_LONGINT_IMPL                  (MICROPY_LONGINT_IMPL_LONGLONG)
// wasi-libc doesn't expose SSIZE_MAX (POSIX-only). On wasm32 ssize_t is
// signed 32-bit, so MP_SSIZE_MAX is INT32_MAX. Vendor objint_longlong.c
// references SSIZE_MAX via mpconfig.h.
#define MP_SSIZE_MAX                          (2147483647)
#endif

// Unicode str: str indexes, slices and iterates by code point. On when
// build.zig's str-unicode option is (default: the full config), which also
// sets the lexer's mode, so compiler and runtime agree.
#ifdef PETITPY_STR_UNICODE
#define MICROPY_PY_BUILTINS_STR_UNICODE        (1)
#endif

// ─── Full-features arm ────────────────────────────────────────────────
//
// When PETITPY_CONFIG_FULL is defined (via build.zig's -Dconfig=full),
// override the nano defaults above to enable every available feature.
// Phase 1 just wires the toggle —
// the actual feature flips land in subsequent phases as the Zig ports
// gain comptime config-gating support.
//
// Each line below is commented-out today; un-comment in Phase 2+ as the
// corresponding Zig-side restoration lands.
#ifdef PETITPY_CONFIG_FULL
// Phase 2 (Category A — Zig comptime restoration):
// MICROPY_PY_DELATTR_SETATTR is now (1) for both arms (was full-only;
// flipped in v0.7). Redefine kept here
// as a no-op marker so a vendor pull diff stays readable.
// MICROPY_PY_FUNCTION_ATTRS_CODE: oracle has it OFF and the matching
// SKIP path in tests/basics/fun_code*.py expects AttributeError on
// (lambda:0).__code__. Enabling here makes those tests diverge.
// #define MICROPY_PY_FUNCTION_ATTRS_CODE        (1)
#define MICROPY_PY_GENERATOR_PEND_THROW       (1)
#define MICROPY_PY_BUILTINS_BYTES_HEX_DELIM   (1)
#define MICROPY_PY_BUILTINS_RANGE_ATTRS       (1)
#define MICROPY_PY_BUILTINS_EVAL_EXEC         (1)
#define MICROPY_PY_BUILTINS_SLICE_ATTRS       (1)
#define MICROPY_PY_BOUND_METHOD_FULL_EQUALITY_CHECK (1)
#define MICROPY_PY_BUILTINS_DICT_FROMKEYS           (1)
#define MICROPY_PY_BUILTINS_ROUND_INT               (1)
#define MICROPY_PY_BUILTINS_POW3                    (1)
#define MICROPY_PY_COLLECTIONS_NAMEDTUPLE__ASDICT    (1)
#define MICROPY_PY_BUILTINS_NOTIMPLEMENTED           (1)
#define MICROPY_PY_BUILTINS_HELP_MODULES             (1)
#define MICROPY_PY_ARRAY_SLICE_ASSIGN                (1)
#define MICROPY_PY_BUILTINS_MEMORYVIEW_ITEMSIZE      (1)
#define MICROPY_PY_GC_COLLECT_RETVAL                 (1)
#define MICROPY_MODULE_BUILTIN_INIT                  (1)
#define MICROPY_FULL_CHECKS                          (1)
#define MICROPY_PY_SYS_TRACEBACKLIMIT                (1)
#define MICROPY_PY_SYS_INTERN                        (1)
#define MICROPY_PY_SYS_EXC_INFO                      (1)
#define MICROPY_OPT_LOAD_ATTR_FAST_PATH              (1)
#define MICROPY_OPT_MAP_LOOKUP_CACHE                 (1)
#define MICROPY_PY_MATH_FACTORIAL                    (1)
#define MICROPY_PY_MATH_ISCLOSE                      (1)
#define MICROPY_PY_MATH_SPECIAL_FUNCTIONS            (1)
#define MICROPY_OPT_MATH_FACTORIAL                   (1)
// MULTIPLE_INHERITANCE (Phase 3 #3, 2026-05-26): scaffolding completed.
// mp_obj_new_type stores bases_tuple as parent slot; is_subclass_fast,
// class_lookup, super_attr, instance_count_native_bases all walk tuple
// parents under comptime is_full guard.
#define MICROPY_MULTIPLE_INHERITANCE             (1)
// COMPILE: mp_compile_to_raw_code now a C-ABI export from compile.zig
// (Phase 3 #2, 2026-05-26).
#define MICROPY_PY_BUILTINS_COMPILE           (1)
//   #define MICROPY_PY_BUILTINS_STR_UNICODE       (1)
//   #define MICROPY_PY_BUILTINS_STR_UNICODE_CHECK (1)
//
// Phase 3 (Category B — algorithm restoration):
#undef  MICROPY_PY_BUILTINS_COMPLEX
#define MICROPY_PY_BUILTINS_COMPLEX           (1)
#undef MICROPY_LONGINT_IMPL
#define MICROPY_LONGINT_IMPL                  (MICROPY_LONGINT_IMPL_MPZ)
#define MICROPY_PY_IO                         (1)
#define MICROPY_PY_IO_IOBASE                  (1)
#define MICROPY_PY_SYS_STDFILES               (1)
#define MICROPY_PY_SYS_STDIO_BUFFER           (1)
#define MICROPY_PY_ASYNC_AWAIT                (1)
#define MICROPY_PY_ATTRTUPLE                  (1)
// PEP 562 module __getattr__ (on in the unix oracle). Also how the ROM
// `os` module serves `os.path` (modules/modos.zig).
#define MICROPY_MODULE_GETATTR                 (1)
// Oracle (unix-standard) has these OFF. Disabling under full matches the
// oracle's "SKIP" path in the gated tests; nano keeps them ON to stay
// byte-identical to the frozen nano-C reference.
// (ALL_INPLACE_SPECIAL_METHODS can't be turned off here — the qstr scanner
// runs once with -DPETITPY_CONFIG_FULL and won't generate __imul__ etc
// qstrs that the nano-side shim references. Accept class_inplace_op2 as a
// benign config mismatch.)
#undef MICROPY_PY_BUILTINS_MEMORYVIEW_ITEMSIZE
#define MICROPY_PY_BUILTINS_MEMORYVIEW_ITEMSIZE (0)
#undef MICROPY_PY_SYS_TRACEBACKLIMIT
#define MICROPY_PY_SYS_TRACEBACKLIMIT (0)
#undef MICROPY_PY_BUILTINS_RANGE_BINOP
#define MICROPY_PY_BUILTINS_RANGE_BINOP (0)
#undef MICROPY_PY_COLLECTIONS_NAMEDTUPLE__ASDICT
#define MICROPY_PY_COLLECTIONS_NAMEDTUPLE__ASDICT (0)
// ADR-002 F1 — MICROPY_WARNINGS is now gated on PETITPY_FEATURE_WARNING
// (preset default: on under full). MICROPY_PY_STR_BYTES_CMP_WARN follows
// the same gate because the warning it emits is a no-op when MICROPY_WARNINGS
// is 0 (see py/runtime.h: mp_warning(...) becomes empty).
#ifdef PETITPY_FEATURE_WARNING
#define MICROPY_WARNINGS                       (1)
#define MICROPY_PY_STR_BYTES_CMP_WARN          (1)
extern const struct _mp_print_t mp_stderr_print;
#undef MICROPY_ERROR_PRINTER
#define MICROPY_ERROR_PRINTER                  (&mp_stderr_print)
#endif
// `os` module (Zig-native).
// Also defined under PETITPY_CONFIG_FULL below (unconditionally, so the
// qstr scanner sees the module qstrs even when the runtime feature is off).
#ifdef PETITPY_FEATURE_OS
#define MICROPY_PY_OS                          (1)
#endif
// `time` module (Zig-native).
#ifdef PETITPY_FEATURE_TIME
#define MICROPY_PY_TIME                        (1)
#endif
// `socket` module (Zig-native).
#ifdef PETITPY_FEATURE_SOCKET
#define MICROPY_PY_SOCKET                      (1)
#endif
// `select` module (Zig-native).
#ifdef PETITPY_FEATURE_SELECT
#define MICROPY_PY_SELECT                      (1)
#endif
// `signal` module (Zig-native, MVP).
#ifdef PETITPY_FEATURE_SIGNAL
#define MICROPY_PY_SIGNAL                      (1)
#endif
// `pwd` + `grp` modules.
#ifdef PETITPY_FEATURE_PWD_GRP
#define MICROPY_PY_PWD                         (1)
#define MICROPY_PY_GRP                         (1)
#endif
// `_subprocess` low-level module.
#ifdef PETITPY_FEATURE_SUBPROCESS
#define MICROPY_PY__SUBPROCESS                 (1)
#endif
// MICROPY_PY_IO_BUFFEREDWRITER not enabled here: the corpus/full oracle
// is the standard MicroPython build, which does not enable it. Enabling
// it diverges io_buffered_writer.out (oracle prints SKIP, we'd run the
// real test).
//   #define MICROPY_PY_ASYNC_AWAIT                (1)
#endif
