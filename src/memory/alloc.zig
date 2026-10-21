// Vendor py/malloc.c's m_* family on top of the collector in memory/gc.zig,
// as vendor routes it through gc.c. Signatures match
// MICROPY_MALLOC_USES_ALLOCATED_SIZE=0.
//
// m_malloc_fail is polled (sets pending_exc + returns, no longjmp).
// Allocators return null on failure; callers must check the null result
// (and pyerr.pending_exc) and propagate.

const gc = @import("gc.zig");

extern fn m_malloc_fail(num_bytes: usize) callconv(.c) void;

// Zero-byte requests get a block: callers treat null as failure, as they
// did with libc malloc(0).
pub export fn m_malloc(num_bytes: usize) ?*anyopaque {
    return gc.allocMaybe(num_bytes) orelse {
        m_malloc_fail(num_bytes);
        return null;
    };
}

// Vendor malloc.c: the collector calls the object's `__del__` before
// freeing it (files, sockets).
pub export fn m_malloc_with_finaliser(num_bytes: usize) ?*anyopaque {
    return gc.allocWith(num_bytes, true) orelse {
        m_malloc_fail(num_bytes);
        return null;
    };
}

pub export fn m_malloc_maybe(num_bytes: usize) ?*anyopaque {
    return gc.allocMaybe(num_bytes);
}

pub export fn m_malloc0(num_bytes: usize) ?*anyopaque {
    return m_malloc(num_bytes); // blocks are always zeroed
}

pub export fn m_realloc(ptr: ?*anyopaque, new_num_bytes: usize) ?*anyopaque {
    return gc.reallocMaybe(ptr, new_num_bytes, true) orelse {
        m_malloc_fail(new_num_bytes);
        return null;
    };
}

// allow_move=false: resize in place or return NULL; the caller then
// allocates, copies and frees.
pub export fn m_realloc_maybe(ptr: ?*anyopaque, new_num_bytes: usize, allow_move: bool) ?*anyopaque {
    return gc.reallocMaybe(ptr, new_num_bytes, allow_move);
}

pub export fn m_free(ptr: ?*anyopaque) void {
    gc.gc_free(ptr);
}
