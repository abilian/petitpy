// Compiler-track scope analysis — pure Zig.
//
// Replaces vendor py/scope.c (154 LOC) and src/frontend/scope_shim.c (the
// verbatim C relocation currently exposing 5 functions plus 34 npy_scope_*
// shim accessors). Consumed by the future compile.zig (C7) for name
// resolution: every Python block (module, class, function, lambda, the
// four comprehension flavours) becomes a `Scope` carrying the per-name
// `IdInfo` table.
//
// Key divergences from vendor scope.c:
//
//   1. Allocator-driven. Vendor uses m_new/m_renew/m_del routed through
//      the GC heap; we take a std.mem.Allocator on Scope.new() and store
//      it in the struct, then back IdInfo with std.ArrayListUnmanaged.
//   2. Errors surface. findOrAdd / checkToCloseOver / new are
//      error{OutOfMemory}!T; callers must `try`. Vendor relies on GC
//      longjmp which is incompatible with a pure-compiler track.
//   3. No C-ABI / no shim. Public API is a Scope struct with methods;
//      the seven currently-MISSING npy_scope_* getters become trivial
//      field reads in C7.
//   4. raw_code deferred. Vendor calls mp_emit_glue_new_raw_code()
//      inside scope_new; we leave the field as ?*anyopaque = null and
//      let C7 wire it once the emitter lifts.
//   5. simple_name lookup via comptime-pinned qstr ids. The six well-
//      known qstrs (<module>/<lambda>/<listcomp>/<dictcomp>/<setcomp>/
//      <genexpr>) live at fixed QDEF0 indices in the embedded
//      qstrdefs.generated.h; we hard-code those ids and a comptime
//      assertion catches a vendor regen that shuffles them.
//   6. The `next` sibling-chain field is exposed but never written by
//      Scope itself — exactly as vendor scope.c never touches it
//      (compile.c owns the chain).
//
// Algorithmically the closure-marking loop is byte-faithful to vendor
// lines 116-152: assert parent != null at entry; walk s = s.parent until
// either an UNDECIDED slot gets promoted to FREE-and-continue or an
// existing LOCAL gets promoted to CELL-and-return; FREE/CELL hits return
// without modification.
//
// Full validation deferred to C7's byte-identical .mpy diff over the
// 552-file corpus; the unit tests below guard the algorithmic core.

const std = @import("std");
const parser = @import("parser.zig");
const qstr_mod = @import("qstr.zig");

// ── Re-exported convenience aliases ───────────────────────────────────────

pub const Pn = parser.Pn;
pub const Qstr = qstr_mod.qstr;

// ── ScopeKind (mirrors vendor scope_kind_t) ───────────────────────────────

pub const ScopeKind = enum(u8) {
    module = 0,
    class = 1,
    lambda = 2,
    list_comp = 3,
    dict_comp = 4,
    set_comp = 5,
    gen_expr = 6,
    function = 7,

    pub inline fn isFuncLike(k: ScopeKind) bool {
        // SCOPE_IS_FUNC_LIKE(s) := (s) >= SCOPE_LAMBDA
        return @intFromEnum(k) >= @intFromEnum(ScopeKind.lambda);
    }

    pub inline fn isCompLike(k: ScopeKind) bool {
        // SCOPE_IS_COMP_LIKE(s) := SCOPE_LIST_COMP <= (s) && (s) <= SCOPE_GEN_EXPR
        const v = @intFromEnum(k);
        return v >= @intFromEnum(ScopeKind.list_comp) and
            v <= @intFromEnum(ScopeKind.gen_expr);
    }
};

// ── IdInfoKind (mirrors vendor id_info_kind_t) ────────────────────────────

pub const IdInfoKind = enum(u8) {
    undecided = 0,
    global_implicit = 1,
    global_implicit_assigned = 2,
    global_explicit = 3,
    local = 4, // in a function f, written and only referenced by f
    cell = 5, // in a function f, read/written by children of f
    free = 6, // in a function f, belongs to the parent of f
};

// ── ID_FLAG_* bitmasks (mirrors enum in py/scope.h) ───────────────────────

pub const ID_FLAG_IS_PARAM: u8 = 0x01;
pub const ID_FLAG_IS_STAR_PARAM: u8 = 0x02;
pub const ID_FLAG_IS_DBL_STAR_PARAM: u8 = 0x04;
pub const ID_FLAG_VIPER_TYPE_POS: u3 = 4;

// ── SCOPE_FLAG_* bitmasks (mirrors py/runtime0.h) ─────────────────────────
//
// Only the bits compile.c actually ORs into scope.scope_flags. The native-
// emitter / viper bits are present in vendor runtime0.h but unused under
// nano config; ported here verbatim so C7 doesn't need a second copy.

pub const SCOPE_FLAG_ALL_SIG: u16 = 0x0f;
pub const SCOPE_FLAG_GENERATOR: u16 = 0x01;
pub const SCOPE_FLAG_VARKEYWORDS: u16 = 0x02;
pub const SCOPE_FLAG_VARARGS: u16 = 0x04;
pub const SCOPE_FLAG_DEFKWARGS: u16 = 0x08;
pub const SCOPE_FLAG_REFGLOBALS: u16 = 0x10;
pub const SCOPE_FLAG_HASCONSTS: u16 = 0x20;

// ── Allocation tuning (matches MICROPY_ALLOC_SCOPE_ID_* in mpconfig.h) ────

const ID_INFO_INIT: usize = 4; // MICROPY_ALLOC_SCOPE_ID_INIT
const ID_INFO_INC: usize = 6; // MICROPY_ALLOC_SCOPE_ID_INC

// ── IdInfo struct (mirrors id_info_t — same wire layout) ──────────────────
//
// Field order matches vendor: u8 kind, u8 flags, u16 local_num, then qst.
// We keep qst as the compiler-track qstr alias (u16) — narrower than
// vendor's usize typedef, but matches vendor's actual storage width
// (scope_t.simple_name is uint16_t already).

pub const IdInfo = struct {
    kind: IdInfoKind = .undecided,
    flags: u8 = 0,
    /// When kind == .local this is the unique local number.
    /// When kind == .cell / .free this is the closed-over variable's number.
    local_num: u16 = 0,
    qst: Qstr,
};

// ── simple_name lookup table (vendor scope_simple_name_table) ─────────────
//
// Vendor uses C99 designated initialisers indexed by scope_kind_t. We
// inline the six QDEF0 ids that are known at comptime (and assert below
// that the embedded qstrdefs hasn't drifted from these pins). FUNCTION
// and CLASS are 0 sentinels — Scope.new() handles them via the parse-node
// extraction path instead.
//
// QDEF0 indices in vendor/micropython_embed/genhdr/qstrdefs.generated.h:
//   <module>    -> id  7
//   <dictcomp>  -> id 169
//   <genexpr>   -> id 170
//   <lambda>    -> id 171
//   <listcomp>  -> id 172
//   <setcomp>   -> id 173
//
// All six fit under UINT8_MAX (255) — vendor relies on the same
// invariant for its uint8_t table.

const SIMPLE_NAME_QSTR_MODULE: Qstr = 7;
const SIMPLE_NAME_QSTR_DICTCOMP: Qstr = 166;
const SIMPLE_NAME_QSTR_GENEXPR: Qstr = 167;
const SIMPLE_NAME_QSTR_LAMBDA: Qstr = 168;
const SIMPLE_NAME_QSTR_LISTCOMP: Qstr = 169;
const SIMPLE_NAME_QSTR_SETCOMP: Qstr = 170;

comptime {
    // Pin-check: if a vendor regen shuffles qstr ids, fail the build
    // here rather than emit mysteriously-wrong simple_names downstream.
    // We can't call qstr_find_strn at comptime (needs an allocator-backed
    // context), but we CAN scan the comptime-parsed pool by hash+bytes.
    if (!staticIdMatches(SIMPLE_NAME_QSTR_MODULE, "<module>"))
        @compileError("qstrdefs drift: <module> no longer at id 7");
    if (!staticIdMatches(SIMPLE_NAME_QSTR_DICTCOMP, "<dictcomp>"))
        @compileError("qstrdefs drift: <dictcomp> no longer at id 166");
    if (!staticIdMatches(SIMPLE_NAME_QSTR_GENEXPR, "<genexpr>"))
        @compileError("qstrdefs drift: <genexpr> no longer at id 167");
    if (!staticIdMatches(SIMPLE_NAME_QSTR_LAMBDA, "<lambda>"))
        @compileError("qstrdefs drift: <lambda> no longer at id 168");
    if (!staticIdMatches(SIMPLE_NAME_QSTR_LISTCOMP, "<listcomp>"))
        @compileError("qstrdefs drift: <listcomp> no longer at id 169");
    if (!staticIdMatches(SIMPLE_NAME_QSTR_SETCOMP, "<setcomp>"))
        @compileError("qstrdefs drift: <setcomp> no longer at id 170");

    // Width check: matches vendor's MP_STATIC_ASSERT(... <= UINT8_MAX).
    if (SIMPLE_NAME_QSTR_SETCOMP > 0xff)
        @compileError("simple_name qstr ids must fit in uint8_t (vendor invariant)");
}

/// Comptime helper: does `id` resolve to `want` in the embedded static pool?
fn staticIdMatches(id: Qstr, comptime want: []const u8) bool {
    // Empty / out-of-range ids never match a non-empty literal.
    if (id >= qstr_mod.N_TOTAL) return false;
    // Re-derive the bytes through qstr.zig's public accessors; we can't
    // construct a QstrContext at comptime, but qstr_str on a static id
    // never reads the dynamic side, so passing an undefined ctx pointer
    // is safe IFF id < N_TOTAL — guarded above.
    var dummy: qstr_mod.QstrContext = .{ .allocator = undefined };
    const got = qstr_mod.qstr_str(&dummy, id);
    const got_len = qstr_mod.qstr_len(&dummy, id);
    if (got_len != want.len) return false;
    return std.mem.eql(u8, got[0..got_len], want);
}

/// Map ScopeKind -> simple_name qstr id (for the kinds that have one).
/// FUNCTION/CLASS return 0; the caller must extract simple_name from the
/// parse node instead.
inline fn simpleNameQstr(k: ScopeKind) Qstr {
    return switch (k) {
        .module => SIMPLE_NAME_QSTR_MODULE,
        .lambda => SIMPLE_NAME_QSTR_LAMBDA,
        .list_comp => SIMPLE_NAME_QSTR_LISTCOMP,
        .dict_comp => SIMPLE_NAME_QSTR_DICTCOMP,
        .set_comp => SIMPLE_NAME_QSTR_SETCOMP,
        .gen_expr => SIMPLE_NAME_QSTR_GENEXPR,
        .function, .class => 0,
    };
}

// ── Scope struct + lifecycle ──────────────────────────────────────────────

pub const Scope = struct {
    kind: ScopeKind,
    parent: ?*Scope = null,
    /// Sibling chain — populated by the compile driver (C7), never
    /// touched by Scope itself. Exactly as vendor scope.c never writes
    /// scope_t.next; compile.c owns that list.
    next: ?*Scope = null,
    pn: Pn = parser.PN_NULL,
    /// Deferred to C7 (mp_emit_glue_new_raw_code wiring). Stays null
    /// through scope analysis; the emitter assigns it later.
    raw_code: ?*anyopaque = null,
    simple_name: Qstr = 0,
    scope_flags: u16 = 0,
    emit_options: u16 = 0,
    num_pos_args: u16 = 0,
    num_kwonly_args: u16 = 0,
    num_def_pos_args: u16 = 0,
    num_locals: u16 = 0,
    stack_size: u16 = 0,
    exc_stack_size: u16 = 0,
    id_info: std.ArrayListUnmanaged(IdInfo) = .empty,
    allocator: std.mem.Allocator,
    /// Has this scope been driven through the SCOPE pass yet? The
    /// compiler's iterative driver uses this to avoid re-processing
    /// (the heuristic "no locals + no ids + no pos_args" misclassifies
    /// empty function bodies like `def f(): pass` as unprocessed and
    /// caused unbounded recursion).
    scope_pass_done: bool = false,

    /// Allocate a fresh Scope on `allocator`. For FUNCTION/CLASS the
    /// `pn` must be a PnStruct whose nodes[0] is an ID leaf (the
    /// function/class name); we extract its qstr arg into simple_name.
    /// For the other six kinds the simple_name is the well-known qstr
    /// from the comptime-pinned table above.
    ///
    /// Pre-sizes id_info to ID_INFO_INIT (=4) entries to match vendor's
    /// scope->id_info_alloc bootstrap. The ArrayList stays empty
    /// (len == 0) — capacity is just reserved so the first few findOrAdd
    /// calls don't allocate.
    pub fn new(
        allocator: std.mem.Allocator,
        kind: ScopeKind,
        pn: Pn,
        emit_options: u16,
    ) std.mem.Allocator.Error!*Scope {
        const self = try allocator.create(Scope);
        errdefer allocator.destroy(self);

        self.* = .{
            .kind = kind,
            .pn = pn,
            .emit_options = emit_options,
            .allocator = allocator,
        };

        if (kind == .function or kind == .class) {
            // Vendor asserts MP_PARSE_NODE_IS_STRUCT(pn) here; preserve.
            std.debug.assert(parser.pnIsStruct(pn));
            const pns: *parser.PnStruct = @ptrFromInt(pn);
            const nodes = parser.pnsNodes(pns);
            // nodes[0] is the ID leaf — pull its arg as the qstr.
            self.simple_name = @intCast(parser.pnLeafArg(nodes[0]));
        } else {
            self.simple_name = simpleNameQstr(kind);
        }

        try self.id_info.ensureTotalCapacityPrecise(allocator, ID_INFO_INIT);
        return self;
    }

    /// Release id_info backing memory. Does NOT free the Scope itself;
    /// use `destroy` for that. Idempotent.
    pub fn deinit(self: *Scope) void {
        self.id_info.deinit(self.allocator);
    }

    /// deinit + allocator.destroy(self). Mirrors vendor scope_free —
    /// frees both the id_info table and the Scope struct. Note: caller
    /// is responsible for the parent / next chain; this destroys only
    /// `self`, exactly like vendor.
    pub fn destroy(self: *Scope) void {
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
    }

    // ── Lookup / insert ──────────────────────────────────────────────────

    /// Linear scan over the current scope's IdInfo table.
    /// Returns null on miss. Mirrors vendor scope_find().
    pub fn find(self: *Scope, q: Qstr) ?*IdInfo {
        for (self.id_info.items) |*info| {
            if (info.qst == q) return info;
        }
        return null;
    }

    /// Find or insert. Returns the existing entry on hit; otherwise
    /// appends a new entry with the given kind (and default flags=0 /
    /// local_num=0) and returns a pointer to it. Mirrors vendor
    /// scope_find_or_add_id().
    ///
    /// Growth: matches vendor's m_renew(old, old + ID_INFO_INC) — when
    /// capacity is exhausted we grow by exactly +6 slots via
    /// ensureTotalCapacityPrecise. This keeps the realloc cadence
    /// identical to vendor (4 → 10 → 16 → 22 → ...), so any future
    /// allocator-sensitive bug surfaces in the same pattern.
    pub fn findOrAdd(
        self: *Scope,
        q: Qstr,
        kind: IdInfoKind,
    ) std.mem.Allocator.Error!*IdInfo {
        if (self.find(q)) |existing| return existing;

        // Grow by exactly ID_INFO_INC slots when capacity is exhausted,
        // matching vendor m_renew(..., alloc, alloc + ID_INFO_INC).
        if (self.id_info.items.len >= self.id_info.capacity) {
            const new_cap = self.id_info.capacity + ID_INFO_INC;
            try self.id_info.ensureTotalCapacityPrecise(self.allocator, new_cap);
        }

        // Push initialised entry; appendAssumeCapacity is safe after the
        // ensureTotalCapacityPrecise above.
        self.id_info.appendAssumeCapacity(.{
            .kind = kind,
            .flags = 0,
            .local_num = 0,
            .qst = q,
        });
        return &self.id_info.items[self.id_info.items.len - 1];
    }

    /// Walk to the outermost (module) scope, then find() there.
    /// Mirrors vendor scope_find_global().
    pub fn findGlobal(self: *Scope, q: Qstr) ?*IdInfo {
        var s: *Scope = self;
        while (s.parent) |p| : (s = p) {}
        return s.find(q);
    }

    // ── Closure marking ──────────────────────────────────────────────────

    /// If `id` shadows a binding in any non-module ancestor, mark it
    /// FREE in `self` and propagate CELL/FREE upward. Mirrors vendor
    /// scope_check_to_close_over() — direct port of scope.c:139-152.
    ///
    /// Error-typed because closeOverInParents may need to insert
    /// UNDECIDED slots along the chain (any of which can allocate).
    pub fn checkToCloseOver(
        self: *Scope,
        id: *IdInfo,
    ) std.mem.Allocator.Error!void {
        if (self.parent == null) return;

        var s: ?*Scope = self.parent;
        // Walk while s has a parent — we don't peek the outer (module)
        // scope, matching vendor's `for (s = parent; s->parent != NULL; s = s->parent)`.
        while (s) |sp| {
            if (sp.parent == null) break;
            if (sp.find(id.qst)) |id2| {
                if (id2.kind == .local or id2.kind == .cell or id2.kind == .free) {
                    id.kind = .free;
                    try closeOverInParents(self, id.qst);
                }
                return;
            }
            s = sp.parent;
        }
    }
};

// ── private: closeOverInParents ───────────────────────────────────────────

/// Walk parent chain, marking the binding's home as CELL and any
/// intermediate scope as FREE. Direct port of vendor
/// scope_close_over_in_parents() at scope.c:116-137.
///
/// Invariants (asserted, matching vendor):
///   - self has at least one parent (caller checked).
///   - We never reach the outer (module) scope — each parent must
///     itself have a parent. The vendor's inner `assert(s->parent != NULL)`
///     would fire on a misuse; we keep the assert in debug builds.
fn closeOverInParents(self: *Scope, q: Qstr) std.mem.Allocator.Error!void {
    std.debug.assert(self.parent != null);
    var s: *Scope = self.parent.?;
    while (true) {
        std.debug.assert(s.parent != null); // never the outer scope
        const id = try s.findOrAdd(q, .undecided);
        if (id.kind == .undecided) {
            // Not previously declared here — declare as free and keep
            // walking upward.
            id.kind = .free;
        } else {
            // Found a binding — promote LOCAL to CELL, leave FREE/CELL
            // alone, and stop.
            if (id.kind == .local) {
                id.kind = .cell;
            } else {
                std.debug.assert(id.kind == .free or id.kind == .cell);
            }
            return;
        }
        s = s.parent.?;
    }
}

// ── Unit tests ────────────────────────────────────────────────────────────
//
// Heavy validation (every scope.zig-emitted bytecode byte-identical to
// vendor) is the C7 .mpy diff's job. These tests guard the algorithmic
// core — find/findOrAdd dedup + growth, simple_name table, the multi-
// level closure-marking walk.

const testing = std.testing;

test "Scope.new: module gets <module> simple_name and empty id_info" {
    const s = try Scope.new(testing.allocator, .module, parser.PN_NULL, 0);
    defer s.destroy();

    try testing.expectEqual(ScopeKind.module, s.kind);
    try testing.expectEqual(SIMPLE_NAME_QSTR_MODULE, s.simple_name);
    try testing.expectEqual(@as(usize, 0), s.id_info.items.len);
    // Pre-sized to ID_INFO_INIT — no allocation on the first 4 inserts.
    try testing.expect(s.id_info.capacity >= ID_INFO_INIT);
}

test "Scope.new: each comprehension kind picks the right qstr" {
    const cases = .{
        .{ ScopeKind.lambda, SIMPLE_NAME_QSTR_LAMBDA },
        .{ ScopeKind.list_comp, SIMPLE_NAME_QSTR_LISTCOMP },
        .{ ScopeKind.dict_comp, SIMPLE_NAME_QSTR_DICTCOMP },
        .{ ScopeKind.set_comp, SIMPLE_NAME_QSTR_SETCOMP },
        .{ ScopeKind.gen_expr, SIMPLE_NAME_QSTR_GENEXPR },
    };
    inline for (cases) |c| {
        const s = try Scope.new(testing.allocator, c[0], parser.PN_NULL, 0);
        defer s.destroy();
        try testing.expectEqual(@as(Qstr, c[1]), s.simple_name);
    }
}

test "Scope.new: FUNCTION extracts simple_name from PnStruct nodes[0]" {
    // Hand-build a PnStruct whose nodes[0] is an ID leaf carrying a
    // synthetic qstr. We don't go through the parser; the struct is
    // sized for one node, lives on the stack, and is dropped after.
    const FakePns = extern struct {
        hdr: parser.PnStruct,
        n0: parser.Pn,
    };
    const want_qstr: usize = 42;
    var fake: FakePns = .{
        .hdr = .{ .source_line = 1, .kind_num_nodes = (1 << 8) },
        .n0 = parser.pnNewLeaf(parser.PN_ID, want_qstr),
    };
    const pn: Pn = @intFromPtr(&fake.hdr);

    const s = try Scope.new(testing.allocator, .function, pn, 0);
    defer s.destroy();
    try testing.expectEqual(@as(Qstr, want_qstr), s.simple_name);
}

test "find: hit + miss" {
    const s = try Scope.new(testing.allocator, .module, parser.PN_NULL, 0);
    defer s.destroy();

    try testing.expect(s.find(100) == null);
    _ = try s.findOrAdd(100, .local);
    const hit = s.find(100) orelse return error.MissingHit;
    try testing.expectEqual(@as(Qstr, 100), hit.qst);
    try testing.expectEqual(IdInfoKind.local, hit.kind);
    try testing.expect(s.find(101) == null);
}

test "findOrAdd: dedup returns same pointer; growth past ID_INFO_INIT" {
    const s = try Scope.new(testing.allocator, .module, parser.PN_NULL, 0);
    defer s.destroy();

    const a1 = try s.findOrAdd(10, .local);
    const a2 = try s.findOrAdd(10, .global_explicit); // kind ignored on hit
    try testing.expectEqual(a1, a2);
    try testing.expectEqual(IdInfoKind.local, a2.kind); // hit preserves original
    try testing.expectEqual(@as(usize, 1), s.id_info.items.len);

    // Insert past ID_INFO_INIT (=4) to force growth to 4 + ID_INFO_INC (=10).
    _ = try s.findOrAdd(11, .undecided);
    _ = try s.findOrAdd(12, .undecided);
    _ = try s.findOrAdd(13, .undecided); // fills cap=4
    _ = try s.findOrAdd(14, .undecided); // triggers grow
    try testing.expectEqual(@as(usize, 5), s.id_info.items.len);
    try testing.expect(s.id_info.capacity >= ID_INFO_INIT + ID_INFO_INC);

    // New entries have default flags=0 / local_num=0.
    const e = s.find(14) orelse return error.MissingHit;
    try testing.expectEqual(@as(u8, 0), e.flags);
    try testing.expectEqual(@as(u16, 0), e.local_num);
}

test "findGlobal: walks parent chain to module" {
    const m = try Scope.new(testing.allocator, .module, parser.PN_NULL, 0);
    defer m.destroy();
    const inner = try Scope.new(testing.allocator, .lambda, parser.PN_NULL, 0);
    defer inner.destroy();
    inner.parent = m;

    _ = try m.findOrAdd(200, .global_explicit);
    const hit = inner.findGlobal(200) orelse return error.MissingGlobal;
    try testing.expectEqual(@as(Qstr, 200), hit.qst);
    try testing.expect(inner.findGlobal(201) == null);
}

test "checkToCloseOver: LOCAL in parent → FREE in child, CELL in parent" {
    const m = try Scope.new(testing.allocator, .module, parser.PN_NULL, 0);
    defer m.destroy();
    const outer = try Scope.new(testing.allocator, .lambda, parser.PN_NULL, 0);
    defer outer.destroy();
    const inner = try Scope.new(testing.allocator, .lambda, parser.PN_NULL, 0);
    defer inner.destroy();
    outer.parent = m;
    inner.parent = outer;

    const outer_id = try outer.findOrAdd(300, .local);
    const inner_id = try inner.findOrAdd(300, .undecided);

    try inner.checkToCloseOver(inner_id);
    try testing.expectEqual(IdInfoKind.free, inner_id.kind);
    try testing.expectEqual(IdInfoKind.cell, outer_id.kind);
}

test "checkToCloseOver: no parent → no-op" {
    const m = try Scope.new(testing.allocator, .module, parser.PN_NULL, 0);
    defer m.destroy();
    const id = try m.findOrAdd(400, .undecided);
    try m.checkToCloseOver(id);
    try testing.expectEqual(IdInfoKind.undecided, id.kind);
}

test "checkToCloseOver: FREE in ancestor → child becomes FREE, ancestor unchanged" {
    const m = try Scope.new(testing.allocator, .module, parser.PN_NULL, 0);
    defer m.destroy();
    const mid = try Scope.new(testing.allocator, .lambda, parser.PN_NULL, 0);
    defer mid.destroy();
    const inner = try Scope.new(testing.allocator, .lambda, parser.PN_NULL, 0);
    defer inner.destroy();
    mid.parent = m;
    inner.parent = mid;

    const mid_id = try mid.findOrAdd(500, .free);
    const inner_id = try inner.findOrAdd(500, .undecided);

    try inner.checkToCloseOver(inner_id);
    try testing.expectEqual(IdInfoKind.free, inner_id.kind);
    try testing.expectEqual(IdInfoKind.free, mid_id.kind); // unchanged
}

test "closeOverInParents: depth-3 chain — intermediate gets FREE, root LOCAL becomes CELL" {
    // module ← outer (LOCAL x) ← mid (no x) ← inner (refs x)
    const m = try Scope.new(testing.allocator, .module, parser.PN_NULL, 0);
    defer m.destroy();
    const outer = try Scope.new(testing.allocator, .lambda, parser.PN_NULL, 0);
    defer outer.destroy();
    const mid = try Scope.new(testing.allocator, .lambda, parser.PN_NULL, 0);
    defer mid.destroy();
    const inner = try Scope.new(testing.allocator, .lambda, parser.PN_NULL, 0);
    defer inner.destroy();
    outer.parent = m;
    mid.parent = outer;
    inner.parent = mid;

    const outer_id = try outer.findOrAdd(600, .local);
    const inner_id = try inner.findOrAdd(600, .undecided);

    try inner.checkToCloseOver(inner_id);
    try testing.expectEqual(IdInfoKind.free, inner_id.kind);
    try testing.expectEqual(IdInfoKind.cell, outer_id.kind);

    // mid gets a synthesised FREE slot inserted by closeOverInParents.
    const mid_id = mid.find(600) orelse return error.MidNotInserted;
    try testing.expectEqual(IdInfoKind.free, mid_id.kind);
}

test "ScopeKind: isFuncLike / isCompLike vendor predicates" {
    try testing.expect(!ScopeKind.module.isFuncLike());
    try testing.expect(!ScopeKind.class.isFuncLike());
    try testing.expect(ScopeKind.lambda.isFuncLike());
    try testing.expect(ScopeKind.list_comp.isFuncLike());
    try testing.expect(ScopeKind.function.isFuncLike());

    try testing.expect(!ScopeKind.module.isCompLike());
    try testing.expect(!ScopeKind.lambda.isCompLike());
    try testing.expect(ScopeKind.list_comp.isCompLike());
    try testing.expect(ScopeKind.dict_comp.isCompLike());
    try testing.expect(ScopeKind.set_comp.isCompLike());
    try testing.expect(ScopeKind.gen_expr.isCompLike());
    try testing.expect(!ScopeKind.function.isCompLike());
}
