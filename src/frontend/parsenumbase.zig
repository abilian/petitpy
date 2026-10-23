//! petitpy — Zig port of py/parsenumbase.c. One pure function,
//! no nlr, no type-def → shimless `export fn` (the smallint recipe). Runtime-hot: the
//! radix-prefix scan for every int/float literal & int()/float().
//!
//! `mp_parse_num_base(const char *str, size_t len, int *base)
//! -> size_t` (nm-verified single export). ABI: const char* =
//! [*c]const u8, size_t = usize, int* = [*c]c_int.
//!
//! Faithful (lesson #6): the C `goto no_prefix` jumps INTO the
//! `else` body, so the `*base==0 → 10` tail runs for the len<=1
//! and c!='0' paths but NOT the c=='0' path. Mirrored with two
//! labeled blocks of identical reachability: `noprefix` (its end =
//! the tail) and `done` (wraps tail+return; the c=='0' path
//! `break :done` skips the tail). Pointer diff via `-%` (p>=str so
//! no wrap; the wrap-safe form per lesson #6).

pub export fn mp_parse_num_base(str: [*c]const u8, len: usize, base: [*c]c_int) usize {
    var p: [*c]const u8 = str;
    done: {
        noprefix: {
            if (len <= 1) break :noprefix; // C: goto no_prefix
            const c0: u32 = p[0]; // c = *(p++)
            p += 1;
            if (c0 == '0') {
                const c: u32 = @as(u32, p[0]) | 32; // c = *(p++) | 32
                p += 1;
                const b = base[0];
                if (c == 'x' and (b == 0 or b == 16)) {
                    base[0] = 16;
                } else if (c == 'o' and (b == 0 or b == 8)) {
                    base[0] = 8;
                } else if (c == 'b' and (b == 0 or b == 2)) {
                    base[0] = 2;
                } else {
                    p -= 2;
                    if (b == 0) base[0] = 1;
                }
                break :done; // c=='0' path: skip the no_prefix tail
            }
            // c != '0'
            p -= 1; // C: p--
            // fall out of `noprefix` → into the tail (no_prefix:)
        }
        // no_prefix: reached by len<=1 break OR the c!='0' fall-through
        if (base[0] == 0) base[0] = 10;
    }
    return @intFromPtr(p) -% @intFromPtr(str); // p - (const byte*)str
}

comptime {
    _ = &mp_parse_num_base; // force body+ABI analysis (the `_ = &fn;` rule)
}
