//! petitpy — Zig-native `_json` module, the fast paths of `json.dumps`
//! and `json.loads`.
//!
//!   _json.encode(obj, item_sep, kv_sep, ensure_ascii) → str
//!   _json.string(s, ensure_ascii) → s as a JSON string literal
//!   _json.decode(s) → value
//!
//! Encodes None, bool, int, finite float, str, list, tuple and dict of
//! exactly those types, with the output of the pure-Python encoder in
//! petitpy-lib/json.py. Anything else (a subclass, a non-str key, NaN,
//! very deep nesting) raises TypeError, and json.py reruns its own
//! encoder, which either handles the value or raises CPython's error.
//!
//! `decode` builds the same values as the pure-Python decoder for the
//! documents it accepts. On anything else (invalid JSON, a surrogate
//! `\u` escape, a leading zero, very deep nesting) it raises ValueError,
//! and json.py reruns its own decoder, which raises JSONDecodeError with
//! the position.
//!
//! __qstr_shadow_begin__
//! MP_QSTR_string
//! MP_QSTR__json
//! MP_QSTR_encode
//! MP_QSTR_decode
//! MP_REGISTER_MODULE(MP_QSTR__json, mp_module__json);
//! __qstr_shadow_end__

const std = @import("std");
const build_options = @import("build_options");
const mirrors = @import("../mp_mirrors.zig");
const pyerr = @import("../pyerr.zig");
const opmethods = @import("../runtime/opmethods.zig");

const Obj = mirrors.Obj;
const Qstr = usize;

const mp = @cImport({
    @cInclude("py/qstr.h");
});

extern const mp_type_module: anyopaque;
extern const mp_type_dict: anyopaque;
extern const mp_type_list: anyopaque;
extern const mp_type_tuple: anyopaque;
extern const mp_type_str: anyopaque;
extern const mp_type_int: anyopaque;
extern const mp_type_float: anyopaque;
extern const mp_type_TypeError: anyopaque;
extern const mp_type_ValueError: anyopaque;
extern const mp_type_fun_builtin_1: anyopaque;
extern const mp_type_fun_builtin_2: anyopaque;
extern const mp_type_fun_builtin_var: anyopaque;
extern fn mp_obj_float_get(o: Obj) callconv(.c) f64;

extern fn vstr_init_print(v: *Vstr, alloc: usize, print: *PrintT) callconv(.c) void;
extern fn vstr_add_strn(v: *Vstr, s: [*]const u8, len: usize) callconv(.c) void;
extern fn vstr_add_byte(v: *Vstr, b: u8) callconv(.c) void;
extern fn mp_obj_new_str_from_vstr(v: *Vstr) callconv(.c) Obj;
extern fn mp_obj_str_get_data(o: Obj, len: *usize) callconv(.c) [*]const u8;
extern fn mp_obj_print_helper(print: *const PrintT, o: Obj, kind: c_int) callconv(.c) void;
extern fn vstr_init(v: *Vstr, alloc: usize) callconv(.c) void;
extern fn vstr_add_char(v: *Vstr, c: u32) callconv(.c) void;
extern fn mp_obj_new_str(data: [*]const u8, len: usize) callconv(.c) Obj;
extern fn mp_obj_new_list(n: usize, items: ?[*]const Obj) callconv(.c) Obj;
extern fn mp_obj_list_append(list: Obj, item: Obj) callconv(.c) Obj;
extern fn mp_obj_new_dict(n: usize) callconv(.c) Obj;
extern fn mp_obj_dict_store(dict: Obj, key: Obj, value: Obj) callconv(.c) Obj;
extern fn mp_parse_num_integer(s: [*]const u8, len: usize, base: c_int, lex: ?*anyopaque) callconv(.c) Obj;
extern fn mp_parse_num_decimal(s: [*]const u8, len: usize, allow_imag: bool, force_complex: bool, lex: ?*anyopaque) callconv(.c) Obj;
extern fn mp_obj_new_exception_msg(t: *const anyopaque, msg: [*:0]const u8) callconv(.c) Obj;

const Vstr = extern struct {
    alloc: usize,
    len: usize,
    buf: [*c]u8,
    fixed_buf: bool,
};

const PrintT = extern struct {
    data: ?*anyopaque,
    print_strn: *const anyopaque,
};

const PRINT_STR: c_int = 0;

// Deeper values (or a reference cycle) go to the Python encoder, which
// raises RecursionError the way CPython does.
const max_depth = 256;

const Unsupported = error{Unsupported};

const Encoder = struct {
    out: Vstr,
    print: PrintT,
    item_sep: []const u8,
    kv_sep: []const u8,
    ascii: bool,

    fn add(self: *Encoder, s: []const u8) void {
        vstr_add_strn(&self.out, s.ptr, s.len);
    }

    fn str(self: *Encoder, o: Obj) void {
        var len: usize = 0;
        const data = mp_obj_str_get_data(o, &len);
        vstr_add_byte(&self.out, '"');
        var run: usize = 0;
        var i: usize = 0;
        while (i < len) {
            const c = data[i];
            const esc: []const u8 = switch (c) {
                '"' => "\\\"",
                '\\' => "\\\\",
                0x08 => "\\b",
                '\t' => "\\t",
                '\n' => "\\n",
                0x0C => "\\f",
                '\r' => "\\r",
                else => if (c < 0x20 or (self.ascii and c >= 0x7F)) "" else {
                    i += 1;
                    continue;
                },
            };
            self.add(data[run..i]);
            if (esc.len > 0) {
                self.add(esc);
                i += 1;
            } else if (c < 0x80) {
                self.hex(c);
                i += 1;
            } else {
                // ensure_ascii: a UTF-8 sequence as a \u escape, or a
                // surrogate pair above U+FFFF, as CPython writes them.
                const n: usize = if (c >= 0xF0) 4 else if (c >= 0xE0) 3 else 2;
                var cp: u32 = c & (@as(u8, 0x7F) >> @intCast(n));
                for (data[i + 1 .. @min(i + n, len)]) |b| cp = (cp << 6) | (b & 0x3F);
                if (cp >= 0x10000) {
                    self.hex(0xD800 + ((cp - 0x10000) >> 10));
                    self.hex(0xDC00 + ((cp - 0x10000) & 0x3FF));
                } else {
                    self.hex(cp);
                }
                i = @min(i + n, len);
            }
            run = i;
        }
        self.add(data[run..len]);
        vstr_add_byte(&self.out, '"');
    }

    fn hex(self: *Encoder, cp: u32) void {
        var buf: [6]u8 = undefined;
        self.add(std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{cp}) catch unreachable);
    }

    fn items(self: *Encoder, elems: []const Obj, depth: usize) Unsupported!void {
        vstr_add_byte(&self.out, '[');
        for (elems, 0..) |e, i| {
            if (i > 0) self.add(self.item_sep);
            try self.value(e, depth + 1);
        }
        vstr_add_byte(&self.out, ']');
    }

    fn value(self: *Encoder, o: Obj, depth: usize) Unsupported!void {
        if (depth > max_depth) return error.Unsupported;
        if (o == mirrors.OBJ_NONE) return self.add("null");
        if (o == mirrors.OBJ_TRUE) return self.add("true");
        if (o == mirrors.OBJ_FALSE) return self.add("false");
        if (mirrors.isSmallInt(o)) {
            var buf: [24]u8 = undefined;
            return self.add(std.fmt.bufPrint(&buf, "{d}", .{mirrors.smallIntValue(o)}) catch unreachable);
        }
        if (mirrors.isQstr(o)) return self.str(o);
        if (!mirrors.isObj(o)) return error.Unsupported;
        const t = mirrors.objBaseType(o);
        if (t == &mp_type_str) return self.str(o);
        if (t == &mp_type_float and !std.math.isFinite(mp_obj_float_get(o))) return error.Unsupported;
        if (t == &mp_type_int or t == &mp_type_float) {
            return mp_obj_print_helper(&self.print, o, PRINT_STR);
        }
        if (t == &mp_type_list) {
            const l = mirrors.MpObjList.fromObj(o);
            return self.items(l.items[0..l.len], depth);
        }
        if (t == &mp_type_tuple) {
            const tup = mirrors.MpObjTuple.fromObj(o);
            return self.items(tup.itemsPtr()[0..tup.len], depth);
        }
        if (t == &mp_type_dict) {
            const map = &mirrors.MpObjDict.fromObj(o).map;
            vstr_add_byte(&self.out, '{');
            var first = true;
            for (0..map.alloc) |i| {
                if (!map.slotFilled(i)) continue;
                const k = map.keyAt(i);
                if (!mirrors.isQstr(k) and !mirrors.isExactType(k, &mp_type_str)) return error.Unsupported;
                if (!first) self.add(self.item_sep);
                first = false;
                self.str(k);
                self.add(self.kv_sep);
                try self.value(map.valueAt(i), depth + 1);
            }
            vstr_add_byte(&self.out, '}');
            return;
        }
        return error.Unsupported;
    }
};

fn sepArg(o: Obj) []const u8 {
    var len: usize = 0;
    const data = mp_obj_str_get_data(o, &len);
    return data[0..len];
}

fn py_encode(_: usize, args: [*c]const Obj) callconv(.c) Obj {
    var enc: Encoder = .{
        .out = undefined,
        .print = undefined,
        .item_sep = sepArg(args[1]),
        .kv_sep = sepArg(args[2]),
        .ascii = args[3] == mirrors.OBJ_TRUE,
    };
    vstr_init_print(&enc.out, 64, &enc.print);
    enc.value(args[0], 0) catch {
        pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_TypeError, "not handled by the native JSON encoder");
        return mirrors.OBJ_NULL;
    };
    return mp_obj_new_str_from_vstr(&enc.out);
}

// A str, or a str subclass by its value, as a JSON string literal.
fn py_string(s: Obj, ascii: Obj) callconv(.c) Obj {
    var enc: Encoder = .{ .out = undefined, .print = undefined, .item_sep = "", .kv_sep = "", .ascii = ascii == mirrors.OBJ_TRUE };
    vstr_init_print(&enc.out, 16, &enc.print);
    enc.str(opmethods.nativeBase(s));
    return mp_obj_new_str_from_vstr(&enc.out);
}

const Decoder = struct {
    s: []const u8,
    i: usize = 0,

    fn ws(self: *Decoder) void {
        while (self.i < self.s.len) : (self.i += 1) {
            switch (self.s[self.i]) {
                ' ', '\t', '\n', '\r' => {},
                else => return,
            }
        }
    }

    fn peek(self: *Decoder) Unsupported!u8 {
        if (self.i >= self.s.len) return error.Unsupported;
        return self.s[self.i];
    }

    fn literal(self: *Decoder, word: []const u8, o: Obj) Unsupported!Obj {
        if (!std.mem.startsWith(u8, self.s[self.i..], word)) return error.Unsupported;
        self.i += word.len;
        return o;
    }

    fn digits(self: *Decoder) usize {
        const start = self.i;
        while (self.i < self.s.len and std.ascii.isDigit(self.s[self.i])) self.i += 1;
        return self.i - start;
    }

    // Only numbers whose meaning is not in doubt. The Python decoder hands
    // its lenient scan to int() and float(); the odd cases ("01", "1.",
    // "1e") go to it.
    fn number(self: *Decoder) Unsupported!Obj {
        const start = self.i;
        if (self.s[self.i] == '-') self.i += 1;
        const int_start = self.i;
        const n_int = self.digits();
        if (n_int == 0 or (n_int > 1 and self.s[int_start] == '0')) return error.Unsupported;
        var is_float = false;
        if (self.i < self.s.len and self.s[self.i] == '.') {
            is_float = true;
            self.i += 1;
            if (self.digits() == 0) return error.Unsupported;
        }
        if (self.i < self.s.len and (self.s[self.i] == 'e' or self.s[self.i] == 'E')) {
            is_float = true;
            self.i += 1;
            if (self.i < self.s.len and (self.s[self.i] == '+' or self.s[self.i] == '-')) self.i += 1;
            if (self.digits() == 0) return error.Unsupported;
        }
        const tok = self.s[start..self.i];
        if (is_float) return mp_parse_num_decimal(tok.ptr, tok.len, false, false, null);
        if (n_int <= 18) return mirrors.newSmallInt(std.fmt.parseInt(isize, tok, 10) catch unreachable);
        return mp_parse_num_integer(tok.ptr, tok.len, 10, null);
    }

    fn string(self: *Decoder) Unsupported!Obj {
        self.i += 1;
        var run = self.i;
        var out: Vstr = undefined;
        var escaped = false;
        while (self.i < self.s.len) {
            const c = self.s[self.i];
            if (c == '"') {
                const tail = self.s[run..self.i];
                self.i += 1;
                if (!escaped) return mp_obj_new_str(tail.ptr, tail.len);
                vstr_add_strn(&out, tail.ptr, tail.len);
                return mp_obj_new_str_from_vstr(&out);
            }
            if (c != '\\') {
                if (c < 0x20) return error.Unsupported;
                self.i += 1;
                continue;
            }
            if (!escaped) {
                vstr_init(&out, self.i - run + 16);
                escaped = true;
            }
            vstr_add_strn(&out, self.s[run..].ptr, self.i - run);
            self.i += 1;
            const e = try self.peek();
            self.i += 1;
            switch (e) {
                '"', '\\', '/' => vstr_add_byte(&out, e),
                'b' => vstr_add_byte(&out, 0x08),
                'f' => vstr_add_byte(&out, 0x0C),
                'n' => vstr_add_byte(&out, '\n'),
                'r' => vstr_add_byte(&out, '\r'),
                't' => vstr_add_byte(&out, '\t'),
                'u' => {
                    if (self.i + 4 > self.s.len) return error.Unsupported;
                    const code = std.fmt.parseInt(u16, self.s[self.i .. self.i + 4], 16) catch return error.Unsupported;
                    if (code >= 0xD800 and code <= 0xDFFF) return error.Unsupported;
                    if (code >= 0x80 and !build_options.str_unicode) return error.Unsupported;
                    vstr_add_char(&out, code);
                    self.i += 4;
                },
                else => return error.Unsupported,
            }
            run = self.i;
        }
        return error.Unsupported;
    }

    fn value(self: *Decoder, depth: usize) Unsupported!Obj {
        if (depth > max_depth) return error.Unsupported;
        self.ws();
        switch (try self.peek()) {
            '"' => return self.string(),
            '{' => {
                self.i += 1;
                const d = mp_obj_new_dict(0);
                self.ws();
                if ((try self.peek()) == '}') {
                    self.i += 1;
                    return d;
                }
                while (true) {
                    self.ws();
                    if ((try self.peek()) != '"') return error.Unsupported;
                    const k = try self.string();
                    self.ws();
                    if ((try self.peek()) != ':') return error.Unsupported;
                    self.i += 1;
                    _ = mp_obj_dict_store(d, k, try self.value(depth + 1));
                    self.ws();
                    const c = try self.peek();
                    self.i += 1;
                    if (c == '}') return d;
                    if (c != ',') return error.Unsupported;
                }
            },
            '[' => {
                self.i += 1;
                const l = mp_obj_new_list(0, null);
                self.ws();
                if ((try self.peek()) == ']') {
                    self.i += 1;
                    return l;
                }
                while (true) {
                    _ = mp_obj_list_append(l, try self.value(depth + 1));
                    self.ws();
                    const c = try self.peek();
                    self.i += 1;
                    if (c == ']') return l;
                    if (c != ',') return error.Unsupported;
                }
            },
            't' => return self.literal("true", mirrors.OBJ_TRUE),
            'f' => return self.literal("false", mirrors.OBJ_FALSE),
            'n' => return self.literal("null", mirrors.OBJ_NONE),
            '-', '0'...'9' => return self.number(),
            else => return error.Unsupported,
        }
    }
};

fn raiseValueError() Obj {
    pyerr.pending_exc = mp_obj_new_exception_msg(&mp_type_ValueError, "not handled by the native JSON decoder");
    return mirrors.OBJ_NULL;
}

fn py_decode(s: Obj) callconv(.c) Obj {
    var len: usize = 0;
    const data = mp_obj_str_get_data(s, &len);
    var dec: Decoder = .{ .s = data[0..len] };
    const v = dec.value(0) catch return raiseValueError();
    dec.ws();
    if (dec.i != len) return raiseValueError();
    return v;
}

pub export const mp_json_decode_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_1 }, .fun = @ptrCast(&py_decode) };

pub export const mp_json_encode_obj: mirrors.MpObjFunBuiltinVar = .{ .base = .{ .type = &mp_type_fun_builtin_var }, .sig = mirrors.makeFunSig(4, 4, false), .fun = &py_encode };

pub export const mp_json_string_obj: mirrors.MpObjFunBuiltinFixed = .{ .base = .{ .type = &mp_type_fun_builtin_2 }, .fun = @ptrCast(&py_string) };

const RomEntry = extern struct {
    key: Obj,
    value: *const anyopaque,
};

inline fn qKey(q: usize) Obj {
    return mirrors.objFromQstr(@as(Qstr, q));
}

const mp_module__json_globals_table = [_]RomEntry{
    .{ .key = qKey(mp.MP_QSTR___name__), .value = @ptrFromInt(qKey(mp.MP_QSTR__json)) },
    .{ .key = qKey(mp.MP_QSTR_encode), .value = &mp_json_encode_obj },
    .{ .key = qKey(mp.MP_QSTR_decode), .value = &mp_json_decode_obj },
    .{ .key = qKey(mp.MP_QSTR_string), .value = &mp_json_string_obj },
};

pub export const mp_module__json_globals: mirrors.MpObjDict = .{
    .base = .{ .type = &mp_type_dict },
    .map = .{
        .bits = .{
            .all_keys_are_qstrs = 1,
            .is_fixed = 1,
            .is_ordered = 1,
            .used = mp_module__json_globals_table.len,
        },
        .alloc = mp_module__json_globals_table.len,
        .table = @ptrCast(@constCast(&mp_module__json_globals_table)),
    },
};

pub export const mp_module__json: mirrors.MpObjModule = .{
    .base = .{ .type = &mp_type_module },
    .globals = @ptrCast(@constCast(&mp_module__json_globals)),
};
