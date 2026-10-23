//! petitpy — Zig port of py/bc.c. Originally 4 varint helpers
//! (Axis-B B1.5 W3). Expanded to cover mp_setup_code_state wrapper.
//! Final port (this session): mp_setup_code_state_helper — the
//! ~250-LOC arg/kwarg/defaults binding algorithm that runs on every
//! Python function call. Pure logic over the bytecode prelude — no
//! NLR; raises propagate via the polled-sentinel (pyerr.pending_exc).
//!
//! Nano: MP_BYTES_PER_OBJ_WORD=8 ⇒ MP_ENCODE_UINT_MAX_BYTES=(8*8+6)/7=10.
//! Bit-pattern faithful: 7-bit chunks, little-endian-encoded /
//! big-endian-stored, MSB continuation flag.
//!
//! Compile-time invariants (preserved verbatim from the C source):
//!   MICROPY_EMIT_BYTECODE_USES_QSTR_TABLE = 1 (set by PERSISTENT_CODE_LOAD)
//!   MICROPY_ENABLE_NATIVE_CODE            = 0
//!   MICROPY_ERROR_REPORTING               = TERSE (ROM_LEVEL_MINIMUM default)
//!   MICROPY_DEBUG_VERBOSE                 = 0

const std = @import("std");
const mirrors = @import("../mp_mirrors.zig");
const pyerr = @import("../pyerr.zig");
const Obj = mirrors.Obj;

const MP_ENCODE_UINT_MAX_BYTES: usize = 10;

const Byte = u8;
const McUint = usize; // mp_uint_t

// uint8_t *(*)(void *env, size_t nbytes)
const Allocator = ?*const fn (?*anyopaque, usize) callconv(.c) [*c]Byte;

export fn mp_encode_uint(env: ?*anyopaque, allocator: Allocator, val_in: McUint) callconv(.c) void {
    // We store each 7 bits in a separate byte, and that's how many bytes needed.
    // We encode in little-endian order, but store in big-endian, to help decoding.
    var val = val_in;
    var buf: [MP_ENCODE_UINT_MAX_BYTES]Byte = undefined;
    var p: usize = MP_ENCODE_UINT_MAX_BYTES;
    while (true) {
        p -= 1;
        buf[p] = @intCast(val & 0x7f);
        val >>= 7;
        if (val == 0) break;
    }
    const n = MP_ENCODE_UINT_MAX_BYTES - p;
    const c_ptr = allocator.?(env, n);
    if (c_ptr != null) {
        var src = p;
        var dst: usize = 0;
        while (src != MP_ENCODE_UINT_MAX_BYTES - 1) : ({
            src += 1;
            dst += 1;
        }) {
            c_ptr[dst] = buf[src] | 0x80;
        }
        c_ptr[dst] = buf[src]; // last byte (MSB clear → continuation flag off)
    }
}

export fn mp_decode_uint(ptr: *[*c]const Byte) callconv(.c) McUint {
    var unum: McUint = 0;
    var p: [*c]const Byte = ptr.*;
    while (true) {
        const v = p[0];
        p += 1;
        unum = (unum << 7) | (v & 0x7f);
        if ((v & 0x80) == 0) break;
    }
    ptr.* = p;
    return unum;
}

export fn mp_decode_uint_value(ptr_in: [*c]const Byte) callconv(.c) McUint {
    var p = ptr_in;
    return mp_decode_uint(&p);
}

export fn mp_decode_uint_skip(ptr_in: [*c]const Byte) callconv(.c) [*c]const Byte {
    var p = ptr_in;
    while ((p[0] & 0x80) != 0) : (p += 1) {}
    return p + 1;
}

// ── mp_setup_code_state wrapper (post-MpCodeState-mirror) ─────────────
//
// Thin pre-helper that snapshots ip + sp for the helper. STACKLESS=0
// and SETTRACE=0 under both configs (no prev / prev_state / frame
// fields in the mirror), so the C version's two #if branches are dead.
//
// sp starts at &state[0] - 1: an out-of-bounds-by-1 pointer that's only
// legal for incrementing. The helper relies on this convention.

export fn mp_setup_code_state(code_state: *mirrors.MpCodeState, n_args: usize, n_kw: usize, args: [*c]const Obj) callconv(.c) void {
    const fun = code_state.fun_bc.?;
    code_state.ip = fun.bytecode;
    // sp = &state[0] - 1 (one slot before state[0]).
    const state_ptr = code_state.statePtr();
    code_state.sp = @ptrFromInt(@intFromPtr(state_ptr) - @sizeOf(Obj));
    mp_setup_code_state_helper(code_state, n_args, n_kw, args);
}

// ── mp_setup_code_state_helper (THE Python-function-call entry) ───────
//
// Ported from py/bc.c verbatim in structure. Raises are polled-sentinel
// — set pyerr.pending_exc, return; caller checks pending_exc + returns.
//
// MP_SCOPE_FLAG_* constants (py/runtime0.h:34-44):
const MP_SCOPE_FLAG_VARARGS: usize = 0x04;
const MP_SCOPE_FLAG_VARKEYWORDS: usize = 0x02;
const MP_SCOPE_FLAG_DEFKWARGS: usize = 0x08;

const MP_MAP_LOOKUP: c_int = 0;
const MP_MAP_LOOKUP_ADD_IF_NOT_FOUND: c_int = 1;

extern fn mp_obj_new_tuple(n: usize, items: [*c]const Obj) callconv(.c) Obj;
extern fn mp_obj_new_dict(n: usize) callconv(.c) Obj;
extern fn mp_obj_new_cell(obj: Obj) callconv(.c) Obj;
extern fn mp_obj_new_exception_msg(t: *const anyopaque, msg: [*:0]const u8) callconv(.c) Obj;
extern fn mp_obj_new_exception_msg_varg(t: *const anyopaque, fmt: [*:0]const u8, ...) callconv(.c) Obj;
extern fn mp_arg_error_terse_mismatch_polled() callconv(.c) void;
extern const mp_type_TypeError: anyopaque;
extern const mp_const_empty_tuple_obj: anyopaque;

inline fn setTypeError(msg: [*:0]const u8) void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_TypeError, msg);
}

// MP_BC_PRELUDE_SIG_DECODE_INTO faithful port. Advances *ip past the
// 1..N sig-prelude bytes; outputs the six S/E/F/A/K/D fields.
inline fn preludeSigDecode(
    ip: *[*]const Byte,
    out_n_state: *usize,
    out_n_exc: *usize,
    out_scope_flags: *usize,
    out_n_pos: *usize,
    out_n_kwonly: *usize,
    out_n_def_pos: *usize,
) void {
    var z: u8 = ip.*[0];
    ip.* += 1;
    // xSSSSEAA
    var S: usize = (z >> 3) & 0xf;
    var E: usize = (z >> 2) & 0x1;
    var F: usize = 0;
    var A: usize = z & 0x3;
    var K: usize = 0;
    var D: usize = 0;
    // ShiftAmt is u6 on 64-bit hosts and u5 on 32-bit hosts (wasm32).
    const ShiftAmt = std.math.Log2Int(usize);
    var n: ShiftAmt = 0;
    while ((z & 0x80) != 0) : (n += 1) {
        z = ip.*[0];
        ip.* += 1;
        // xFSSKAED
        S |= @as(usize, z & 0x30) << (@as(ShiftAmt, 2) * n);
        E |= @as(usize, z & 0x02) << n;
        F |= (@as(usize, (z & 0x40) >> 6)) << n;
        A |= @as(usize, z & 0x4) << n;
        K |= (@as(usize, (z & 0x08) >> 3)) << n;
        D |= @as(usize, z & 0x1) << n;
    }
    S += 1;
    out_n_state.* = S;
    out_n_exc.* = E;
    out_scope_flags.* = F;
    out_n_pos.* = A;
    out_n_kwonly.* = K;
    out_n_def_pos.* = D;
}

// MP_BC_PRELUDE_SIZE_DECODE_INTO faithful port. Reads bytes interleaving
// I (n_info) and C (n_cell) — xIIIIIIC repeated.
inline fn preludeSizeDecode(ip: *[*]const Byte, out_n_info: *usize, out_n_cell: *usize) void {
    var C: usize = 0;
    var I: usize = 0;
    // ShiftAmt is u6 on 64-bit hosts and u5 on 32-bit hosts (wasm32).
    // Counter `n` is kept as usize and cast at each shift site to avoid
    // overflow in the (6 * n) arithmetic on narrow shift types.
    const ShiftAmt = std.math.Log2Int(usize);
    var n: usize = 0;
    while (true) : (n += 1) {
        const z: u8 = ip.*[0];
        ip.* += 1;
        // xIIIIIIC
        C |= @as(usize, z & 1) << @as(ShiftAmt, @intCast(n));
        I |= (@as(usize, (z & 0x7e) >> 1)) << @as(ShiftAmt, @intCast(6 * n));
        if ((z & 0x80) == 0) break;
    }
    out_n_info.* = I;
    out_n_cell.* = C;
}

// Standard 7-bit varint decode. Advances *p.
inline fn decodeUint(p: *[*]const Byte) usize {
    var unum: usize = 0;
    var q = p.*;
    while (true) {
        const v = q[0];
        q += 1;
        unum = (unum << 7) | (v & 0x7f);
        if ((v & 0x80) == 0) break;
    }
    p.* = q;
    return unum;
}

// Skip past one varint. Used to step over the simple_name qstr at start
// of the source-info section.
inline fn decodeUintSkip(p: [*]const Byte) [*]const Byte {
    var q = p;
    while ((q[0] & 0x80) != 0) : (q += 1) {}
    return q + 1;
}

export fn mp_setup_code_state_helper(
    code_state: *mirrors.MpCodeState,
    n_args_in: usize,
    n_kw: usize,
    args: [*c]const Obj,
) callconv(.c) void {
    var n_args = n_args_in;

    const self = code_state.fun_bc.?;
    const n_state: usize = code_state.n_state;

    // Decode prelude. The C macros advance code_state->ip — mirror that
    // by passing &code_state.ip directly so the post-state matches the
    // C version (code_state.ip then points at the source-info section).
    var ip_ref: [*]const Byte = code_state.ip;
    var n_state_unused: usize = undefined;
    var n_exc_stack_unused: usize = undefined;
    var scope_flags: usize = undefined;
    var n_pos_args: usize = undefined;
    var n_kwonly_args: usize = undefined;
    var n_def_pos_args: usize = undefined;
    preludeSigDecode(&ip_ref, &n_state_unused, &n_exc_stack_unused, &scope_flags, &n_pos_args, &n_kwonly_args, &n_def_pos_args);
    var n_info: usize = undefined;
    var n_cell: usize = undefined;
    preludeSizeDecode(&ip_ref, &n_info, &n_cell);
    code_state.ip = ip_ref;

    // code_state_state = code_state->sp + 1 (sp was set to &state[0] - 1
    // by the wrapper; +1 brings it back to state[0]).
    const code_state_state: [*]Obj = @ptrFromInt(@intFromPtr(code_state.sp) + @sizeOf(Obj));
    code_state.exc_sp_idx = 0;

    // zero out the local stack
    @memset(code_state_state[0..n_state], 0);

    const kwargs: [*c]const Obj = args + n_args;

    // var_pos_kw_args points to the stack where the var-args tuple, and
    // var-kw dict, should go. Tracked as a signed index into code_state_state
    // so the `*var_pos_kw_args-- = ...` pattern works.
    var vpk_idx: isize = @as(isize, @intCast(n_state)) - 1 - @as(isize, @intCast(n_pos_args)) - @as(isize, @intCast(n_kwonly_args));

    // check positional arguments

    if (n_args > n_pos_args) {
        if ((scope_flags & MP_SCOPE_FLAG_VARARGS) == 0) {
            mp_arg_error_terse_mismatch_polled();
            return;
        }
        code_state_state[@intCast(vpk_idx)] = mp_obj_new_tuple(n_args - n_pos_args, args + n_pos_args);
        vpk_idx -= 1;
        n_args = n_pos_args;
    } else {
        if ((scope_flags & MP_SCOPE_FLAG_VARARGS) != 0) {
            code_state_state[@intCast(vpk_idx)] = @intFromPtr(&mp_const_empty_tuple_obj);
            vpk_idx -= 1;
        }
        // Apply processing and check below only if we don't have kwargs,
        // otherwise, kw handling code below has own extensive checks.
        if (n_kw == 0 and (scope_flags & MP_SCOPE_FLAG_DEFKWARGS) == 0) {
            // n_pos_args - n_def_pos_args is always >= 0 by construction
            // (def args are a suffix of positional args).
            if (n_args >= n_pos_args - n_def_pos_args) {
                const extra = self.extraArgsPtr();
                var i: usize = n_args;
                while (i < n_pos_args) : (i += 1) {
                    code_state_state[n_state - 1 - i] = extra[i - (n_pos_args - n_def_pos_args)];
                }
            } else {
                mp_arg_error_terse_mismatch_polled();
                return;
            }
        }
    }

    // copy positional args into state
    {
        var i: usize = 0;
        while (i < n_args) : (i += 1) {
            code_state_state[n_state - 1 - i] = args[i];
        }
    }

    // check keyword arguments
    if (n_kw != 0 or (scope_flags & MP_SCOPE_FLAG_DEFKWARGS) != 0) {
        var dict: Obj = 0; // MP_OBJ_NULL
        if ((scope_flags & MP_SCOPE_FLAG_VARKEYWORDS) != 0) {
            dict = mp_obj_new_dict(n_kw);
            code_state_state[@intCast(vpk_idx)] = dict;
        }

        const qstr_table: [*]const u16 = @ptrFromInt(self.contextPtr().constants.qstr_table_or_source_file);

        var i: usize = 0;
        kw_outer: while (i < n_kw) : (i += 1) {
            const wanted_arg_name: Obj = kwargs[2 * i];

            // arg_names = mp_decode_uint_skip(code_state->ip) — skip simple_name qstr.
            var arg_names: [*]const Byte = decodeUintSkip(code_state.ip);

            var j: usize = 0;
            const n_named = n_pos_args + n_kwonly_args;
            while (j < n_named) : (j += 1) {
                var arg_qstr = decodeUint(&arg_names);
                arg_qstr = qstr_table[arg_qstr];
                if (wanted_arg_name == mirrors.objFromQstr(arg_qstr)) {
                    if (code_state_state[n_state - 1 - j] != 0) {
                        // error_multiple
                        pyerr.pending_exc = mp_obj_new_exception_msg_varg(
                            &mp_type_TypeError,
                            "function got multiple values for argument '%q'",
                            @as(usize, mirrors.qstrValue(wanted_arg_name)),
                        );
                        return;
                    }
                    code_state_state[n_state - 1 - j] = kwargs[2 * i + 1];
                    continue :kw_outer;
                }
            }
            // Didn't find name match with positional args
            if ((scope_flags & MP_SCOPE_FLAG_VARKEYWORDS) == 0) {
                // TERSE form (MICROPY_ERROR_REPORTING_TERSE)
                setTypeError("unexpected keyword argument");
                return;
            }
            const map_ptr: *mirrors.MpMap = &mirrors.MpObjDict.fromObj(dict).map;
            const elem = mirrors.mp_map_lookup(map_ptr, wanted_arg_name, MP_MAP_LOOKUP_ADD_IF_NOT_FOUND).?;
            if (elem.value == 0) {
                elem.value = kwargs[2 * i + 1];
            } else {
                // error_multiple (jumped to from goto in C)
                pyerr.pending_exc = mp_obj_new_exception_msg_varg(
                    &mp_type_TypeError,
                    "function got multiple values for argument '%q'",
                    @as(usize, mirrors.qstrValue(wanted_arg_name)),
                );
                return;
            }
        }

        // fill in defaults for positional args
        // C: mp_obj_t *d = &code_state_state[n_state - n_pos_args];
        //    mp_obj_t *s = &self->extra_args[n_def_pos_args - 1];
        //    for (i = n_def_pos_args; i > 0; i--, d++, s--) ...
        const extra = self.extraArgsPtr();
        var d_idx: usize = n_state - n_pos_args;
        // s_idx starts at n_def_pos_args - 1 and walks down to 0; isize for safety.
        {
            var s_idx: isize = @as(isize, @intCast(n_def_pos_args)) - 1;
            var k: usize = n_def_pos_args;
            while (k > 0) : (k -= 1) {
                if (code_state_state[d_idx] == 0) {
                    code_state_state[d_idx] = extra[@intCast(s_idx)];
                }
                d_idx += 1;
                s_idx -= 1;
            }
        }

        // Check that all mandatory positional args are specified.
        // C: while (d < &code_state_state[n_state]) { if (*d++ == NULL) ... }
        // The `*d++ == NULL` post-increments d, then checks the OLD slot.
        // The argument-number formula: &code_state_state[n_state] - d (post-inc).
        while (d_idx < n_state) {
            const old_d = d_idx;
            d_idx += 1;
            if (code_state_state[old_d] == 0) {
                // arg #N = n_state - d (after post-increment) — i.e. n_state - d_idx.
                pyerr.pending_exc = mp_obj_new_exception_msg_varg(
                    &mp_type_TypeError,
                    "function missing required positional argument #%d",
                    @as(isize, @intCast(n_state)) - @as(isize, @intCast(d_idx)),
                );
                return;
            }
        }

        // Check that all mandatory keyword args are specified
        // Fill in default kw args if we have them.
        // C: arg_names = mp_decode_uint_skip(code_state->ip);
        var arg_names2: [*]const Byte = decodeUintSkip(code_state.ip);
        {
            var k: usize = 0;
            while (k < n_pos_args) : (k += 1) {
                arg_names2 = decodeUintSkip(arg_names2);
            }
        }
        {
            var k: usize = 0;
            while (k < n_kwonly_args) : (k += 1) {
                var arg_qstr = decodeUint(&arg_names2);
                arg_qstr = qstr_table[arg_qstr];
                if (code_state_state[n_state - 1 - n_pos_args - k] == 0) {
                    var found: ?*mirrors.MpMap.Elem = null;
                    if ((scope_flags & MP_SCOPE_FLAG_DEFKWARGS) != 0) {
                        const def_kw_dict_obj = extra[n_def_pos_args];
                        const def_kw_dict = mirrors.MpObjDict.fromObj(def_kw_dict_obj);
                        found = mirrors.mp_map_lookup(&def_kw_dict.map, mirrors.objFromQstr(arg_qstr), MP_MAP_LOOKUP);
                    }
                    if (found) |fe| {
                        code_state_state[n_state - 1 - n_pos_args - k] = fe.value;
                    } else {
                        pyerr.pending_exc = mp_obj_new_exception_msg_varg(
                            &mp_type_TypeError,
                            "function missing required keyword argument '%q'",
                            @as(usize, arg_qstr),
                        );
                        return;
                    }
                }
            }
        }
    } else {
        // no keyword arguments given
        if (n_kwonly_args != 0) {
            setTypeError("function missing keyword-only argument");
            return;
        }
        if ((scope_flags & MP_SCOPE_FLAG_VARKEYWORDS) != 0) {
            code_state_state[@intCast(vpk_idx)] = mp_obj_new_dict(0);
        }
    }

    // jump over code info (source file, argument names and line-number mapping)
    var ip2: [*]const Byte = code_state.ip + n_info;

    // bytecode prelude: initialise closed over variables
    {
        var c = n_cell;
        while (c != 0) : (c -= 1) {
            const local_num: usize = ip2[0];
            ip2 += 1;
            const cell_in = code_state_state[n_state - 1 - local_num];
            code_state_state[n_state - 1 - local_num] = mp_obj_new_cell(cell_in);
        }
    }

    // now that we skipped over the prelude, set the ip for the VM
    code_state.ip = ip2;
}

comptime {
    _ = &mp_encode_uint;
    _ = &mp_decode_uint;
    _ = &mp_decode_uint_value;
    _ = &mp_decode_uint_skip;
    _ = &mp_setup_code_state;
    _ = &mp_setup_code_state_helper;
}
