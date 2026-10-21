//! nanopython — Zig port of py/map.c (full).
//!
//! Ports all of map.c: mp_map_init/_init_fixed_table/_deinit/_clear,
//! mp_map_lookup (+ private rehash), and (under MICROPY_PY_BUILTINS_SET)
//! mp_set_init/_lookup/_remove_first/_clear. The C shim used to host
//! ~30 npy_mapz_* accessor wrappers; those are now direct field access
//! via `mp_mirrors.MpMap` (lesson #11 retired by the packed-struct
//! mirror).
//!
//! mp_map_t has bitfields (all_keys_are_qstrs, is_fixed, is_ordered,
//! used) — mirrored as a `packed struct(usize)` in mp_mirrors.zig.
//!
//! Raise path: mp_unary_op(MP_UNARY_OP_HASH, index) for non-qstr keys.
//! The longjmp travels through these Zig frames harmlessly (no defers).
//!
//! Under nano: MICROPY_PY_COLLECTIONS_ORDEREDDICT=1, MICROPY_PY_BUILTINS_SET=1,
//! MICROPY_OPT_MAP_LOOKUP_CACHE=1: see `lookup_cache` below.

const std = @import("std");
const mirrors = @import("../../mp_mirrors.zig");

const Obj = mirrors.Obj;
const MpMap = mirrors.MpMap;
const Elem = MpMap.Elem;

// MP_OBJ_NULL/SENTINEL local aliases (Obj = usize).
const OBJ_NULL: Obj = mirrors.OBJ_NULL;
const OBJ_SENTINEL: Obj = mirrors.OBJ_SENTINEL;

// mp_map_lookup_kind_t (obj.h:491-496).
const MP_MAP_LOOKUP: c_int = 0;
const MP_MAP_LOOKUP_ADD_IF_NOT_FOUND: c_int = 1;
const MP_MAP_LOOKUP_REMOVE_IF_FOUND: c_int = 2;
// const MP_MAP_LOOKUP_ADD_IF_NOT_FOUND_OR_REMOVE_IF_FOUND: c_int = 3;

// MP_UNARY_OP_HASH from runtime0.h: enum value 6 (POSITIVE=0, NEGATIVE,
// INVERT, NOT, BOOL, LEN, HASH=6).
const MP_UNARY_OP_HASH: c_int = 6;

// mp_set_t (obj.h:512-516). All fields are size_t / ptr — no bitfields.
const MpSet = extern struct {
    alloc: usize,
    used: usize,
    table: ?[*]Obj,
};

// External C-public symbols.
extern fn mp_unary_op(op: c_int, arg: Obj) callconv(.c) Obj;
extern fn mp_obj_equal(o1: Obj, o2: Obj) callconv(.c) bool;
extern fn qstr_hash(q: usize) callconv(.c) usize;
extern const mp_type_str: anyopaque;

// Allocator glue (m_new0 / m_del / m_renew expand to these in nano builds:
// MICROPY_MALLOC_USES_ALLOCATED_SIZE=0 → m_free(ptr) only, m_realloc(ptr, new_bytes)).
extern fn m_malloc0(num_bytes: usize) callconv(.c) ?*anyopaque;
extern fn m_free(ptr: ?*anyopaque) callconv(.c) void;
extern fn m_realloc(ptr: ?*anyopaque, new_num_bytes: usize) callconv(.c) ?*anyopaque;

inline fn newElemTable(n: usize) ?[*]Elem {
    if (n == 0) return null;
    const p = m_malloc0(n * @sizeOf(Elem));
    return @ptrCast(@alignCast(p));
}

inline fn delElemTable(t: ?[*]Elem) void {
    m_free(@ptrCast(t));
}

inline fn newObjTable(n: usize) ?[*]Obj {
    if (n == 0) return null;
    const p = m_malloc0(n * @sizeOf(Obj));
    return @ptrCast(@alignCast(p));
}

inline fn delObjTable(t: ?[*]Obj) void {
    m_free(@ptrCast(t));
}

// This table mirrors hash_allocation_sizes[] from map.c. Used by both
// the dict (map) rehash and the set rehash.
const hash_allocation_sizes = [_]u16{
    0, 2, 4, 6, 8, 10, 12, // +2
    17, 23, 29, 37, 47, 59, 73, // *1.25
    97, 127, 167, 223, 293, 389, 521, 691, 919, 1223, 1627, 2161, // *1.33
    3229, 4831, 7243, 10861, 16273, 24407, 36607, 54907, // *1.5
};

fn getHashAllocGeq(x: usize) usize {
    for (hash_allocation_sizes) |s| {
        if (s >= x) return s;
    }
    // Ran out of primes — return something sensible (odd).
    return (x + x / 2) | 1;
}

// ===========================================================================
// mp_map_* (dict / locals_dict hash table)
// ===========================================================================

export fn mp_map_init(map: *MpMap, n: usize) callconv(.c) void {
    if (n == 0) {
        map.alloc = 0;
        map.table = null;
    } else {
        map.alloc = n;
        map.table = @ptrCast(newElemTable(n));
    }
    map.bits = .{
        .all_keys_are_qstrs = 1,
        .is_fixed = 0,
        .is_ordered = 0,
        .used = 0,
    };
}

export fn mp_map_init_fixed_table(map: *MpMap, n: usize, table: [*]const Obj) callconv(.c) void {
    map.alloc = n;
    map.bits = .{
        .all_keys_are_qstrs = 1,
        .is_fixed = 1,
        .is_ordered = 1,
        .used = @intCast(n),
    };
    map.table = @ptrCast(@constCast(table));
}

export fn mp_map_deinit(map: *MpMap) callconv(.c) void {
    if (map.bits.is_fixed == 0) {
        delElemTable(@ptrCast(@alignCast(map.table)));
    }
    map.alloc = 0;
    map.bits.used = 0;
}

export fn mp_map_clear(map: *MpMap) callconv(.c) void {
    if (map.bits.is_fixed == 0) {
        delElemTable(@ptrCast(@alignCast(map.table)));
    }
    map.alloc = 0;
    map.bits = .{
        .all_keys_are_qstrs = 1,
        .is_fixed = 0,
        .is_ordered = 0,
        .used = 0,
    };
    map.table = null;
}

// OrderedDict-aware helpers exposed for mp_map_lookup below. Inlined now;
// no separate shim.
inline fn orderedRemoveAt(map: *MpMap, i: usize) void {
    if (i + 1 < map.alloc) {
        const tbl = map.tablePtr();
        const used: usize = @intCast(map.bits.used);
        // memmove down: (used - i) elements (the +1 to overwrite slot i,
        // matching the C `npy_mapz_ordered_remove_at` which uses `used - i`).
        const dst = @as([*]Elem, @ptrCast(&tbl[i]));
        const src = @as([*]const Elem, @ptrCast(&tbl[i + 1]));
        const n = used - i;
        // @memmove handles aliasing.
        @memmove(dst[0..n], src[0..n]);
    }
}

inline fn orderedGrow(map: *MpMap, delta: usize) void {
    const old_alloc = map.alloc;
    const new_alloc = old_alloc + delta;
    const new_bytes = new_alloc * @sizeOf(Elem);
    const new_ptr = m_realloc(map.table, new_bytes);
    map.table = new_ptr;
    // Zero the newly-grown tail (mirrors mp_seq_clear).
    if (new_ptr) |p| {
        const base: [*]u8 = @ptrCast(p);
        const zero_start = old_alloc * @sizeOf(Elem);
        const zero_end = new_alloc * @sizeOf(Elem);
        @memset(base[zero_start..zero_end], 0);
    }
    map.alloc = new_alloc;
}

// Private rehash: grow the table; replay non-NULL/non-SENTINEL entries
// into the new slots. Called from mp_map_lookup when the table fills.
fn mapRehash(map: *MpMap) void {
    const old_alloc = map.alloc;
    const old_table_opt: ?[*]Elem = if (map.table) |p| @ptrCast(@alignCast(p)) else null;
    const new_alloc = getHashAllocGeq(old_alloc + 1);
    const new_table = newElemTable(new_alloc);

    map.alloc = new_alloc;
    map.bits.used = 0;
    map.bits.all_keys_are_qstrs = 1;
    map.table = @ptrCast(new_table);

    if (old_table_opt) |old_table| {
        var i: usize = 0;
        while (i < old_alloc) : (i += 1) {
            const k = old_table[i].key;
            if (k != OBJ_NULL and k != OBJ_SENTINEL) {
                const slot = mp_map_lookup(map, k, MP_MAP_LOOKUP_ADD_IF_NOT_FOUND);
                // mp_map_lookup with ADD_IF_NOT_FOUND on a fresh table always
                // returns a non-NULL slot.
                slot.?.value = old_table[i].value;
            }
        }
        delElemTable(old_table);
    }
}

// MICROPY_OPT_MAP_LOOKUP_CACHE (vendor map.c:43): the last slot position
// found for a key, indexed by the key's bits and shared by all maps. A
// hit is validated by comparing the slot's key, so a stale or colliding
// entry is only a miss. A plain global rather than MP_STATE_VM, like
// pyerr.pending_exc: nanopython has no threads.
var lookup_cache = [_]u8{0} ** 128;
inline fn cacheEntry(index: Obj) *u8 {
    return &lookup_cache[(index >> 2) % lookup_cache.len];
}

export fn mp_map_lookup(map: *MpMap, index: Obj, lookup_kind: c_int) callconv(.c) ?*Elem {
    if (lookup_kind != MP_MAP_LOOKUP_REMOVE_IF_FOUND and map.alloc != 0) {
        const slot = &map.tablePtr()[cacheEntry(index).* % map.alloc];
        if (slot.key == index) return slot;
    }
    // Work out if we can compare just pointers.
    var compare_only_ptrs: bool = map.bits.all_keys_are_qstrs == 1;
    if (compare_only_ptrs) {
        if (mirrors.isQstr(index)) {
            // Index is a qstr — pointer comparison is OK.
        } else if (mirrors.isExactType(index, &mp_type_str)) {
            // Non-interned string — must do full equality.
            compare_only_ptrs = false;
        } else if (lookup_kind != MP_MAP_LOOKUP_ADD_IF_NOT_FOUND) {
            // Not adding and not a qstr/str → will never find it.
            return null;
        }
    }

    // Ordered-array path (fixed maps + OrderedDict).
    if (map.bits.is_ordered == 1) {
        const used: usize = @intCast(map.bits.used);
        if (map.table) |table_raw| {
            const tbl: [*]Elem = @ptrCast(@alignCast(table_raw));
            var i: usize = 0;
            while (i < used) : (i += 1) {
                const slot = &tbl[i];
                const k = slot.key;
                if (k == index or (!compare_only_ptrs and mp_obj_equal(k, index))) {
                    if (lookup_kind == MP_MAP_LOOKUP_REMOVE_IF_FOUND) {
                        // Move the rest of the array down, place the found
                        // element after the end so the caller can read it.
                        const value = slot.value;
                        map.bits.used = @intCast(used - 1);
                        orderedRemoveAt(map, i);
                        const tail = &tbl[used - 1];
                        tail.key = OBJ_NULL;
                        tail.value = value;
                        cacheEntry(index).* = @truncate(used - 1);
                        return tail;
                    }
                    cacheEntry(index).* = @truncate(i);
                    return slot;
                }
            }
        }
        // Not found.
        if (lookup_kind != MP_MAP_LOOKUP_ADD_IF_NOT_FOUND) return null;
        // Add to tail. Grow if needed.
        if (used == map.alloc) {
            orderedGrow(map, 4);
        }
        const tbl2: [*]Elem = @ptrCast(@alignCast(map.table.?));
        map.bits.used = @intCast(used + 1);
        const slot = &tbl2[used];
        slot.key = index;
        slot.value = OBJ_NULL;
        if (!mirrors.isQstr(index)) {
            map.bits.all_keys_are_qstrs = 0;
        }
        return slot;
    }

    // Hash-table path.
    if (map.alloc == 0) {
        if (lookup_kind == MP_MAP_LOOKUP_ADD_IF_NOT_FOUND) {
            mapRehash(map);
        } else {
            return null;
        }
    }

    // Compute hash (qstr fast path, else mp_unary_op HASH — raise-path!).
    var hash: usize = undefined;
    if (mirrors.isQstr(index)) {
        hash = qstr_hash(mirrors.qstrValue(index));
    } else {
        const h_obj = mp_unary_op(MP_UNARY_OP_HASH, index);
        // h_obj is a small int; extract value (MP_OBJ_SMALL_INT_VALUE = signed >> 1 in REPR_A).
        hash = @as(usize, @bitCast(@as(isize, @bitCast(h_obj)) >> 1));
    }

    var pos: usize = hash % map.alloc;
    var start_pos: usize = pos;
    var avail_slot: ?*Elem = null;
    while (true) {
        const tbl = map.tablePtr();
        const slot = &tbl[pos];
        const k = slot.key;
        if (k == OBJ_NULL) {
            // Empty slot — index not in table.
            if (lookup_kind == MP_MAP_LOOKUP_ADD_IF_NOT_FOUND) {
                map.bits.used = @intCast(@as(usize, @intCast(map.bits.used)) + 1);
                const dest = if (avail_slot) |s| s else slot;
                dest.key = index;
                dest.value = OBJ_NULL;
                if (!mirrors.isQstr(index)) {
                    map.bits.all_keys_are_qstrs = 0;
                }
                return dest;
            }
            return null;
        } else if (k == OBJ_SENTINEL) {
            // Deleted slot — remember for later add.
            if (avail_slot == null) avail_slot = slot;
        } else if (k == index or (!compare_only_ptrs and mp_obj_equal(k, index))) {
            // Found index.
            if (lookup_kind == MP_MAP_LOOKUP_REMOVE_IF_FOUND) {
                map.bits.used = @intCast(@as(usize, @intCast(map.bits.used)) - 1);
                // If next slot is empty, set key to NULL (search-terminating);
                // else SENTINEL (keep chain alive).
                const next_pos = (pos + 1) % map.alloc;
                const next_k = tbl[next_pos].key;
                if (next_k == OBJ_NULL) {
                    slot.key = OBJ_NULL;
                } else {
                    slot.key = OBJ_SENTINEL;
                }
                // value kept so caller can read it
            }
            cacheEntry(index).* = @truncate(pos);
            return slot;
        }

        // Continue searching.
        pos = (pos + 1) % map.alloc;
        if (pos == start_pos) {
            // Wrapped all the way around — not in table.
            if (lookup_kind == MP_MAP_LOOKUP_ADD_IF_NOT_FOUND) {
                if (avail_slot) |s| {
                    map.bits.used = @intCast(@as(usize, @intCast(map.bits.used)) + 1);
                    s.key = index;
                    s.value = OBJ_NULL;
                    if (!mirrors.isQstr(index)) {
                        map.bits.all_keys_are_qstrs = 0;
                    }
                    return s;
                } else {
                    // Table is full → rehash and restart.
                    mapRehash(map);
                    pos = hash % map.alloc;
                    start_pos = pos;
                }
            } else {
                return null;
            }
        }
    }
}

// ===========================================================================
// mp_set_* (set underlying hash table — MICROPY_PY_BUILTINS_SET)
// ===========================================================================

export fn mp_set_init(set: *MpSet, n: usize) callconv(.c) void {
    set.alloc = n;
    set.used = 0;
    set.table = newObjTable(n);
}

fn setRehash(set: *MpSet) void {
    const old_alloc = set.alloc;
    const old_table = set.table;
    set.alloc = getHashAllocGeq(set.alloc + 1);
    set.used = 0;
    set.table = newObjTable(set.alloc);
    if (old_table) |ot| {
        var i: usize = 0;
        while (i < old_alloc) : (i += 1) {
            const k = ot[i];
            if (k != OBJ_NULL and k != OBJ_SENTINEL) {
                _ = mp_set_lookup(set, k, MP_MAP_LOOKUP_ADD_IF_NOT_FOUND);
            }
        }
        delObjTable(ot);
    }
}

export fn mp_set_lookup(set: *MpSet, index: Obj, lookup_kind: c_int) callconv(.c) Obj {
    // lookup_kind can be MP_MAP_LOOKUP_ADD_IF_NOT_FOUND_OR_REMOVE_IF_FOUND (3);
    // bitwise-test against ADD and REMOVE flags individually.
    if (set.alloc == 0) {
        if ((lookup_kind & MP_MAP_LOOKUP_ADD_IF_NOT_FOUND) != 0) {
            setRehash(set);
        } else {
            return OBJ_NULL;
        }
    }
    const hash_obj = mp_unary_op(MP_UNARY_OP_HASH, index);
    const hash: usize = @as(usize, @bitCast(@as(isize, @bitCast(hash_obj)) >> 1));
    var pos: usize = hash % set.alloc;
    var start_pos: usize = pos;
    var avail_slot: ?*Obj = null;
    while (true) {
        const tbl = set.table.?;
        const elem = tbl[pos];
        if (elem == OBJ_NULL) {
            // Found NULL slot — index is not in table.
            if ((lookup_kind & MP_MAP_LOOKUP_ADD_IF_NOT_FOUND) != 0) {
                const dest = if (avail_slot) |s| s else &tbl[pos];
                set.used += 1;
                dest.* = index;
                return index;
            } else {
                return OBJ_NULL;
            }
        } else if (elem == OBJ_SENTINEL) {
            // Found deleted slot — remember for later.
            if (avail_slot == null) avail_slot = &tbl[pos];
        } else if (mp_obj_equal(elem, index)) {
            // Found index.
            if ((lookup_kind & MP_MAP_LOOKUP_REMOVE_IF_FOUND) != 0) {
                set.used -= 1;
                if (tbl[(pos + 1) % set.alloc] == OBJ_NULL) {
                    // Optimisation if next slot is empty.
                    tbl[pos] = OBJ_NULL;
                } else {
                    tbl[pos] = OBJ_SENTINEL;
                }
            }
            return elem;
        }

        // Not yet found, keep searching.
        pos = (pos + 1) % set.alloc;
        if (pos == start_pos) {
            // Search wrapped — index not in table.
            if ((lookup_kind & MP_MAP_LOOKUP_ADD_IF_NOT_FOUND) != 0) {
                if (avail_slot) |s| {
                    set.used += 1;
                    s.* = index;
                    return index;
                } else {
                    // Not enough room — rehash and restart.
                    setRehash(set);
                    pos = hash % set.alloc;
                    start_pos = pos;
                }
            } else {
                return OBJ_NULL;
            }
        }
    }
}

export fn mp_set_remove_first(set: *MpSet) callconv(.c) Obj {
    var pos: usize = 0;
    while (pos < set.alloc) : (pos += 1) {
        const tbl = set.table.?;
        const elem = tbl[pos];
        if (elem != OBJ_NULL and elem != OBJ_SENTINEL) {
            set.used -= 1;
            if (tbl[(pos + 1) % set.alloc] == OBJ_NULL) {
                tbl[pos] = OBJ_NULL;
            } else {
                tbl[pos] = OBJ_SENTINEL;
            }
            return elem;
        }
    }
    return OBJ_NULL;
}

export fn mp_set_clear(set: *MpSet) callconv(.c) void {
    delObjTable(set.table);
    set.alloc = 0;
    set.used = 0;
    set.table = null;
}

comptime {
    _ = &mp_map_init;
    _ = &mp_map_init_fixed_table;
    _ = &mp_map_deinit;
    _ = &mp_map_clear;
    _ = &mp_map_lookup;
    _ = &mapRehash;
    _ = &mp_set_init;
    _ = &mp_set_lookup;
    _ = &mp_set_remove_first;
    _ = &mp_set_clear;
    _ = &setRehash;
}
