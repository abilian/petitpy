//! nanopython — Zig port of py/pairheap.c (Axis-B B1 W6; TRUE-ZIG).
//! A pure pairing-heap: 3 fns over `mp_pairheap_t*` + a C fn-ptr
//! comparator. No nlr, no mp_obj, no MP_STATE, no config — the
//! genuine-algorithm ideal of the corrected bar. `mp_pairheap_t` is
//! 4 plain pointers (mp_obj_base_t = a single type ptr, stable /
//! non-config) so it is replicated as an extern struct (not the
//! "don't-guess-ABI" hazard — that is for bitfield/config layouts).
//!
//! Faithful (lesson #6): the NEXT_* tag macros are pointer-LSB
//! tag ops mirrored exactly via @intFromPtr/@ptrFromInt; `lt`
//! returns C int → nonzero is true; control flow of meld/pairing/
//! delete transcribed branch-for-branch.

const Node = extern struct {
    type: ?*const anyopaque, // mp_obj_base_t.base.type (untouched)
    child: ?*Node,
    child_last: ?*Node,
    next: ?*Node,
};
const Lt = ?*const fn (?*Node, ?*Node) callconv(.c) c_int;

inline fn rpMake(parent: ?*Node) ?*Node {
    return @ptrFromInt(@intFromPtr(parent) | 1);
}
inline fn rpIs(next: ?*Node) bool {
    return (@intFromPtr(next) & 1) != 0;
}
inline fn rpGet(next: ?*Node) ?*Node {
    return @ptrFromInt(@intFromPtr(next) & ~@as(usize, 1));
}
inline fn lessThan(lt: Lt, a: ?*Node, b: ?*Node) bool {
    return lt.?(a, b) != 0;
}

pub export fn mp_pairheap_meld(lt: Lt, heap1: ?*Node, heap2: ?*Node) ?*Node {
    if (heap1 == null) return heap2;
    if (heap2 == null) return heap1;
    const h1 = heap1.?;
    const h2 = heap2.?;
    if (lessThan(lt, heap1, heap2)) {
        if (h1.child == null) {
            h1.child = heap2;
        } else {
            h1.child_last.?.next = heap2;
        }
        h1.child_last = heap2;
        h2.next = rpMake(heap1);
        return heap1;
    } else {
        h1.next = h2.child;
        h2.child = heap1;
        if (h1.next == null) {
            h2.child_last = heap1;
            h1.next = rpMake(heap2);
        }
        return heap2;
    }
}

pub export fn mp_pairheap_pairing(lt: Lt, child_in: ?*Node) ?*Node {
    if (child_in == null) return null;
    var child = child_in;
    var heap: ?*Node = null;
    while (!rpIs(child)) {
        var n1 = child;
        child = child.?.next;
        n1.?.next = null;
        if (!rpIs(child)) {
            const n2 = child;
            child = child.?.next;
            n2.?.next = null;
            n1 = mp_pairheap_meld(lt, n1, n2);
        }
        heap = mp_pairheap_meld(lt, heap, n1);
    }
    heap.?.next = null;
    return heap;
}

pub export fn mp_pairheap_delete(lt: Lt, heap: ?*Node, node: ?*Node) ?*Node {
    const nd = node.?;
    if (node == heap) {
        const child = heap.?.child;
        nd.child = null;
        return mp_pairheap_pairing(lt, child);
    }
    if (nd.next == null) {
        return heap;
    }
    var parent = node;
    while (!rpIs(parent.?.next)) {
        parent = parent.?.next;
    }
    parent = rpGet(parent.?.next);
    const par = parent.?;
    var next: ?*Node = undefined;
    var n_node = node;
    if (node == par.child and nd.child == null) {
        if (rpIs(nd.next)) {
            par.child = null;
        } else {
            par.child = nd.next;
        }
        nd.next = null;
        return heap;
    } else if (node == par.child) {
        const child = nd.child;
        next = nd.next;
        nd.child = null;
        nd.next = null;
        n_node = mp_pairheap_pairing(lt, child);
        par.child = n_node;
    } else {
        var n = par.child;
        while (node != n.?.next) {
            n = n.?.next;
        }
        const child = nd.child;
        next = nd.next;
        nd.child = null;
        nd.next = null;
        n_node = mp_pairheap_pairing(lt, child);
        if (n_node == null) {
            n_node = n;
        } else {
            n.?.next = n_node;
        }
    }
    n_node.?.next = next;
    if (rpIs(next)) {
        par.child_last = n_node;
    }
    return heap;
}

comptime {
    _ = &mp_pairheap_meld;
    _ = &mp_pairheap_pairing;
    _ = &mp_pairheap_delete;
}
