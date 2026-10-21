//! nanopython — shimless port of MicroPython's `qstr_compute_hash`.
//!
//! Mirrors vendor `py/qstr.c:qstr_compute_hash` (djb2, `hash * 33 ^ data`)
//! byte-for-byte. Used by `src/modules/modos.zig` for ROM string
//! constants (`os.sep`, `os.name`, …); computing the hash at Zig
//! comptime lets those constants live in the module-globals ROM table
//! without a MICROPY_MODULE_BUILTIN_INIT hook.
//!
//! The hash bit-width comes from `MICROPY_QSTR_BYTES_IN_HASH`:
//!   0 → mask 0xFFFF (nanopython's default under ROM_LEVEL_MINIMUM)
//!   1 → mask 0xFF
//!   2 → mask 0xFFFF
//!
//! Under `bytes_in_hash == 0`, `Q_HASH_MASK` in `qstr.c` is defined
//! as `0xffff` (not 0 — the enclosing `#if MICROPY_QSTR_BYTES_IN_HASH`
//! block swaps to the literal mask when the byte count is zero). So
//! the effective hash is a 16-bit djb2 value, and this file matches.
//!
//! Guard: MicroPython treats `hash == 0` as "not computed", so
//! `qstr_compute_hash` bumps zero to one before returning. Same here.
//!
//! Shimless: no `@cImport`, no vendor headers, no external symbols.
//! Test-covered in `src/tests.zig`.

const std = @import("std");

/// djb2 hash of `s`, matching vendor `py/qstr.c:qstr_compute_hash`
/// under `MICROPY_QSTR_BYTES_IN_HASH == 0` (i.e. mask = 0xFFFF).
///
/// Zeros are re-mapped to 1 (upstream's "valid hash is never zero"
/// convention); the empty string therefore hashes to 5381 & 0xFFFF
/// = 5381 (`5381 == 0x1505`, non-zero, no bump).
pub inline fn djb2Hash(comptime s: []const u8) usize {
    @setEvalBranchQuota(10_000);
    var h: usize = 5381;
    for (s) |b| h = ((h << 5) +% h) ^ @as(usize, b);
    h &= 0xffff;
    return if (h == 0) 1 else h;
}

/// Runtime variant of `djb2Hash` — same algorithm, callable on
/// non-comptime data. Useful in tests that iterate over cases.
pub fn djb2HashRuntime(s: []const u8) usize {
    var h: usize = 5381;
    for (s) |b| h = ((h << 5) +% h) ^ @as(usize, b);
    h &= 0xffff;
    return if (h == 0) 1 else h;
}
