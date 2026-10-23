//! petitpy — Zig port of py/binary.c.
//! 8 class-A exports, 0 nlr-hosts. Binary-verified LIVE (array/struct
//! backends). Nano-specialised (probed): MP_ENDIANNESS_LITTLE=1,
//! MP_BYTES_PER_OBJ_WORD=8, FLOAT=0 (half-float + e/f/d *value*
//! branches dead; their SIZES stay — struct layout), LONGINT_IMPL=
//! NONE (q/Q value + int_to_bytes_impl/exact-int paths dead),
//! STRUCT_UNSAFE_TYPECODES=1 (O/P/S live). Widths from Zig
//! @sizeOf/@alignOf(c_*) (ABI-exact, not transcribed). Faithful
//! (lesson #6): C integer narrowing on store = `@truncate` of the
//! 2's-complement bits; endianness byte-loops mirrored exactly;
//! is_signed(tc)=(tc>'Z').

const mp = @cImport({
    @cInclude("py/binary.h");
    @cInclude("py/mpconfig.h");
});
const mirrors = @import("../../mp_mirrors.zig");
const pyerr = @import("../../pyerr.zig");
const PyError = pyerr.PyError;
const Obj = mirrors.Obj;

// Stage replacement for binary_api.h:
extern fn mp_obj_new_exception_msg(t: *const anyopaque, msg: [*:0]const u8) callconv(.c) Obj;
extern const mp_type_ValueError: anyopaque;
extern const mp_type_int: anyopaque;
const SMALLINT_MIN: c_longlong = mirrors.SMALL_INT_MIN;
const SMALLINT_MAX: c_longlong = mirrors.SMALL_INT_MAX;

// Cleanup pass: retire pure pass-through npy_bin_* wrappers.
extern fn mp_obj_new_int(v: isize) callconv(.c) Obj;
extern fn mp_obj_new_int_from_uint(v: usize) callconv(.c) Obj;
extern fn mp_obj_new_int_from_ll(v: c_longlong) callconv(.c) Obj;
extern fn mp_obj_new_int_from_ull(v: c_ulonglong) callconv(.c) Obj;
extern fn mp_obj_new_str_from_cstr(s: [*:0]const u8) callconv(.c) Obj;
extern fn mp_obj_get_int(o: Obj) callconv(.c) isize;
// MPZ-only: bignum serializer (vendor objint_mpz.c). Used by set_val{,_array}
// when val_in is an exact-int that exceeds small-int range.
extern fn mp_obj_int_to_bytes_impl(self_in: Obj, big_endian: bool, len: usize, buf: [*c]u8) callconv(.c) bool;
const build_options = @import("build_options");

inline fn isSigned(tc: u8) bool {
    return tc > 'Z';
}

fn raiseBadTypecode() PyError!void {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_ValueError, "bad typecode");
    return error.PyRaise;
}

fn mpBinaryGetSizeImpl(struct_type: u8, val_type: u8, palign: [*c]usize) PyError!usize {
    var size: usize = 0;
    var al: c_int = 1;
    if (struct_type == '<' or struct_type == '>') {
        switch (val_type) {
            'b', 'B' => size = 1,
            'h', 'H' => size = 2,
            'i', 'I' => size = 4,
            'l', 'L' => size = 4,
            'q', 'Q' => size = 8,
            'P', 'O', 'S' => size = @sizeOf(?*anyopaque), // STRUCT_UNSAFE=1
            'e' => size = 2,
            'f' => size = 4,
            'd' => size = 8,
            else => {},
        }
    } else if (struct_type == '@') {
        const BA: u8 = @intCast(mp.BYTEARRAY_TYPECODE);
        if (val_type == BA or val_type == 'b' or val_type == 'B') {
            al = 1;
            size = 1;
        } else if (val_type == 'h' or val_type == 'H') {
            al = @alignOf(c_short);
            size = @sizeOf(c_short);
        } else if (val_type == 'i' or val_type == 'I') {
            al = @alignOf(c_int);
            size = @sizeOf(c_int);
        } else if (val_type == 'l' or val_type == 'L') {
            al = @alignOf(c_long);
            size = @sizeOf(c_long);
        } else if (val_type == 'q' or val_type == 'Q') {
            al = @alignOf(c_longlong);
            size = @sizeOf(c_longlong);
        } else if (val_type == 'P' or val_type == 'O' or val_type == 'S') {
            al = @alignOf(?*anyopaque);
            size = @sizeOf(?*anyopaque);
        } else if (val_type == 'e') {
            al = 2;
            size = 2;
        } else if (val_type == 'f') {
            al = @alignOf(f32);
            size = @sizeOf(f32);
        } else if (val_type == 'd') {
            al = @alignOf(f64);
            size = @sizeOf(f64);
        }
    }
    if (size == 0) {
        try raiseBadTypecode();
        unreachable;
    }
    if (palign != null) palign[0] = @intCast(al);
    return size;
}
export fn mp_binary_get_size(struct_type: u8, val_type: u8, palign: [*c]usize) usize {
    return pyerr.bridge(usize, mpBinaryGetSizeImpl(struct_type, val_type, palign));
}

export fn mp_binary_get_val_array(typecode: u8, p: ?*anyopaque, index: usize) Obj {
    var val: isize = 0;
    const BA: u8 = @intCast(mp.BYTEARRAY_TYPECODE);
    if (typecode == 'b') {
        val = @as([*c]i8, @ptrCast(@alignCast(p)))[index];
    } else if (typecode == BA or typecode == 'B') {
        val = @as([*c]u8, @ptrCast(@alignCast(p)))[index];
    } else if (typecode == 'h') {
        val = @as([*c]c_short, @ptrCast(@alignCast(p)))[index];
    } else if (typecode == 'H') {
        val = @as([*c]c_ushort, @ptrCast(@alignCast(p)))[index];
    } else if (typecode == 'i') {
        return mp_obj_new_int(@as([*c]c_int, @ptrCast(@alignCast(p)))[index]);
    } else if (typecode == 'I') {
        return mp_obj_new_int_from_uint(@as([*c]c_uint, @ptrCast(@alignCast(p)))[index]);
    } else if (typecode == 'l') {
        return mp_obj_new_int(@as([*c]c_long, @ptrCast(@alignCast(p)))[index]);
    } else if (typecode == 'L') {
        return mp_obj_new_int_from_uint(@as([*c]c_ulong, @ptrCast(@alignCast(p)))[index]);
    } else if (build_options.is_full and typecode == 'q') {
        return mp_obj_new_int_from_ll(@as([*c]c_longlong, @ptrCast(@alignCast(p)))[index]);
    } else if (build_options.is_full and typecode == 'Q') {
        return mp_obj_new_int_from_ull(@as([*c]c_ulonglong, @ptrCast(@alignCast(p)))[index]);
    } else if (typecode == 'O') { // STRUCT_UNSAFE=1
        return @as([*c]Obj, @ptrCast(@alignCast(p)))[index];
    } else if (typecode == 'P') {
        return mp_obj_new_int(@bitCast(@intFromPtr(@as([*c]?*anyopaque, @ptrCast(@alignCast(p)))[index])));
    }
    return mirrors.newSmallInt(val);
}

export fn mp_binary_get_int(size: usize, is_sgn: bool, big_endian: bool, src_in: [*c]const u8) c_longlong {
    if (size == 0) return 0; // C wraps size-1 to SIZE_MAX and skips the loop; Zig safe-checks would panic.
    var src = src_in;
    var delta: isize = undefined;
    if (!big_endian) {
        delta = -1;
        src += size - 1;
    } else {
        delta = 1;
    }
    var val: u64 = 0;
    if (is_sgn and (src[0] & 0x80) != 0) {
        val = ~@as(u64, 0);
    }
    var i: usize = 0;
    while (i < size) : (i += 1) {
        val <<= 8;
        val |= src[0];
        src = if (delta == 1) src + 1 else src - 1;
    }
    return @bitCast(val);
}

export fn mp_binary_set_int(val_sz: usize, big_endian: bool, dest: [*c]u8, val: usize) void {
    var v = val;
    const vb: [*]u8 = @ptrCast(&v);
    if (!big_endian) { // MP_ENDIANNESS_LITTLE && !big_endian
        @memcpy(dest[0..val_sz], vb[0..val_sz]);
    } else { // else-branch, LITTLE: src = &val + val_sz; while(sz--) *d++=*--src
        var sz = val_sz;
        var d = dest;
        var s = vb + val_sz;
        while (sz != 0) : (sz -%= 1) {
            s -= 1;
            d[0] = s[0];
            d += 1;
        }
    }
}

inline fn mpAlign(ptr: usize, alignment: usize) usize {
    return (ptr + (alignment - 1)) & ~(alignment - 1);
}

export fn mp_binary_get_val(struct_type_in: u8, val_type: u8, p_base: [*c]u8, ptr: [*c][*c]u8) Obj {
    var p = ptr[0];
    var struct_type = struct_type_in;
    var al: usize = undefined;
    const size = mp_binary_get_size(struct_type, val_type, &al);
    if (struct_type == '@') {
        const off = @intFromPtr(p) - @intFromPtr(p_base);
        p = p_base + mpAlign(off, al);
        struct_type = '<'; // MP_ENDIANNESS_LITTLE
    }
    ptr[0] = p + size;
    const v = mp_binary_get_int(size, isSigned(val_type), struct_type == '>', p);
    if (val_type == 'O') { // STRUCT_UNSAFE=1
        // wasm32 has 32-bit usize; truncate c_longlong (64-bit) to usize first.
        return @bitCast(@as(isize, @truncate(v))); // (mp_obj_t)(mp_uint_t)val — raw bits
    } else if (val_type == 'S') {
        return mp_obj_new_str_from_cstr(@ptrFromInt(@as(usize, @truncate(@as(c_ulonglong, @bitCast(v))))));
    } else if (isSigned(val_type)) {
        if (SMALLINT_MIN <= v and v <= SMALLINT_MAX) {
            return mp_obj_new_int(@truncate(v));
        } else {
            return mp_obj_new_int_from_ll(v);
        }
    } else {
        const uv: u64 = @bitCast(v);
        if (uv <= @as(u64, @bitCast(@as(i64, SMALLINT_MAX)))) {
            return mp_obj_new_int_from_uint(@truncate(uv));
        } else {
            return mp_obj_new_int_from_ull(uv);
        }
    }
}

export fn mp_binary_set_val(struct_type_in: u8, val_type: u8, val_in: Obj, p_base: [*c]u8, ptr: [*c][*c]u8) void {
    var p = ptr[0];
    var struct_type = struct_type_in;
    var al: usize = undefined;
    const size = mp_binary_get_size(struct_type, val_type, &al);
    if (struct_type == '@') {
        const off = @intFromPtr(p) - @intFromPtr(p_base);
        p = p_base + mpAlign(off, al);
        struct_type = '<';
    }
    ptr[0] = p + size;
    var val: usize = undefined;
    if (val_type == 'O') { // STRUCT_UNSAFE=1
        val = @intCast(val_in);
    } else {
        // Under MPZ: a heap-int (exact mp_type_int) bypasses the small-int
        // path and writes directly via mp_obj_int_to_bytes_impl. Else fall
        // back to mp_obj_get_int (handles bool, small_int).
        if (build_options.is_full and mirrors.isExactType(val_in, &mp_type_int)) {
            _ = mp_obj_int_to_bytes_impl(val_in, struct_type == '>', size, p);
            return;
        }
        val = @bitCast(@as(isize, mp_obj_get_int(val_in)));
    }
    const m = if (size < @sizeOf(usize)) size else @sizeOf(usize); // MIN
    mp_binary_set_int(m, struct_type == '>', p, val);
}

export fn mp_binary_set_val_array(typecode: u8, p: ?*anyopaque, index: usize, val_in: Obj) void {
    if (typecode == 'O') { // STRUCT_UNSAFE=1 (FLOAT f/d dead)
        @as([*c]Obj, @ptrCast(@alignCast(p)))[index] = val_in;
    } else {
        if (build_options.is_full and mirrors.isExactType(val_in, &mp_type_int)) {
            var dummy_al: usize = undefined;
            const size = mp_binary_get_size('@', typecode, &dummy_al);
            // MP_ENDIANNESS_BIG=0 on x86_64/wasm32 (LE host); pass false.
            _ = mp_obj_int_to_bytes_impl(val_in, false, size, @as([*c]u8, @ptrCast(p)) + index * size);
            return;
        }
        mp_binary_set_val_array_from_int(typecode, p, index, mp_obj_get_int(val_in));
    }
}

export fn mp_binary_set_val_array_from_int(typecode: u8, p: ?*anyopaque, index: usize, val: isize) void {
    const BA: u8 = @intCast(mp.BYTEARRAY_TYPECODE);
    if (typecode == 'b') {
        @as([*c]i8, @ptrCast(@alignCast(p)))[index] = @truncate(val);
    } else if (typecode == BA or typecode == 'B') {
        @as([*c]u8, @ptrCast(@alignCast(p)))[index] = @truncate(@as(usize, @bitCast(val)));
    } else if (typecode == 'h') {
        @as([*c]c_short, @ptrCast(@alignCast(p)))[index] = @truncate(val);
    } else if (typecode == 'H') {
        @as([*c]c_ushort, @ptrCast(@alignCast(p)))[index] = @truncate(@as(usize, @bitCast(val)));
    } else if (typecode == 'i') {
        @as([*c]c_int, @ptrCast(@alignCast(p)))[index] = @truncate(val);
    } else if (typecode == 'I') {
        @as([*c]c_uint, @ptrCast(@alignCast(p)))[index] = @truncate(@as(usize, @bitCast(val)));
    } else if (typecode == 'l') {
        @as([*c]c_long, @ptrCast(@alignCast(p)))[index] = @truncate(val);
    } else if (typecode == 'L') {
        @as([*c]c_ulong, @ptrCast(@alignCast(p)))[index] = @truncate(@as(usize, @bitCast(val)));
    } else if (typecode == 'P') { // STRUCT_UNSAFE=1
        @as([*c]?*anyopaque, @ptrCast(@alignCast(p)))[index] = @ptrFromInt(@as(usize, @bitCast(val)));
    } else if (build_options.is_full and (typecode == 'q' or typecode == 'Q')) {
        // MPZ: long long array elements (only meaningful for small-int values
        // that fit in mp_int_t; the bigint path is taken above in set_val_array).
        @as([*c]c_longlong, @ptrCast(@alignCast(p)))[index] = @intCast(val);
    }
}

comptime {
    for (.{
        &mp_binary_get_size,      &mp_binary_get_val_array,
        &mp_binary_get_int,       &mp_binary_set_int,
        &mp_binary_get_val,       &mp_binary_set_val,
        &mp_binary_set_val_array, &mp_binary_set_val_array_from_int,
    }) |f| {
        _ = f;
    }
}
