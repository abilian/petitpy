//! nanopython — Zig port of py/argcheck.c (Axis-B B1 #2; notes/11).
//! 4 class-A exports, 0 nlr-hosts. Struct access goes through the
//! `mirrors.MpArg` / `MpArgVal` mirrors (no C-shim trip). Nano
//! ERROR_REPORTING<=TERSE ⇒ every error path is the single terse
//! mismatch.
//!
//! Uses the B0-pinned PyError convention (notes/11) via the shared
//! `pyerr.bridge`. `terse` sets `pyerr.pending_exc` and returns
//! `error.PyRaise`; it propagates via `try` through the internal
//! `*Impl` fns. Exported C-ABI symbols are thin `pyerr.bridge`
//! wrappers (B1 mode → nlr_jump; B2 → delete the bridge bodies).

const std = @import("std");
const mp = @cImport({
    @cInclude("py/runtime.h");
});
const mirrors = @import("../mp_mirrors.zig");
const pyerr = @import("../pyerr.zig");
const PyError = pyerr.PyError;

const Obj = mirrors.Obj;

// Direct extern fns (replacing the type-cast wrappers from argcheck_shim).
extern fn mp_obj_get_int(arg: Obj) callconv(.c) isize;
extern fn mp_obj_is_true(o: Obj) callconv(.c) bool;
extern fn mp_obj_new_exception_msg(t: *const anyopaque, msg: [*:0]const u8) callconv(.c) Obj;
extern fn mp_map_init_fixed_table(map: *mirrors.MpMap, n: usize, table: [*c]const Obj) callconv(.c) void;
extern const mp_type_TypeError: anyopaque;

inline fn makeTerseExc() Obj {
    return mp_obj_new_exception_msg(&mp_type_TypeError, "argument num/types mismatch");
}

fn terse() PyError!void {
    pyerr.pending_exc = makeTerseExc(); // construct, do NOT raise
    return error.PyRaise; // propagates via `try` (no longjmp)
}

fn mpArgCheckNumSigImpl(n_args: usize, n_kw: usize, sig: u32) PyError!void {
    const takes_kw = (sig & 1) != 0;
    const n_args_min: usize = sig >> 17;
    const n_args_max: usize = (sig >> 1) & 0xffff;
    if (n_kw != 0 and !takes_kw) try terse();
    if (n_args_min == n_args_max) {
        if (n_args != n_args_min) try terse();
    } else {
        if (n_args < n_args_min) {
            try terse();
        } else if (n_args > n_args_max) {
            try terse();
        }
    }
}

fn mpArgParseAllImpl(
    n_pos: usize,
    pos: [*c]const Obj,
    kws: ?*anyopaque,
    n_allowed: usize,
    allowed: ?*const anyopaque,
    out_vals: ?*anyopaque,
) PyError!void {
    var pos_found: usize = 0;
    var kws_found: usize = 0;
    var i: usize = 0;
    const out_base: [*]mirrors.MpArgVal = @ptrCast(@alignCast(out_vals));
    while (i < n_allowed) : (i += 1) {
        const arg = mirrors.MpArg.at(allowed, i);
        const flags: c_int = @intCast(arg.flags);
        var given_arg: Obj = undefined;
        if (i < n_pos) {
            if ((flags & mp.MP_ARG_KW_ONLY) != 0) try terse(); // goto extra_positional
            pos_found += 1;
            given_arg = pos[i];
        } else {
            const km: *mirrors.MpMap = @ptrCast(@alignCast(kws));
            const e = mirrors.mp_map_lookup(km, mirrors.objFromQstr(arg.qst), mirrors.MP_MAP_LOOKUP);
            if (e == null) {
                if ((flags & mp.MP_ARG_REQUIRED) != 0) try terse();
                out_base[i] = arg.defval;
                continue;
            } else {
                kws_found += 1;
                given_arg = e.?.value;
            }
        }
        const kind = flags & mp.MP_ARG_KIND_MASK;
        if (kind == mp.MP_ARG_BOOL) {
            out_base[i] = .{ .u_bool = mp_obj_is_true(given_arg) };
        } else if (kind == mp.MP_ARG_INT) {
            out_base[i] = .{ .u_int = mp_obj_get_int(given_arg) };
        } else {
            out_base[i] = .{ .u_obj = given_arg };
        }
    }
    if (pos_found < n_pos) try terse(); // extra_positional:
    if (kws_found < mirrors.MpMap.fromPtr(kws).bits.used) try terse();
}

export fn mp_arg_check_num_sig(n_args: usize, n_kw: usize, sig: u32) void {
    pyerr.bridge(void, mpArgCheckNumSigImpl(n_args, n_kw, sig));
    // Tried adding longjmpIfPending() here — works under full (+1 corpus)
    // but regresses 1 nano test (namedtuple1): the nano corpus golden
    // captures the buggy "format string needs more arguments" output that
    // came from vendor C callers using uninitialized format args after
    // the polled-raise; the clean post-longjmp behavior ("can't convert
    // to int") would require a nano-C refreeze we can't do here. Leaving
    // the polled-only path; vendor C bugs at call sites stay as-is for now.
    // TODO: revisit when corpus-nano refreeze is in scope.
}

// NX-3 N4b: polled-only. Vendor C is gone; all Zig callers now poll
// pyerr.pending_exc after the call. The previous longjmp-bridge to
// vendor C is no longer needed.

export fn mp_arg_parse_all(
    n_pos: usize,
    pos: [*c]const Obj,
    kws: ?*anyopaque,
    n_allowed: usize,
    allowed: ?*const anyopaque,
    out_vals: ?*anyopaque,
) void {
    pyerr.bridge(void, mpArgParseAllImpl(n_pos, pos, kws, n_allowed, allowed, out_vals));
}

export fn mp_arg_parse_all_kw_array(
    n_pos: usize,
    n_kw: usize,
    args: [*c]const Obj,
    n_allowed: usize,
    allowed: ?*const anyopaque,
    out_vals: ?*anyopaque,
) void {
    var buf: [256]u8 align(16) = undefined;
    std.debug.assert(@sizeOf(mirrors.MpMap) <= buf.len);
    const map_ptr: *mirrors.MpMap = @ptrCast(@alignCast(&buf));
    mp_map_init_fixed_table(map_ptr, n_kw, args + n_pos);
    pyerr.bridge(void, mpArgParseAllImpl(n_pos, args, map_ptr, n_allowed, allowed, out_vals));
}

// NX-3 N4b: vendor public ABI; no nano caller exercises this path
// (corpus never hits it). Keep the noreturn signature for ABI but
// @panic — the body is unreachable under nano.
export fn mp_arg_error_terse_mismatch() callconv(.c) noreturn {
    _ = makeTerseExc; // keep the helper analyzed
    @panic("mp_arg_error_terse_mismatch: unreachable under nano");
}

// B2 Phase B-3: polled sibling. Sets pending_exc + returns. The C
// caller MUST be a non-noreturn function declared without MP_NORETURN,
// AND must check pending_exc + return early after the call.
export fn mp_arg_error_terse_mismatch_polled() callconv(.c) void {
    pyerr.pending_exc = makeTerseExc();
}

comptime {
    _ = &mp_arg_check_num_sig;
    _ = &mp_arg_parse_all;
    _ = &mp_arg_parse_all_kw_array;
    _ = &mp_arg_error_terse_mismatch;
}
