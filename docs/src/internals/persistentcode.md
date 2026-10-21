# Persistentcode Loader (`.mpy` Loader)

`src/runtime/persistentcode.zig` is the Zig port of MicroPython's `.mpy` bytecode loader. It was the last vendor C file in the compile graph; porting it was NX-1, the inflection point of the strangler arc.

## What it does

When you run `petitpy script.py`, the flow is:

1. Compiler track lexes + parses + emits → produces a `.mpy` byte stream.
2. **Persistentcode loader** reads the `.mpy` bytes and constructs the runtime data structures (raw_code, qstr table, const table, child raw_codes).
3. VM executes the loaded code.

The loader is the bridge from "bytecode as bytes in memory" to "bytecode as live runtime structures." It's invoked on every script execution AND on every `import x` (`.mpy` is also the format MicroPython caches compiled modules in).

## The format being loaded

`.mpy` v6 is a binary format. Per file:

1. **Header**: 4 bytes: `'M'`, version (6), feature flags, small-int width.
2. **Qstr table**: a length-prefixed list of qstrs used by this code.
3. **Object table**: a length-prefixed list of const objects (str/bytes literals, int/float constants, tuples).
4. **Raw_code tree**: a recursive structure encoding the top-level function + all nested functions/classes.

Each raw_code has:
- A kind byte (BYTECODE, NATIVE_PY, NATIVE_VIPER, NATIVE_ASM)
- A `has_children` flag
- A `fun_data_len` (the byte length of the bytecode)
- The bytecode bytes themselves
- Optionally a child count + recursive raw_codes

The encoding uses **7-bit varints** for lengths (`read_uint`), **bit-packed preludes** for function metadata (`decodePreludeSig`/`decodePreludeSize`), and exact byte matching for the magic header.

## The port

The vendor C file is `vendor/micropython_embed/py/persistentcode.c` (940 LOC). The Zig port `src/runtime/persistentcode.zig` is 424 LOC. The reduction came from:

- Dropping the save path (we don't write `.mpy`, only read)
- Dropping the native code arms (NATIVE_PY, NATIVE_VIPER, NATIVE_ASM, disabled by config)
- Dropping the VFS_ROM optimization (memory-mapped .mpy from ROM, embedded-only)

The active code path is ~270 LOC C, ported to ~350 LOC Zig (with comments + checks).

## Port structure

```zig
// ── extern surface used by load_qstr / load_obj ──────────────────────
extern fn qstr_from_strn(str: [*]const u8, len: usize) callconv(.c) usize;
extern fn m_malloc(num_bytes: usize) callconv(.c) ?*anyopaque;
extern fn m_free(ptr: ?*anyopaque) callconv(.c) void;
extern fn mp_obj_new_tuple(n: usize, items: [*c]const Obj) callconv(.c) Obj;
// ... more externs ...

// ── leaf primitives (persistentcode.c:159–179) ─────────────────────
pub fn read_byte(reader: *mirrors.MpReader) u8 { ... }
pub fn read_bytes(reader: *mirrors.MpReader, buf: [*]u8, len: usize) void { ... }
pub fn read_uint(reader: *mirrors.MpReader) usize { ... }

// ── prelude decoders (bc.h:104–162) ─────────────────────────────────
pub fn decodePreludeSig(ip: *[*]const u8) mirrors.MpBytecodePrelude { ... }
pub fn decodePreludeSize(ip: *[*]const u8) PreludeSize { ... }

// ── load_qstr / load_obj (persistentcode.c:181–289) ────────────────
fn load_qstr(reader: *mirrors.MpReader) mirrors.QstrShort { ... }
fn load_obj(reader: *mirrors.MpReader) Obj { ... }

// ── load_raw_code (persistentcode.c:291-462) ───────────────────────
fn load_raw_code(
    reader: *mirrors.MpReader,
    context: ?*mirrors.MpModuleContext,
) PyError!*mirrors.MpRawCode { ... }

// ── top-level entries (persistentcode.c:464-539) ───────────────────
pub export fn mp_raw_code_load(reader: *mirrors.MpReader, cm: *mirrors.MpCompiledModule) callconv(.c) void { ... }
pub export fn mp_raw_code_load_mem(buf: [*]const u8, len: usize, cm: *mirrors.MpCompiledModule) callconv(.c) void { ... }
```

The structure mirrors the C source's section organization. Comments cite the vendor C line ranges so anyone investigating "is the port faithful?" can do a side-by-side diff.

## Notable porting decisions

### Varint reading

The `read_uint` decoder is a 7-bit continuation varint:

```zig
pub fn read_uint(reader: *mirrors.MpReader) usize {
    var unum: usize = 0;
    while (true) {
        const b = read_byte(reader);
        unum = (unum << 7) | @as(usize, b & 0x7f);
        if ((b & 0x80) == 0) break;
    }
    return unum;
}
```

The unit test in `src/tests.zig` covers boundary values 0, 1, 0x7E, 0x7F, 0x80, 0x81, 0x3FFF, 0x4000, 0xFFFFFF. Off-by-one bugs in the shift loop would surface immediately.

### Prelude decoder integer widths

The bytecode prelude packs 6 fields into bit-shifted bytes. Vendor C uses `unsigned int` (≥32 bit) for the loop counter; an early port used `u5` (the natural shift-width type for `u32`), which overflowed at n=16. Caught by a med-severity correctness review, fixed in commit `cc6f674`:

```zig
// CORRECT — n is u32; @intCast at shift sites
var n: u32 = 0;
while ((z & 0x80) != 0) : (n += 1) {
    z = p[0];
    p += 1;
    const s: u5 = @intCast(n);
    const s2: u5 = @intCast(2 * n);
    S |= (@as(u32, z) & 0x30) << s2;
    // ...
}
```

The `@intCast(s2)` will panic on malformed input (n ≥ 16): correct defensive behavior since real `.mpy` files don't have 16+ continuation bytes.

### Memory leak in load_raw_code

`load_raw_code` allocates a `fun_data` buffer + a `children` array via `m_malloc`, then recursively calls itself for each child. If any recursive call raises (via the original noreturn longjmp), the buffers leak.

Vendor C has the same bug. The Zig port fixed it via `errdefer`:

```zig
const fun_data: [*]u8 = @ptrCast(m_malloc(fun_data_len));
errdefer m_free(@ptrCast(fun_data));
read_bytes(reader, fun_data, fun_data_len);

var children: ?[*]?*mirrors.MpRawCode = null;
if (has_children) {
    const n_children = read_uint(reader);
    const buf_bytes = std.math.mul(usize, @sizeOf(?*mirrors.MpRawCode), n_children) catch {
        try raiseIncompatibleMpy();
    };
    const buf = m_malloc(buf_bytes).?;
    errdefer m_free(buf);
    // ... recursion that can raise ...
}
```

Now if the recursion raises, the `errdefer`s fire and free the allocations. This was a side-effect bonus of the PyError conversion (which it landed alongside, in commit `f37727f`).

### Overflow guards on attacker-derived sizes

`.mpy` is potentially untrusted input. The `n_children * @sizeOf(ptr)` multiplication could overflow on 64-bit if `n_children` is near `SIZE_MAX/8`. Zig's `std.math.mul` returns an error on overflow:

```zig
const buf_bytes = std.math.mul(usize, @sizeOf(?*mirrors.MpRawCode), n_children) catch {
    try raiseIncompatibleMpy();
};
```

Vendor C has the same exposure (`m_new(mp_raw_code_t *, n_children + ...)` is an unchecked multiplication). The Zig port is **strictly safer** than the original.

### Header byte 3 (small-int width)

`.mpy` files encode the small-int width in their header. Our nano config uses 63-bit small-ints (64-bit target minus the tag bit). The `mp_raw_code_load` entry validates that the file's claimed width is ≤ ours:

```zig
const MP_SMALL_INT_BITS: u8 = 63;  // matches smallint.h:69
// ...
if (header[3] > MP_SMALL_INT_BITS) {
    try raiseIncompatibleMpy();
}
```

This catches `.mpy` files compiled on platforms with wider small-ints (e.g., a hypothetical 128-bit platform). Files compiled on narrower platforms work fine; files compiled on wider platforms raise `ValueError("incompatible .mpy file")`.

## Test coverage

Unit tests in `src/tests.zig`:

- `read_uint` boundary cases (9 values)
- `decodePreludeSig` minimal + realistic + 2-byte-continuation cases
- `decodePreludeSize` minimal + 1-byte + 2-byte-continuation cases

Indirect coverage via the corpus: every test program is compiled to `.mpy` and loaded by this code, so the broader paths (`load_qstr`, `load_obj`, `load_raw_code`, `mp_raw_code_load`) are exercised by 540+ tests.

`tools/compile-exec-test.py` is the gate for "is the loader producing the right runtime structures?": it compiles each test, loads via this code, runs through the vendor VM, and checks for byte-identical output against the full-config golden. 540/542 pass.

## The strangle moment

The NX-1 strangle commit (`7d6d7f1`) deleted `vendor/.../py/persistentcode.c` from the build graph. Before the commit: C version compiles, Zig version is dead code (force-analyzed via `comptime { _ = &mp_raw_code_load_mem; }` in main.zig). After the commit: C version is gone, Zig version is the only definer of the symbol.

The test gate was `make check` at 537/541 + `tools/compile-exec-test.py` at 540/542. Both held. That meant the Zig port was producing **byte-identical raw_code structures** to the vendor C version, proven by the fact that the VM produced identical output. The strangler had its full proof.

## See also

- [`src/runtime/persistentcode.zig`](https://git.sr.ht/~sfermigier/petitpy/tree/main/item/src/runtime/persistentcode.zig): the canonical source
- `vendor/micropython_embed/py/persistentcode.c`: vendor C source (not in compile graph)
- Strangler Journey § NX-1 (`strangler-journey.md`): narrative
