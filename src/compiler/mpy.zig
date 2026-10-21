// .mpy file format — Zig serializer/deserializer.
//
// Format reference: vendor/micropython_embed/py/persistentcode.{c,h}.
// Tracks MPY_VERSION = 6 (current vendor).
//
// File layout:
//   header (4 bytes):
//     byte 0: 'M' (0x4d) magic
//     byte 1: MPY_VERSION (6)
//     byte 2: native arch + sub-version flags (0 = no native)
//     byte 3: MP_SMALL_INT_BITS (e.g. 31 = 0x1f on 32-bit small int)
//   if arch_flags != 0: vlen arch_flags
//   vlen n_qstr
//   vlen n_obj
//   for each qstr:
//     static: vlen (qstr_id << 1) | 1
//     new:    vlen (len << 1), bytes str[0..len+1] (incl NUL)
//   for each obj: tagged encoding (see ObjKind enum + readObj/writeObj)
//   raw_code (recursive):
//     vlen (fun_data_len << 3) | (has_children << 2) | (kind - MP_CODE_BYTECODE)
//     bytes fun_data[0..fun_data_len]
//     if has_children: vlen n_children, then each child raw_code

const std = @import("std");

pub const MPY_VERSION: u8 = 6;
pub const MPY_MAGIC: u8 = 'M';
pub const QSTR_LAST_STATIC: u16 = 165; // MP_QSTR_zip — zero-based index of MP_QSTR_zip among QDEF0 entries (vendor persistentcode.c:48 `#define QSTR_LAST_STATIC MP_QSTR_zip`). Kept in sync with src/compiler/qstr.zig (a comptime assert there will fire if these drift).

pub const Error = error{
    InvalidMagic,
    InvalidVersion,
    UnexpectedEof,
    UnsupportedFeature,
    OutOfMemory,
};

/// Object kinds in the constants table.
pub const ObjKind = enum(u8) {
    fun_table = 0,
    none = 1,
    false = 2,
    true = 3,
    ellipsis = 4,
    str = 5,
    bytes = 6,
    int = 7,
    float = 8,
    complex = 9,
    tuple = 10,
};

/// A qstr entry in the .mpy file. Either a reference to a static qstr (by id)
/// or a fresh literal string with bytes carried inline.
pub const QstrEntry = union(enum) {
    static: u16,           // id <= QSTR_LAST_STATIC
    new: []const u8,       // bytes (without NUL terminator)
};

/// A constant-table object entry.
pub const ObjEntry = union(enum) {
    none,
    false,
    true,
    ellipsis,
    str: []const u8,           // text (without NUL)
    bytes: []const u8,         // raw bytes (without NUL)
    int: []const u8,           // text representation (vendor uses "TODO" — text-based)
    float: []const u8,         // text representation
    complex: []const u8,
    tuple: []const ObjEntry,
};

/// Raw-code kind tags. Stored as a u2; vendor encodes (kind - BYTECODE) into
/// the .mpy header so BYTECODE itself is the implicit zero offset.
pub const MP_CODE_BYTECODE: u2 = 2;
pub const MP_CODE_NATIVE_PY: u2 = 3;

/// A raw code blob — bytecode (or native code) for one function/scope.
pub const RawCode = struct {
    kind: u2,                  // MP_CODE_BYTECODE=2, NATIVE_PY=3, etc.
    fun_data: []const u8,      // bytecode + prelude
    children: []const RawCode, // nested functions (often empty)
};

/// A complete loaded .mpy file.
pub const Module = struct {
    version: u8,
    feature_flags: u8,
    small_int_bits: u8,
    arch_flags: ?u64,          // present iff (feature_flags & ARCH_FLAGS_BIT) — set during reader if needed
    qstrs: []const QstrEntry,
    objs: []const ObjEntry,
    rc: RawCode,

    /// Free everything allocated by `read()`. Safe to call only on modules
    /// returned by `read()` (not on caller-constructed ones).
    pub fn deinit(self: *const Module, gpa: std.mem.Allocator) void {
        for (self.qstrs) |q| {
            switch (q) {
                .new => |bytes| gpa.free(bytes),
                .static => {},
            }
        }
        gpa.free(self.qstrs);
        deinitObjList(self.objs, gpa);
        gpa.free(self.objs);
        deinitRawCode(&self.rc, gpa);
    }
};

fn deinitObjList(list: []const ObjEntry, gpa: std.mem.Allocator) void {
    for (list) |o| {
        switch (o) {
            .str, .bytes, .int, .float, .complex => |b| gpa.free(b),
            .tuple => |t| { deinitObjList(t, gpa); gpa.free(t); },
            .none, .false, .true, .ellipsis => {},
        }
    }
}

fn deinitRawCode(rc: *const RawCode, gpa: std.mem.Allocator) void {
    gpa.free(rc.fun_data);
    for (rc.children) |child| deinitRawCode(&child, gpa);
    gpa.free(rc.children);
}

// ──────────────────────────────────────────────────────────────────────
// Reader

const Reader = struct {
    data: []const u8,
    pos: usize,

    fn readByte(self: *Reader) Error!u8 {
        if (self.pos >= self.data.len) return Error.UnexpectedEof;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    fn readBytes(self: *Reader, n: usize) Error![]const u8 {
        if (self.pos + n > self.data.len) return Error.UnexpectedEof;
        const slice = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return slice;
    }

    /// Variable-length unsigned int: 7 bits per byte, high bit = continuation.
    /// Big-endian (most significant chunks first).
    fn readUint(self: *Reader) Error!u64 {
        var n: u64 = 0;
        while (true) {
            const b = try self.readByte();
            n = (n << 7) | (b & 0x7f);
            if ((b & 0x80) == 0) break;
        }
        return n;
    }
};

pub fn read(gpa: std.mem.Allocator, data: []const u8) (Error || std.mem.Allocator.Error)!Module {
    var r = Reader{ .data = data, .pos = 0 };

    // Header
    const magic = try r.readByte();
    if (magic != MPY_MAGIC) return Error.InvalidMagic;
    const version = try r.readByte();
    if (version != MPY_VERSION) return Error.InvalidVersion;
    const feature_flags = try r.readByte();
    const small_int_bits = try r.readByte();

    var arch_flags: ?u64 = null;
    // Bit 0 of feature_flags = sub_version (encoded with arch); bit 7 = ARCH_FLAGS.
    // We don't decode the meaning here — just preserve for round-trip. The exact
    // condition for the optional `arch_flags` field is: bit 6 of feature_flags.
    // (vendor: MPY_FEATURE_ARCH_FLAGS = 1 << 6; tested with cm->arch_flags != 0)
    if (feature_flags & 0x40 != 0) {
        arch_flags = try r.readUint();
    }

    const n_qstr = try r.readUint();
    const n_obj = try r.readUint();

    // Qstrs
    const qstrs = try gpa.alloc(QstrEntry, @as(usize, @intCast(n_qstr)));
    errdefer gpa.free(qstrs);
    for (qstrs) |*q| {
        const v = try r.readUint();
        if (v & 1 != 0) {
            // Static qstr
            q.* = .{ .static = @intCast(v >> 1) };
        } else {
            const len: usize = @intCast(v >> 1);
            // bytes are len + 1 (incl trailing NUL); we copy just the len bytes
            const raw = try r.readBytes(len + 1);
            const owned = try gpa.dupe(u8, raw[0..len]);
            q.* = .{ .new = owned };
        }
    }

    // Objects
    const objs = try gpa.alloc(ObjEntry, @as(usize, @intCast(n_obj)));
    errdefer gpa.free(objs);
    for (objs) |*o| o.* = try readObj(gpa, &r);

    // Outer raw code
    const rc = try readRawCode(gpa, &r);

    return Module{
        .version = version,
        .feature_flags = feature_flags,
        .small_int_bits = small_int_bits,
        .arch_flags = arch_flags,
        .qstrs = qstrs,
        .objs = objs,
        .rc = rc,
    };
}

fn readObj(gpa: std.mem.Allocator, r: *Reader) (Error || std.mem.Allocator.Error)!ObjEntry {
    const tag = try r.readByte();
    switch (tag) {
        @intFromEnum(ObjKind.none) => return .none,
        @intFromEnum(ObjKind.false) => return .false,
        @intFromEnum(ObjKind.true) => return .true,
        @intFromEnum(ObjKind.ellipsis) => return .ellipsis,
        @intFromEnum(ObjKind.str), @intFromEnum(ObjKind.bytes) => {
            const len = try r.readUint();
            const raw = try r.readBytes(@intCast(len + 1)); // incl NUL
            const owned = try gpa.dupe(u8, raw[0..@intCast(len)]);
            return if (tag == @intFromEnum(ObjKind.str))
                ObjEntry{ .str = owned }
            else
                ObjEntry{ .bytes = owned };
        },
        @intFromEnum(ObjKind.int), @intFromEnum(ObjKind.float), @intFromEnum(ObjKind.complex) => {
            const len = try r.readUint();
            const raw = try r.readBytes(@intCast(len));
            const owned = try gpa.dupe(u8, raw);
            return switch (tag) {
                @intFromEnum(ObjKind.int) => ObjEntry{ .int = owned },
                @intFromEnum(ObjKind.float) => ObjEntry{ .float = owned },
                @intFromEnum(ObjKind.complex) => ObjEntry{ .complex = owned },
                else => unreachable,
            };
        },
        @intFromEnum(ObjKind.tuple) => {
            const len = try r.readUint();
            const items = try gpa.alloc(ObjEntry, @intCast(len));
            errdefer gpa.free(items);
            for (items) |*it| it.* = try readObj(gpa, r);
            return ObjEntry{ .tuple = items };
        },
        else => return Error.UnsupportedFeature, // fun_table or unknown
    }
}

fn readRawCode(gpa: std.mem.Allocator, r: *Reader) (Error || std.mem.Allocator.Error)!RawCode {
    const hdr = try r.readUint();
    // Disk encodes (kind - MP_CODE_BYTECODE) in the low 2 bits; lift it
    // back to the absolute kind so RawCode.kind matches its docstring.
    const kind_offset: u2 = @intCast(hdr & 0x3);
    const has_children = (hdr & 0x4) != 0;
    const fun_data_len: usize = @intCast(hdr >> 3);

    const fun_data_raw = try r.readBytes(fun_data_len);
    const fun_data = try gpa.dupe(u8, fun_data_raw);

    var children: []RawCode = &[_]RawCode{};
    if (has_children) {
        const n = try r.readUint();
        children = try gpa.alloc(RawCode, @intCast(n));
        for (children) |*c| c.* = try readRawCode(gpa, r);
    }

    return RawCode{
        .kind = @intCast(@as(u8, kind_offset) + MP_CODE_BYTECODE),
        .fun_data = fun_data,
        .children = children,
    };
}

// ──────────────────────────────────────────────────────────────────────
// Writer

pub fn write(gpa: std.mem.Allocator, m: Module) std.mem.Allocator.Error![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(gpa);

    // Header
    try buf.appendSlice(gpa, &.{ MPY_MAGIC, m.version, m.feature_flags, m.small_int_bits });

    if (m.arch_flags) |af| try writeUint(&buf, gpa, af);

    try writeUint(&buf, gpa, m.qstrs.len);
    try writeUint(&buf, gpa, m.objs.len);

    for (m.qstrs) |q| {
        switch (q) {
            .static => |id| try writeUint(&buf, gpa, (@as(u64, id) << 1) | 1),
            .new => |bytes| {
                try writeUint(&buf, gpa, @as(u64, bytes.len) << 1);
                try buf.appendSlice(gpa, bytes);
                try buf.append(gpa, 0); // NUL terminator
            },
        }
    }

    for (m.objs) |o| try writeObj(&buf, gpa, o);

    try writeRawCode(&buf, gpa, m.rc);

    return buf.toOwnedSlice(gpa);
}

fn writeUint(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, n_in: u64) std.mem.Allocator.Error!void {
    // Big-endian 7-bit chunks, high bit = continuation.
    var tmp: [10]u8 = undefined;
    var p: usize = tmp.len;
    p -= 1;
    tmp[p] = @intCast(n_in & 0x7f);
    var n = n_in >> 7;
    while (n != 0) {
        p -= 1;
        tmp[p] = @as(u8, @intCast(n & 0x7f)) | 0x80;
        n >>= 7;
    }
    try buf.appendSlice(gpa, tmp[p..]);
}

fn writeObj(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, o: ObjEntry) std.mem.Allocator.Error!void {
    switch (o) {
        .none => try buf.append(gpa, @intFromEnum(ObjKind.none)),
        .false => try buf.append(gpa, @intFromEnum(ObjKind.false)),
        .true => try buf.append(gpa, @intFromEnum(ObjKind.true)),
        .ellipsis => try buf.append(gpa, @intFromEnum(ObjKind.ellipsis)),
        .str => |s| {
            try buf.append(gpa, @intFromEnum(ObjKind.str));
            try writeUint(buf, gpa, s.len);
            try buf.appendSlice(gpa, s);
            try buf.append(gpa, 0);
        },
        .bytes => |b| {
            try buf.append(gpa, @intFromEnum(ObjKind.bytes));
            try writeUint(buf, gpa, b.len);
            try buf.appendSlice(gpa, b);
            try buf.append(gpa, 0);
        },
        .int => |s| {
            try buf.append(gpa, @intFromEnum(ObjKind.int));
            try writeUint(buf, gpa, s.len);
            try buf.appendSlice(gpa, s);
        },
        .float => |s| {
            try buf.append(gpa, @intFromEnum(ObjKind.float));
            try writeUint(buf, gpa, s.len);
            try buf.appendSlice(gpa, s);
        },
        .complex => |s| {
            try buf.append(gpa, @intFromEnum(ObjKind.complex));
            try writeUint(buf, gpa, s.len);
            try buf.appendSlice(gpa, s);
        },
        .tuple => |t| {
            try buf.append(gpa, @intFromEnum(ObjKind.tuple));
            try writeUint(buf, gpa, t.len);
            for (t) |it| try writeObj(buf, gpa, it);
        },
    }
}

fn writeRawCode(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, rc: RawCode) std.mem.Allocator.Error!void {
    const has_children = rc.children.len > 0;
    // RawCode.kind stores the absolute MP_CODE_* value; encode the
    // offset (kind - MP_CODE_BYTECODE) into the low 2 bits.
    const kind_offset: u8 = rc.kind - MP_CODE_BYTECODE;
    const hdr: u64 = (@as(u64, rc.fun_data.len) << 3) |
        (@as(u64, @intFromBool(has_children)) << 2) |
        kind_offset;
    try writeUint(buf, gpa, hdr);
    try buf.appendSlice(gpa, rc.fun_data);
    if (has_children) {
        try writeUint(buf, gpa, rc.children.len);
        for (rc.children) |c| try writeRawCode(buf, gpa, c);
    }
}
