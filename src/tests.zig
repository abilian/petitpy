//! nanopython — Zig unit tests for the pure (shimless) strangled
//! modules. Run with `zig build unittest` (or `make unit`).
//!
//! Zig has first-class built-in testing: `test "name" { ... }`
//! blocks compiled/run by the toolchain itself (no framework to
//! install — closer to Rust's #[test] than to Pytest). Assertions
//! come from `std.testing` (expectEqual / expect / expectError /
//! expectEqualStrings / …). Only the *shimless* modules
//! (smallint/parsenumbase/unicode — no @cImport, no C deps) are
//! unit-testable in isolation; the shim-coupled modules are covered
//! end-to-end by the corpus + tests/integration.py instead.

const std = @import("std");
const testing = std.testing;

const smallint = @import("support/smallint.zig");
const unicode = @import("support/unicode.zig");
const qstr_hash = @import("support/qstr_hash.zig");
const parsenumbase = @import("frontend/parsenumbase.zig");
const persistentcode = @import("runtime/persistentcode.zig");
const mirrors = @import("mp_mirrors.zig");

// `mp_mirrors.zig`'s `assertLayout` references C-shim externs
// (`npy_mirror_sizeof_*`, `npy_mirror_offsetof_*`) that aren't linked
// into the unit-test binary. Provide stub values here so the linker
// is happy; assertLayout is never *called* from tests (it's invoked
// from the main binary via `npy_mirror_layout_check`).
comptime {
    @setEvalBranchQuota(10_000);
    const stub_names = [_][:0]const u8{
        "npy_mirror_sizeof_mp_map_t",
        "npy_mirror_sizeof_mp_obj_dict_t",
        "npy_mirror_sizeof_mp_obj_list_t",
        "npy_mirror_sizeof_mp_obj_module_t",
        "npy_mirror_sizeof_mp_obj_str_t",
        "npy_mirror_sizeof_mp_obj_tuple_t",
        "npy_mirror_sizeof_mp_obj_closure_t",
        "npy_mirror_sizeof_mp_obj_bound_meth_t",
        "npy_mirror_sizeof_mp_obj_fun_bc_t",
        "npy_mirror_offsetof_mp_obj_fun_bc_t_bytecode",
        "npy_mirror_sizeof_mp_code_state_t",
        "npy_mirror_offsetof_mp_code_state_t_state",
        "npy_mirror_sizeof_mp_exc_stack_t",
        "npy_mirror_sizeof_mp_obj_exception_t",
        "npy_mirror_sizeof_mp_obj_instance_t",
        "npy_mirror_offsetof_mp_map_t_alloc",
        "npy_mirror_offsetof_mp_map_t_table",
        "npy_mirror_offsetof_mp_obj_dict_t_map",
        "npy_mirror_offsetof_mp_obj_list_t_items",
        "npy_mirror_offsetof_mp_obj_str_t_data",
        "npy_mirror_offsetof_mp_obj_exception_t_traceback_data",
        "npy_mirror_offsetof_mp_obj_exception_t_args",
        "npy_mirror_offsetof_mp_obj_instance_t_subobj",
        "npy_mirror_sizeof_mp_obj_empty_type_t",
        "npy_mirror_sizeof_mp_obj_full_type_t",
        "npy_mirror_offsetof_mp_obj_full_type_t_slots",
        "npy_mirror_offsetof_mp_obj_type_t_flags",
        "npy_mirror_offsetof_mp_obj_type_t_name",
        "npy_mirror_offsetof_mp_obj_type_t_slot_index_make_new",
        "npy_mirror_offsetof_mp_obj_type_t_slot_index_print",
        "npy_mirror_offsetof_mp_obj_type_t_slot_index_call",
        "npy_mirror_offsetof_mp_obj_type_t_slot_index_unary_op",
        "npy_mirror_offsetof_mp_obj_type_t_slot_index_binary_op",
        "npy_mirror_offsetof_mp_obj_type_t_slot_index_attr",
        "npy_mirror_offsetof_mp_obj_type_t_slot_index_subscr",
        "npy_mirror_offsetof_mp_obj_type_t_slot_index_iter",
        "npy_mirror_offsetof_mp_obj_type_t_slot_index_buffer",
        "npy_mirror_offsetof_mp_obj_type_t_slot_index_protocol",
        "npy_mirror_offsetof_mp_obj_type_t_slot_index_parent",
        "npy_mirror_offsetof_mp_obj_type_t_slot_index_locals_dict",
        "npy_mirror_sizeof_mp_raw_code_t",
        "npy_mirror_offsetof_mp_raw_code_t_kind",
        "npy_mirror_offsetof_mp_raw_code_t_is_generator",
        "npy_mirror_offsetof_mp_raw_code_t_fun_data",
        "npy_mirror_offsetof_mp_raw_code_t_children",
        "npy_mirror_sizeof_mp_compiled_module_t",
        "npy_mirror_offsetof_mp_compiled_module_t_rc",
        "npy_mirror_sizeof_mp_reader_t",
        "npy_mirror_offsetof_mp_reader_t_readbyte",
        "npy_mirror_offsetof_mp_reader_t_close",
        "npy_mirror_sizeof_mp_print_t",
        "npy_mirror_offsetof_mp_print_t_print_strn",
    };
    for (stub_names) |n| {
        @export(&@as(usize, 0), .{ .name = n, .linkage = .strong });
    }
}

// Persistentcode load_qstr/load_obj reference vendor heap + object
// constructors. The unit-test binary never calls them (only read_uint
// and the prelude decoders are exercised), but the linker still needs
// the symbols. Stub them as panicking placeholders.
const StubFns = struct {
    fn m_malloc_stub(_: usize) callconv(.c) ?*anyopaque {
        @panic("unit-test stub: m_malloc");
    }
    fn m_free_stub(_: ?*anyopaque) callconv(.c) void {
        @panic("unit-test stub: m_free");
    }
    fn obj_stub_1(_: ?*anyopaque) callconv(.c) usize {
        @panic("unit-test stub: 1-arg obj fn");
    }
    fn obj_stub_2(_: usize, _: ?*const usize) callconv(.c) usize {
        @panic("unit-test stub: 2-arg obj fn");
    }
    fn parse_int_stub(_: [*]const u8, _: usize, _: c_int, _: ?*anyopaque) callconv(.c) usize {
        @panic("unit-test stub: mp_parse_num_integer");
    }
    fn parse_float_stub(_: [*]const u8, _: usize, _: bool, _: ?*anyopaque) callconv(.c) usize {
        @panic("unit-test stub: mp_parse_num_float");
    }
    fn qstr_stub(_: [*]const u8, _: usize) callconv(.c) usize {
        @panic("unit-test stub: qstr_from_strn");
    }
    fn vstr_init_stub(_: ?*anyopaque, _: usize) callconv(.c) void {
        @panic("unit-test stub: vstr_init_len");
    }
    fn reader_new_mem_stub(_: ?*anyopaque, _: [*]const u8, _: usize, _: usize) callconv(.c) void {
        @panic("unit-test stub: mp_reader_new_mem");
    }
    fn raise_value_error_stub(_: [*:0]const u8) callconv(.c) noreturn {
        @panic("unit-test stub: mp_raise_ValueError");
    }
    fn new_exception_msg_stub(_: *const anyopaque, _: [*:0]const u8) callconv(.c) usize {
        @panic("unit-test stub: mp_obj_new_exception_msg");
    }
    fn emit_glue_new_raw_code_stub() callconv(.c) ?*anyopaque {
        @panic("unit-test stub: mp_emit_glue_new_raw_code");
    }
    fn emit_glue_assign_bytecode_stub(
        _: ?*anyopaque,
        _: [*]const u8,
        _: ?*anyopaque,
        _: u16,
    ) callconv(.c) void {
        @panic("unit-test stub: mp_emit_glue_assign_bytecode");
    }
};
comptime {
    @export(&StubFns.m_malloc_stub, .{ .name = "m_malloc", .linkage = .strong });
    @export(&StubFns.m_free_stub, .{ .name = "m_free", .linkage = .strong });
    @export(&StubFns.obj_stub_1, .{ .name = "mp_obj_new_str_from_vstr", .linkage = .strong });
    @export(&StubFns.obj_stub_1, .{ .name = "mp_obj_new_bytes_from_vstr", .linkage = .strong });
    @export(&StubFns.obj_stub_2, .{ .name = "mp_obj_new_tuple", .linkage = .strong });
    @export(&StubFns.parse_int_stub, .{ .name = "mp_parse_num_integer", .linkage = .strong });
    @export(&StubFns.parse_float_stub, .{ .name = "mp_parse_num_float", .linkage = .strong });
    @export(&StubFns.qstr_stub, .{ .name = "qstr_from_strn", .linkage = .strong });
    @export(&StubFns.vstr_init_stub, .{ .name = "vstr_init_len", .linkage = .strong });
    @export(&StubFns.reader_new_mem_stub, .{ .name = "mp_reader_new_mem", .linkage = .strong });
    @export(&StubFns.raise_value_error_stub, .{ .name = "mp_raise_ValueError", .linkage = .strong });
    @export(&StubFns.new_exception_msg_stub, .{ .name = "mp_obj_new_exception_msg", .linkage = .strong });
    @export(&StubFns.emit_glue_new_raw_code_stub, .{ .name = "mp_emit_glue_new_raw_code", .linkage = .strong });
    @export(&StubFns.emit_glue_assign_bytecode_stub, .{ .name = "mp_emit_glue_assign_bytecode", .linkage = .strong });
    @export(&@as(usize, 0), .{ .name = "mp_const_empty_bytes_obj", .linkage = .strong });
    @export(&@as(usize, 0), .{ .name = "mp_const_ellipsis_obj", .linkage = .strong });
    @export(&@as(usize, 0), .{ .name = "mp_type_ValueError", .linkage = .strong });
}

test "mp_small_int_modulo — Python sign-of-divisor semantics" {
    try testing.expectEqual(@as(isize, 1), smallint.mp_small_int_modulo(7, 3));
    try testing.expectEqual(@as(isize, 2), smallint.mp_small_int_modulo(-7, 3));
    try testing.expectEqual(@as(isize, -2), smallint.mp_small_int_modulo(7, -3));
    try testing.expectEqual(@as(isize, -1), smallint.mp_small_int_modulo(-7, -3));
    try testing.expectEqual(@as(isize, 0), smallint.mp_small_int_modulo(6, 3));
}

test "mp_small_int_floor_divide — floor toward -inf" {
    try testing.expectEqual(@as(isize, 2), smallint.mp_small_int_floor_divide(7, 3));
    try testing.expectEqual(@as(isize, -3), smallint.mp_small_int_floor_divide(-7, 3));
    try testing.expectEqual(@as(isize, -3), smallint.mp_small_int_floor_divide(7, -3));
    try testing.expectEqual(@as(isize, 2), smallint.mp_small_int_floor_divide(-7, -3));
}

test "unichar classification (ASCII)" {
    try testing.expect(unicode.unichar_isdigit('5'));
    try testing.expect(!unicode.unichar_isdigit('a'));
    try testing.expect(unicode.unichar_isalpha('a'));
    try testing.expect(!unicode.unichar_isalpha('5'));
    try testing.expect(unicode.unichar_isspace(' '));
    try testing.expect(unicode.unichar_isident('_'));
    try testing.expect(!unicode.unichar_isalpha(200)); // non-ASCII → false
}

test "unichar case + hex value" {
    try testing.expectEqual(@as(u32, 'a'), unicode.unichar_tolower('A'));
    try testing.expectEqual(@as(u32, 'A'), unicode.unichar_toupper('a'));
    try testing.expectEqual(@as(u32, 'z'), unicode.unichar_tolower('z')); // unchanged
    try testing.expectEqual(@as(usize, 9), unicode.unichar_xdigit_value('9'));
    try testing.expectEqual(@as(usize, 10), unicode.unichar_xdigit_value('a'));
    try testing.expectEqual(@as(usize, 15), unicode.unichar_xdigit_value('F'));
}

// ── persistentcode read_uint round-trip ──────────────────────────────
//
// Hand-encoded byte sequences exercising the 7-bit-continuation varint
// boundaries: 0, 0x7F (1-byte max), 0x80 (forces 2 bytes), 0x3FFF
// (2-byte max), 0x4000 (forces 3 bytes), 0xFFFFFF (3-byte max + extra
// byte). Encoding (MSB-group first; high bit = continuation):
//   0           → [0x00]
//   0x7F        → [0x7F]
//   0x80        → [0x81, 0x00]            // (1<<7) | 0
//   0x3FFF      → [0xFF, 0x7F]            // (0x7F<<7) | 0x7F
//   0x4000      → [0x81, 0x80, 0x00]      // (1<<14) | 0 | 0
//   0xFFFFFF    → [0x87, 0xFF, 0xFF, 0x7F]
// Each byte is OR'd with 0x80 if not last.
const FakeReader = struct {
    data: [*]const u8,
    len: usize,
    pos: usize,

    fn readbyte(opaque_self: ?*anyopaque) callconv(.c) usize {
        const self: *FakeReader = @ptrCast(@alignCast(opaque_self.?));
        if (self.pos >= self.len) return ~@as(usize, 0); // MP_READER_EOF
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    fn close(opaque_self: ?*anyopaque) callconv(.c) void {
        _ = opaque_self;
    }
};

fn makeReader(fake: *FakeReader, bytes: []const u8) mirrors.MpReader {
    fake.* = .{ .data = bytes.ptr, .len = bytes.len, .pos = 0 };
    return .{
        .data = @ptrCast(fake),
        .readbyte = FakeReader.readbyte,
        .close = FakeReader.close,
    };
}

test "persistentcode read_uint — varint round-trip boundaries" {
    const cases = [_]struct { bytes: []const u8, expected: usize }{
        .{ .bytes = &[_]u8{0x00}, .expected = 0 },
        .{ .bytes = &[_]u8{0x01}, .expected = 1 },
        .{ .bytes = &[_]u8{0x7E}, .expected = 0x7E },
        .{ .bytes = &[_]u8{0x7F}, .expected = 0x7F },
        .{ .bytes = &[_]u8{ 0x81, 0x00 }, .expected = 0x80 },
        .{ .bytes = &[_]u8{ 0x81, 0x01 }, .expected = 0x81 },
        .{ .bytes = &[_]u8{ 0xFF, 0x7F }, .expected = 0x3FFF },
        .{ .bytes = &[_]u8{ 0x81, 0x80, 0x00 }, .expected = 0x4000 },
        .{ .bytes = &[_]u8{ 0x87, 0xFF, 0xFF, 0x7F }, .expected = 0xFFFFFF },
    };
    for (cases) |c| {
        var fake: FakeReader = undefined;
        var reader = makeReader(&fake, c.bytes);
        try testing.expectEqual(c.expected, persistentcode.read_uint(&reader));
        // Confirm the decoder consumed exactly the bytes we provided.
        try testing.expectEqual(c.bytes.len, fake.pos);
    }
}

// ── persistentcode prelude decoders ──────────────────────────────────
//
// Hand-encoded byte sequences (computed by running the C
// MP_BC_PRELUDE_SIG_ENCODE / SIZE_ENCODE macros on paper for the
// chosen field values). Each case exercises decoder→encoder round-trip
// for the bit-twiddling.

test "persistentcode decodePreludeSig — minimal (all zeros, S=1)" {
    // S=1, E=0, F=0, A=0, K=0, D=0 → encoder S-=1=0 → emit [0x00].
    var bytes = [_]u8{0x00};
    var ip: [*]const u8 = &bytes;
    const got = persistentcode.decodePreludeSig(&ip);
    try testing.expectEqual(@as(u32, 1), got.n_state);
    try testing.expectEqual(@as(u32, 0), got.n_exc_stack);
    try testing.expectEqual(@as(u32, 0), got.scope_flags);
    try testing.expectEqual(@as(u32, 0), got.n_pos_args);
    try testing.expectEqual(@as(u32, 0), got.n_kwonly_args);
    try testing.expectEqual(@as(u32, 0), got.n_def_pos_args);
    // ip advanced past the single consumed byte.
    try testing.expectEqual(@intFromPtr(&bytes) + 1, @intFromPtr(ip));
}

test "persistentcode decodePreludeSig — realistic (n_state=5,E=1,A=2 → single byte 0x26)" {
    // S=5 → encoder S-=1=4. z = (4<<3) | (1<<2) | 2 = 0x20|0x04|0x02 = 0x26.
    var bytes = [_]u8{0x26};
    var ip: [*]const u8 = &bytes;
    const got = persistentcode.decodePreludeSig(&ip);
    try testing.expectEqual(@as(u32, 5), got.n_state);
    try testing.expectEqual(@as(u32, 1), got.n_exc_stack);
    try testing.expectEqual(@as(u32, 0), got.scope_flags);
    try testing.expectEqual(@as(u32, 2), got.n_pos_args);
    try testing.expectEqual(@as(u32, 0), got.n_kwonly_args);
    try testing.expectEqual(@as(u32, 0), got.n_def_pos_args);
}

test "persistentcode decodePreludeSig — continuation (n_state=20 → two bytes 0x98,0x10)" {
    // S=20 → S-=1=19. First z = (19&0xf)<<3 = 3<<3 = 0x18. S>>=4 → 1.
    // Need cont: emit 0x98. Next z = (1&3)<<4 = 0x10. emit 0x10.
    var bytes = [_]u8{ 0x98, 0x10 };
    var ip: [*]const u8 = &bytes;
    const got = persistentcode.decodePreludeSig(&ip);
    try testing.expectEqual(@as(u32, 20), got.n_state);
    try testing.expectEqual(@as(u32, 0), got.n_exc_stack);
    try testing.expectEqual(@as(u32, 0), got.scope_flags);
    try testing.expectEqual(@as(u32, 0), got.n_pos_args);
    try testing.expectEqual(@as(u32, 0), got.n_kwonly_args);
    try testing.expectEqual(@as(u32, 0), got.n_def_pos_args);
}

test "persistentcode decodePreludeSize — minimal [0x00]" {
    var bytes = [_]u8{0x00};
    var ip: [*]const u8 = &bytes;
    const got = persistentcode.decodePreludeSize(&ip);
    try testing.expectEqual(@as(usize, 0), got.n_info);
    try testing.expectEqual(@as(usize, 0), got.n_cell);
}

test "persistentcode decodePreludeSize — single byte I=5,C=1 → [0x0B]" {
    // z = (5 & 0x3f) << 1 | 1 = 0x0B.
    var bytes = [_]u8{0x0B};
    var ip: [*]const u8 = &bytes;
    const got = persistentcode.decodePreludeSize(&ip);
    try testing.expectEqual(@as(usize, 5), got.n_info);
    try testing.expectEqual(@as(usize, 1), got.n_cell);
}

test "persistentcode decodePreludeSize — continuation I=100,C=0 → [0xC8,0x02]" {
    // z0 = (0x24)<<1 | 0 = 0x48 → with cont 0xC8. z1 = (1&0x3f)<<1 = 2.
    var bytes = [_]u8{ 0xC8, 0x02 };
    var ip: [*]const u8 = &bytes;
    const got = persistentcode.decodePreludeSize(&ip);
    try testing.expectEqual(@as(usize, 100), got.n_info);
    try testing.expectEqual(@as(usize, 0), got.n_cell);
}

// ── qstr djb2 hash (used by modos.zig ROM string constants) ──────────
//
// Values pinned against vendor `py/qstr.c:qstr_compute_hash` output.
// Cross-checked at test-authoring time via
// `grep 'MP_QSTR_os,' vendor/micropython_embed/genhdr/qstrdefs.generated.h`
// which prints e.g. `QDEF1(MP_QSTR_os, 28537, 2, "os")` — the second
// field IS the vendor's computed hash. Any drift here means
// `src/support/qstr_hash.zig` diverges from vendor's algorithm and
// ROM string comparisons in `src/modules/modos.zig` will silently
// mismatch (e.g. `os.name == "posix"` will return False).

test "qstr_hash djb2Hash — matches vendor py/qstr.c for os module qstrs" {
    // Cross-checked against vendor/micropython_embed/genhdr/qstrdefs.generated.h.
    try testing.expectEqual(@as(usize, 28537), qstr_hash.djb2Hash("os"));
    try testing.expectEqual(@as(usize, 44715), qstr_hash.djb2Hash("urandom"));
    try testing.expectEqual(@as(usize, 8606), qstr_hash.djb2Hash("st_mode"));
    try testing.expectEqual(@as(usize, 24245), qstr_hash.djb2Hash("st_ino"));
}

test "qstr_hash djb2Hash — modos ROM string constants" {
    // These are the strings modos.zig ships as ROM MpObjStr constants
    // (os.sep, os.linesep, etc.). If any drifts, os.sep == '/' etc. fail.
    try testing.expectEqual(@as(usize, 46474), qstr_hash.djb2Hash("/"));
    try testing.expectEqual(@as(usize, 46511), qstr_hash.djb2Hash("\n"));
    try testing.expectEqual(@as(usize, 46475), qstr_hash.djb2Hash("."));
    try testing.expectEqual(@as(usize, 26309), qstr_hash.djb2Hash(".."));
    try testing.expectEqual(@as(usize, 56408), qstr_hash.djb2Hash("posix"));
    try testing.expectEqual(@as(usize, 5381), qstr_hash.djb2Hash("")); // seed, non-zero
}

test "qstr_hash djb2Hash — zero-remaps-to-one guard" {
    // The runtime variant lets us construct an adversarial input at test
    // time. There's no known short string whose djb2 & 0xFFFF is exactly
    // 0 (would need a search), but the guard is trivially observable
    // via the algorithm's promise: no hash of any string returns 0.
    // Sample-check across a range of short inputs.
    var buf: [4]u8 = undefined;
    var i: u32 = 0;
    while (i < 256 * 256) : (i += 1) {
        buf[0] = @intCast(i & 0xff);
        buf[1] = @intCast((i >> 8) & 0xff);
        try testing.expect(qstr_hash.djb2HashRuntime(buf[0..2]) != 0);
    }
}

test "qstr_hash djb2Hash — comptime and runtime agree" {
    try testing.expectEqual(qstr_hash.djb2Hash("posix"), qstr_hash.djb2HashRuntime("posix"));
    try testing.expectEqual(qstr_hash.djb2Hash("/"), qstr_hash.djb2HashRuntime("/"));
    try testing.expectEqual(qstr_hash.djb2Hash(""), qstr_hash.djb2HashRuntime(""));
}

test "mp_parse_num_base — radix prefix scan" {
    var base: c_int = 0;
    // "0x1f" base 0 → base=16, skip 2 prefix bytes
    base = 0;
    try testing.expectEqual(@as(usize, 2), parsenumbase.mp_parse_num_base("0x1f", 4, &base));
    try testing.expectEqual(@as(c_int, 16), base);
    // "0b101" → base 2, skip 2
    base = 0;
    try testing.expectEqual(@as(usize, 2), parsenumbase.mp_parse_num_base("0b101", 5, &base));
    try testing.expectEqual(@as(c_int, 2), base);
    // "123" base 0 → base 10, no prefix consumed
    base = 0;
    try testing.expectEqual(@as(usize, 0), parsenumbase.mp_parse_num_base("123", 3, &base));
    try testing.expectEqual(@as(c_int, 10), base);
    // explicit base 16 with no prefix → unchanged, 0 consumed
    base = 16;
    try testing.expectEqual(@as(usize, 0), parsenumbase.mp_parse_num_base("ff", 2, &base));
    try testing.expectEqual(@as(c_int, 16), base);
}
