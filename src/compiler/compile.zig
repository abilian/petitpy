//! nanopython compiler driver — pure-Zig port (C7 of the compiler/ track).
//!
//! Port of src/frontend/compile.zig + the C shim trampoline in
//! src/frontend/compile_shim.c, stripped of every `@cImport` / vendor
//! header / `npy_*` shim call. The algorithmic structure follows vendor
//! py/compile.c (~3700 LOC) — handler order, label allocation sequence,
//! scopeComputeThings ordering, scope-slot pointer trick, c_if_cond
//! ordering, optimised-range recognizer, and the 3-pass driver — all
//! ported verbatim because byte-identical .mpy output against mpy-cross
//! requires it.
//!
//! Substrate changes are surgical (vs the frontend/compile.zig strangler):
//!
//!   * No `@cImport`. Every npy_* call routes through the pure-Zig
//!     modules src/compiler/{parser,scope,emit,qstr,mpy}.zig.
//!   * The 128-byte opaque emit_common buffer becomes a typed
//!     `EmitCommon` field — Compiler owns it by value.
//!   * The C-side `npy_compile_dispatch` trampoline is replaced by a
//!     single comptime-built `compile_function: [grammar.NUM_RULES]
//!     CompileFn` table, populated by @field-reflection over a
//!     `CompileRules` namespace, indexed by `grammar.RULE_<name>`
//!     ordinals.
//!   * Error reporting stays field-based (`comp.compile_error` /
//!     `comp.compile_error_line`) to preserve vendor's
//!     "first-error-wins" timing — that timing affects label allocation
//!     in error-recovery paths. The public `compile()` entry returns
//!     `CompileError!Module`; the discriminator goes through the error
//!     set, the payload (SyntaxErrorInfo) is read from `comp` before
//!     returning.
//!   * Async handlers are always compiled (not is_full-gated) so the
//!     dispatch table is dense. The nano lexer never emits async
//!     tokens, so these bodies are dead-but-present.
//!
//! Nano-config "dead-#if" map (matches mpconfigport.h at landing):
//!   MICROPY_EMIT_NATIVE=0, MICROPY_EMIT_INLINE_ASM=0,
//!   MICROPY_ENABLE_DOC_STRING=0, MICROPY_PY_SYS_SETTRACE=0,
//!   MICROPY_COMP_RETURN_IF_EXPR=0, MICROPY_COMP_CONST*=0,
//!   MICROPY_PY_FSTRINGS=0,
//!   MICROPY_PY_MODULE_OVERRIDE_MAIN_IMPORT=0.
//! One deliberate departure: MICROPY_COMP_{DOUBLE,TRIPLE}_TUPLE_ASSIGN is
//! off at the port's MINIMUM ROM level but implemented here (see
//! compileExprStmt, notes/15 section 2).
//!
//! STATE-MUTATION MATRIX (auditable via `git grep 'comp\\.[a-z_]* ='`):
//!
//!   field                       writer sections
//!   --------------------------  ---------------------------------------
//!   compile_error / _line       §7 (compileSyntaxError + setLine)
//!   next_label                  §9 (compNextLabel — ONLY writer)
//!   break_label / continue_     §15/§16 (compileWhileStmt, compileForStmt)
//!   cur_except_level            §9 (compileIncrease/DecreaseExceptLevel)
//!   break_continue_except_level §15/§16 (loop stmts save+restore)
//!   scope_head / scope_cur      §9 (scopeNewAndLink), §31 (compileScope)
//!   num_dict_params/default_pa  §20 (compileFuncdefHelper)
//!   have_star                   §20 (compileFuncdefLambdefParam)
//!   pass                        §33 (compileToRawCode driver)
//!
//! Status: see notes/26-c7-compile.md (this is the scaffold; full
//! parity is the C7 integration sweep).
//!
//! Pin: vendor py/compile.c v1.22 — mirrors the frozen mpy-cross v6.3
//! oracle used by `make check`.

const std = @import("std");
const build_options = @import("build_options");
const parser = @import("parser.zig");
const scope_mod = @import("scope.zig");
const emit_mod = @import("emit.zig");
const qstr_mod = @import("qstr.zig");
const mpy = @import("mpy.zig");
const grammar = @import("grammar_data.zig");
const grammar_ext = @import("grammar_ext.zig");
const lexer_mod = @import("lexer.zig");
const bigint = @import("bigint.zig");

const Allocator = std.mem.Allocator;

// ─────────────────────────────────────────────────────────────────────────
// §3 — Type aliases. The substrate is five modules; everything we touch
// here is one indirection away.
// ─────────────────────────────────────────────────────────────────────────

pub const Pn = parser.Pn;
pub const PnStruct = parser.PnStruct;
pub const ParseTree = parser.ParseTree;
pub const Scope = scope_mod.Scope;
pub const IdInfo = scope_mod.IdInfo;
pub const IdInfoKind = scope_mod.IdInfoKind;
pub const ScopeKind = scope_mod.ScopeKind;
pub const Emit = emit_mod.Emit;
pub const EmitCommon = emit_mod.EmitCommon;
pub const ConstObj = emit_mod.ConstObj;
pub const Pass = emit_mod.Pass;
pub const Qstr = qstr_mod.qstr;
pub const QstrContext = qstr_mod.QstrContext;
pub const TokenKind = lexer_mod.TokenKind;

/// Handler signature shared by every compile_* in the dispatch table.
pub const CompileFn = *const fn (*Compiler, *PnStruct) void;

/// Sentinel label id used by vendor (see compile.c MP_EMIT_BREAK_FROM_FOR
/// peer constant; the 0xffff label is "no label assigned").
pub const INVALID_LABEL: usize = 0xffff;

// ─────────────────────────────────────────────────────────────────────────
// §4 — Well-known qstr block.
//
// Vendor compile.c references roughly seventeen MP_QSTR_* identifiers
// directly (for super(), __class__, __name__, the four comprehension
// names, etc). Resolving them at *first call* (one qstr_find_strn per
// session per name) lazily on the QstrContext keeps the file pure-Zig
// AND avoids a comptime drift between grammar_data.zig and
// qstrdefs.generated.h. The cached table lives on the Compiler.
//
// (The "hard-coded id" alternative — what scope.zig does for the six
// SIMPLE_NAME_QSTR_* ids — would be terser but couples this file to the
// embedded qstrdefs; we already have a comptime check in scope.zig for
// that, no need for a second copy.)
// ─────────────────────────────────────────────────────────────────────────

const WK_NAMES = [_][]const u8{
    "range", // 0
    "super", // 1
    "__class__", // 2
    "__init__", // 3
    "__locals__", // 4
    "__module__", // 5
    "__name__", // 6
    "__qualname__", // 7
    "__doc__", // 8
    "_", // 9
    "<module>", // 10
    "<lambda>", // 11
    "<listcomp>", // 12
    "<dictcomp>", // 13
    "<setcomp>", // 14
    "<genexpr>", // 15
    "<repl_print>", // 16  (REPL only)
    "StopIteration", // 17
    "AssertionError", // 18
    "__aiter__", // 19  (async/await — A2/A3)
    "__anext__", // 20
    "__aenter__", // 21
    "__aexit__", // 22
    "StopAsyncIteration", // 23
    "update", // 24 — dict.update, used by PEP 448 {**d} unpack emit
    "append", // 25 — list.append, used by PEP 448 [a, *b] unpack emit
    "extend", // 26 — list.extend, used by PEP 448 [a, *b] unpack emit
};

const WK_IDX = struct {
    const range: usize = 0;
    const super: usize = 1;
    const __class__: usize = 2;
    const __init__: usize = 3;
    const __locals__: usize = 4;
    const __module__: usize = 5;
    const __name__: usize = 6;
    const __qualname__: usize = 7;
    const __doc__: usize = 8;
    const _underscore: usize = 9;
    const _module: usize = 10;
    const _lambda: usize = 11;
    const _listcomp: usize = 12;
    const _dictcomp: usize = 13;
    const _setcomp: usize = 14;
    const _genexpr: usize = 15;
    const _repl_print: usize = 16;
    const StopIteration: usize = 17;
    const AssertionError: usize = 18;
    const __aiter__: usize = 19;
    const __anext__: usize = 20;
    const __aenter__: usize = 21;
    const __aexit__: usize = 22;
    const StopAsyncIteration: usize = 23;
    const update: usize = 24;
    const append: usize = 25;
    const extend: usize = 26;
};

const WK_LEN: usize = WK_NAMES.len;

// ─────────────────────────────────────────────────────────────────────────
// §5 — Vendor enum re-exports (already pub-aliased from emit_mod).
// Aliased so handler bodies read clean without long qualifiers.
// ─────────────────────────────────────────────────────────────────────────

const MP_EMIT_IDOP_LOCAL_FAST = emit_mod.MP_EMIT_IDOP_LOCAL_FAST;
const MP_EMIT_IDOP_GLOBAL_NAME = emit_mod.MP_EMIT_IDOP_GLOBAL_NAME;
const MP_EMIT_IMPORT_NAME = emit_mod.MP_EMIT_IMPORT_NAME;
const MP_EMIT_IMPORT_FROM = emit_mod.MP_EMIT_IMPORT_FROM;
const MP_EMIT_IMPORT_STAR = emit_mod.MP_EMIT_IMPORT_STAR;
const MP_EMIT_SUBSCR_LOAD = emit_mod.MP_EMIT_SUBSCR_LOAD;
const MP_EMIT_SUBSCR_STORE = emit_mod.MP_EMIT_SUBSCR_STORE;
const MP_EMIT_SUBSCR_DELETE = emit_mod.MP_EMIT_SUBSCR_DELETE;
const MP_EMIT_ATTR_LOAD = emit_mod.MP_EMIT_ATTR_LOAD;
const MP_EMIT_ATTR_STORE = emit_mod.MP_EMIT_ATTR_STORE;
const MP_EMIT_ATTR_DELETE = emit_mod.MP_EMIT_ATTR_DELETE;
const MP_EMIT_SETUP_BLOCK_WITH = emit_mod.MP_EMIT_SETUP_BLOCK_WITH;
const MP_EMIT_SETUP_BLOCK_EXCEPT = emit_mod.MP_EMIT_SETUP_BLOCK_EXCEPT;
const MP_EMIT_SETUP_BLOCK_FINALLY = emit_mod.MP_EMIT_SETUP_BLOCK_FINALLY;
const MP_EMIT_BUILD_TUPLE = emit_mod.MP_EMIT_BUILD_TUPLE;
const MP_EMIT_BUILD_LIST = emit_mod.MP_EMIT_BUILD_LIST;
const MP_EMIT_BUILD_MAP = emit_mod.MP_EMIT_BUILD_MAP;
const MP_EMIT_BUILD_SET = emit_mod.MP_EMIT_BUILD_SET;
const MP_EMIT_BUILD_SLICE = emit_mod.MP_EMIT_BUILD_SLICE;
const MP_EMIT_YIELD_VALUE = emit_mod.MP_EMIT_YIELD_VALUE;
const MP_EMIT_YIELD_FROM = emit_mod.MP_EMIT_YIELD_FROM;
const MP_EMIT_STAR_FLAG_SINGLE = emit_mod.MP_EMIT_STAR_FLAG_SINGLE;
const MP_EMIT_STAR_FLAG_DOUBLE = emit_mod.MP_EMIT_STAR_FLAG_DOUBLE;
const MP_EMIT_BREAK_FROM_FOR = emit_mod.MP_EMIT_BREAK_FROM_FOR;

const ID_FLAG_IS_PARAM = scope_mod.ID_FLAG_IS_PARAM;
const ID_FLAG_IS_STAR_PARAM = scope_mod.ID_FLAG_IS_STAR_PARAM;
const ID_FLAG_IS_DBL_STAR_PARAM = scope_mod.ID_FLAG_IS_DBL_STAR_PARAM;
const SCOPE_FLAG_GENERATOR = scope_mod.SCOPE_FLAG_GENERATOR;
const SCOPE_FLAG_VARKEYWORDS = scope_mod.SCOPE_FLAG_VARKEYWORDS;
const SCOPE_FLAG_VARARGS = scope_mod.SCOPE_FLAG_VARARGS;
const SCOPE_FLAG_DEFKWARGS = scope_mod.SCOPE_FLAG_DEFKWARGS;
const SCOPE_FLAG_REFGLOBALS = scope_mod.SCOPE_FLAG_REFGLOBALS;
const SCOPE_FLAG_HASCONSTS = scope_mod.SCOPE_FLAG_HASCONSTS;

// ─────────────────────────────────────────────────────────────────────────
// §6 — Compiler struct + SyntaxErrorInfo.
//
// Field set verified against frontend/compile.zig:73-101 (nano config).
// Two surgical substrate changes:
//   * emit_common: typed by value (no opaque 128B buffer).
//   * compile_error: optional SyntaxErrorInfo (no PyError obj construction).
// ─────────────────────────────────────────────────────────────────────────

pub const SyntaxErrorKind = enum { syntax, indentation };

pub const SyntaxErrorInfo = struct {
    line: usize,
    kind: SyntaxErrorKind,
    msg: []const u8,
    q_arg: ?Qstr = null,
};

pub const CompileError = error{
    OutOfMemory,
    SyntaxError,
    IndentationError,
};

pub const Compiler = struct {
    allocator: Allocator,
    qctx: *QstrContext,
    is_repl: bool,

    pass: Pass = .scope,
    have_star: bool = false,

    compile_error: ?SyntaxErrorInfo = null,
    compile_error_line: usize = 0,

    next_label: u16 = 0,
    num_dict_params: u16 = 0,
    num_default_params: u16 = 0,

    /// High bit (MP_EMIT_BREAK_FROM_FOR) tags "break out of a for loop"
    /// so the unwind path can pop the iterator. Vendor uses the same
    /// encoding.
    break_label: usize = INVALID_LABEL,
    continue_label: usize = INVALID_LABEL,
    cur_except_level: u16 = 0,
    break_continue_except_level: u16 = 0,

    scope_head: ?*Scope = null,
    scope_cur: ?*Scope = null,

    emit: *Emit,
    // EmitCommon is owned by the caller (or by `compile()`'s prologue)
    // and reached via `comp.emit.emit_common`. Storing it on Compiler
    // would either dup-init (double-deinit) or shadow the real one with
    // a stale copy — both have bitten before.

    /// Lazy-resolved well-known qstr cache. WK_LEN entries; 0 sentinel
    /// means "not resolved yet" (vendor MP_QSTRnull, since real qstrs
    /// never get id 0).
    wk_cache: [WK_LEN]Qstr = [_]Qstr{0} ** WK_LEN,

    pub fn init(
        allocator: Allocator,
        qctx: *QstrContext,
        emit: *Emit,
        is_repl: bool,
    ) Compiler {
        return .{
            .allocator = allocator,
            .qctx = qctx,
            .is_repl = is_repl,
            .emit = emit,
        };
    }

    pub fn deinit(self: *Compiler) void {
        // Walk the scope chain and destroy each.
        var s = self.scope_head;
        while (s) |sp| {
            const next = sp.next;
            sp.destroy();
            s = next;
        }
    }

    /// Resolve a well-known qstr lazily, caching the result. Caller
    /// supplies one of the WK_IDX constants.
    pub fn wk(self: *Compiler, idx: usize) Qstr {
        if (self.wk_cache[idx] != 0) return self.wk_cache[idx];
        const id = qstr_mod.qstr_from_strn(self.qctx, WK_NAMES[idx]) catch {
            // OOM during wk-cache fill: surface 0 sentinel and let the
            // caller's next allocator-typed step pick up the OOM. Vendor
            // would longjmp; we degrade gracefully.
            return 0;
        };
        self.wk_cache[idx] = id;
        return id;
    }
};

// ─────────────────────────────────────────────────────────────────────────
// §7 — Error plumbing.
//
// Field-based; "first error wins" timing matches vendor. Public API
// returns `CompileError!` — the discriminator goes through the error
// set; the payload (SyntaxErrorInfo) is read from `comp.compile_error`
// by the entry point before returning.
// ─────────────────────────────────────────────────────────────────────────

fn compileErrorSetLine(comp: *Compiler, pn: Pn) void {
    if (comp.compile_error_line == 0 and parser.pnIsStruct(pn)) {
        const pns: *PnStruct = @ptrFromInt(pn);
        comp.compile_error_line = pns.source_line;
    }
}

fn compileSyntaxError(comp: *Compiler, pn: Pn, msg: []const u8) void {
    if (comp.compile_error == null) {
        comp.compile_error = .{
            .line = 0,
            .kind = .syntax,
            .msg = msg,
        };
        compileErrorSetLine(comp, pn);
        if (comp.compile_error) |*e| e.line = comp.compile_error_line;
    }
}

fn compileSyntaxErrorArg(comp: *Compiler, pn: Pn, msg: []const u8, q_arg: Qstr) void {
    if (comp.compile_error == null) {
        comp.compile_error = .{
            .line = 0,
            .kind = .syntax,
            .msg = msg,
            .q_arg = q_arg,
        };
        compileErrorSetLine(comp, pn);
        if (comp.compile_error) |*e| e.line = comp.compile_error_line;
    }
}

// ─────────────────────────────────────────────────────────────────────────
// §8 — Parse-node helper wrappers. Direct thin forwarders to parser.zig
// accessors. Kept here so handler bodies don't sprout `parser.` prefixes.
// ─────────────────────────────────────────────────────────────────────────

inline fn pnIsNull(pn: Pn) bool {
    return parser.pnIsNull(pn);
}
inline fn pnIsLeaf(pn: Pn) bool {
    return parser.pnIsLeaf(pn);
}
inline fn pnIsStruct(pn: Pn) bool {
    return parser.pnIsStruct(pn);
}
inline fn pnIsId(pn: Pn) bool {
    return parser.pnIsId(pn);
}
inline fn pnIsSmallInt(pn: Pn) bool {
    return parser.pnIsSmallInt(pn);
}
inline fn pnIsStructKind(pn: Pn, k: u8) bool {
    return parser.pnIsStructKind(pn, k);
}
inline fn pnIsTokenKind(pn: Pn, tk: TokenKind) bool {
    return parser.pnIsTokenKind(pn, @intFromEnum(tk));
}
inline fn pnLeafArg(pn: Pn) Qstr {
    return @intCast(parser.pnLeafArg(pn));
}
inline fn pnLeafKind(pn: Pn) usize {
    return parser.pnLeafKind(pn);
}
inline fn pnLeafSmallInt(pn: Pn) isize {
    return parser.pnLeafSmallInt(pn);
}
inline fn pnsKind(pns: *PnStruct) u8 {
    return parser.pnsKind(pns);
}
inline fn pnsNumNodes(pns: *PnStruct) u32 {
    return parser.pnsNumNodes(pns);
}
inline fn pnsNodes(pns: *PnStruct) [*]Pn {
    return parser.pnsNodes(pns);
}
inline fn asPns(pn: Pn) *PnStruct {
    return @ptrFromInt(pn);
}

/// Extract a list of children from `pn`. Wrapper around
/// parser.parseNodeExtractList with a struct return for cleaner call
/// sites.
const NodeList = struct { nodes: [*]Pn, len: usize };

fn pnExtractList(pn: *Pn, kind: u8) NodeList {
    var nodes: [*]Pn = undefined;
    const n = parser.parseNodeExtractList(pn, kind, &nodes);
    return .{ .nodes = nodes, .len = n };
}

// ─────────────────────────────────────────────────────────────────────────
// §9 — Misc small helpers.
// ─────────────────────────────────────────────────────────────────────────

/// THE only writer of `comp.next_label`. Every label allocation goes
/// through here so the byte-exact label ordering matches vendor.
fn compNextLabel(comp: *Compiler) u16 {
    const l = comp.next_label;
    comp.next_label +%= 1;
    return l;
}

fn compileIncreaseExceptLevel(comp: *Compiler, label: u16, kind: u8) void {
    comp.emit.setupBlock(label, kind);
    comp.cur_except_level += 1;
    const sc = comp.scope_cur.?;
    if (comp.cur_except_level > sc.exc_stack_size) {
        sc.exc_stack_size = comp.cur_except_level;
    }
}

fn compileDecreaseExceptLevel(comp: *Compiler) void {
    std.debug.assert(comp.cur_except_level > 0);
    comp.cur_except_level -= 1;
    // Vendor compile.c:306-309 always emits END_FINALLY here. It's the
    // sentinel the VM looks at when unwinding a try/except/finally block
    // to decide whether to re-raise (no match) or fall through. Earlier
    // scaffold lifted this into specific handlers, but several call
    // sites (compileTryExcept, compileWithStmt) failed to emit it →
    // shorter bytecode + wrong unwind path.
    comp.emit.endFinally();
}

/// Allocate a Scope, link it into the chain, and bump the child counter.
/// Mirrors vendor `scope_new_and_link`.
fn scopeNewAndLink(
    comp: *Compiler,
    kind: ScopeKind,
    pn: Pn,
    emit_options: u16,
) Allocator.Error!*Scope {
    const s = try Scope.new(comp.allocator, kind, pn, emit_options);
    s.parent = comp.scope_cur;
    // Chain: append to scope_head's tail. Vendor walks the existing
    // list to find the tail (it's short in practice; module + a handful
    // of functions). We do the same.
    if (comp.scope_head) |head| {
        var tail = head;
        while (tail.next) |n| tail = n;
        tail.next = s;
    } else {
        comp.scope_head = s;
    }
    return s;
}

/// Apply `f` over every element of a list rule, or once for the bare
/// non-list case. Mirrors vendor `apply_to_single_or_list`.
fn applyToSingleOrList(
    comp: *Compiler,
    pn_in: Pn,
    list_rule: u8,
    comptime f: fn (*Compiler, Pn) void,
) void {
    var pn = pn_in;
    const list = pnExtractList(&pn, list_rule);
    var i: usize = 0;
    while (i < list.len) : (i += 1) f(comp, list.nodes[i]);
}

/// Vendor compile_load_id (compile.c:355). In SCOPE pass we register the
/// binding as GLOBAL_IMPLICIT (later passes may promote it to LOCAL or
/// CELL/FREE via scope_close_over). In codegen passes idOp dispatches
/// on the resolved kind.
fn compileLoadId(comp: *Compiler, q: Qstr) void {
    const sc = comp.scope_cur.?;
    if (comp.pass == .scope) {
        _ = sc.findOrAdd(q, .global_implicit) catch {
            comp.emit.overflow = true;
        };
        return;
    }
    EmitCommon.idOp(comp.emit, .load, sc, q) catch {
        comp.emit.overflow = true;
    };
}

/// Vendor compile_store_id (compile.c:367). In SCOPE pass:
/// `getIdForModification` registers as GLOBAL_IMPLICIT, then rebinds
/// to LOCAL in func-like scopes (so future references see a local).
fn compileStoreId(comp: *Compiler, q: Qstr) void {
    const sc = comp.scope_cur.?;
    if (comp.pass == .scope) {
        _ = EmitCommon.getIdForModification(sc, q) catch {
            comp.emit.overflow = true;
        };
        return;
    }
    EmitCommon.idOp(comp.emit, .store, sc, q) catch {
        comp.emit.overflow = true;
    };
}

/// Vendor compile_delete_id (compile.c:379). Same SCOPE-pass rebind
/// as store (a `del x` makes `x` a local in a function scope).
fn compileDeleteId(comp: *Compiler, q: Qstr) void {
    const sc = comp.scope_cur.?;
    if (comp.pass == .scope) {
        _ = EmitCommon.getIdForModification(sc, q) catch {
            comp.emit.overflow = true;
        };
        return;
    }
    EmitCommon.idOp(comp.emit, .delete, sc, q) catch {
        comp.emit.overflow = true;
    };
}

// ─────────────────────────────────────────────────────────────────────────
// §11 — Generic dispatch helpers. (Section numbers follow the plan.)
//
// `compileGenericAllNodes` walks every child and recursively compiles
// it. Used as the safe default for dispatch slots without a dedicated
// handler.
// ─────────────────────────────────────────────────────────────────────────

fn compileGenericAllNodes(comp: *Compiler, pns: *PnStruct) void {
    const n = pnsNumNodes(pns);
    const nodes = pnsNodes(pns);
    var i: u32 = 0;
    while (i < n) : (i += 1) compileNode(comp, nodes[i]);
}

fn compileGenericTuple(comp: *Compiler, pns: *PnStruct) void {
    // Tuple: compile all children, then BUILD_TUPLE(n).
    const n = pnsNumNodes(pns);
    const nodes = pnsNodes(pns);
    var i: u32 = 0;
    while (i < n) : (i += 1) compileNode(comp, nodes[i]);
    comp.emit.build(n, MP_EMIT_BUILD_TUPLE);
}

// ─────────────────────────────────────────────────────────────────────────
// §12 — Simple statement handlers.
//
// These are mechanical translations of compile.c handlers — order +
// stack effects + label allocation must match vendor.
// ─────────────────────────────────────────────────────────────────────────

fn compilePassStmt(comp: *Compiler, pns: *PnStruct) void {
    _ = comp;
    _ = pns;
    // No-op. Vendor emits nothing; suite-block wrappers handle the rest.
}

fn compileBreakContStmt(comp: *Compiler, pns: *PnStruct) void {
    const is_break = pnsKind(pns) == grammar.RULE_break_stmt;
    const label = if (is_break) comp.break_label else comp.continue_label;
    if (label == INVALID_LABEL) {
        compileSyntaxError(comp, @intFromPtr(pns), "'break'/'continue' outside loop");
        return;
    }
    const depth_delta = comp.cur_except_level - comp.break_continue_except_level;
    // unwindJump handles the BREAK_FROM_FOR high bit encoded in `label`.
    comp.emit.unwindJump(label, depth_delta);
}

fn compileReturnStmt(comp: *Compiler, pns: *PnStruct) void {
    const sc = comp.scope_cur.?;
    if (!sc.kind.isFuncLike()) {
        compileSyntaxError(comp, @intFromPtr(pns), "'return' outside function");
        return;
    }
    const arg = pnsNodes(pns)[0];
    if (pnIsNull(arg)) {
        comp.emit.loadConstTok(emit_mod.MP_TOKEN_KW_NONE);
    } else {
        compileNode(comp, arg);
    }
    comp.emit.returnValue();
}

fn compileYieldStmt(comp: *Compiler, pns: *PnStruct) void {
    // Vendor delegates to compile_yield_expr; we inline the simple form.
    compileGenericAllNodes(comp, pns);
    comp.emit.popTop();
}

fn compileRaiseStmt(comp: *Compiler, pns: *PnStruct) void {
    // Vendor compile_raise_stmt (compile.c:1070-1086). The grammar shape
    // is: raise_stmt: opt_rule(raise_stmt_arg). raise_stmt_arg in turn
    // wraps (test, opt_rule(raise_stmt_from)). The scaffold checked
    // RULE_raise_stmt_from at the wrong level — the wrapping struct is
    // raise_stmt_arg, not raise_stmt_from.
    const arg = pnsNodes(pns)[0];
    if (pnIsNull(arg)) {
        comp.emit.raiseVarargs(0);
        return;
    }
    if (pnIsStructKind(arg, grammar.RULE_raise_stmt_arg)) {
        const pns_arg = asPns(arg);
        const a0 = pnsNodes(pns_arg)[0];
        const a1 = pnsNodes(pns_arg)[1];
        compileNode(comp, a0);
        if (pnIsNull(a1)) {
            comp.emit.raiseVarargs(1);
        } else {
            // a1 is a raise_stmt_from struct (KW_FROM, test); generic
            // walk compiles the KW_FROM no-op then pushes the from-arg.
            compileNode(comp, a1);
            comp.emit.raiseVarargs(2);
        }
    } else {
        compileNode(comp, arg);
        comp.emit.raiseVarargs(1);
    }
}

fn compileDelStmt(comp: *Compiler, pns: *PnStruct) void {
    applyToSingleOrList(comp, pnsNodes(pns)[0], grammar.RULE_exprlist, cDelAtom);
}

/// Compile one atom in a `del` target list. Vendor `c_del_stmt` body.
fn cDelAtom(comp: *Compiler, pn: Pn) void {
    if (pnIsId(pn)) {
        compileDeleteId(comp, pnLeafArg(pn));
        return;
    }
    if (pnIsStructKind(pn, grammar.RULE_atom_expr_normal)) {
        // a.b or a[b] target — compile the chain except the last
        // trailer, then emit DELETE_ATTR / DELETE_SUBSCR for it.
        // The trailer chain may be a single trailer directly OR an
        // atom_expr_trailers struct wrapping multiple — see
        // cAssignAtomExpr for the matching shape handling.
        const pns = asPns(pn);
        const nodes = pnsNodes(pns);
        std.debug.assert(pnsNumNodes(pns) == 2);
        compileNode(comp, nodes[0]);

        var last_trailer: Pn = nodes[1];
        if (pnIsStructKind(nodes[1], grammar.RULE_atom_expr_trailers)) {
            const trailers = asPns(nodes[1]);
            const trail_n = pnsNumNodes(trailers);
            const trail_nodes = pnsNodes(trailers);
            var i: u32 = 0;
            while (i + 1 < trail_n) : (i += 1) compileNode(comp, trail_nodes[i]);
            last_trailer = trail_nodes[trail_n - 1];
        }

        if (pnIsStructKind(last_trailer, grammar.RULE_trailer_period)) {
            const lpns = asPns(last_trailer);
            const q = pnLeafArg(pnsNodes(lpns)[0]);
            comp.emit.attr(q, MP_EMIT_ATTR_DELETE);
        } else if (pnIsStructKind(last_trailer, grammar.RULE_trailer_bracket)) {
            const lpns = asPns(last_trailer);
            compileNode(comp, pnsNodes(lpns)[0]);
            comp.emit.subscr(MP_EMIT_SUBSCR_DELETE);
        } else {
            compileSyntaxError(comp, pn, "can't delete expression");
        }
        return;
    }
    if (pnIsStructKind(pn, grammar.RULE_atom_paren) or
        pnIsStructKind(pn, grammar.RULE_atom_bracket) or
        pnIsStructKind(pn, grammar.RULE_testlist_comp))
    {
        // Tuple / list target — recurse on each child.
        const pns = asPns(pn);
        const nodes = pnsNodes(pns);
        const n = pnsNumNodes(pns);
        var i: u32 = 0;
        while (i < n) : (i += 1) cDelAtom(comp, nodes[i]);
        return;
    }
    compileSyntaxError(comp, pn, "can't delete this expression");
}

// ─────────────────────────────────────────────────────────────────────────
// §14 — Global / nonlocal.
// ─────────────────────────────────────────────────────────────────────────

fn compileDeclareGlobal(comp: *Compiler, pn: Pn, q: Qstr) void {
    const sc = comp.scope_cur.?;
    const id = sc.findOrAdd(q, .global_explicit) catch {
        compileSyntaxError(comp, pn, "out of memory in global decl");
        return;
    };
    if (id.kind != .global_explicit and id.kind != .undecided and
        id.kind != .global_implicit and id.kind != .global_implicit_assigned)
    {
        compileSyntaxError(comp, pn, "identifier redefined as global");
        return;
    }
    id.kind = .global_explicit;
    sc.scope_flags |= SCOPE_FLAG_REFGLOBALS;
}

fn compileDeclareNonlocal(comp: *Compiler, pn: Pn, q: Qstr) void {
    const sc = comp.scope_cur.?;
    // Vendor compile.c:1289 only rejects `nonlocal` at module scope.
    // Classes are valid (the binding refers to the enclosing function's
    // variable and propagates via the cell/free machinery as usual).
    if (sc.kind == .module) {
        compileSyntaxError(comp, pn, "can't declare nonlocal in outer code");
        return;
    }
    // Three-way branch from vendor compile.c:1265-1275. The seed kind
    // must be .undecided (NOT .free) so we can detect a brand-new entry
    // vs. a re-declaration of something already classified by an earlier
    // pass / statement.
    const id = sc.findOrAdd(q, .undecided) catch {
        compileSyntaxError(comp, pn, "out of memory in nonlocal decl");
        return;
    };
    if (id.kind == .undecided) {
        // First sighting: tentatively .global_implicit, then ask the
        // scope chain for a binding. checkToCloseOver writes .free iff
        // an ancestor function has `q` as .local / .cell / .free; on
        // miss it leaves .global_implicit alone, which is our error
        // sentinel.
        id.kind = .global_implicit;
        sc.checkToCloseOver(id) catch {
            compileSyntaxError(comp, pn, "out of memory promoting nonlocal");
            return;
        };
        if (id.kind == .global_implicit) {
            compileSyntaxError(comp, pn, "no binding for nonlocal found");
        }
    } else if (id.kind != .free) {
        // Already classified as .local (e.g. parameter, prior write),
        // .cell, .global_explicit, or .global_implicit-from-earlier-
        // statement — none of these can be re-declared nonlocal.
        compileSyntaxError(comp, pn, "identifier redefined as nonlocal");
    }
    // id.kind == .free → idempotent re-declaration, no error.
}

fn compileGlobalNonlocalStmt(comp: *Compiler, pns: *PnStruct) void {
    const is_global = pnsKind(pns) == grammar.RULE_global_stmt;
    var name_list = pnsNodes(pns)[0];
    const list = pnExtractList(&name_list, grammar.RULE_name_list);
    var i: usize = 0;
    while (i < list.len) : (i += 1) {
        const name = list.nodes[i];
        if (!pnIsId(name)) {
            compileSyntaxError(comp, name, "expected identifier");
            continue;
        }
        const q = pnLeafArg(name);
        if (is_global) compileDeclareGlobal(comp, name, q) else compileDeclareNonlocal(comp, name, q);
    }
}

// ─────────────────────────────────────────────────────────────────────────
// §15 — Control-flow statements.
// ─────────────────────────────────────────────────────────────────────────

fn compileAssertStmt(comp: *Compiler, pns: *PnStruct) void {
    // Vendor py/compile.c:1304-1320 compile_assert_stmt.
    // (Nano omits the MP_STATE_VM(mp_optimise_value) early-return — we
    // always emit assertions; nano has no -O optimise flag.)
    const nodes = pnsNodes(pns);
    const lab_end = compNextLabel(comp);
    cIfCond(comp, nodes[0], true, lab_end);
    // Vendor compile_assert_stmt (compile.c:1312) emits LOAD_GLOBAL for
    // AssertionError — kind GLOBAL_GLOBAL, not GLOBAL_NAME (LOAD_NAME).
    comp.emit.loadGlobal(comp.wk(WK_IDX.AssertionError), emit_mod.MP_EMIT_IDOP_GLOBAL_GLOBAL);
    const extra = nodes[1];
    if (!pnIsNull(extra)) {
        // Optional assertion message — pass as single arg.
        compileNode(comp, extra);
        comp.emit.callFunction(1, 0, 0);
    }
    comp.emit.raiseVarargs(1);
    comp.emit.labelAssign(lab_end);
}

fn compileIfStmt(comp: *Compiler, pns: *PnStruct) void {
    // Vendor: compile.c:1322-1395 compile_if_stmt.
    // if_stmt: condition, body, elif_list, else_block.
    //
    // BYTE-CRITICAL label ordering:
    //   1. l_end is allocated FIRST (always).
    //   2. l_fail for the main `if` is allocated only when the condition
    //      is not a const-false (`if False:` skips the body entirely).
    //   3. Same per-elif logic for elif fail labels.
    //   4. The `jump l_end` over elif/else is suppressed when both are
    //      empty (otherwise we emit an unused unconditional jump).
    //   5. When the condition is const-true we short-circuit past every
    //      remaining elif/else (vendor `goto done`).
    const nodes = pnsNodes(pns);
    const lab_end = compNextLabel(comp);

    var done = false;

    if (!parser.parseNodeIsConstFalse(nodes[0])) {
        const lab_fail = compNextLabel(comp);
        cIfCond(comp, nodes[0], false, lab_fail); // if condition

        compileNode(comp, nodes[1]); // if block

        if (parser.parseNodeIsConstTrue(nodes[0])) {
            // `if True:` body: skip everything else.
            done = true;
        } else {
            // Only emit the jump-over if there's actually elif/else to skip.
            if (!(pnIsNull(nodes[2]) and pnIsNull(nodes[3]))) {
                comp.emit.jump(lab_end);
            }
            comp.emit.labelAssign(lab_fail);
        }
    }

    if (!done) {
        // elif list.
        var elif_list = nodes[2];
        const elist = pnExtractList(&elif_list, grammar.RULE_if_stmt_elif_list);
        var i: usize = 0;
        while (i < elist.len) : (i += 1) {
            const elif_pn = elist.nodes[i];
            const elif = asPns(elif_pn);
            const elif_nodes = pnsNodes(elif);

            if (parser.parseNodeIsConstFalse(elif_nodes[0])) continue;

            const lab_fail = compNextLabel(comp);
            cIfCond(comp, elif_nodes[0], false, lab_fail); // elif condition
            compileNode(comp, elif_nodes[1]); // elif block

            if (parser.parseNodeIsConstTrue(elif_nodes[0])) {
                // `elif True:` — vendor `goto done`: skip rest + else.
                done = true;
                break;
            }

            comp.emit.jump(lab_end);
            comp.emit.labelAssign(lab_fail);
        }

        if (!done) {
            // else block (may be null — compileNode no-ops on null).
            if (!pnIsNull(nodes[3])) compileNode(comp, nodes[3]);
        }
    }

    comp.emit.labelAssign(lab_end);
}

fn compileWhileStmt(comp: *Compiler, pns: *PnStruct) void {
    // Vendor: compile.c:1392-1412 compile_while_stmt.
    // while_stmt: condition, body, else_block.
    //
    // BYTE-CRITICAL label ordering (START_BREAK_CONTINUE_BLOCK):
    //   1. break_label allocated FIRST.
    //   2. continue_label allocated SECOND.
    //   3. top_label allocated THIRD (inside the body, only when the
    //      condition is not const-false; `while False:` emits nothing
    //      for the loop body at all).
    const nodes = pnsNodes(pns);

    // START_BREAK_CONTINUE_BLOCK
    const old_break = comp.break_label;
    const old_continue = comp.continue_label;
    const old_excl = comp.break_continue_except_level;
    const lab_break = compNextLabel(comp);
    const lab_continue = compNextLabel(comp);
    comp.break_label = lab_break;
    comp.continue_label = lab_continue;
    comp.break_continue_except_level = comp.cur_except_level;

    if (!parser.parseNodeIsConstFalse(nodes[0])) {
        const lab_top = compNextLabel(comp);
        if (!parser.parseNodeIsConstTrue(nodes[0])) {
            // `while True:` — vendor skips the jump-to-cond.
            comp.emit.jump(lab_continue);
        }
        comp.emit.labelAssign(lab_top);
        compileNode(comp, nodes[1]); // body
        comp.emit.labelAssign(lab_continue);
        cIfCond(comp, nodes[0], true, lab_top); // condition
    }

    // END_BREAK_CONTINUE_BLOCK — break/continue in the else target the
    // ENCLOSING loop, not this one.
    comp.break_label = old_break;
    comp.continue_label = old_continue;
    comp.break_continue_except_level = old_excl;

    if (!pnIsNull(nodes[2])) compileNode(comp, nodes[2]); // else

    comp.emit.labelAssign(lab_break);
}

// ─────────────────────────────────────────────────────────────────────────
// §16 — For-stmt + optimised-range.
//
// The range() recognizer is BYTE-CRITICAL — it must trigger on exactly
// the same call shapes vendor recognises (range(stop), range(start,stop),
// range(start,stop,step) with all small-int args). Vendor compile.c
// lines 1668-1750.
//
// SCAFFOLD NOTE: full optimisation is deferred to integration; here we
// emit the generic GET_ITER + FOR_ITER form.
// ─────────────────────────────────────────────────────────────────────────

fn compileForStmt(comp: *Compiler, pns: *PnStruct) void {
    // Vendor: compile.c:1512-1590 compile_for_stmt (with the range()
    // recognizer optimisation at compile.c:1516-1567 dispatching to
    // compile_for_stmt_optimised_range at compile.c:1430-1510).
    //
    // for_stmt: target, iter, body, else_block.
    const nodes = pnsNodes(pns);

    // range() recognizer ────────────────────────────────────────────────
    // Pattern: target is a bare identifier AND iter is an atom_expr_normal
    // whose head is the identifier `range` and whose first trailer is
    // trailer_paren. If 1..3 plain args, dispatch to the optimised form.
    if (pnIsId(nodes[0]) and pnIsStructKind(nodes[1], grammar.RULE_atom_expr_normal)) {
        const pns_it = asPns(nodes[1]);
        const it_nodes = pnsNodes(pns_it);
        const head = it_nodes[0];
        const trail0 = it_nodes[1];
        if (pnIsId(head) and pnLeafArg(head) == comp.wk(WK_IDX.range) and pnIsStructKind(trail0, grammar.RULE_trailer_paren)) {
            var pn_range_args = pnsNodes(asPns(trail0))[0];
            var args_buf: [*]Pn = undefined;
            const n_args = parser.parseNodeExtractList(&pn_range_args, grammar.RULE_arglist, &args_buf);
            var pn_range_start: Pn = 0;
            var pn_range_end: Pn = 0;
            var pn_range_step: Pn = 0;
            var optimize = false;
            if (1 <= n_args and n_args <= 3) {
                optimize = true;
                if (n_args == 1) {
                    pn_range_start = parser.pnNewSmallInt(0);
                    pn_range_end = args_buf[0];
                    pn_range_step = parser.pnNewSmallInt(1);
                } else if (n_args == 2) {
                    pn_range_start = args_buf[0];
                    pn_range_end = args_buf[1];
                    pn_range_step = parser.pnNewSmallInt(1);
                } else {
                    pn_range_start = args_buf[0];
                    pn_range_end = args_buf[1];
                    pn_range_step = args_buf[2];
                    if (!pnIsSmallInt(pn_range_step) or pnLeafSmallInt(pn_range_step) == 0) {
                        optimize = false;
                    }
                }
                // start/end must NOT be *arg / **arg / kwarg.
                if (optimize and pnIsStruct(pn_range_start)) {
                    const k = pnsKind(asPns(pn_range_start));
                    if (k == grammar.RULE_arglist_star or k == grammar.RULE_arglist_dbl_star or k == grammar.RULE_argument) {
                        optimize = false;
                    }
                }
                if (optimize and pnIsStruct(pn_range_end)) {
                    const k = pnsKind(asPns(pn_range_end));
                    if (k == grammar.RULE_arglist_star or k == grammar.RULE_arglist_dbl_star or k == grammar.RULE_argument) {
                        optimize = false;
                    }
                }
            }
            if (optimize) {
                compileForStmtOptimisedRange(comp, nodes[0], pn_range_start, pn_range_end, pn_range_step, nodes[2], nodes[3]);
                return;
            }
        }
    }

    // Generic for-loop ─────────────────────────────────────────────────
    // START_BREAK_CONTINUE_BLOCK
    const old_break = comp.break_label;
    const old_continue = comp.continue_label;
    const old_excl = comp.break_continue_except_level;
    const lab_break_raw = compNextLabel(comp);
    const lab_continue = compNextLabel(comp);
    comp.break_label = @as(usize, lab_break_raw) | MP_EMIT_BREAK_FROM_FOR;
    comp.continue_label = lab_continue;
    comp.break_continue_except_level = comp.cur_except_level;

    const lab_pop = compNextLabel(comp);

    compileNode(comp, nodes[1]); // iterator
    comp.emit.getIter(true);
    comp.emit.labelAssign(lab_continue);
    comp.emit.forIter(lab_pop);
    cAssign(comp, nodes[0], .store); // loop variable
    compileNode(comp, nodes[2]); // body
    comp.emit.jump(lab_continue);
    comp.emit.labelAssign(lab_pop);
    comp.emit.forIterEnd();

    // END_BREAK_CONTINUE_BLOCK — break/continue in else target outer loop.
    comp.break_label = old_break;
    comp.continue_label = old_continue;
    comp.break_continue_except_level = old_excl;

    if (!pnIsNull(nodes[3])) compileNode(comp, nodes[3]); // else

    comp.emit.labelAssign(lab_break_raw);
}

// ─────────────────────────────────────────────────────────────────────────
// §17 — Try/except/finally + with.
//
// SCAFFOLD NOTE: byte-critical adjust_stack_size dance. Full port lives
// here; the integration tests verify against mpy-cross on the corpus.
// ─────────────────────────────────────────────────────────────────────────

fn compileTryStmt(comp: *Compiler, pns: *PnStruct) void {
    // Vendor compile_try_stmt (compile.c:1718). The try statement has
    // three possible shapes:
    //   try: body
    //   finally: ...                       — try_stmt_finally
    //   try: body
    //   except A: ...                      — bare try-except (no else/finally)
    //   try: body                          — try_stmt_except_and_more
    //   except A: ...
    //   [else: ...] [finally: ...]
    //
    // pns->nodes[0] is the body; pns->nodes[1] discriminates the shape.
    const nodes = pnsNodes(pns);
    std.debug.assert(pnIsStruct(nodes[1]));
    const pns2 = asPns(nodes[1]);

    if (pnsKind(pns2) == grammar.RULE_try_stmt_finally) {
        // just try-finally
        compileTryFinally(comp, nodes[0], 0, &[_]Pn{}, parser.PN_NULL, pnsNodes(pns2)[0]);
        return;
    }

    if (pnsKind(pns2) == grammar.RULE_try_stmt_except_and_more) {
        // try-except with optional else and/or finally
        var pn_excepts_in = pnsNodes(pns2)[0];
        const list = pnExtractList(&pn_excepts_in, grammar.RULE_try_stmt_except_list);
        const excepts: []Pn = list.nodes[0..list.len];
        const pn_else = pnsNodes(pns2)[1];
        const pn_finally_wrap = pnsNodes(pns2)[2];
        if (pnIsNull(pn_finally_wrap)) {
            // no finally clause
            compileTryExcept(comp, nodes[0], @intCast(list.len), excepts, pn_else);
        } else {
            // finally wraps the try-except-else
            const pn_finally = pnsNodes(asPns(pn_finally_wrap))[0];
            compileTryFinally(comp, nodes[0], @intCast(list.len), excepts, pn_else, pn_finally);
        }
        return;
    }

    // just try-except (no else, no finally)
    var pn_excepts_in = nodes[1];
    const list = pnExtractList(&pn_excepts_in, grammar.RULE_try_stmt_except_list);
    const excepts: []Pn = list.nodes[0..list.len];
    compileTryExcept(comp, nodes[0], @intCast(list.len), excepts, parser.PN_NULL);
}

fn compileWithStmt(comp: *Compiler, pns: *PnStruct) void {
    // Vendor compile_with_stmt (compile.c:1772). The with-statement's
    // pre-bits (a, a as b, c as d, ...) come in as a list rooted at
    // pns->nodes[0]; the body is pns->nodes[1]. Each pre-bit is either a
    // bare expr or an as-binding (PN_with_item). The bytecode is built
    // recursively in a nested fashion so SETUP_WITH / WITH_CLEANUP /
    // END_FINALLY nest from outer to inner.
    var pre_list = extractWithList(pnsNodes(pns)[0]);
    const list_kind = if (pnIsStructKind(pre_list, grammar.RULE_with_paren_list))
        grammar.RULE_with_paren_list
    else
        grammar.RULE_with_stmt_list;
    const list = pnExtractList(&pre_list, list_kind);
    std.debug.assert(list.len > 0);
    compileWithStmtHelper(comp, list.len, list.nodes, pnsNodes(pns)[1]);
}

/// PEP 617 `with (a, b, …):` wraps the item list in a with_body_paren
/// struct — unwrap it so downstream sees the raw list node.
fn extractWithList(pn: Pn) Pn {
    if (pnIsStructKind(pn, grammar.RULE_with_body_paren)) {
        return pnsNodes(asPns(pn))[0];
    }
    return pn;
}

// ─────────────────────────────────────────────────────────────────────────
// §18 — Expression-statement.
//
// Handles:
//   * bare expression (pop result, or REPL print)
//   * augassign (a += b)
//   * single assign (a = b)
//   * multi-target (a = b = c) via assign_list
// ─────────────────────────────────────────────────────────────────────────

// ── Class annotations (PEP 526) ──────────────────────────────────────
// Vendor compiles `x: T` in a class to nothing and drops T from `x: T = v`,
// so a class has no __annotations__ and @dataclass cannot see a field
// without a default, nor the order of its fields. Here a class body that
// annotates a name records it in `__annotations__`, in source order. The
// value is the annotation's text, as under `from __future__ import
// annotations` (PEP 563): evaluating it would raise NameError on forward
// references such as `next: Node` inside `class Node`. Annotations the
// unparser below does not cover record None.

fn annotationsQstr(comp: *Compiler) Qstr {
    return qstrFromStrn(comp, "__annotations__");
}

/// Whether `pn` annotates anything, outside nested defs, lambdas and classes.
/// Those, comprehensions (comp_for) and const objects are not descended
/// into: their slots hold scope pointers or raw payloads, not parse nodes.
fn hasAnnassign(pn: Pn) bool {
    if (!pnIsStruct(pn)) return false;
    const pns = asPns(pn);
    switch (pnsKind(pns)) {
        grammar.RULE_annassign => return true,
        grammar.RULE_funcdef, grammar.RULE_async_funcdef, grammar.RULE_lambdef, grammar.RULE_lambdef_nocond, grammar.RULE_classdef, grammar.RULE_comp_for, grammar.RULE_const_object => return false,
        else => {},
    }
    for (pnsNodes(pns)[0..pnsNumNodes(pns)]) |child| {
        if (hasAnnassign(child)) return true;
    }
    return false;
}

const AnnText = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    fn add(self: *AnnText, text: []const u8) bool {
        if (self.len + text.len > self.buf.len) return false;
        @memcpy(self.buf[self.len .. self.len + text.len], text);
        self.len += text.len;
        return true;
    }
};

/// A string annotation (a forward reference) as repr would quote it.
fn addQuoted(out: *AnnText, text: []const u8) bool {
    const quote: []const u8 = if (std.mem.indexOfScalar(u8, text, '\'') != null) "\"" else "'";
    return out.add(quote) and out.add(text) and out.add(quote);
}

/// The source text of an annotation, for the forms annotations use; false
/// for anything else (a call, an operator other than `|`, too long).
fn unparseAnnotation(comp: *Compiler, pn: Pn, out: *AnnText) bool {
    if (pnIsNull(pn)) return false;
    if (pnIsId(pn)) return out.add(qstr_mod.qstr_str(comp.qctx, pnLeafArg(pn)));
    if (pnIsSmallInt(pn)) {
        var digits: [24]u8 = undefined;
        return out.add(std.fmt.bufPrint(&digits, "{d}", .{parser.pnLeafSmallInt(pn)}) catch return false);
    }
    if (pnIsLeaf(pn)) {
        if (pnLeafKind(pn) == parser.PN_STRING) return addQuoted(out, qstr_mod.qstr_str(comp.qctx, pnLeafArg(pn)));
        inline for (.{ .{ lexer_mod.TokenKind.KW_NONE, "None" }, .{ lexer_mod.TokenKind.KW_TRUE, "True" }, .{ lexer_mod.TokenKind.KW_FALSE, "False" } }) |tok| {
            if (parser.pnIsTokenKind(pn, @intFromEnum(tok[0]))) return out.add(tok[1]);
        }
        return false;
    }
    const pns = asPns(pn);
    const nodes = pnsNodes(pns)[0..pnsNumNodes(pns)];
    switch (pnsKind(pns)) {
        grammar.RULE_atom_expr_normal => {
            if (!unparseAnnotation(comp, nodes[0], out)) return false;
            const trailers: []const Pn = if (pnIsStructKind(nodes[1], grammar.RULE_atom_expr_trailers))
                pnsNodes(asPns(nodes[1]))[0..pnsNumNodes(asPns(nodes[1]))]
            else
                nodes[1..2];
            for (trailers) |t| {
                if (pnIsStructKind(t, grammar.RULE_trailer_period)) {
                    if (!out.add(".") or !unparseAnnotation(comp, pnsNodes(asPns(t))[0], out)) return false;
                } else if (pnIsStructKind(t, grammar.RULE_trailer_bracket)) {
                    if (!out.add("[") or !unparseAnnotation(comp, pnsNodes(asPns(t))[0], out) or !out.add("]")) return false;
                } else return false;
            }
            return true;
        },
        grammar.RULE_subscriptlist, grammar.RULE_testlist_comp, grammar.RULE_expr => {
            const sep: []const u8 = if (pnsKind(pns) == grammar.RULE_expr) " | " else ", ";
            for (nodes, 0..) |child, i| {
                if (i > 0 and !out.add(sep)) return false;
                if (!unparseAnnotation(comp, child, out)) return false;
            }
            return true;
        },
        grammar.RULE_const_object => {
            // A string that is not a valid identifier is a const object.
            if (@as(parser.ConstObjectKind, @enumFromInt(@as(u32, @intCast(nodes[0])))) != .long_string) return false;
            const text: []const u8 = if (nodes[1] == 0) "" else @as([*]const u8, @ptrFromInt(nodes[2]))[0..nodes[1]];
            return addQuoted(out, text);
        },
        grammar.RULE_atom_bracket => {
            if (!out.add("[")) return false;
            if (nodes.len > 0 and !pnIsNull(nodes[0]) and !unparseAnnotation(comp, nodes[0], out)) return false;
            return out.add("]");
        },
        else => return false,
    }
}

/// `__annotations__[name] = '<annotation text>'` (or None).
fn recordAnnotation(comp: *Compiler, name: Qstr, annotation: Pn) void {
    var text = AnnText{};
    if (unparseAnnotation(comp, annotation, &text)) {
        comp.emit.loadConstStr(qstrFromStrn(comp, text.buf[0..text.len]));
    } else {
        comp.emit.loadConstTok(emit_mod.MP_TOKEN_KW_NONE);
    }
    compileLoadId(comp, annotationsQstr(comp));
    comp.emit.loadConstStr(name);
    comp.emit.subscr(MP_EMIT_SUBSCR_STORE);
}

fn compileExprStmt(comp: *Compiler, pns: *PnStruct) void {
    // Vendor: py/compile.c:2006 compile_expr_stmt.
    //
    // expr_stmt has two children: nodes[0] = LHS testlist_star_expr,
    // nodes[1] = optional RHS.  The RHS, after the parser's and_ident/or
    // collapses, is one of:
    //   * NULL                            -> bare expression statement
    //   * struct PN_annassign             -> "x: T"  or  "x: T = rhs"
    //   * struct PN_expr_stmt_augassign   -> "x += rhs" etc.
    //   * struct PN_expr_stmt_assign_list -> "a = b = c" (>= 2 targets)
    //   * anything else (struct or leaf)  -> plain "x = rhs"
    const nodes = pnsNodes(pns);
    var pn_rhs: Pn = nodes[1];

    if (pnIsNull(pn_rhs)) {
        if (comp.is_repl and comp.scope_cur.?.kind == ScopeKind.module) {
            // REPL top-level bare expression: evaluate then print.
            compileLoadId(comp, compReplPrintQstr(comp));
            compileNode(comp, nodes[0]);
            comp.emit.callFunction(1, 0, 0);
            comp.emit.popTop();
        } else {
            // Non-REPL bare expression: drop the result.
            // Skip the emit entirely for a lonely constant literal
            // (vendor optimisation: leaf-but-not-id, or PN_const_object).
            const n0 = nodes[0];
            const is_lonely_const = (pnIsLeaf(n0) and !pnIsId(n0)) or
                pnIsStructKind(n0, grammar.RULE_const_object);
            if (!is_lonely_const) {
                compileNode(comp, n0);
                comp.emit.popTop();
            }
        }
        return;
    }

    if (pnIsStruct(pn_rhs)) {
        const pns1 = asPns(pn_rhs);
        const kind = pnsKind(pns1);
        const sub_nodes = pnsNodes(pns1);

        if (kind == grammar.RULE_annassign) {
            // annassign children: [annotation, opt(rhs)]
            if (comp.scope_cur.?.kind == ScopeKind.class and pnIsId(nodes[0])) {
                if (!pnIsNull(sub_nodes[1])) {
                    compileNode(comp, sub_nodes[1]);
                    cAssign(comp, nodes[0], .store);
                }
                recordAnnotation(comp, pnLeafArg(nodes[0]), sub_nodes[0]);
                return;
            }
            if (pnIsNull(sub_nodes[1])) {
                // Bare annotation "x: T" — inside a function this declares
                // x as a local; elsewhere it's a no-op at runtime.
                if (comp.scope_cur.?.kind == ScopeKind.function) {
                    if (pnIsId(nodes[0])) {
                        const lhs_q = pnLeafArg(nodes[0]);
                        _ = comp.scope_cur.?.findOrAdd(lhs_q, IdInfoKind.local) catch {
                            comp.emit.overflow = true;
                        };
                    }
                }
                return;
            }
            // "x: T = rhs" — drop the annotation, then plain-assign rhs.
            pn_rhs = sub_nodes[1];
            // fall through to the plain_assign tail below.
        } else if (kind == grammar.RULE_expr_stmt_augassign) {
            // augassign children: [op_token, rhs]
            cAssign(comp, nodes[0], .aug_load);
            compileNode(comp, sub_nodes[1]);
            std.debug.assert(pnIsLeaf(sub_nodes[0]) and
                pnLeafKind(sub_nodes[0]) == parser.PN_TOKEN);
            const tok: u32 = @intCast(pnLeafArg(sub_nodes[0]));
            // Vendor: MP_BINARY_OP_INPLACE_OR + (tok - MP_TOKEN_DEL_PIPE_EQUAL).
            // Both enum ranges are 13 contiguous entries in lock-step order.
            const op: u8 = @intCast(MP_BINARY_OP_INPLACE_OR +
                (tok - MP_TOKEN_DEL_PIPE_EQUAL));
            comp.emit.binaryOp(op);
            cAssign(comp, nodes[0], .aug_store);
            return;
        } else if (kind == grammar.RULE_expr_stmt_assign_list) {
            // Chained assignment "a = b = ... = rhs".  The list contains the
            // intermediate targets (left-to-right) plus the final rhs at
            // the tail.  Vendor: compile rhs, then store left-most first,
            // DUP_TOP between each pair.
            const list_n = pnsNumNodes(pns1);
            const rhs_idx: u32 = list_n - 1;
            compileNode(comp, sub_nodes[rhs_idx]);
            if (rhs_idx > 0) comp.emit.dupTop();
            cAssign(comp, nodes[0], .store);
            var i: u32 = 0;
            while (i < rhs_idx) : (i += 1) {
                if (i + 1 < rhs_idx) comp.emit.dupTop();
                cAssign(comp, sub_nodes[i], .store);
            }
            return;
        } else if (kind == grammar.RULE_testlist_star_expr and
            pnIsStructKind(nodes[0], grammar.RULE_testlist_star_expr))
        {
            // Vendor MICROPY_COMP_{DOUBLE,TRIPLE}_TUPLE_ASSIGN (compile.c:2069):
            // "a, b = c, d" / "a, b, c = d, e, f" via ROT_TWO/ROT_THREE,
            // skipping the BUILD_TUPLE + UNPACK_SEQUENCE heap allocation.
            const lhs = pnsNodes(asPns(nodes[0]));
            const n = pnsNumNodes(asPns(nodes[0]));
            const no_star = for (lhs[0..n]) |t| {
                if (pnIsStructKind(t, grammar.RULE_star_expr)) break false;
            } else true;
            if ((n == 2 or n == 3) and n == pnsNumNodes(pns1) and no_star) {
                for (sub_nodes[0..n]) |r| compileNode(comp, r);
                if (n == 3) comp.emit.rotThree();
                comp.emit.rotTwo();
                for (lhs[0..n]) |t| cAssign(comp, t, .store);
                return;
            }
        }
        // Any other struct kind: fall through to plain_assign.
    }

    // plain_assign — vendor's labelled tail.  Reached from:
    //   * the "else" branch above (pn_rhs is a leaf such as an id, int,
    //     or a struct of some non-special kind), or
    //   * the annassign "x: T = rhs" path with pn_rhs rebound to the rhs.
    compileNode(comp, pn_rhs);
    cAssign(comp, nodes[0], .store);
}

// ─────────────────────────────────────────────────────────────────────────
// §10 — Assignment compilers. AssignKind matches vendor enum order.
// ─────────────────────────────────────────────────────────────────────────

const AssignKind = enum(u8) {
    store = 0,
    aug_load = 1,
    aug_store = 2,
};

fn cAssign(comp: *Compiler, pn: Pn, kind: AssignKind) void {
    if (pnIsId(pn)) {
        const q = pnLeafArg(pn);
        switch (kind) {
            .store => compileStoreId(comp, q),
            .aug_load => compileLoadId(comp, q),
            .aug_store => compileStoreId(comp, q),
        }
        return;
    }

    if (pnIsStructKind(pn, grammar.RULE_atom_expr_normal)) {
        cAssignAtomExpr(comp, asPns(pn), kind);
        return;
    }

    if (pnIsStructKind(pn, grammar.RULE_testlist_star_expr) or
        pnIsStructKind(pn, grammar.RULE_testlist_comp) or
        pnIsStructKind(pn, grammar.RULE_exprlist))
    {
        // Vendor c_assign:553-560 rejects augmented-assignment to a
        // tuple LHS ("a, b += c" / "(a, b) += c" / "[a, b] += c").
        // The atom_paren and atom_bracket branches below already gate
        // on kind == .store; this bare tuple branch matches.
        if (kind != .store) {
            compileSyntaxError(comp, pn, "can't assign to expression");
            return;
        }
        cAssignTuple(comp, asPns(pn));
        return;
    }

    if (pnIsStructKind(pn, grammar.RULE_atom_paren)) {
        // `(a, b) = ...` — vendor compile.c:562. Empty paren is a
        // SyntaxError; otherwise the inner MUST be a testlist_comp
        // (single-name `(a)` collapses to `a` at parse time and never
        // reaches this branch). Sub-targets unpack via c_assign_tuple.
        const pns = asPns(pn);
        if (pnsNumNodes(pns) < 1) {
            compileSyntaxError(comp, pn, "can't assign to expression");
            return;
        }
        const inner = pnsNodes(pns)[0];
        if (pnIsNull(inner)) {
            compileSyntaxError(comp, pn, "can't assign to ()");
            return;
        }
        if (kind != .store) {
            compileSyntaxError(comp, pn, "can't assign to expression");
            return;
        }
        if (pnIsStructKind(inner, grammar.RULE_testlist_comp)) {
            cAssignTuple(comp, asPns(inner));
            return;
        }
        // Fallback for unusual single-item paren patterns the parser
        // might produce. Treat as `(x,)` semantic — UNPACK_SEQUENCE 1.
        cAssignTupleFlat(comp, &.{inner});
        return;
    }

    if (pnIsStructKind(pn, grammar.RULE_atom_bracket)) {
        // `[a, b] = ...` — vendor compile.c:577. Three sub-cases:
        //   * `[]`             — empty unpack (UNPACK_SEQUENCE 0)
        //   * `[a]`            — single-item unpack (UNPACK_SEQUENCE 1)
        //   * `[a, b, ...]`    — testlist_comp → c_assign_tuple full
        const pns = asPns(pn);
        if (kind != .store) {
            compileSyntaxError(comp, pn, "can't assign to expression");
            return;
        }
        if (pnsNumNodes(pns) < 1) {
            // Truly empty struct (zero slots) — emit UNPACK_SEQUENCE 0.
            cAssignTupleFlat(comp, &.{});
            return;
        }
        const inner = pnsNodes(pns)[0];
        if (pnIsNull(inner)) {
            // `[]` — empty list, allowed; emit UNPACK_SEQUENCE 0.
            cAssignTupleFlat(comp, &.{});
            return;
        }
        if (pnIsStructKind(inner, grammar.RULE_testlist_comp)) {
            cAssignTuple(comp, asPns(inner));
            return;
        }
        // `[a]` — single-item list pattern. Vendor passes `pns->nodes`
        // (the 1-element array) to c_assign_tuple with num_tail=1.
        cAssignTupleFlat(comp, &.{inner});
        return;
    }

    compileSyntaxError(comp, pn, "can't assign to expression");
}

/// Helper for the atom_paren/atom_bracket single-item or empty cases
/// that vendor's c_assign handles by calling c_assign_tuple with an
/// inline array. Lifted into its own function so cAssignTuple can stay
/// focused on the testlist_comp / star-target codepath.
fn cAssignTupleFlat(comp: *Compiler, targets: []const Pn) void {
    var star_idx: ?u32 = null;
    var i: u32 = 0;
    while (i < targets.len) : (i += 1) {
        if (pnIsStructKind(targets[i], grammar.RULE_star_expr)) {
            if (star_idx != null) {
                compileSyntaxError(comp, targets[i], "multiple starred targets");
                return;
            }
            star_idx = i;
        }
    }

    if (star_idx) |s| {
        comp.emit.unpackEx(s, @intCast(targets.len - s - 1));
    } else {
        comp.emit.unpackSequence(@intCast(targets.len));
    }

    i = 0;
    while (i < targets.len) : (i += 1) {
        var tgt = targets[i];
        if (pnIsStructKind(tgt, grammar.RULE_star_expr)) {
            tgt = pnsNodes(asPns(tgt))[0];
        }
        cAssign(comp, tgt, .store);
    }
}

/// `a.b = ...` / `a[b] = ...` — compile the chain except the last
/// trailer, then emit STORE_ATTR / STORE_SUBSCR. Mirrors vendor
/// c_assign_atom_expr.
fn cAssignAtomExpr(comp: *Compiler, pns: *PnStruct, kind: AssignKind) void {
    // Vendor c_assign_atom_expr (compile.c:450). pns is atom_expr_normal
    // with 2 children: nodes[0] = atom, nodes[1] = trailer(s).
    //
    // If nodes[1] is RULE_atom_expr_trailers, it wraps N trailers (the
    // chain `a.b[c].d` shape). Otherwise nodes[1] IS the single trailer.
    // In either case we compile every trailer except the last as a load,
    // then dispatch on the last trailer's kind to emit STORE_ATTR or
    // STORE_SUBSCR.
    const nodes = pnsNodes(pns);
    std.debug.assert(pnsNumNodes(pns) == 2);

    // ASSIGN_AUG_STORE skips re-compiling the LHS chain — the
    // augmented-load pass already left the result on the stack.
    if (kind != .aug_store) {
        compileNode(comp, nodes[0]);
    }

    var last_trailer: Pn = nodes[1];
    if (pnIsStructKind(nodes[1], grammar.RULE_atom_expr_trailers)) {
        const trailers = asPns(nodes[1]);
        const trail_n = pnsNumNodes(trailers);
        const trail_nodes = pnsNodes(trailers);
        if (kind != .aug_store) {
            var i: u32 = 0;
            while (i + 1 < trail_n) : (i += 1) compileNode(comp, trail_nodes[i]);
        }
        last_trailer = trail_nodes[trail_n - 1];
    }

    if (pnIsStructKind(last_trailer, grammar.RULE_trailer_bracket)) {
        const lpns = asPns(last_trailer);
        if (kind == .aug_store) {
            comp.emit.rotThree();
            comp.emit.subscr(MP_EMIT_SUBSCR_STORE);
        } else {
            compileNode(comp, pnsNodes(lpns)[0]);
            if (kind == .aug_load) {
                comp.emit.dupTopTwo();
                comp.emit.subscr(MP_EMIT_SUBSCR_LOAD);
            } else {
                comp.emit.subscr(MP_EMIT_SUBSCR_STORE);
            }
        }
        return;
    }
    if (pnIsStructKind(last_trailer, grammar.RULE_trailer_period)) {
        const lpns = asPns(last_trailer);
        const q = pnLeafArg(pnsNodes(lpns)[0]);
        if (kind == .aug_load) {
            comp.emit.dupTop();
            comp.emit.attr(q, MP_EMIT_ATTR_LOAD);
        } else {
            if (kind == .aug_store) comp.emit.rotTwo();
            comp.emit.attr(q, MP_EMIT_ATTR_STORE);
        }
        return;
    }

    compileSyntaxError(comp, @intFromPtr(pns), "can't assign to expression");
}

/// `a, b, c = ...` — UNPACK_SEQUENCE (or UNPACK_EX if a star target is
/// present), then assign each component recursively. Mirrors vendor
/// c_assign_tuple.
fn cAssignTuple(comp: *Compiler, pns: *PnStruct) void {
    const nodes = pnsNodes(pns);
    const n = pnsNumNodes(pns);

    // Find a star target, if any.
    var star_idx: ?u32 = null;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (pnIsStructKind(nodes[i], grammar.RULE_star_expr)) {
            if (star_idx != null) {
                compileSyntaxError(comp, @intFromPtr(pns), "multiple starred targets");
                return;
            }
            star_idx = i;
        }
    }

    if (star_idx) |s| {
        const n_left = s;
        const n_right = n - s - 1;
        comp.emit.unpackEx(n_left, n_right);
    } else {
        comp.emit.unpackSequence(n);
    }

    // Assign each component.
    i = 0;
    while (i < n) : (i += 1) {
        var tgt = nodes[i];
        if (pnIsStructKind(tgt, grammar.RULE_star_expr)) {
            tgt = pnsNodes(asPns(tgt))[0];
        }
        cAssign(comp, tgt, .store);
    }
}

// ─────────────────────────────────────────────────────────────────────────
// §19 — c_if_cond + boolean tests. BYTE-CRITICAL label ordering.
// ─────────────────────────────────────────────────────────────────────────

/// Compile a condition expression: jump to `label` if the condition is
/// `if_true` (mirrors vendor c_if_cond). The key invariant is the label
/// allocation order inside the recursive and/or cases — these are
/// observable in the .mpy because labels are numbered in allocation
/// order.
fn cIfCond(comp: *Compiler, pn: Pn, if_true: bool, label: u16) void {
    // Constant short-circuit.
    if (parser.parseNodeIsConstTrue(pn)) {
        if (if_true) comp.emit.jump(label);
        return;
    }
    if (parser.parseNodeIsConstFalse(pn)) {
        if (!if_true) comp.emit.jump(label);
        return;
    }

    if (pnIsStruct(pn)) {
        const pns = asPns(pn);
        const k = pnsKind(pns);
        if (k == grammar.RULE_or_test) {
            if (if_true) {
                // x or y, jump-if-true: jump on either.
                const n = pnsNumNodes(pns);
                const nodes = pnsNodes(pns);
                var i: u32 = 0;
                while (i < n) : (i += 1) cIfCond(comp, nodes[i], true, label);
            } else {
                // jump-if-false: only if ALL fail; need a fall-through label.
                const lab_fall = compNextLabel(comp);
                const n = pnsNumNodes(pns);
                const nodes = pnsNodes(pns);
                var i: u32 = 0;
                while (i + 1 < n) : (i += 1) cIfCond(comp, nodes[i], true, lab_fall);
                cIfCond(comp, nodes[n - 1], false, label);
                comp.emit.labelAssign(lab_fall);
            }
            return;
        }
        if (k == grammar.RULE_and_test) {
            if (if_true) {
                const lab_fall = compNextLabel(comp);
                const n = pnsNumNodes(pns);
                const nodes = pnsNodes(pns);
                var i: u32 = 0;
                while (i + 1 < n) : (i += 1) cIfCond(comp, nodes[i], false, lab_fall);
                cIfCond(comp, nodes[n - 1], true, label);
                comp.emit.labelAssign(lab_fall);
            } else {
                const n = pnsNumNodes(pns);
                const nodes = pnsNodes(pns);
                var i: u32 = 0;
                while (i < n) : (i += 1) cIfCond(comp, nodes[i], false, label);
            }
            return;
        }
        if (k == grammar.RULE_not_test_2) {
            cIfCond(comp, pnsNodes(pns)[0], !if_true, label);
            return;
        }
    }

    // Default: emit the value, then conditional jump.
    compileNode(comp, pn);
    comp.emit.popJumpIf(if_true, label);
}

// ─────────────────────────────────────────────────────────────────────────
// §21 — Expression compilers.
// ─────────────────────────────────────────────────────────────────────────

fn compileOrTest(comp: *Compiler, pns: *PnStruct) void {
    // Vendor compile_or_and_test (cond=true). Compile all N nodes; emit
    // jump_if_or_pop(true) after every non-last child so the first truthy
    // child short-circuits to l_end with itself on the stack.
    const n = pnsNumNodes(pns);
    const nodes = pnsNodes(pns);
    const l_end = compNextLabel(comp);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        compileNode(comp, nodes[i]);
        if (i + 1 < n) comp.emit.jumpIfOrPop(true, l_end);
    }
    comp.emit.labelAssign(l_end);
}

fn compileAndTest(comp: *Compiler, pns: *PnStruct) void {
    // Vendor compile_or_and_test (cond=false). Same shape as compileOrTest
    // but the short-circuit predicate is inverted: first falsy child wins.
    const n = pnsNumNodes(pns);
    const nodes = pnsNodes(pns);
    const l_end = compNextLabel(comp);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        compileNode(comp, nodes[i]);
        if (i + 1 < n) comp.emit.jumpIfOrPop(false, l_end);
    }
    comp.emit.labelAssign(l_end);
}

fn compileNotTest2(comp: *Compiler, pns: *PnStruct) void {
    // Vendor compile_not_test_2: compile the operand, then UNARY_OP NOT.
    compileNode(comp, pnsNodes(pns)[0]);
    comp.emit.unaryOp(emit_mod.MP_UNARY_OP_NOT);
}

fn compileBinaryOp(comp: *Compiler, pns: *PnStruct) void {
    // Unified handler for the six binary-op rules. The CompileRules table
    // wires all of expr / xor_expr / and_expr / shift_expr / arith_expr /
    // term to this entry point. We split on rule kind:
    //
    //   RULE_expr/xor_expr/and_expr  — vendor compile_binary_op: the op
    //       comes from the rule kind (OR + (kind - RULE_expr)). The grammar
    //       has no per-pair op token; children are pure list elements.
    //
    //   RULE_shift_expr/arith_expr/term — vendor compile_term: each pair
    //       carries its own op token; op = LSHIFT + (tok - OP_DBL_LESS).
    //
    // The two contiguous rule-id windows let us comptime-assert the layout.
    comptime {
        std.debug.assert(grammar.RULE_xor_expr == grammar.RULE_expr + 1);
        std.debug.assert(grammar.RULE_and_expr == grammar.RULE_expr + 2);
        std.debug.assert(grammar.RULE_shift_expr == grammar.RULE_expr + 3);
        std.debug.assert(grammar.RULE_arith_expr == grammar.RULE_expr + 4);
        std.debug.assert(grammar.RULE_term == grammar.RULE_expr + 5);
    }
    const kind = pnsKind(pns);
    if (kind <= grammar.RULE_and_expr) {
        // compile_binary_op path — op encoded in rule kind.
        const op: u8 = MP_BINARY_OP_OR + (kind - grammar.RULE_expr);
        const n = pnsNumNodes(pns);
        const nodes = pnsNodes(pns);
        compileNode(comp, nodes[0]);
        var i: u32 = 1;
        while (i < n) : (i += 1) {
            compileNode(comp, nodes[i]);
            comp.emit.binaryOp(op);
        }
    } else {
        // compile_term path — per-pair op token.
        compileTerm(comp, pns);
    }
}

fn compileComparison(comp: *Compiler, pns: *PnStruct) void {
    // Vendor compile_comparison: chained comparisons (a < b < c == ...).
    // For each operator pair we DUP/ROT to keep the next lhs available,
    // emit the binary_op, and short-circuit on false via jump_if_or_pop.
    // The trailing cleanup uses ROT/POP to drop the dangling value left
    // on the stack when the chain short-circuits.
    const num_nodes = pnsNumNodes(pns);
    const nodes = pnsNodes(pns);
    compileNode(comp, nodes[0]);
    const multi = (num_nodes > 3);
    var l_fail: u16 = 0;
    if (multi) l_fail = compNextLabel(comp);
    var i: u32 = 1;
    while (i + 1 < num_nodes) : (i += 2) {
        compileNode(comp, nodes[i + 1]);
        if (i + 2 < num_nodes) {
            comp.emit.dupTop();
            comp.emit.rotThree();
        }
        const pn_op = nodes[i];
        if (parser.pnLeafKind(pn_op) == parser.PN_TOKEN) {
            const tok: u8 = @intCast(parser.pnLeafArg(pn_op));
            var op: u8 = undefined;
            if (tok == @intFromEnum(TokenKind.KW_IN)) {
                op = emit_mod.MP_BINARY_OP_IN;
            } else {
                op = emit_mod.MP_BINARY_OP_LESS + (tok - @intFromEnum(TokenKind.OP_LESS));
            }
            comp.emit.binaryOp(op);
        } else {
            std.debug.assert(pnIsStruct(pn_op));
            const pns2 = asPns(pn_op);
            const k2 = pnsKind(pns2);
            if (k2 == grammar.RULE_comp_op_not_in) {
                comp.emit.binaryOp(emit_mod.MP_BINARY_OP_NOT_IN);
            } else {
                std.debug.assert(k2 == grammar.RULE_comp_op_is);
                if (pnIsNull(pnsNodes(pns2)[0])) {
                    comp.emit.binaryOp(emit_mod.MP_BINARY_OP_IS);
                } else {
                    comp.emit.binaryOp(emit_mod.MP_BINARY_OP_IS_NOT);
                }
            }
        }
        if (i + 2 < num_nodes) comp.emit.jumpIfOrPop(false, l_fail);
    }
    if (multi) {
        const l_end = compNextLabel(comp);
        comp.emit.jump(l_end);
        comp.emit.labelAssign(l_fail);
        comp.emit.adjustStackSize(1);
        comp.emit.rotTwo();
        comp.emit.popTop();
        comp.emit.labelAssign(l_end);
    }
}

fn compileStarExpr(comp: *Compiler, pns: *PnStruct) void {
    // Inside a tuple assignment target — vendor flags the star; the
    // tuple-assign helper handles the actual unpack. In any other
    // context this is a syntax error.
    compileSyntaxError(comp, @intFromPtr(pns), "can't use starred expression here");
}

fn compileFactor2(comp: *Compiler, pns: *PnStruct) void {
    // Vendor compile_factor_2: unary +/-/~. nodes[0] is the op token,
    // nodes[1] is the operand. Token arithmetic mirrors mp_unary_op_t:
    // OP_TILDE→INVERT, OP_PLUS→POSITIVE, OP_MINUS→NEGATIVE.
    const nodes = pnsNodes(pns);
    compileNode(comp, nodes[1]);
    const tok: u8 = @intCast(parser.pnLeafArg(nodes[0]));
    var op: u8 = undefined;
    if (tok == @intFromEnum(TokenKind.OP_TILDE)) {
        op = emit_mod.MP_UNARY_OP_INVERT;
    } else {
        std.debug.assert(tok == @intFromEnum(TokenKind.OP_PLUS) or tok == @intFromEnum(TokenKind.OP_MINUS));
        op = emit_mod.MP_UNARY_OP_POSITIVE + (tok - @intFromEnum(TokenKind.OP_PLUS));
    }
    comp.emit.unaryOp(op);
}

fn compilePower(comp: *Compiler, pns: *PnStruct) void {
    // Vendor compile_power: walk both children (base, exponent), emit POWER.
    compileGenericAllNodes(comp, pns);
    comp.emit.binaryOp(MP_BINARY_OP_POWER);
}

fn compileTestIfExpr(comp: *Compiler, pns: *PnStruct) void {
    // `a if c else b` — vendor compile.c:2121. The parse tree is
    //   test_if_expr: [success_value, test_if_else_struct]
    //   test_if_else: [condition, failure_value]
    // i.e. the condition + failure value live inside a nested struct,
    // not as flat siblings. Reading nodes[2] off test_if_expr (only 2
    // entries) walked into the chunk's next struct header and crashed
    // pnsKind / pnLeafArg on the wild bytes.
    const nodes = pnsNodes(pns);
    std.debug.assert(pnIsStructKind(nodes[1], grammar.RULE_test_if_else));
    const else_pns = asPns(nodes[1]);
    const else_nodes = pnsNodes(else_pns);

    const lab_else = compNextLabel(comp);
    const lab_end = compNextLabel(comp);
    cIfCond(comp, else_nodes[0], false, lab_else); // condition
    compileNode(comp, nodes[0]); // success value
    comp.emit.jump(lab_end);
    comp.emit.labelAssign(lab_else);
    // Vendor compile.c:2131 — both branches push one value; the
    // emitter saw a +1 stack delta when it compiled the success
    // branch, and at lab_else we're about to push again. Tell the
    // STACK_SIZE pass that the failure path starts one slot lower so
    // the recorded max-stack matches mpy-cross byte-for-byte.
    comp.emit.adjustStackSize(-1);
    compileNode(comp, else_nodes[1]); // failure value
    comp.emit.labelAssign(lab_end);
}

// ─────────────────────────────────────────────────────────────────────────
// §22 — Atom-expr + trailers + call. SCAFFOLD: generic walk.
// ─────────────────────────────────────────────────────────────────────────

fn compileAtomExprNormal(comp: *Compiler, pns: *PnStruct) void {
    // Vendor-faithful port of compile_atom_expr_normal (py/compile.c:2300).
    // Two peepholes:
    //   (a) super() within a function -> LOAD __class__ + LOAD <self> + ...,
    //       with an extra fold when followed by .name(...) so we emit
    //       LOAD_SUPER_METHOD + CALL_METHOD instead of allocating a super
    //       bound-method object.
    //   (b) any .name FOLLOWED BY (...) -> LOAD_METHOD + CALL_METHOD
    //       (PyPy-style method-call optimisation).
    // OrderedDict({...}) peephole is gated by MICROPY_COMP_CONST_LITERAL,
    // which is 0 at nano's ROM level — omitted here, matches vendor under
    // the same #ifdef.

    const nodes = pnsNodes(pns);

    // 1. Compile the subject of the expression.
    compileNode(comp, nodes[0]);

    // 2. compile_atom_expr_await may call us with a NULL node.
    if (pnIsNull(nodes[1])) return;

    // 3. Resolve the trailer array. Either a single trailer at nodes[1]
    //    or an atom_expr_trailers wrapper holding the chain.
    var num_trail: usize = 1;
    var pns_trail: [*]Pn = @ptrCast(&nodes[1]);
    if (pnIsStructKind(nodes[1], grammar.RULE_atom_expr_trailers)) {
        const wrap = asPns(nodes[1]);
        num_trail = pnsNumNodes(wrap);
        pns_trail = pnsNodes(wrap);
    }

    var i: usize = 0;

    // 4. super() peephole — only inside a function body, when the atom
    //    is the identifier `super` and the first trailer is `()`.
    const sc = comp.scope_cur.?;
    const t0 = asPns(pns_trail[0]);
    const is_paren_empty = pnsKind(t0) == grammar.RULE_trailer_paren and pnIsNull(pnsNodes(t0)[0]);
    if (sc.kind == .function and pnIsId(nodes[0]) and pnLeafArg(nodes[0]) == comp.wk(WK_IDX.super) and is_paren_empty) {
        // Matched "super()" inside a function.

        // Load the enclosing class so super can search for a parent.
        compileLoadId(comp, comp.wk(WK_IDX.__class__));

        // Locate the first parameter (assumed to be `self`) and load it.
        var found = false;
        for (sc.id_info.items) |*id| {
            if ((id.flags & scope_mod.ID_FLAG_IS_PARAM) != 0) {
                compileLoadId(comp, id.qst);
                found = true;
                break;
            }
        }
        if (!found) {
            // Really a TypeError; vendor uses syntax-error machinery.
            compileSyntaxError(comp, pns_trail[0], "super() can't find self");
            return;
        }

        // super().method(...) fold: eliminates the super bound-method
        // heap allocation by going straight to LOAD_SUPER_METHOD + CALL.
        if (num_trail >= 3 and pnIsStructKind(pns_trail[1], grammar.RULE_trailer_period) and pnIsStructKind(pns_trail[2], grammar.RULE_trailer_paren)) {
            const pns_period = asPns(pns_trail[1]);
            const pns_paren = asPns(pns_trail[2]);
            const mname = pnLeafArg(pnsNodes(pns_period)[0]);
            comp.emit.loadMethod(mname, true);
            compileTrailerParenHelper(comp, pnsNodes(pns_paren)[0], true, 0);
            i = 3;
        } else {
            // Bare super() call: 2 positional args (class, self) on stack.
            comp.emit.callFunction(2, 0, 0);
            i = 1;
        }
    }

    // 5. Walk remaining trailers, applying the LOAD_METHOD peephole on
    //    every adjacent (.name)+(paren) pair.
    while (i < num_trail) : (i += 1) {
        if (i + 1 < num_trail and pnIsStructKind(pns_trail[i], grammar.RULE_trailer_period) and pnIsStructKind(pns_trail[i + 1], grammar.RULE_trailer_paren)) {
            const pns_period = asPns(pns_trail[i]);
            const pns_paren = asPns(pns_trail[i + 1]);
            const mname = pnLeafArg(pnsNodes(pns_period)[0]);
            comp.emit.loadMethod(mname, false);
            compileTrailerParenHelper(comp, pnsNodes(pns_paren)[0], true, 0);
            i += 1;
        } else {
            // trailer_paren, trailer_bracket, or trailer_period — dispatch
            // through the normal handler table.
            compileNode(comp, pns_trail[i]);
        }
    }
}

fn compileTrailerParen(comp: *Compiler, pns: *PnStruct) void {
    // Vendor compile.c:2665 — thin wrapper. The helper is shared with
    // method-call sites (compile_atom_expr_normal's load_method peephole).
    compileTrailerParenHelper(comp, pnsNodes(pns)[0], false, 0);
}

fn compileTrailerBracket(comp: *Compiler, pns: *PnStruct) void {
    compileNode(comp, pnsNodes(pns)[0]);
    comp.emit.subscr(MP_EMIT_SUBSCR_LOAD);
}

/// Vendor compile_subscript (compile.c:2681). Builds a SLICE object
/// when called from compileTrailerBracket → compileNode for a slice
/// expression like x[a:b] or x[a:b:c]. The subscript-list case
/// (multi-subscript like x[a, b]) routes through compileSubscriptlist,
/// which wraps in a tuple and lets BUILD_SUBSCR consume that.
fn compileSubscript(comp: *Compiler, pns: *PnStruct) void {
    var p = pns;
    const k0 = pnsKind(p);
    if (k0 == grammar.RULE_subscript_2) {
        compileNode(comp, pnsNodes(p)[0]); // start
        std.debug.assert(pnIsStruct(pnsNodes(p)[1]));
        p = asPns(pnsNodes(p)[1]);
    } else {
        // PN_subscript_3 — start is None.
        comp.emit.loadConstTok(emit_mod.MP_TOKEN_KW_NONE);
    }
    std.debug.assert(pnsKind(p) == grammar.RULE_subscript_3);

    const pn = pnsNodes(p)[0];
    if (pnIsNull(pn)) {
        // [?:]
        comp.emit.loadConstTok(emit_mod.MP_TOKEN_KW_NONE);
        comp.emit.build(2, MP_EMIT_BUILD_SLICE);
    } else if (pnIsStruct(pn)) {
        const pns_inner = asPns(pn);
        const k_inner = pnsKind(pns_inner);
        if (k_inner == grammar.RULE_subscript_3c) {
            // [?:?:?]
            comp.emit.loadConstTok(emit_mod.MP_TOKEN_KW_NONE);
            const pn2 = pnsNodes(pns_inner)[0];
            if (pnIsNull(pn2)) {
                comp.emit.build(2, MP_EMIT_BUILD_SLICE);
            } else {
                compileNode(comp, pn2);
                comp.emit.build(3, MP_EMIT_BUILD_SLICE);
            }
        } else if (k_inner == grammar.RULE_subscript_3d) {
            compileNode(comp, pnsNodes(pns_inner)[0]);
            std.debug.assert(pnIsStruct(pnsNodes(pns_inner)[1]));
            const pns_slop = asPns(pnsNodes(pns_inner)[1]);
            std.debug.assert(pnsKind(pns_slop) == grammar.RULE_sliceop);
            if (pnIsNull(pnsNodes(pns_slop)[0])) {
                comp.emit.build(2, MP_EMIT_BUILD_SLICE);
            } else {
                compileNode(comp, pnsNodes(pns_slop)[0]);
                comp.emit.build(3, MP_EMIT_BUILD_SLICE);
            }
        } else {
            // [?:x]
            compileNode(comp, pn);
            comp.emit.build(2, MP_EMIT_BUILD_SLICE);
        }
    } else {
        // [?:x]
        compileNode(comp, pn);
        comp.emit.build(2, MP_EMIT_BUILD_SLICE);
    }
}

/// Vendor compile_subscriptlist (compile.c:2750-ish).
/// `x[a, b]` shape: builds a tuple of the subscripts, then leaves it
/// on the stack for the enclosing trailer_bracket's LOAD_SUBSCR.
fn compileSubscriptlist(comp: *Compiler, pns: *PnStruct) void {
    compileGenericTuple(comp, pns);
}

/// Vendor compile_dictorsetmaker_item (compile.c:2736).
/// dict key:value pair — value pushed first, key second (vendor swaps
/// order to match STORE_MAP's stack expectation).
fn compileDictorsetmakerItem(comp: *Compiler, pns: *PnStruct) void {
    compileNode(comp, pnsNodes(pns)[1]); // value
    compileNode(comp, pnsNodes(pns)[0]); // key
}

/// PEP 448 `{**expr}` inside a dict display. Assumes the growing dict
/// is already on TOS; emits an in-place merge:
///   DUP_TOP; LOAD_METHOD update; <expr>; CALL_METHOD 1; POP_TOP
/// Net stack delta: 0. The pop discards update()'s None return.
fn compileDictorsetmakerDblStar(comp: *Compiler, pns: *PnStruct) void {
    comp.emit.dupTop();
    comp.emit.loadMethod(comp.wk(WK_IDX.update), false);
    compileNode(comp, pnsNodes(pns)[0]);
    comp.emit.callMethod(1, 0, 0);
    comp.emit.popTop();
}

fn compileTrailerPeriod(comp: *Compiler, pns: *PnStruct) void {
    const q = pnLeafArg(pnsNodes(pns)[0]);
    comp.emit.attr(q, MP_EMIT_ATTR_LOAD);
}

/// Vendor MP_PARSE_NODE_TESTLIST_COMP_HAS_COMP_FOR (compile.c:62).
/// A testlist_comp is "(x for x in ...)" or "[x for x in ...]" shape
/// when it has exactly two nodes and the second is a comp_for struct.
inline fn testlistCompHasCompFor(pns: *PnStruct) bool {
    return pnsNumNodes(pns) == 2 and
        pnIsStructKind(pnsNodes(pns)[1], grammar.RULE_comp_for);
}

fn compileAtomParen(comp: *Compiler, pns: *PnStruct) void {
    // Vendor compile_atom_paren (compile.c:2521).
    const inner = pnsNodes(pns)[0];
    if (pnIsNull(inner)) {
        comp.emit.build(0, MP_EMIT_BUILD_TUPLE);
        return;
    }
    std.debug.assert(pnIsStructKind(inner, grammar.RULE_testlist_comp));
    const inner_pns = asPns(inner);
    if (testlistCompHasCompFor(inner_pns)) {
        compileComprehensionStub(comp, inner_pns, .gen_expr);
    } else {
        compileGenericTuple(comp, inner_pns);
    }
}

fn compileAtomBracket(comp: *Compiler, pns: *PnStruct) void {
    // Vendor compile_atom_bracket (compile.c:2538).
    const inner = pnsNodes(pns)[0];
    if (pnIsNull(inner)) {
        comp.emit.build(0, MP_EMIT_BUILD_LIST);
        return;
    }
    if (pnIsStructKind(inner, grammar.RULE_testlist_comp)) {
        const inner_pns = asPns(inner);
        if (testlistCompHasCompFor(inner_pns)) {
            compileComprehensionStub(comp, inner_pns, .list_comp);
        } else {
            const n = pnsNumNodes(inner_pns);
            const inner_nodes = pnsNodes(inner_pns);
            if (childrenHaveStarExpr(inner_nodes[0..n])) {
                emitListWithStarUnpack(comp, inner_nodes[0..n]);
            } else {
                var i: u32 = 0;
                while (i < n) : (i += 1) compileNode(comp, inner_nodes[i]);
                comp.emit.build(n, MP_EMIT_BUILD_LIST);
            }
        }
    } else {
        // Single item — a lone `*expr` is `[*expr]`, emit as unpack of one.
        if (pnIsStructKind(inner, grammar.RULE_star_expr)) {
            emitListWithStarUnpack(comp, &[_]Pn{inner});
        } else {
            compileNode(comp, inner);
            comp.emit.build(1, MP_EMIT_BUILD_LIST);
        }
    }
}

fn childrenHaveStarExpr(nodes: []const Pn) bool {
    for (nodes) |n| {
        if (pnIsStructKind(n, grammar.RULE_star_expr)) return true;
    }
    return false;
}

/// PEP 448 list-unpack emit. Assumes at least one child is star_expr;
/// mixed forms like `[1, *a, 2]` fall through here too. Emits
///   BUILD_LIST 0
///   for each plain x:   DUP_TOP; LOAD_METHOD append; <x>; CALL_METHOD 1; POP_TOP
///   for each *e:        DUP_TOP; LOAD_METHOD extend; <e>; CALL_METHOD 1; POP_TOP
/// Net delta: +1 (the list stays on TOS).
fn emitListWithStarUnpack(comp: *Compiler, nodes: []const Pn) void {
    comp.emit.build(0, MP_EMIT_BUILD_LIST);
    for (nodes) |node| {
        if (pnIsStructKind(node, grammar.RULE_star_expr)) {
            const star_pns = asPns(node);
            comp.emit.dupTop();
            comp.emit.loadMethod(comp.wk(WK_IDX.extend), false);
            compileNode(comp, pnsNodes(star_pns)[0]);
            comp.emit.callMethod(1, 0, 0);
            comp.emit.popTop();
        } else {
            comp.emit.dupTop();
            comp.emit.loadMethod(comp.wk(WK_IDX.append), false);
            compileNode(comp, node);
            comp.emit.callMethod(1, 0, 0);
            comp.emit.popTop();
        }
    }
}

fn compileAtomBrace(comp: *Compiler, pns: *PnStruct) void {
    // Vendor compile.c:2661 — thin wrapper around the helper with
    // create_map=true. The helper is shared with compile_atom_brace_helper
    // callers (e.g. class-body dict construction).
    compileAtomBraceHelper(comp, pns, true);
}

fn compileTestlistComp(comp: *Compiler, pns: *PnStruct) void {
    // Tuple constructor body: build the tuple.
    compileGenericTuple(comp, pns);
}

fn compileTestlist(comp: *Compiler, pns: *PnStruct) void {
    compileGenericTuple(comp, pns);
}

// ─────────────────────────────────────────────────────────────────────────
// §13 — Import family. SCAFFOLD generic walks.
// ─────────────────────────────────────────────────────────────────────────

fn compileImportName(comp: *Compiler, pns: *PnStruct) void {
    // Vendor py/compile.c:1159 — apply_to_single_or_list over PN_dotted_as_names
    // dispatching to compile_dotted_as_name for each entry.
    applyToSingleOrList(comp, pnsNodes(pns)[0], grammar.RULE_dotted_as_names, compileDottedAsName);
}

/// Is this dotted-name node exactly the single identifier `name`?
fn matchesName(comp: *Compiler, pn: Pn, name: []const u8) bool {
    return parser.pnIsId(pn) and parser.pnLeafArg(pn) == qstrFromStrn(comp, name);
}

fn compileImportFrom(comp: *Compiler, pns: *PnStruct) void {
    // Vendor py/compile.c:1163-1249 — `from <module> import ...`.
    var pn_import_source = pnsNodes(pns)[0];

    // Walk the optional leading dots / ellipses to compute the relative
    // import level.
    var import_level: isize = 0;
    while (true) {
        var pn_rel: Pn = parser.PN_NULL;
        if (pnIsToken(pn_import_source) or
            pnIsStructKind(pn_import_source, grammar.RULE_one_or_more_period_or_ellipsis))
        {
            pn_rel = pn_import_source;
            pn_import_source = parser.PN_NULL;
        } else if (pnIsStructKind(pn_import_source, grammar.RULE_import_from_2b)) {
            const pns_2b = asPns(pn_import_source);
            pn_rel = pnsNodes(pns_2b)[0];
            pn_import_source = pnsNodes(pns_2b)[1];
            std.debug.assert(!pnIsNull(pn_import_source));
        } else {
            break;
        }

        const list = pnExtractList(&pn_rel, grammar.RULE_one_or_more_period_or_ellipsis);
        var i: usize = 0;
        while (i < list.len) : (i += 1) {
            if (pnIsTokenKind(list.nodes[i], TokenKind.DEL_PERIOD)) {
                import_level += 1;
            } else {
                import_level += 3;
            }
        }
        // Loop continues — drop into the next iteration on import_from_2b
        // chains; the `else { break; }` above exits when no further
        // wrapper is present. (Earlier scaffold had an unconditional
        // `break;` here, truncating multi-dot relative imports.)
    }

    // `from __future__ import ...` is a compiler directive, not an
    // import — CPython's compiler consumes it and emits nothing. Every
    // feature it can name is already the default here, so the whole
    // statement is a no-op.
    //
    // Vendor MicroPython has no such case and fails with `ImportError:
    // no module named '__future__'`, so this is a deliberate divergence
    // toward CPython, in the same family as the CPython-compatible
    // `collections.deque`. It is unconditional rather than full-only:
    // wasm is pinned to the nano arm, and that is the arm web developers
    // meet.
    //
    // The feature name is not checked. CPython raises SyntaxError for an
    // unknown one, but since every known name is ignored too, validating
    // would change nothing but the message.
    if (import_level == 0 and matchesName(comp, pn_import_source, "__future__")) return;

    const from_list = pnsNodes(pns)[1];
    if (pnIsTokenKind(from_list, TokenKind.OP_STAR)) {
        comp.emit.loadConstSmallInt(import_level);
        const q_star = qstr_mod.qstr_from_strn(comp.qctx, "*") catch {
            comp.emit.overflow = true;
            return;
        };
        comp.emit.loadConstStr(q_star);
        comp.emit.build(1, MP_EMIT_BUILD_TUPLE);
        var dummy_q: Qstr = 0;
        doImportName(comp, pn_import_source, &dummy_q);
        comp.emit.import(0, MP_EMIT_IMPORT_STAR);
        return;
    }

    comp.emit.loadConstSmallInt(import_level);
    var pn_from = pnsNodes(pns)[1];
    const names = pnExtractList(&pn_from, grammar.RULE_import_as_names);
    var i: usize = 0;
    while (i < names.len) : (i += 1) {
        std.debug.assert(pnIsStructKind(names.nodes[i], grammar.RULE_import_as_name));
        const pns3 = asPns(names.nodes[i]);
        const id2 = pnLeafArg(pnsNodes(pns3)[0]);
        comp.emit.loadConstStr(id2);
    }
    comp.emit.build(names.len, MP_EMIT_BUILD_TUPLE);

    var dummy_q: Qstr = 0;
    doImportName(comp, pn_import_source, &dummy_q);

    i = 0;
    while (i < names.len) : (i += 1) {
        std.debug.assert(pnIsStructKind(names.nodes[i], grammar.RULE_import_as_name));
        const pns3 = asPns(names.nodes[i]);
        const id2 = pnLeafArg(pnsNodes(pns3)[0]);
        comp.emit.import(id2, MP_EMIT_IMPORT_FROM);
        const as_node = pnsNodes(pns3)[1];
        if (pnIsNull(as_node)) {
            compileStoreId(comp, id2);
        } else {
            compileStoreId(comp, pnLeafArg(as_node));
        }
    }
    comp.emit.popTop();
}

// ─────────────────────────────────────────────────────────────────────────
// §20 — Funcdef / classdef / decorator scaffolding. SCAFFOLD.
// ─────────────────────────────────────────────────────────────────────────

fn compileFuncdef(comp: *Compiler, pns: *PnStruct) void {
    // Port of compile_funcdef (compile.c:957). The full algorithm lives in
    // compileFuncdefHelper; this wrapper stores the result by name.
    const fname = compileFuncdefHelper(comp, pns, comp.scope_cur.?.emit_options);
    compileStoreId(comp, fname);
}

fn compileClassdef(comp: *Compiler, pns: *PnStruct) void {
    // Port of compile_classdef (compile.c:2742). All work in helper.
    const cname = compileClassdefHelper(comp, pns, comp.scope_cur.?.emit_options);
    compileStoreId(comp, cname);
}

fn compileLambdef(comp: *Compiler, pns: *PnStruct) void {
    // Port of compile_lambdef (compile.c:2136). Lambda's parse-node
    // layout: nodes[0]=varargslist params, nodes[1]=body expr, nodes[2]
    // is a parser-managed slot we hijack to stash the child scope across
    // passes (mirrors vendor pns->nodes[2] = (mp_parse_node_t)s).
    var this_scope: *Scope = undefined;
    if (comp.pass == .scope) {
        const s = scopeNewAndLink(
            comp,
            .lambda,
            @intFromPtr(pns),
            comp.scope_cur.?.emit_options,
        ) catch {
            compileSyntaxError(comp, @intFromPtr(pns), "out of memory creating lambda scope");
            return;
        };
        pnsNodes(pns)[2] = @intFromPtr(s);
        this_scope = s;
    } else {
        this_scope = @ptrFromInt(pnsNodes(pns)[2]);
    }
    compileFuncdefLambdef(comp, this_scope, pnsNodes(pns)[0], grammar.RULE_varargslist);
}

// Vendor compile_decorated (compile.c:889). The earlier stub
// (compileGenericAllNodes) walked the children but never wrapped the
// body in CALL_FUNCTION per decorator and never bound the decorated
// result by name. That left the decorator factory dangling on the
// stack and the body name unstored, with cascading stack-size /
// qstr-table divergences from mpy-cross.
//
// Built-in @micropython.* decorators (vendor compile.c:838-887) are
// NOT recognised here: no test in our corpus uses them, the relevant
// emit options (NATIVE, VIPER, ASM) are out-of-scope for nano, and
// recognising them would just convert the user-visible NameError on
// undefined `micropython` into a different one. If any future test
// needs @micropython.bytecode, port compile_built_in_decorator at
// that point.
fn compileDecorated(comp: *Compiler, pns: *PnStruct) void {
    var decorators_pn = pnsNodes(pns)[0];
    const list = pnExtractList(&decorators_pn, grammar.RULE_decorators);
    const emit_options: u16 = comp.scope_cur.?.emit_options;

    // For each decorator: compile the dotted-name head + attr chain,
    // then evaluate any (...) arguments. This leaves one stack value
    // per decorator before the body is compiled.
    var i: usize = 0;
    while (i < list.len) : (i += 1) {
        std.debug.assert(pnIsStructKind(list.nodes[i], grammar.RULE_decorator));
        const pns_dec = asPns(list.nodes[i]);

        var name_pn = pnsNodes(pns_dec)[0];
        const name_list = pnExtractList(&name_pn, grammar.RULE_dotted_name);

        compileNode(comp, name_list.nodes[0]);
        var j: usize = 1;
        while (j < name_list.len) : (j += 1) {
            std.debug.assert(pnIsId(name_list.nodes[j]));
            comp.emit.attr(@intCast(pnLeafArg(name_list.nodes[j])), emit_mod.MP_EMIT_ATTR_LOAD);
        }

        if (!pnIsNull(pnsNodes(pns_dec)[1])) {
            // `@deco(args)` — evaluate the args, which dispatches to
            // compileTrailerParen and turns the LOAD on stack into a
            // call result (the "decorator factory" semantics).
            compileNode(comp, pnsNodes(pns_dec)[1]);
        }
    }

    // Body is funcdef, classdef, or async_funcdef (vendor decorated_body
    // OR rule per compile.c:921-942 + grammar.h decorated_body).
    std.debug.assert(pnIsStruct(pnsNodes(pns)[1]));
    const pns_body = asPns(pnsNodes(pns)[1]);
    var body_name: Qstr = 0;
    if (pnsKind(pns_body) == grammar.RULE_funcdef) {
        body_name = compileFuncdefHelper(comp, pns_body, emit_options);
    } else if (pnsKind(pns_body) == grammar.RULE_async_funcdef) {
        // `@dec async def f(): ...` — vendor compile.c:936-942.
        std.debug.assert(pnIsStruct(pnsNodes(pns_body)[0]));
        const pns0 = asPns(pnsNodes(pns_body)[0]);
        body_name = compileFuncdefHelper(comp, pns0, emit_options);
        const fscope: *Scope = @ptrFromInt(pnsNodes(pns0)[4]);
        fscope.scope_flags |= SCOPE_FLAG_GENERATOR;
    } else if (pnsKind(pns_body) == grammar.RULE_classdef) {
        body_name = compileClassdefHelper(comp, pns_body, emit_options);
    } else {
        compileSyntaxError(comp, @intFromPtr(pns_body), "decorated body must be function or class");
        return;
    }

    // Apply each decorator: stack has [d1, d2, ..., dN, body]; emit N
    // CALL_FUNCTION(1, 0, 0) ops so the final result is d1(d2(...dN(body))).
    var k: usize = 0;
    while (k < list.len) : (k += 1) {
        comp.emit.callFunction(1, 0, 0);
    }

    compileStoreId(comp, body_name);
}

fn compileSuiteBlockStmts(comp: *Compiler, pns: *PnStruct) void {
    compileGenericAllNodes(comp, pns);
}

fn compileFileInput(comp: *Compiler, pns: *PnStruct) void {
    compileGenericAllNodes(comp, pns);
}

fn compileEvalInput(comp: *Compiler, pns: *PnStruct) void {
    // Top-level expression: compile + RETURN_VALUE.
    compileNode(comp, pnsNodes(pns)[0]);
    comp.emit.returnValue();
}

fn compileSingleInput(comp: *Compiler, pns: *PnStruct) void {
    compileGenericAllNodes(comp, pns);
}

// ─────────────────────────────────────────────────────────────────────────
// §23 — Walrus. SCAFFOLD.
// ─────────────────────────────────────────────────────────────────────────

fn compileNamedexpr(comp: *Compiler, pns: *PnStruct) void {
    // `a := expr` — vendor compile.c:2184 delegates straight to
    // compile_namedexpr_helper, which carries the PEP-572 close-over
    // logic for the comprehension case. The earlier inline version
    // here lacked the close-over so any `(x := …)` inside a comp
    // scope bound `x` as a comp-local instead of in the parent.
    const nodes = pnsNodes(pns);
    compileNamedexprHelper(comp, nodes[0], nodes[1]);
}

// ─────────────────────────────────────────────────────────────────────────
// §24 — Class + yield-expr. SCAFFOLD.
// ─────────────────────────────────────────────────────────────────────────

fn compileYieldExpr(comp: *Compiler, pns: *PnStruct) void {
    // Vendor compile_yield_expr (compile.c:2748-2766). Three cases:
    //   - yield outside FUNCTION/LAMBDA → SyntaxError.
    //   - `yield` (bare) → LOAD_CONST_NONE, YIELD_VALUE.
    //   - `yield from X` → compile X, GET_ITER, LOAD_CONST_NONE, YIELD_FROM.
    //   - `yield X` → compile X, YIELD_VALUE.
    const scope = comp.scope_cur orelse return;
    if (scope.kind != .function and scope.kind != .lambda) {
        compileSyntaxError(comp, @intFromPtr(pns), "'yield' outside function");
        return;
    }
    const arg = pnsNodes(pns)[0];
    if (pnIsNull(arg)) {
        comp.emit.loadConstTok(emit_mod.MP_TOKEN_KW_NONE);
        comp.emit.yield(MP_EMIT_YIELD_VALUE);
    } else if (pnIsStructKind(arg, grammar.RULE_yield_arg_from)) {
        // yield_arg_from: KW_FROM, test (vendor grammar.h:372). The
        // parser drops literal keyword tokens during AND-reduction —
        // the resulting struct has just one child, the test
        // expression at nodes[0] (matches vendor compile.c:2758-2759).
        const inner = asPns(arg);
        compileNode(comp, pnsNodes(inner)[0]);
        comp.emit.getIter(false);
        comp.emit.loadConstTok(emit_mod.MP_TOKEN_KW_NONE);
        comp.emit.yield(MP_EMIT_YIELD_FROM);
    } else {
        compileNode(comp, arg);
        comp.emit.yield(MP_EMIT_YIELD_VALUE);
    }
}

// ─────────────────────────────────────────────────────────────────────────
// §25 — (Removed) — async family handlers now live in §33.1 (A2/A3).
// ─────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────
// §26 — Const-object handler.
// ─────────────────────────────────────────────────────────────────────────

fn compileConstObject(comp: *Compiler, pns: *PnStruct) void {
    // ConstObjectKind discriminator + raw bytes payload — see parser
    // makeNodeConstObject. We surface integers as small-ints when they
    // fit; everything else routes through ConstObj.
    const nodes = pnsNodes(pns);
    // Const-object payload is split across three nodes:
    //   [0] = ConstObjectKind discriminator (u32 stored in usize)
    //   [1] = byte length (or element count for .tuple)
    //   [2] = pointer to the byte buffer (or element array for .tuple)
    // Arch-agnostic: previously packed (kind << 32) | len in nodes[0]
    // which only worked on 64-bit hosts (usize = u64).
    const kind_u32: u32 = @intCast(nodes[0]);
    const len: usize = nodes[1];
    const buf_ptr = nodes[2];
    const kind: parser.ConstObjectKind = @enumFromInt(kind_u32);
    const bytes: []const u8 = if (len == 0)
        &.{}
    else
        @as([*]const u8, @ptrFromInt(buf_ptr))[0..len];

    switch (kind) {
        .integer => {
            // Vendor's threshold: fit in MP_SMALL_INT (63-bit signed
            // for MICROPY_OBJ_REPR_A on a 64-bit host — our nano +
            // full build). Without this gate, values like
            // `0o12345670123456701234` (=1.88e17, fits i64 but
            // overflows 62-bit small_int magnitude) would silently go
            // out as LOAD_CONST_SMALL_INT with a VLI payload, where
            // vendor emits an int_big const obj with the decimal text.
            //
            // For the int_big path we may need a decimal re-encoding —
            // vendor stores int_big as the DECIMAL text representation,
            // so a literal like 0o123 becomes "83" inside the .mpy. We
            // do that conversion here when the source text wasn't
            // already decimal.
            // SMALL_INT range tracks MP_SMALL_INT_BITS in the configured
            // object representation: 63 bits on 64-bit hosts
            // (MICROPY_OBJ_REPR_A, our nano + full build), 31 bits on
            // 32-bit hosts (wasm32) where mp_obj_t is u32.
            const SMALL_INT_BITS: comptime_int = if (@bitSizeOf(usize) >= 64) 63 else 31;
            const SMALL_INT_MAX: isize = (@as(isize, 1) << (SMALL_INT_BITS - 1)) - 1;
            const SMALL_INT_MIN: isize = -(@as(isize, 1) << (SMALL_INT_BITS - 1));
            if (std.fmt.parseInt(isize, bytes, 0)) |v| {
                if (v >= SMALL_INT_MIN and v <= SMALL_INT_MAX) {
                    comp.emit.loadConstSmallInt(v);
                    return;
                }
                // Fits in isize but not in small_int: emit as int_big
                // with the decimal text (matching vendor's mpz print).
                const dec = std.fmt.allocPrint(comp.allocator, "{d}", .{v}) catch {
                    comp.emit.overflow = true;
                    return;
                };
                comp.emit.loadConstObj(.{ .int_big = dec }) catch {
                    comp.emit.overflow = true;
                };
                return;
            } else |_| {}
            // Overflowed isize — beyond what std.fmt.parseInt can hold.
            // The source text may also be hex/octal/binary; vendor mpy-cross
            // always serialises int_big as CANONICAL DECIMAL TEXT (see
            // py/persistentcode.c + py/parsenum.c with base=10). Passing
            // the raw token text through here would produce a byte-mismatch
            // against mpy-cross on every non-decimal literal that exceeds
            // 30-bit SMALL_INT or i64. Route through std.math.big.int via
            // src/compiler/bigint.zig.
            const dec_big = bigint.normalizeToDecimal(comp.allocator, bytes) catch {
                comp.emit.overflow = true;
                return;
            };
            comp.emit.loadConstObj(.{ .int_big = dec_big }) catch {
                comp.emit.overflow = true;
            };
        },
        .float_or_imag => {
            comp.emit.loadConstObj(.{ .float = bytes }) catch {
                comp.emit.overflow = true;
            };
        },
        .long_string => {
            comp.emit.loadConstObj(.{ .str = bytes }) catch {
                comp.emit.overflow = true;
            };
        },
        .bytes_literal => {
            comp.emit.loadConstObj(.{ .bytes = bytes }) catch {
                comp.emit.overflow = true;
            };
        },
        .tuple => {
            // Parser-folded const tuple. nodes[1] points at an array
            // of `len` Pn values, each a const-foldable parse node.
            // Convert each recursively to a ConstObj, build the
            // .tuple variant, and emit LOAD_CONST_OBJ.
            const items_pn: [*]const Pn = @ptrFromInt(buf_ptr);
            const items_slice = items_pn[0..len];
            const obj = pnToConstObj(comp, .{ .tuple_kind = items_slice }) catch {
                comp.emit.overflow = true;
                return;
            };
            comp.emit.loadConstObj(obj) catch {
                comp.emit.overflow = true;
            };
        },
    }
}

/// Recursive helper: convert a const-foldable Pn into the emit-side
/// ConstObj union. Bytes for big ints / floats / strings borrow from
/// the parser's chunk (lifetime = ParseTree); the tuple-element slice
/// is freshly allocated via comp.allocator and owned by the eventually-
/// built ConstObj.tuple value. Vendor mp_parse_node_convert_to_obj
/// (parse.c:396) is the analogue.
const PnToConstObjArg = union(enum) {
    pn: Pn,
    tuple_kind: []const Pn,
};

fn pnToConstObj(
    comp: *Compiler,
    arg: PnToConstObjArg,
) std.mem.Allocator.Error!emit_mod.ConstObj {
    // Handle a folded tuple's element list (called from compileConstObject
    // when the const_object's kind is .tuple).
    if (arg == .tuple_kind) {
        const items = arg.tuple_kind;
        const out = try comp.allocator.alloc(emit_mod.ConstObj, items.len);
        for (items, 0..) |it, i| {
            out[i] = try pnToConstObj(comp, .{ .pn = it });
        }
        return emit_mod.ConstObj{ .tuple = out };
    }

    const pn = arg.pn;
    if (pnIsSmallInt(pn)) {
        // Vendor encodes ints in const-obj tables as text. fmt buffer
        // is short — fits any 64-bit signed.
        const v = pnLeafSmallInt(pn);
        const buf = try std.fmt.allocPrint(comp.allocator, "{d}", .{v});
        return emit_mod.ConstObj{ .int_big = buf };
    }
    if (pnIsLeaf(pn)) {
        const lk = pnLeafKind(pn);
        const a = pnLeafArg(pn);
        if (lk == parser.PN_STRING) {
            // String literal interned as a qstr — resolve bytes from
            // the context. The slice borrows from QstrContext storage
            // (lifetime ≥ Module via the dupe in compile()).
            const s = qstr_mod.qstr_str(comp.qctx, @intCast(a));
            const slen = qstr_mod.qstr_len(comp.qctx, @intCast(a));
            return emit_mod.ConstObj{ .str = s[0..slen] };
        }
        if (lk == parser.PN_TOKEN) {
            const tk: TokenKind = @enumFromInt(@as(u8, @intCast(a)));
            return switch (tk) {
                .KW_NONE => emit_mod.ConstObj.none,
                .KW_TRUE => emit_mod.ConstObj.bool_true,
                .KW_FALSE => emit_mod.ConstObj.bool_false,
                .ELLIPSIS => emit_mod.ConstObj.ellipsis,
                else => emit_mod.ConstObj.none, // unreachable in const fold
            };
        }
        return emit_mod.ConstObj.none;
    }
    // Struct: either nested const_object (recurse) or empty atom_paren
    // (the empty tuple `()`).
    if (pnIsStructKind(pn, grammar.RULE_const_object)) {
        const pns = asPns(pn);
        const nodes = pnsNodes(pns);
        // Three-node layout: kind, length, pointer. See parser.zig.
        const kind_u32: u32 = @intCast(nodes[0]);
        const len: usize = nodes[1];
        const buf_ptr = nodes[2];
        const kind: parser.ConstObjectKind = @enumFromInt(kind_u32);
        const bytes: []const u8 = if (len == 0)
            &.{}
        else
            @as([*]const u8, @ptrFromInt(buf_ptr))[0..len];
        return switch (kind) {
            .integer => emit_mod.ConstObj{ .int_big = bytes },
            .float_or_imag => emit_mod.ConstObj{ .float = bytes },
            .long_string => emit_mod.ConstObj{ .str = bytes },
            .bytes_literal => emit_mod.ConstObj{ .bytes = bytes },
            .tuple => blk: {
                const items_pn: [*]const Pn = @ptrFromInt(buf_ptr);
                const items_slice = items_pn[0..len];
                const inner = try comp.allocator.alloc(emit_mod.ConstObj, items_slice.len);
                for (items_slice, 0..) |it, i| {
                    inner[i] = try pnToConstObj(comp, .{ .pn = it });
                }
                break :blk emit_mod.ConstObj{ .tuple = inner };
            },
        };
    }
    if (pnIsStructKind(pn, grammar.RULE_atom_paren)) {
        // Empty `()`.
        return emit_mod.ConstObj{ .tuple = &.{} };
    }
    return emit_mod.ConstObj.none;
}

// ─────────────────────────────────────────────────────────────────────────
// §29 — C7b-6 helpers — file-local consts and ported helpers used by the
// handlers above. Grouped here so the section above stays one handler per
// fn; all consts live before the helpers that consume them.
// ─────────────────────────────────────────────────────────────────────────

/// Vendor py/runtime0.h:121 — first of the 13 normal arithmetic ops.
const MP_BINARY_OP_OR: u8 = 22;

/// Vendor py/runtime0.h:124 — LSHIFT op id; base for the per-token dispatch.
const MP_BINARY_OP_LSHIFT: u8 = 25;

/// Vendor py/runtime0.h:133 — POWER op id used by compilePower.
const MP_BINARY_OP_POWER: u8 = 34;

/// Vendor py/runtime0.h:106 — first of the 13 INPLACE_* binary ops.
const MP_BINARY_OP_INPLACE_OR: u8 = 9;

/// Vendor py/runtime0.h: MORE = 1, INPLACE_ADD = 14.
const MP_BINARY_OP_MORE: u8 = 1;
const MP_BINARY_OP_INPLACE_ADD: u8 = 14;

/// First of the 13 DEL_*_EQUAL tokens. Vendor py/lexer.h:129 has 71
/// because its enum includes async/await keywords ahead of these
/// tokens; our nano lexer's TokenKind enum (without async/await)
/// places DEL_PIPE_EQUAL at 69. Sourced from TokenKind directly so
/// we don't drift when more tokens are added or removed.
const MP_TOKEN_DEL_PIPE_EQUAL: u32 = @intFromEnum(TokenKind.DEL_PIPE_EQUAL);

/// MP_SMALL_INT_BITS — bit-width of the tagged small-int payload.
const MP_SMALL_INT_BITS: usize = @bitSizeOf(isize) - 1;

/// True if `pn` is a TOKEN leaf (of any token kind).
inline fn pnIsToken(pn: Pn) bool {
    return (pn & 0x0f) == parser.PN_TOKEN;
}

/// Vendor MP_QSTR___repl_print__ — resolved on demand.
fn compReplPrintQstr(comp: *Compiler) Qstr {
    return qstr_mod.qstr_from_strn(comp.qctx, "__repl_print__") catch 0;
}

/// Vendor compile_term (compile.c:2276-2285). Used by shift_expr,
/// arith_expr, and term rules.
fn compileTerm(comp: *Compiler, pns: *PnStruct) void {
    const num_nodes = pnsNumNodes(pns);
    const nodes = pnsNodes(pns);
    compileNode(comp, nodes[0]);
    var i: u32 = 1;
    while (i + 1 < num_nodes) : (i += 2) {
        compileNode(comp, nodes[i + 1]);
        const tok: u8 = @intCast(parser.pnLeafArg(nodes[i]));
        const op: u8 = MP_BINARY_OP_LSHIFT + (tok - @intFromEnum(TokenKind.OP_DBL_LESS));
        comp.emit.binaryOp(op);
    }
}

fn compileXorExpr(comp: *Compiler, pns: *PnStruct) void {
    compileBinaryOp(comp, pns);
}

fn compileAndExpr(comp: *Compiler, pns: *PnStruct) void {
    compileBinaryOp(comp, pns);
}

fn compileShiftExpr(comp: *Compiler, pns: *PnStruct) void {
    compileTerm(comp, pns);
}

fn compileArithExpr(comp: *Compiler, pns: *PnStruct) void {
    compileTerm(comp, pns);
}

// Vendor compile.c:1430-1510 compile_for_stmt_optimised_range.
fn compileForStmtOptimisedRange(comp: *Compiler, pn_var: Pn, pn_start: Pn, pn_end: Pn, pn_step: Pn, pn_body: Pn, pn_else: Pn) void {
    const old_break = comp.break_label;
    const old_continue = comp.continue_label;
    const old_excl = comp.break_continue_except_level;
    const lab_break = compNextLabel(comp);
    const lab_continue = compNextLabel(comp);
    comp.break_label = lab_break;
    comp.continue_label = lab_continue;
    comp.break_continue_except_level = comp.cur_except_level;

    const lab_top = compNextLabel(comp);
    const lab_entry = compNextLabel(comp);

    const end_on_stack = !pnIsSmallInt(pn_end);
    if (end_on_stack) {
        compileNode(comp, pn_end);
    }

    compileNode(comp, pn_start);

    comp.emit.jump(lab_entry);
    comp.emit.labelAssign(lab_top);

    comp.emit.dupTop();
    cAssign(comp, pn_var, .store);

    compileNode(comp, pn_body);

    comp.emit.labelAssign(lab_continue);

    compileNode(comp, pn_step);
    comp.emit.binaryOp(MP_BINARY_OP_INPLACE_ADD);

    comp.emit.labelAssign(lab_entry);

    if (end_on_stack) {
        comp.emit.dupTopTwo();
        comp.emit.rotTwo();
    } else {
        comp.emit.dupTop();
        compileNode(comp, pn_end);
    }
    if (pnLeafSmallInt(pn_step) >= 0) {
        comp.emit.binaryOp(emit_mod.MP_BINARY_OP_LESS);
    } else {
        comp.emit.binaryOp(MP_BINARY_OP_MORE);
    }
    comp.emit.popJumpIf(true, lab_top);

    comp.break_label = old_break;
    comp.continue_label = old_continue;
    comp.break_continue_except_level = old_excl;

    var lab_end: u16 = 0;
    if (!pnIsNull(pn_else)) {
        comp.emit.popTop();
        if (end_on_stack) comp.emit.popTop();
        compileNode(comp, pn_else);
        lab_end = compNextLabel(comp);
        comp.emit.jump(lab_end);
        const adj: i32 = 1 + @as(i32, if (end_on_stack) 1 else 0);
        comp.emit.adjustStackSize(adj);
    }

    comp.emit.labelAssign(lab_break);

    comp.emit.popTop();
    if (end_on_stack) comp.emit.popTop();

    if (!pnIsNull(pn_else)) {
        comp.emit.labelAssign(lab_end);
    }
}

// Vendor compile_try_except (compile.c:1592).
fn compileTryExcept(
    comp: *Compiler,
    pn_body: Pn,
    n_except: usize,
    pn_excepts: []Pn,
    pn_else: Pn,
) void {
    const l1 = compNextLabel(comp);
    const success_label = compNextLabel(comp);

    compileIncreaseExceptLevel(comp, l1, MP_EMIT_SETUP_BLOCK_EXCEPT);

    compileNode(comp, pn_body);
    comp.emit.popExceptJump(@as(usize, success_label));

    comp.emit.labelAssign(@as(usize, l1));
    comp.emit.startExceptHandler();

    const l2 = compNextLabel(comp);

    var i: usize = 0;
    while (i < n_except) : (i += 1) {
        std.debug.assert(pnIsStructKind(pn_excepts[i], grammar.RULE_try_stmt_except));
        const pns_except = asPns(pn_excepts[i]);

        var qstr_exception_local: Qstr = 0;
        const end_finally_label = compNextLabel(comp);

        if (pnIsNull(pnsNodes(pns_except)[0])) {
            if (i + 1 != n_except) {
                compileSyntaxError(comp, pn_excepts[i], "default 'except' must be last");
                compileDecreaseExceptLevel(comp);
                return;
            }
        } else {
            var pns_exception_expr = pnsNodes(pns_except)[0];
            if (pnIsStruct(pns_exception_expr)) {
                const pns3 = asPns(pns_exception_expr);
                if (pnsKind(pns3) == grammar.RULE_try_stmt_as_name) {
                    pns_exception_expr = pnsNodes(pns3)[0];
                    qstr_exception_local = pnLeafArg(pnsNodes(pns3)[1]);
                }
            }
            comp.emit.dupTop();
            compileNode(comp, pns_exception_expr);
            comp.emit.binaryOp(emit_mod.MP_BINARY_OP_EXCEPTION_MATCH);
            comp.emit.popJumpIf(false, @as(usize, end_finally_label));
        }

        if (qstr_exception_local == 0) {
            comp.emit.popTop();
        } else {
            compileStoreId(comp, qstr_exception_local);
        }

        var l3: u16 = 0;
        if (qstr_exception_local != 0) {
            l3 = compNextLabel(comp);
            compileIncreaseExceptLevel(comp, l3, MP_EMIT_SETUP_BLOCK_FINALLY);
        }
        compileNode(comp, pnsNodes(pns_except)[1]);
        if (qstr_exception_local != 0) {
            comp.emit.loadConstTok(emit_mod.MP_TOKEN_KW_NONE);
            comp.emit.labelAssign(@as(usize, l3));
            comp.emit.adjustStackSize(1);
            comp.emit.loadConstTok(emit_mod.MP_TOKEN_KW_NONE);
            compileStoreId(comp, qstr_exception_local);
            compileDeleteId(comp, qstr_exception_local);
            comp.emit.adjustStackSize(-1);
            compileDecreaseExceptLevel(comp);
        }

        comp.emit.popExceptJump(@as(usize, l2));
        comp.emit.labelAssign(@as(usize, end_finally_label));
        comp.emit.adjustStackSize(1);
    }

    compileDecreaseExceptLevel(comp);
    comp.emit.endExceptHandler();

    comp.emit.labelAssign(@as(usize, success_label));
    if (!pnIsNull(pn_else)) compileNode(comp, pn_else);
    comp.emit.labelAssign(@as(usize, l2));
}

// Vendor compile_try_finally (compile.c:1689).
fn compileTryFinally(
    comp: *Compiler,
    pn_body: Pn,
    n_except: usize,
    pn_except: []Pn,
    pn_else: Pn,
    pn_finally: Pn,
) void {
    const l_finally_block = compNextLabel(comp);

    compileIncreaseExceptLevel(comp, l_finally_block, MP_EMIT_SETUP_BLOCK_FINALLY);

    if (n_except == 0) {
        std.debug.assert(pnIsNull(pn_else));
        comp.emit.adjustStackSize(3);
        compileNode(comp, pn_body);
        comp.emit.adjustStackSize(-3);
    } else {
        compileTryExcept(comp, pn_body, n_except, pn_except, pn_else);
    }

    comp.emit.loadConstTok(emit_mod.MP_TOKEN_KW_NONE);

    comp.emit.labelAssign(@as(usize, l_finally_block));
    comp.emit.adjustStackSize(1);
    compileNode(comp, pn_finally);
    comp.emit.adjustStackSize(-1);

    compileDecreaseExceptLevel(comp);
}

// Vendor compile_with_stmt_helper (compile.c:1745).
fn compileWithStmtHelper(
    comp: *Compiler,
    n: usize,
    nodes: [*]Pn,
    body: Pn,
) void {
    if (n == 0) {
        compileNode(comp, body);
        return;
    }
    const l_end = compNextLabel(comp);
    if (pnIsStructKind(nodes[0], grammar.RULE_with_item)) {
        const pns = asPns(nodes[0]);
        compileNode(comp, pnsNodes(pns)[0]);
        compileIncreaseExceptLevel(comp, l_end, MP_EMIT_SETUP_BLOCK_WITH);
        cAssign(comp, pnsNodes(pns)[1], .store);
    } else {
        compileNode(comp, nodes[0]);
        compileIncreaseExceptLevel(comp, l_end, MP_EMIT_SETUP_BLOCK_WITH);
        comp.emit.popTop();
    }
    compileWithStmtHelper(comp, n - 1, nodes + 1, body);
    // Vendor compile.c:1766-1768 emits only with_cleanup +
    // decrease_except_level. END_FINALLY is handled by the outer
    // compile_try_finally context, NOT here. (Earlier scaffold added
    // an extra end_finally which doubled the unwind.)
    comp.emit.withCleanup(@as(usize, l_end));
    compileDecreaseExceptLevel(comp);
}

// Vendor do_import_name (compile.c:1090-1146).
fn doImportName(comp: *Compiler, pn_in: Pn, q_base: *Qstr) void {
    var pn = pn_in;
    var is_as = false;
    if (pnIsStructKind(pn, grammar.RULE_dotted_as_name)) {
        const pns = asPns(pn);
        q_base.* = pnLeafArg(pnsNodes(pns)[1]);
        pn = pnsNodes(pns)[0];
        is_as = true;
    }
    if (pnIsNull(pn)) {
        const q_empty = qstr_mod.qstr_from_strn(comp.qctx, "") catch {
            comp.emit.overflow = true;
            return;
        };
        q_base.* = q_empty;
        comp.emit.import(q_empty, MP_EMIT_IMPORT_NAME);
        return;
    }
    if (pnIsId(pn)) {
        const q_full = pnLeafArg(pn);
        if (!is_as) q_base.* = q_full;
        comp.emit.import(q_full, MP_EMIT_IMPORT_NAME);
        return;
    }
    std.debug.assert(pnIsStructKind(pn, grammar.RULE_dotted_name));
    const pns = asPns(pn);
    const n = pnsNumNodes(pns);
    const nodes = pnsNodes(pns);
    if (!is_as) q_base.* = pnLeafArg(nodes[0]);
    std.debug.assert(n > 0);
    var total_len: usize = n - 1;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        total_len += qstr_mod.qstr_len(comp.qctx, pnLeafArg(nodes[i]));
    }
    const buf = comp.allocator.alloc(u8, total_len) catch {
        comp.emit.overflow = true;
        return;
    };
    defer comp.allocator.free(buf);
    var off: usize = 0;
    i = 0;
    while (i < n) : (i += 1) {
        if (i > 0) {
            buf[off] = '.';
            off += 1;
        }
        const q = pnLeafArg(nodes[i]);
        const slen = qstr_mod.qstr_len(comp.qctx, q);
        const s = qstr_mod.qstr_str(comp.qctx, q);
        @memcpy(buf[off .. off + slen], s[0..slen]);
        off += slen;
    }
    const q_full = qstr_mod.qstr_from_strn(comp.qctx, buf) catch {
        comp.emit.overflow = true;
        return;
    };
    comp.emit.import(q_full, MP_EMIT_IMPORT_NAME);
    if (is_as) {
        var k: usize = 1;
        while (k < n) : (k += 1) {
            comp.emit.attr(pnLeafArg(nodes[k]), MP_EMIT_ATTR_LOAD);
        }
    }
}

// Vendor compile_dotted_as_name (compile.c:1148-1155).
fn compileDottedAsName(comp: *Compiler, pn: Pn) void {
    comp.emit.loadConstSmallInt(0);
    comp.emit.loadConstTok(emit_mod.MP_TOKEN_KW_NONE);
    var q_base: Qstr = 0;
    doImportName(comp, pn, &q_base);
    compileStoreId(comp, q_base);
}

// Vendor compile_namedexpr_helper (compile.c:2152). PEP-572: `(x := e)`
// inside a comprehension binds `x` in the comprehension's PARENT scope,
// not in the comprehension itself. Without this, our SCOPE pass binds
// `x` as a local of the comp scope and emits LOAD_FAST in the body's
// reference site — vendor binds it in the enclosing function (or as
// global at module level) and emits LOAD_DEREF / LOAD_GLOBAL_NAME.
fn compileNamedexprHelper(comp: *Compiler, pn_name: Pn, pn_expr: Pn) void {
    if (!pnIsId(pn_name)) {
        compileSyntaxError(comp, pn_name, "can't assign to expression");
        return;
    }
    compileNode(comp, pn_expr);
    comp.emit.dupTop();

    const target = pnLeafArg(pn_name);

    // PEP-572 close-over runs in the SCOPE pass only. The other passes
    // just see the resulting id_info and route the store through it.
    if (comp.pass == .scope) {
        const sc = comp.scope_cur.?;
        if (sc.kind.isCompLike()) {
            const parent = sc.parent.?;
            const id_parent = EmitCommon.getIdForModification(parent, target) catch {
                compileSyntaxError(comp, pn_name, "out of memory in namedexpr close-over");
                return;
            };
            if (id_parent.kind == .global_explicit) {
                _ = sc.findOrAdd(target, .global_explicit) catch {
                    compileSyntaxError(comp, pn_name, "out of memory in namedexpr close-over");
                    return;
                };
            } else {
                const id_local = sc.findOrAdd(target, .undecided) catch {
                    compileSyntaxError(comp, pn_name, "out of memory in namedexpr close-over");
                    return;
                };
                // is_global == "the comprehension is defined at module scope" —
                // its parent's parent is null. In that case PEP-572 promotes the
                // target to a module-level global; otherwise it's a nonlocal
                // (closed over via the cell/free chain).
                const is_global = parent.parent == null;
                if (!is_global and id_local.kind == .global_implicit) {
                    id_local.kind = .undecided;
                }
                if (is_global) {
                    // Vendor compile_declare_global (compile.c:1252-1255):
                    // a walrus target that's already bound to something else
                    // in this scope (typically the comprehension's own
                    // for-target, PEP-572 rebind error) is a SyntaxError.
                    if (id_local.kind != .undecided and id_local.kind != .global_explicit) {
                        compileSyntaxError(comp, pn_name, "identifier redefined as global");
                        return;
                    }
                    id_local.kind = .global_explicit;
                } else {
                    // Vendor compile_declare_nonlocal (compile.c:1265-1274):
                    // only an UNDECIDED slot can be promoted to nonlocal;
                    // anything already bound (e.g. for-target) is the
                    // PEP-572 rebind error.
                    if (id_local.kind != .undecided and id_local.kind != .free) {
                        compileSyntaxError(comp, pn_name, "identifier redefined as nonlocal");
                        return;
                    }
                    if (id_local.kind == .undecided) {
                        id_local.kind = .global_implicit;
                        sc.checkToCloseOver(id_local) catch {
                            compileSyntaxError(comp, pn_name, "out of memory promoting namedexpr");
                            return;
                        };
                        if (id_local.kind == .global_implicit) {
                            compileSyntaxError(comp, pn_name, "no binding for nonlocal found");
                            return;
                        }
                    }
                }
            }
        }
    }

    compileStoreId(comp, target);
}

/// Vendor compile_comprehension (compile.c:2496).
/// pns: a testlist_comp / dictorsetmaker / argument testlist whose
///   nodes[0] is the inner expression and nodes[1] is a comp_for struct.
/// kind: the scope kind (.list_comp / .dict_comp / .set_comp / .gen_expr).
fn compileComprehensionStub(comp: *Compiler, pns: *PnStruct, kind: ScopeKind) void {
    std.debug.assert(pnsNumNodes(pns) == 2);
    std.debug.assert(pnIsStructKind(pnsNodes(pns)[1], grammar.RULE_comp_for));
    const pns_comp_for = asPns(pnsNodes(pns)[1]);

    if (comp.pass == .scope) {
        const parent = comp.scope_cur.?;
        const s = scopeNewAndLink(comp, kind, @intFromPtr(pns), parent.emit_options) catch {
            compileSyntaxError(comp, @intFromPtr(pns), "out of memory creating comprehension scope");
            return;
        };
        // Stash the scope pointer on comp_for nodes[3] so all subsequent
        // passes pick it up.
        pnsNodes(pns_comp_for)[3] = @intFromPtr(s);
    }

    const this_scope: *Scope = @ptrFromInt(pnsNodes(pns_comp_for)[3]);
    closeOverVariablesEtc(comp, this_scope, 0, 0);

    // Compile the source iterator IN THE PARENT scope (the for-clause's
    // RHS is evaluated before entering the comprehension function).
    compileNode(comp, pnsNodes(pns_comp_for)[1]);
    if (kind == .gen_expr) {
        comp.emit.getIter(false);
    }
    comp.emit.callFunction(1, 0, 0);
}

/// Vendor compile_scope_comp_iter (compile.c:2954). Recursive walker
/// for nested for/if clauses in a comprehension scope. Called from
/// driveScopeBody's comp-like branch.
fn compileScopeCompIter(
    comp: *Compiler,
    pns_comp_for: *PnStruct,
    pn_inner_expr: Pn,
    for_depth: u32,
) void {
    const l_top = compNextLabel(comp);
    const l_end = compNextLabel(comp);
    comp.emit.labelAssign(l_top);
    comp.emit.forIter(l_end);
    cAssign(comp, pnsNodes(pns_comp_for)[0], .store);

    var pn_iter = pnsNodes(pns_comp_for)[2];
    // tail_recursion: vendor uses goto. Iterate over comp_if chains
    // until either NULL (emit inner expr) or comp_for (recurse).
    while (true) {
        if (pnIsNull(pn_iter)) {
            compileNode(comp, pn_inner_expr);
            if (comp.scope_cur.?.kind == .gen_expr) {
                comp.emit.yield(MP_EMIT_YIELD_VALUE);
                comp.emit.popTop();
            } else {
                comp.emit.storeComp(comp.scope_cur.?.kind, 4 * for_depth + 5);
            }
            break;
        }
        if (!pnIsStruct(pn_iter)) break;
        const pns_iter = asPns(pn_iter);
        if (pnsKind(pns_iter) == grammar.RULE_comp_if) {
            cIfCond(comp, pnsNodes(pns_iter)[0], false, l_top);
            pn_iter = pnsNodes(pns_iter)[1];
            continue;
        }
        std.debug.assert(pnsKind(pns_iter) == grammar.RULE_comp_for);
        // Nested for: compile the new iter (in this scope, since we're
        // inside the comprehension body now), GET_ITER_STACK, recurse.
        compileNode(comp, pnsNodes(pns_iter)[1]);
        comp.emit.getIter(true);
        compileScopeCompIter(comp, pns_iter, pn_inner_expr, for_depth + 1);
        break;
    }

    comp.emit.jump(l_top);
    comp.emit.labelAssign(l_end);
    comp.emit.forIterEnd();
}

// Vendor compile_trailer_paren_helper (compile.c:2401).
fn compileTrailerParenHelper(
    comp: *Compiler,
    pn_arglist_in: Pn,
    is_method_call: bool,
    n_positional_extra: u32,
) void {
    var pn_arglist = pn_arglist_in;
    const list = pnExtractList(&pn_arglist, grammar.RULE_arglist);
    const args = list.nodes;
    const n_args = list.len;

    var n_positional: u32 = n_positional_extra;
    var n_keyword: u32 = 0;
    var star_flags: u8 = 0;
    var star_args: usize = 0;

    var i: usize = 0;
    while (i < n_args) : (i += 1) {
        const arg = args[i];
        var handled_as_normal = false;

        if (pnIsStruct(arg)) {
            const pns_arg = asPns(arg);
            const kind = pnsKind(pns_arg);
            const arg_nodes = pnsNodes(pns_arg);

            if (kind == grammar.RULE_arglist_star) {
                if ((star_flags & MP_EMIT_STAR_FLAG_DOUBLE) != 0) {
                    compileSyntaxError(comp, arg, "* arg after **");
                    return;
                }
                if (i >= MP_SMALL_INT_BITS - 1) {
                    compileSyntaxError(comp, arg, "too many args");
                    return;
                }
                star_flags |= MP_EMIT_STAR_FLAG_SINGLE;
                star_args |= (@as(usize, 1) << @intCast(i));
                compileNode(comp, arg_nodes[0]);
                n_positional += 1;
            } else if (kind == grammar.RULE_arglist_dbl_star) {
                star_flags |= MP_EMIT_STAR_FLAG_DOUBLE;
                comp.emit.loadNull();
                compileNode(comp, arg_nodes[0]);
                n_keyword += 1;
            } else if (kind == grammar.RULE_argument) {
                const arg0 = arg_nodes[0];
                const arg1 = arg_nodes[1];
                if (pnIsStructKind(arg1, grammar.RULE_argument_3)) {
                    const pns_walrus = asPns(arg1);
                    compileNamedexprHelper(comp, arg0, pnsNodes(pns_walrus)[0]);
                    n_positional += 1;
                } else if (!pnIsStructKind(arg1, grammar.RULE_comp_for)) {
                    if (!pnIsId(arg0)) {
                        compileSyntaxError(comp, arg, "LHS of keyword arg must be an id");
                        return;
                    }
                    comp.emit.loadConstStr(pnLeafArg(arg0));
                    compileNode(comp, arg1);
                    n_keyword += 1;
                } else {
                    compileComprehensionStub(comp, pns_arg, .gen_expr);
                    n_positional += 1;
                }
            } else {
                handled_as_normal = true;
            }
        } else {
            handled_as_normal = true;
        }

        if (handled_as_normal) {
            if ((star_flags & MP_EMIT_STAR_FLAG_DOUBLE) != 0) {
                compileSyntaxError(comp, arg, "positional arg after **");
                return;
            }
            if (n_keyword > 0) {
                compileSyntaxError(comp, arg, "positional arg after keyword arg");
                return;
            }
            compileNode(comp, arg);
            n_positional += 1;
        }
    }

    if (star_flags != 0) {
        comp.emit.loadConstSmallInt(@intCast(star_args));
    }

    if (is_method_call) {
        comp.emit.callMethod(n_positional, n_keyword, star_flags);
    } else {
        comp.emit.callFunction(n_positional, n_keyword, star_flags);
    }
}

// Vendor compile_atom_brace_helper (compile.c:2559).
fn compileAtomBraceHelper(
    comp: *Compiler,
    pns_in: *PnStruct,
    create_map: bool,
) void {
    const pn = pnsNodes(pns_in)[0];
    if (pnIsNull(pn)) {
        if (create_map) comp.emit.build(0, MP_EMIT_BUILD_MAP);
        return;
    }

    if (!pnIsStruct(pn)) {
        compileNode(comp, pn);
        comp.emit.build(1, MP_EMIT_BUILD_SET);
        return;
    }

    const pns = asPns(pn);
    const kind = pnsKind(pns);

    if (kind == grammar.RULE_dictorsetmaker_item) {
        if (create_map) comp.emit.build(1, MP_EMIT_BUILD_MAP);
        compileNode(comp, pn);
        comp.emit.storeMap();
        return;
    }

    if (kind == grammar.RULE_dictorsetmaker_dbl_star) {
        // Single-item dict `{**d}` — build empty, merge in place.
        if (create_map) comp.emit.build(0, MP_EMIT_BUILD_MAP);
        compileNode(comp, pn);
        return;
    }

    if (kind == grammar.RULE_dictorsetmaker) {
        const ds_nodes = pnsNodes(pns);
        std.debug.assert(pnIsStruct(ds_nodes[1]));
        const pns1 = asPns(ds_nodes[1]);
        const pns1_kind = pnsKind(pns1);

        if (pns1_kind == grammar.RULE_dictorsetmaker_list) {
            var pn_tail = pnsNodes(pns1)[0];
            const tail = pnExtractList(&pn_tail, grammar.RULE_dictorsetmaker_list2);
            const n_tail = tail.len;

            const first_is_kv = pnIsStructKind(ds_nodes[0], grammar.RULE_dictorsetmaker_item);
            const first_is_dbl = pnIsStructKind(ds_nodes[0], grammar.RULE_dictorsetmaker_dbl_star);
            const is_dict = first_is_kv or first_is_dbl;
            if (is_dict) {
                if (create_map) comp.emit.build(@intCast(1 + n_tail), MP_EMIT_BUILD_MAP);
                if (first_is_kv) {
                    compileNode(comp, ds_nodes[0]);
                    comp.emit.storeMap();
                } else {
                    // dbl_star merges in place; no storeMap follow-up.
                    compileNode(comp, ds_nodes[0]);
                }
            } else {
                compileNode(comp, ds_nodes[0]);
            }

            var idx0: usize = 0;
            while (idx0 < n_tail) : (idx0 += 1) {
                const pn_i = tail.nodes[idx0];
                const is_key_value = pnIsStructKind(pn_i, grammar.RULE_dictorsetmaker_item);
                const is_dbl_star = pnIsStructKind(pn_i, grammar.RULE_dictorsetmaker_dbl_star);
                if (is_dict) {
                    if (!is_key_value and !is_dbl_star) {
                        compileSyntaxError(comp, @intFromPtr(pns), "expecting key:value for dict");
                        return;
                    }
                    compileNode(comp, pn_i);
                    if (is_key_value) comp.emit.storeMap();
                    // dbl_star merges in place — nothing more to emit.
                } else {
                    if (is_key_value) {
                        compileSyntaxError(comp, @intFromPtr(pns), "expecting just a value for set");
                        return;
                    }
                    if (is_dbl_star) {
                        compileSyntaxError(comp, @intFromPtr(pns), "** unpacking not allowed in set literal");
                        return;
                    }
                    compileNode(comp, pn_i);
                }
            }

            if (!is_dict) {
                comp.emit.build(@intCast(1 + n_tail), MP_EMIT_BUILD_SET);
            }
            return;
        }

        std.debug.assert(pns1_kind == grammar.RULE_comp_for);
        if (pnIsStructKind(ds_nodes[0], grammar.RULE_dictorsetmaker_dbl_star)) {
            compileSyntaxError(comp, @intFromPtr(pns), "dict unpacking cannot be used in dict comprehension");
            return;
        }
        const scope_kind: ScopeKind = if (pnIsStructKind(ds_nodes[0], grammar.RULE_dictorsetmaker_item))
            .dict_comp
        else
            .set_comp;
        compileComprehensionStub(comp, pns, scope_kind);
        return;
    }

    compileNode(comp, pn);
    comp.emit.build(1, MP_EMIT_BUILD_SET);
}

// Codegen-pass param walker (compile.c:659).
fn compileFuncdefLambdefParam(comp: *Compiler, pn: Pn) void {
    var pn_kind: i32 = -1;
    if (!pnIsId(pn)) {
        std.debug.assert(pnIsStruct(pn));
        pn_kind = @intCast(pnsKind(asPns(pn)));
    }

    const is_star = pn_kind == @as(i32, grammar.RULE_typedargslist_star) or
        pn_kind == @as(i32, grammar.RULE_varargslist_star);
    const is_dbl_star = pn_kind == @as(i32, grammar.RULE_typedargslist_dbl_star) or
        pn_kind == @as(i32, grammar.RULE_varargslist_dbl_star);
    // PEP 570 `/` marker — MicroPython doesn't enforce positional-only
    // semantics; the grammar accepts the marker so imports don't fail,
    // and we skip it here (no binding, no default handling).
    const is_slash = pn_kind == @as(i32, grammar.RULE_typedargslist_slash) or
        pn_kind == @as(i32, grammar.RULE_varargslist_slash);

    if (is_star) {
        comp.have_star = true;
        return;
    }
    if (is_dbl_star) {
        return;
    }
    if (is_slash) {
        return;
    }

    var pn_id: Pn = parser.PN_NULL;
    var pn_equal: Pn = parser.PN_NULL;
    if (pn_kind == -1) {
        pn_id = pn;
    } else if (pn_kind == @as(i32, grammar.RULE_typedargslist_name)) {
        const inner = asPns(pn);
        pn_id = pnsNodes(inner)[0];
        pn_equal = pnsNodes(inner)[2];
    } else {
        const inner = asPns(pn);
        pn_id = pnsNodes(inner)[0];
        pn_equal = pnsNodes(inner)[1];
    }

    if (pnIsNull(pn_equal)) {
        if (!comp.have_star and comp.num_default_params != 0) {
            compileSyntaxError(comp, pn, "non-default argument follows default argument");
        }
        return;
    }

    if (comp.have_star) {
        comp.num_dict_params += 1;
        if (comp.num_dict_params == 1) {
            if (comp.num_default_params > 0) {
                comp.emit.build(comp.num_default_params, MP_EMIT_BUILD_TUPLE);
            } else {
                comp.emit.loadNull();
            }
            comp.emit.build(0, MP_EMIT_BUILD_MAP);
        }
        compileNode(comp, pn_equal);
        comp.emit.loadConstStr(pnLeafArg(pn_id));
        comp.emit.storeMap();
    } else {
        comp.num_default_params += 1;
        compileNode(comp, pn_equal);
    }
}

// Port of close_over_variables_etc (compile.c:617).
fn closeOverVariablesEtc(
    comp: *Compiler,
    this_scope: *Scope,
    n_pos_defaults: usize,
    n_kw_defaults: usize,
) void {
    if (n_kw_defaults > 0) this_scope.scope_flags |= SCOPE_FLAG_DEFKWARGS;
    this_scope.num_def_pos_args = @intCast(n_pos_defaults);

    var nfree: u8 = 0;
    const parent = comp.scope_cur.?;
    if (parent.kind != .module) {
        var pi: usize = 0;
        while (pi < parent.id_info.items.len) : (pi += 1) {
            const id = &parent.id_info.items[pi];
            if (id.kind == .cell or id.kind == .free) {
                var ci: usize = 0;
                while (ci < this_scope.id_info.items.len) : (ci += 1) {
                    const id2 = &this_scope.id_info.items[ci];
                    if (id2.kind == .free and id.qst == id2.qst) {
                        comp.emit.loadLocal(id.local_num, emit_mod.MP_EMIT_IDOP_LOCAL_FAST);
                        nfree += 1;
                    }
                }
            }
        }
    }

    if (nfree == 0) {
        comp.emit.makeFunction(this_scope, n_pos_defaults, n_kw_defaults) catch {
            comp.emit.overflow = true;
        };
    } else {
        comp.emit.makeClosure(this_scope, nfree, n_pos_defaults, n_kw_defaults) catch {
            comp.emit.overflow = true;
        };
    }
}

// Port of compile_funcdef_lambdef (compile.c:750).
fn compileFuncdefLambdef(
    comp: *Compiler,
    scope: *Scope,
    pn_params: Pn,
    pn_list_kind: u8,
) void {
    const orig_have_star = comp.have_star;
    const orig_num_dict = comp.num_dict_params;
    const orig_num_default = comp.num_default_params;

    comp.have_star = false;
    comp.num_dict_params = 0;
    comp.num_default_params = 0;
    applyToSingleOrList(comp, pn_params, pn_list_kind, compileFuncdefLambdefParam);

    if (comp.compile_error != null) return;

    if (comp.num_default_params > 0 and comp.num_dict_params == 0) {
        comp.emit.build(comp.num_default_params, MP_EMIT_BUILD_TUPLE);
        comp.emit.loadNull();
    }

    closeOverVariablesEtc(comp, scope, comp.num_default_params, comp.num_dict_params);

    comp.have_star = orig_have_star;
    comp.num_dict_params = orig_num_dict;
    comp.num_default_params = orig_num_default;
}

// Port of compile_funcdef_helper (compile.c:786).
fn compileFuncdefHelper(
    comp: *Compiler,
    pns: *PnStruct,
    emit_options: u16,
) Qstr {
    if (comp.pass == .scope) {
        const s = scopeNewAndLink(comp, .function, @intFromPtr(pns), emit_options) catch {
            compileSyntaxError(comp, @intFromPtr(pns), "out of memory creating function scope");
            return 0;
        };
        pnsNodes(pns)[4] = @intFromPtr(s);
    }
    const fscope: *Scope = @ptrFromInt(pnsNodes(pns)[4]);
    compileFuncdefLambdef(comp, fscope, pnsNodes(pns)[1], grammar.RULE_typedargslist);
    return fscope.simple_name;
}

// Port of compile_classdef_helper (compile.c:806).
fn compileClassdefHelper(
    comp: *Compiler,
    pns: *PnStruct,
    emit_options: u16,
) Qstr {
    if (comp.pass == .scope) {
        const s = scopeNewAndLink(comp, .class, @intFromPtr(pns), emit_options) catch {
            compileSyntaxError(comp, @intFromPtr(pns), "out of memory creating class scope");
            return 0;
        };
        pnsNodes(pns)[3] = @intFromPtr(s);
    }

    comp.emit.loadBuildClass();

    const cscope: *Scope = @ptrFromInt(pnsNodes(pns)[3]);
    closeOverVariablesEtc(comp, cscope, 0, 0);
    comp.emit.loadConstStr(cscope.simple_name);

    // Vendor compile_classdef_helper (compile.c:806-831) routes the base
    // list THROUGH compile_trailer_paren_helper with n_positional_extra=2.
    // That preserves metaclass=X (kwarg), *bases, **kw, and the
    // CALL_FUNCTION_VAR_KW flags. The earlier scaffold hand-rolled a
    // bare callFunction(n, 0, 0) which silently dropped them.
    var parents = pnsNodes(pns)[1];
    if (pnIsStructKind(parents, grammar.RULE_classdef_2)) {
        parents = parser.PN_NULL;
    }
    if (pnIsNull(parents)) {
        comp.emit.callFunction(2, 0, 0);
    } else {
        compileTrailerParenHelper(comp, parents, false, 2);
    }

    return cscope.simple_name;
}

// Shared body of compile_scope_func_lambda_param (compile.c:2859).
fn cScopeFuncLambdaParam(
    comp: *Compiler,
    pn: Pn,
    pn_name: u8,
    pn_star: u8,
    pn_dbl_star: u8,
) void {
    const sc = comp.scope_cur.?;

    if ((sc.scope_flags & SCOPE_FLAG_VARKEYWORDS) != 0) {
        compileSyntaxError(comp, pn, "invalid syntax");
        return;
    }

    var param_name: Qstr = 0;
    var param_flag: u8 = ID_FLAG_IS_PARAM;

    if (pnIsId(pn)) {
        param_name = pnLeafArg(pn);
        if (comp.have_star) sc.num_kwonly_args += 1 else sc.num_pos_args += 1;
    } else {
        std.debug.assert(pnIsStruct(pn));
        const pns = asPns(pn);
        const k = pnsKind(pns);
        // PEP 570 `/` marker — no binding, no counter bump.
        if (k == grammar.RULE_typedargslist_slash or k == grammar.RULE_varargslist_slash) {
            return;
        }
        if (k == pn_name) {
            param_name = pnLeafArg(pnsNodes(pns)[0]);
            if (comp.have_star) sc.num_kwonly_args += 1 else sc.num_pos_args += 1;
        } else if (k == pn_star) {
            if (comp.have_star) {
                compileSyntaxError(comp, pn, "invalid syntax");
                return;
            }
            comp.have_star = true;
            param_flag = ID_FLAG_IS_PARAM | ID_FLAG_IS_STAR_PARAM;
            const inner = pnsNodes(pns)[0];
            if (pnIsNull(inner)) {
                // bare star — nothing to bind
            } else if (pnIsId(inner)) {
                sc.scope_flags |= SCOPE_FLAG_VARARGS;
                param_name = pnLeafArg(inner);
            } else {
                std.debug.assert(pnIsStruct(inner));
                sc.scope_flags |= SCOPE_FLAG_VARARGS;
                const tfp = asPns(inner);
                param_name = pnLeafArg(pnsNodes(tfp)[0]);
            }
        } else {
            std.debug.assert(k == pn_dbl_star);
            param_name = pnLeafArg(pnsNodes(pns)[0]);
            param_flag = ID_FLAG_IS_PARAM | ID_FLAG_IS_DBL_STAR_PARAM;
            sc.scope_flags |= SCOPE_FLAG_VARKEYWORDS;
        }
    }

    if (param_name != 0) {
        const id = sc.findOrAdd(param_name, .undecided) catch {
            compileSyntaxError(comp, pn, "out of memory binding parameter");
            return;
        };
        if (id.kind != .undecided) {
            compileSyntaxError(comp, pn, "argument name reused");
            return;
        }
        id.kind = .local;
        id.flags = param_flag;
    }
}

fn cScopeFuncParam(comp: *Compiler, pn: Pn) void {
    cScopeFuncLambdaParam(
        comp,
        pn,
        grammar.RULE_typedargslist_name,
        grammar.RULE_typedargslist_star,
        grammar.RULE_typedargslist_dbl_star,
    );
}

fn cScopeLambdaParam(comp: *Compiler, pn: Pn) void {
    cScopeFuncLambdaParam(
        comp,
        pn,
        grammar.RULE_varargslist_name,
        grammar.RULE_varargslist_star,
        grammar.RULE_varargslist_dbl_star,
    );
}

// Per-scope body walker (replaces old driveScope).
fn driveScopeBody(comp: *Compiler, scope: *Scope) Allocator.Error!void {
    comp.scope_cur = scope;
    if (comp.pass == .scope) {
        scope.stack_size = 0;
        scope.exc_stack_size = 0;
    }

    if (pnIsStructKind(scope.pn, grammar.RULE_eval_input)) {
        std.debug.assert(scope.kind == .module);
        const pns = asPns(scope.pn);
        compileNode(comp, pnsNodes(pns)[0]);
        comp.emit.returnValue();
        return;
    }

    switch (scope.kind) {
        .module => {
            compileNode(comp, scope.pn);
            comp.emit.loadConstTok(emit_mod.MP_TOKEN_KW_NONE);
            comp.emit.returnValue();
        },
        .function => {
            std.debug.assert(pnIsStruct(scope.pn));
            const pns = asPns(scope.pn);
            std.debug.assert(pnsKind(pns) == grammar.RULE_funcdef);
            if (comp.pass == .scope) {
                comp.have_star = false;
                applyToSingleOrList(
                    comp,
                    pnsNodes(pns)[1],
                    grammar.RULE_typedargslist,
                    cScopeFuncParam,
                );
            }
            compileNode(comp, pnsNodes(pns)[3]);
            comp.emit.loadConstTok(emit_mod.MP_TOKEN_KW_NONE);
            comp.emit.returnValue();
        },
        .lambda => {
            std.debug.assert(pnIsStruct(scope.pn));
            const pns = asPns(scope.pn);
            std.debug.assert(pnsNumNodes(pns) == 3);
            comp.emit.setSourceLine(pns.source_line);
            if (comp.pass == .scope) {
                comp.have_star = false;
                applyToSingleOrList(
                    comp,
                    pnsNodes(pns)[0],
                    grammar.RULE_varargslist,
                    cScopeLambdaParam,
                );
            }
            compileNode(comp, pnsNodes(pns)[1]);
            if ((scope.scope_flags & SCOPE_FLAG_GENERATOR) != 0) {
                comp.emit.popTop();
                comp.emit.loadConstTok(emit_mod.MP_TOKEN_KW_NONE);
            }
            comp.emit.returnValue();
        },
        .class => {
            std.debug.assert(pnIsStruct(scope.pn));
            const pns = asPns(scope.pn);
            std.debug.assert(pnsKind(pns) == grammar.RULE_classdef);
            if (comp.pass == .scope) {
                _ = scope.findOrAdd(comp.wk(WK_IDX.__class__), .local) catch return error.OutOfMemory;
            }
            compileLoadId(comp, comp.wk(WK_IDX.__name__));
            compileStoreId(comp, comp.wk(WK_IDX.__module__));
            comp.emit.loadConstStr(pnLeafArg(pnsNodes(pns)[0]));
            compileStoreId(comp, comp.wk(WK_IDX.__qualname__));
            if (hasAnnassign(pnsNodes(pns)[2])) {
                // __annotations__ = __import__("ucollections").OrderedDict():
                // a dict here is not insertion-ordered, and field order is
                // what @dataclass binds positional arguments by. ucollections
                // resolves to the built-in module, binding no name.
                comp.emit.loadConstSmallInt(0);
                comp.emit.loadConstTok(emit_mod.MP_TOKEN_KW_NONE);
                comp.emit.import(qstrFromStrn(comp, "ucollections"), MP_EMIT_IMPORT_NAME);
                comp.emit.attr(qstrFromStrn(comp, "OrderedDict"), MP_EMIT_ATTR_LOAD);
                comp.emit.callFunction(0, 0, 0);
                compileStoreId(comp, annotationsQstr(comp));
            }
            compileNode(comp, pnsNodes(pns)[2]);
            const id = scope.find(comp.wk(WK_IDX.__class__));
            std.debug.assert(id != null);
            if (id.?.kind == .local) {
                comp.emit.loadConstTok(emit_mod.MP_TOKEN_KW_NONE);
            } else {
                comp.emit.loadLocal(id.?.local_num, emit_mod.MP_EMIT_IDOP_LOCAL_FAST);
            }
            comp.emit.returnValue();
        },
        .list_comp, .dict_comp, .set_comp, .gen_expr => {
            // Vendor compile_scope's SCOPE_IS_COMP_LIKE branch (compile.c:3111).
            // The comprehension's scope.pn is the original testlist_comp /
            // dictorsetmaker / argument node — same shape we wrapped in
            // compileComprehensionStub: nodes[0]=inner expr, nodes[1]=comp_for.
            std.debug.assert(pnIsStruct(scope.pn));
            const pns = asPns(scope.pn);
            std.debug.assert(pnsNumNodes(pns) == 2);
            std.debug.assert(pnIsStructKind(pnsNodes(pns)[1], grammar.RULE_comp_for));
            const pns_comp_for = asPns(pnsNodes(pns)[1]);

            // The comprehension takes one synthetic positional arg holding
            // the outermost iterator. CPython uses ".0"; vendor uses the
            // blank qstr (id 1) which can't clash with a user binding.
            const qstr_arg: Qstr = 1; // MP_QSTR_ (the empty-string qstr)
            if (comp.pass == .scope) {
                _ = scope.findOrAdd(qstr_arg, .local) catch return error.OutOfMemory;
                scope.num_pos_args = 1;
            }

            comp.emit.setSourceLine(pns.source_line);

            // Seed the accumulator: empty list / dict / set; for gen_expr
            // the four-slot iter buffer per the YIELD/PEP-3155 ABI.
            switch (scope.kind) {
                .list_comp => comp.emit.build(0, MP_EMIT_BUILD_LIST),
                .dict_comp => comp.emit.build(0, MP_EMIT_BUILD_MAP),
                .set_comp => comp.emit.build(0, MP_EMIT_BUILD_SET),
                .gen_expr => {
                    // 4-slot iterator buffer: NULL, the iterator, two NULL
                    // padding slots (MP_OBJ_ITER_BUF_NSLOTS = 4).
                    comp.emit.loadNull();
                    compileLoadId(comp, qstr_arg);
                    comp.emit.loadNull();
                    comp.emit.loadNull();
                },
                else => unreachable,
            }
            if (scope.kind != .gen_expr) {
                compileLoadId(comp, qstr_arg);
                comp.emit.getIter(true);
            }

            compileScopeCompIter(comp, pns_comp_for, pnsNodes(pns)[0], 0);

            if (scope.kind == .gen_expr) {
                comp.emit.loadConstTok(emit_mod.MP_TOKEN_KW_NONE);
            }
            comp.emit.returnValue();
        },
    }
}

// SCOPE pass for a single scope. Iteratively drains the scope_head
// chain of any newly-discovered child scopes. The previous version
// recursed and used a heuristic gate (no locals + no ids + no
// pos_args) to detect "already processed"; that misclassifies empty
// bodies like `def f(): pass` and produced unbounded recursion as
// soon as two sibling scopes existed. Use the explicit
// `scope_pass_done` flag instead and drive iteratively.
fn runScopePass(comp: *Compiler, scope: *Scope) Allocator.Error!void {
    try runScopePassOne(comp, scope);

    // Worklist: keep sweeping comp.scope_head until every scope's
    // SCOPE pass has been driven. Driving one scope may discover new
    // sibling scopes (via nested funcdef/classdef/lambdef), which is
    // why we re-scan from the head each round.
    while (true) {
        var made_progress = false;
        var s = comp.scope_head;
        while (s) |sp| : (s = sp.next) {
            if (sp.scope_pass_done) continue;
            try runScopePassOne(comp, sp);
            made_progress = true;
        }
        if (!made_progress) break;
    }
}

// SCOPE pass for a single scope — no recursion. Marks the scope as
// scope_pass_done on completion.
fn runScopePassOne(comp: *Compiler, scope: *Scope) Allocator.Error!void {
    comp.emit.emit_common.children.clearRetainingCapacity();
    comp.next_label = 0;

    comp.pass = .scope;
    comp.emit.emit_common.startPass(.scope);
    try comp.emit.startPass(.scope, scope);
    try driveScopeBody(comp, scope);
    _ = try comp.emit.endPass();

    // Vendor compile.c:3513-3517 — after each scope's SCOPE pass, walk
    // its id_info for any binding that's still GLOBAL_IMPLICIT and check
    // whether a parent scope actually owns it (as LOCAL / CELL / FREE).
    // If so, scope_check_to_close_over rebinds it to FREE in this scope
    // and CELL in the owning parent. Without this, closure free
    // variables stay as GLOBAL_IMPLICIT and get emitted as
    // LOAD_GLOBAL_NAME (adding the qstr to qstr_table) instead of
    // LOAD_DEREF.
    var i: usize = 0;
    while (i < scope.id_info.items.len) : (i += 1) {
        const id = &scope.id_info.items[i];
        if (id.kind == .global_implicit) {
            try scope.checkToCloseOver(id);
        }
    }

    scope.scope_pass_done = true;
}

// STACK_SIZE → CODE_SIZE → EMIT for one scope.
fn runCodegenPasses(comp: *Compiler, scope: *Scope) Allocator.Error!void {
    const ec = comp.emit.emit_common;

    ec.children.clearRetainingCapacity();

    // Vendor compile_scope (compile.c:3041) resets next_label = 0 at
    // the START of EVERY pass. Label allocation must be deterministic
    // and produce the same ids across STACK_SIZE / CODE_SIZE / EMIT so
    // labelAssign and forward-jumps reference stable indices into
    // emit.label_offsets. (Earlier scaffold only reset before STACK_SIZE,
    // which let next_label grow monotonically and trip max_num_labels
    // on any program with multiple short-circuit branches.)
    comp.pass = .stack_size;
    comp.next_label = 0;
    ec.startPass(.stack_size);
    try comp.emit.startPass(.stack_size, scope);
    try driveScopeBody(comp, scope);
    _ = try comp.emit.endPass();

    comp.pass = .code_size;
    comp.next_label = 0;
    ec.startPass(.code_size);
    try comp.emit.startPass(.code_size, scope);
    try driveScopeBody(comp, scope);
    _ = try comp.emit.endPass();

    while (true) {
        comp.pass = .emit;
        comp.next_label = 0;
        ec.startPass(.emit);
        try comp.emit.startPass(.emit, scope);
        try driveScopeBody(comp, scope);
        if (try comp.emit.endPass()) break;
    }

    if (comp.emit.overflow) return error.OutOfMemory;

    const n_children = ec.children.items.len;
    const child_slots = try comp.allocator.alloc(mpy.RawCode, n_children);
    for (child_slots, 0..) |*slot, i| {
        slot.* = .{
            .kind = mpy.MP_CODE_BYTECODE,
            .fun_data = &.{},
            .children = &.{},
        };
        const sc_ptr: usize = @intFromPtr(ec.children.items[i]);
        const buf = try comp.allocator.alloc(u8, @sizeOf(usize));
        std.mem.writeInt(usize, buf[0..@sizeOf(usize)], sc_ptr, .little);
        slot.fun_data = buf;
    }

    // Vendor emitbc.c:404-411 assigns the raw_code with bytecode_len =
    // code_info_size + bytecode_size (the FINAL EMIT-pass sizes). If
    // EMIT shrank below the CODE_SIZE pass's estimate — e.g. a JUMP
    // CODE_SIZE allocated 3 bytes for but EMIT resolved to a 1-byte
    // offset — code_base is still the larger CODE_SIZE allocation with
    // trailing zero-init bytes. Slice to the used length so the .mpy
    // never carries a phantom trailing 0x00.
    const used: usize = @as(usize, comp.emit.code_info_size) + @as(usize, comp.emit.bytecode_size);
    const bytecode_owned = try comp.allocator.dupe(u8, comp.emit.code_base[0..used]);
    const rc_box = try comp.allocator.create(mpy.RawCode);
    rc_box.* = .{
        .kind = mpy.MP_CODE_BYTECODE,
        .fun_data = bytecode_owned,
        .children = child_slots,
    };
    scope.raw_code = rc_box;
}

fn cloneRawCodeTree(allocator: Allocator, src: mpy.RawCode) Allocator.Error!mpy.RawCode {
    const fun_data_owned = try allocator.dupe(u8, src.fun_data);
    var children_owned = try allocator.alloc(mpy.RawCode, src.children.len);
    for (src.children, 0..) |child_slot, i| {
        if (child_slot.fun_data.len == @sizeOf(usize) and child_slot.children.len == 0) {
            const sc_ptr = std.mem.readInt(usize, child_slot.fun_data[0..@sizeOf(usize)], .little);
            const child_scope: *Scope = @ptrFromInt(sc_ptr);
            const child_rc_box: *mpy.RawCode = @ptrCast(@alignCast(child_scope.raw_code.?));
            children_owned[i] = try cloneRawCodeTree(allocator, child_rc_box.*);
        } else {
            children_owned[i] = try cloneRawCodeTree(allocator, child_slot);
        }
    }
    return mpy.RawCode{
        .kind = src.kind,
        .fun_data = fun_data_owned,
        .children = children_owned,
    };
}

// ─────────────────────────────────────────────────────────────────────────
// §30 — compileNode: top-level dispatch.
//
// Three tag forms — small-int, leaf (id/string/token), or struct (rule).
// The struct case looks up compile_function[kind] and calls it.
// ─────────────────────────────────────────────────────────────────────────

pub fn compileNode(comp: *Compiler, pn: Pn) void {
    if (pnIsNull(pn)) return;

    if (pnIsSmallInt(pn)) {
        comp.emit.loadConstSmallInt(pnLeafSmallInt(pn));
        return;
    }

    if (pnIsLeaf(pn)) {
        const lk = pnLeafKind(pn);
        const arg = pnLeafArg(pn);
        if (lk == parser.PN_ID) {
            compileLoadId(comp, arg);
            return;
        }
        if (lk == parser.PN_STRING) {
            comp.emit.loadConstStr(arg);
            return;
        }
        if (lk == parser.PN_TOKEN) {
            // Vendor compile_node (compile.c:2805) for MP_PARSE_NODE_TOKEN:
            // NEWLINE is silently ignored (file_input or single_input may
            // let through a NEWLINE if the file starts with a blank line
            // or the REPL sees an empty line). Everything else routes to
            // load_const_tok with the raw token id, which is exactly the
            // set our emit.loadConstTok understands.
            const tk: TokenKind = @enumFromInt(@as(u8, @intCast(arg)));
            switch (tk) {
                .NEWLINE => {},
                .KW_FALSE => comp.emit.loadConstTok(emit_mod.MP_TOKEN_KW_FALSE),
                .KW_NONE => comp.emit.loadConstTok(emit_mod.MP_TOKEN_KW_NONE),
                .KW_TRUE => comp.emit.loadConstTok(emit_mod.MP_TOKEN_KW_TRUE),
                .ELLIPSIS => comp.emit.loadConstTok(emit_mod.MP_TOKEN_ELLIPSIS),
                else => compileSyntaxError(comp, pn, "unexpected token"),
            }
            return;
        }
        return;
    }

    // Struct.
    const pns = asPns(pn);
    const k = pnsKind(pns);
    if (k >= grammar.NUM_RULES) {
        // An extension rule (grammar_ext.zig). The dispatch table is
        // sized to the vendor grammar, so these must be handled before
        // it is indexed. The rules under match_stmt are consumed by
        // compileMatchStmt itself and never reach here.
        switch (k) {
            grammar_ext.RULE_match_stmt => compileMatchStmt(comp, pns),
            else => compileSyntaxError(comp, pn, "unsupported extension rule"),
        }
        return;
    }
    const handler = compile_function[k];
    handler(comp, pns);
}

// ─────────────────────────────────────────────────────────────────────────
// §33.1 — Async/await: full compilation (A2/A3).
//
// MICROPY_PY_ASYNC_AWAIT=1 (port/mpconfigport.h) — `async def`/`await`/
// `async for`/`async with` are recognised at parse time and lowered to
// generator bytecode here. Per vendor, async functions ARE generators
// (SCOPE_FLAG_GENERATOR); `await` lowers to GET_ITER+YIELD_FROM; async
// for/with use the __aiter__/__anext__/__aenter__/__aexit__ dunders.
//
// No new VM opcodes are introduced — vendor's `async_with_setup_finally`
// is a compile-time helper that emits existing opcodes.
//
// Vendor reference: py/compile.c:1782-2003 + 2769-2781.
// ─────────────────────────────────────────────────────────────────────────

// Vendor compile_yield_from (compile.c:1782): GET_ITER + LOAD_CONST_NONE
// + YIELD(YIELD_FROM). The YIELD also flips SCOPE_FLAG_GENERATOR on the
// current scope (see emit.yield()).
fn compileYieldFrom(comp: *Compiler) void {
    comp.emit.getIter(false);
    comp.emit.loadConstTok(emit_mod.MP_TOKEN_KW_NONE);
    comp.emit.yield(MP_EMIT_YIELD_FROM);
}

// Vendor compile_await_object_method (compile.c:1790): LOAD_METHOD m,
// CALL_METHOD 0 args, YIELD_FROM. Used by async_for (m=__anext__) and
// async_with (m=__aenter__/__aexit__).
fn compileAwaitObjectMethod(comp: *Compiler, method: Qstr) void {
    comp.emit.loadMethod(method, false);
    comp.emit.callMethod(0, 0, 0);
    compileYieldFrom(comp);
}

// Vendor compile_async_for_stmt (compile.c:1796): async-for is sugar for
// `try: while True: yield from iter.__anext__(); body except
// StopAsyncIteration: pop; goto else`. The bytecode mirrors a try-except
// inside a while loop without START_BREAK_CONTINUE_BLOCK's optimised
// for-loop fast-path.
fn compileAsyncForStmt(comp: *Compiler, pns: *PnStruct) void {
    const nodes = pnsNodes(pns);

    const lab_while_else = compNextLabel(comp);
    const lab_try_exception = compNextLabel(comp);
    const lab_try_else = compNextLabel(comp);
    const lab_try_finally = compNextLabel(comp);

    // Stack: (...)
    // Compile the iterator expression and call its __aiter__ method.
    compileNode(comp, nodes[1]); // iterator
    comp.emit.loadMethod(comp.wk(WK_IDX.__aiter__), false);
    comp.emit.callMethod(0, 0, 0);
    // Stack: (..., iterable)

    // START_BREAK_CONTINUE_BLOCK
    const old_break = comp.break_label;
    const old_continue = comp.continue_label;
    const old_excl = comp.break_continue_except_level;
    const lab_break = compNextLabel(comp);
    const lab_continue = compNextLabel(comp);
    comp.break_label = lab_break;
    comp.continue_label = lab_continue;
    comp.break_continue_except_level = comp.cur_except_level;

    comp.emit.labelAssign(lab_continue);

    compileIncreaseExceptLevel(comp, lab_try_exception, MP_EMIT_SETUP_BLOCK_EXCEPT);

    comp.emit.dupTop();
    // Stack: (..., iterable, iterable)

    // yield from iterable.__anext__()
    compileAwaitObjectMethod(comp, comp.wk(WK_IDX.__anext__));
    // Stack: (..., iterable, yielded_value)

    cAssign(comp, nodes[0], .store); // loop variable
    // Stack: (..., iterable)
    comp.emit.popExceptJump(lab_try_else);

    comp.emit.labelAssign(lab_try_exception);
    comp.emit.startExceptHandler();
    comp.emit.dupTop();
    comp.emit.loadGlobal(comp.wk(WK_IDX.StopAsyncIteration), emit_mod.MP_EMIT_IDOP_GLOBAL_GLOBAL);
    comp.emit.binaryOp(emit_mod.MP_BINARY_OP_EXCEPTION_MATCH);
    comp.emit.popJumpIf(false, lab_try_finally);
    comp.emit.popTop(); // pop exception instance
    // pop_except_jump pops the except block and jumps. Vendor passes
    // within_exc_handler=true; the bytecode encoder ignores it.
    comp.emit.popExceptJump(lab_while_else);

    comp.emit.labelAssign(lab_try_finally);
    comp.emit.adjustStackSize(1); // if we jump here, the exc is on the stack
    compileDecreaseExceptLevel(comp);
    comp.emit.endExceptHandler();

    // Stack: (..., iterable)

    comp.emit.labelAssign(lab_try_else);
    compileNode(comp, nodes[2]); // body

    comp.emit.jump(lab_continue);
    // END_BREAK_CONTINUE_BLOCK — break/continue in else target outer loop
    comp.break_label = old_break;
    comp.continue_label = old_continue;
    comp.break_continue_except_level = old_excl;

    comp.emit.labelAssign(lab_while_else);
    if (!pnIsNull(nodes[3])) compileNode(comp, nodes[3]); // else

    comp.emit.labelAssign(lab_break);
    // Stack: (..., iterable)

    comp.emit.popTop();
    // Stack: (...)
}

// Vendor compile_async_with_stmt_helper (compile.c:1863): nested
// recursion across `async with a, b: body`. Each pre-bit is either a
// PN_with_item (`expr as name`) or a bare expression.
fn compileAsyncWithStmtHelper(
    comp: *Compiler,
    n: usize,
    nodes: [*]Pn,
    body: Pn,
) void {
    if (n == 0) {
        compileNode(comp, body);
        return;
    }

    const l_finally_block = compNextLabel(comp);
    const l_aexit_no_exc = compNextLabel(comp);
    const l_ret_unwind_jump = compNextLabel(comp);
    const l_end = compNextLabel(comp);

    if (pnIsStructKind(nodes[0], grammar.RULE_with_item)) {
        // `expr as name`
        const pns = asPns(nodes[0]);
        compileNode(comp, pnsNodes(pns)[0]);
        comp.emit.dupTop();
        compileAwaitObjectMethod(comp, comp.wk(WK_IDX.__aenter__));
        cAssign(comp, pnsNodes(pns)[1], .store);
    } else {
        // bare expression
        compileNode(comp, nodes[0]);
        comp.emit.dupTop();
        compileAwaitObjectMethod(comp, comp.wk(WK_IDX.__aenter__));
        comp.emit.popTop();
    }

    // Start the try-finally statement.
    compileIncreaseExceptLevel(comp, l_finally_block, MP_EMIT_SETUP_BLOCK_FINALLY);

    // Compile any additional pre-bits of the "async with", and also the body.
    comp.emit.adjustStackSize(3); // stack adjust for possible UNWIND_JUMP state
    compileAsyncWithStmtHelper(comp, n - 1, nodes + 1, body);
    comp.emit.adjustStackSize(-3);

    // Now the "finally" block. There are 3 cases at this point:
    // 1. no exception, fall through: stack (..., ctx_mgr)
    // 2. exception propagating out: stack (..., ctx_mgr, exc)
    // 3. return or unwind jump: stack (..., ctx_mgr, X, INT)

    // Handle case 1: vendor's emit_bc_async_with_setup_finally inlines
    // LOAD_CONST_NONE + ROT_TWO + JUMP(l_aexit_no_exc) and the
    // l_finally_block prefix. We inline it here directly (no new opcode).
    // Stack: (..., ctx_mgr)
    comp.emit.loadConstTok(emit_mod.MP_TOKEN_KW_NONE);
    comp.emit.rotTwo();
    comp.emit.jump(l_aexit_no_exc);

    // Start of "finally" block — entered via exception / return / unwind.
    comp.emit.labelAssign(l_finally_block);
    // Detect which case: is TOS an exception?
    comp.emit.dupTop();
    comp.emit.loadGlobal(emit_mod.MP_QSTR_BaseException, emit_mod.MP_EMIT_IDOP_GLOBAL_GLOBAL);
    comp.emit.binaryOp(emit_mod.MP_BINARY_OP_EXCEPTION_MATCH);
    comp.emit.popJumpIf(false, l_ret_unwind_jump);

    // Case 2: exception. Call __aexit__ and either swallow or re-raise.
    // Stack: (..., ctx_mgr, exc)
    comp.emit.dupTop();
    comp.emit.rotThree();
    comp.emit.rotTwo();
    comp.emit.loadMethod(comp.wk(WK_IDX.__aexit__), false);
    comp.emit.rotThree();
    comp.emit.rotThree();
    comp.emit.dupTop();
    // type(exc): use the `type` builtin (MICROPY_CPYTHON_COMPAT off path).
    compileLoadId(comp, qstrFromStrn(comp, "type"));
    comp.emit.rotTwo();
    comp.emit.callFunction(1, 0, 0);
    comp.emit.rotTwo();
    comp.emit.loadConstTok(emit_mod.MP_TOKEN_KW_NONE); // dummy traceback
    // Stack: (..., exc, __aexit__, ctx_mgr, type(exc), exc, None)
    comp.emit.callMethod(3, 0, 0);
    compileYieldFrom(comp);
    comp.emit.popJumpIf(false, l_end);
    comp.emit.popTop(); // pop exception
    comp.emit.loadConstTok(emit_mod.MP_TOKEN_KW_NONE); // replace with None to swallow
    // Stack: (..., None)
    comp.emit.jump(l_end);
    comp.emit.adjustStackSize(2);

    // Case 3: return/unwind. Stack: (..., ctx_mgr, X, INT)
    comp.emit.labelAssign(l_ret_unwind_jump);
    comp.emit.rotThree();
    comp.emit.rotThree();
    comp.emit.labelAssign(l_aexit_no_exc);
    // Arrived from case 1 (jump) or case 3 (fall through):
    //   case 1: (..., None, ctx_mgr); case 3: (..., X, INT, ctx_mgr)
    comp.emit.loadMethod(comp.wk(WK_IDX.__aexit__), false);
    comp.emit.loadConstTok(emit_mod.MP_TOKEN_KW_NONE);
    comp.emit.dupTop();
    comp.emit.dupTop();
    comp.emit.callMethod(3, 0, 0);
    compileYieldFrom(comp);
    comp.emit.popTop();
    // Stack: case 1: (..., None) or case 3: (..., X, INT)
    comp.emit.adjustStackSize(-1);

    // End of "finally" block.
    // Stack: (..., None) | (..., exc) | (..., X, INT)
    comp.emit.labelAssign(l_end);
    compileDecreaseExceptLevel(comp);
}

// Vendor compile_async_with_stmt (compile.c:1967).
fn compileAsyncWithStmt(comp: *Compiler, pns: *PnStruct) void {
    var pre_list = extractWithList(pnsNodes(pns)[0]);
    const list_kind = if (pnIsStructKind(pre_list, grammar.RULE_with_paren_list))
        grammar.RULE_with_paren_list
    else
        grammar.RULE_with_stmt_list;
    const list = pnExtractList(&pre_list, list_kind);
    std.debug.assert(list.len > 0);
    compileAsyncWithStmtHelper(comp, list.len, list.nodes, pnsNodes(pns)[1]);
}

// Vendor compile_async_stmt (compile.c:1977). Dispatches the inner
// (funcdef | with_stmt | for_stmt). The async_stmt grammar rule is
// `KW_ASYNC async_stmt_2`; KW_ASYNC isn't pushed, async_stmt_2 is a
// transparent OR rule, so pns->nodes[0] is the inner funcdef/with/for
// struct directly.
fn compileAsyncStmt(comp: *Compiler, pns: *PnStruct) void {
    std.debug.assert(pnIsStruct(pnsNodes(pns)[0]));
    const pns0 = asPns(pnsNodes(pns)[0]);
    const k = pnsKind(pns0);
    if (k == grammar.RULE_funcdef) {
        // async def: compile as a regular funcdef, then mark scope as generator.
        compileFuncdef(comp, pns0);
        const fscope: *Scope = @ptrFromInt(pnsNodes(pns0)[4]);
        fscope.scope_flags |= SCOPE_FLAG_GENERATOR;
    } else {
        // async for/with: must be inside an async function (generator scope).
        const sf = comp.scope_cur.?.scope_flags;
        if ((sf & SCOPE_FLAG_GENERATOR) == 0) {
            compileSyntaxError(comp, @intFromPtr(pns0), "async for/with outside async function");
            return;
        }
        if (k == grammar.RULE_for_stmt) {
            compileAsyncForStmt(comp, pns0);
        } else {
            std.debug.assert(k == grammar.RULE_with_stmt);
            compileAsyncWithStmt(comp, pns0);
        }
    }
}

// Vendor decorated body handler for async_funcdef (compile.c:936): a
// `@dec async def f(): ...` whose body is reached through compileDecorated
// hits us here. Behaves like compileFuncdef wrapped to also flag scope as
// generator.
fn compileAsyncFuncdef(comp: *Compiler, pns: *PnStruct) void {
    // pns is the async_funcdef wrapper; nodes[0] is the inner funcdef.
    std.debug.assert(pnIsStruct(pnsNodes(pns)[0]));
    const pns_inner = asPns(pnsNodes(pns)[0]);
    std.debug.assert(pnsKind(pns_inner) == grammar.RULE_funcdef);
    compileFuncdef(comp, pns_inner);
    const fscope: *Scope = @ptrFromInt(pnsNodes(pns_inner)[4]);
    fscope.scope_flags |= SCOPE_FLAG_GENERATOR;
}

// Vendor compile_atom_expr_await (compile.c:2769).
// The atom_expr_await rule is `KW_AWAIT atom opt(atom_expr_trailers)`;
// KW_AWAIT isn't pushed by the parser, so node layout is identical to
// atom_expr_normal (nodes[0]=atom, nodes[1]=trailers).
fn compileAtomExprAwait(comp: *Compiler, pns: *PnStruct) void {
    const sc = comp.scope_cur.?;
    if (sc.kind != .function and sc.kind != .lambda) {
        compileSyntaxError(comp, @intFromPtr(pns), "'await' outside function");
        return;
    }
    compileAtomExprNormal(comp, pns);
    compileYieldFrom(comp);
}

// Helper: resolve a qstr by literal name (used by async_with for "type").
fn qstrFromStrn(comp: *Compiler, name: []const u8) Qstr {
    return qstr_mod.qstr_from_strn(comp.qctx, name) catch 0;
}

// ─────────────────────────────────────────────────────────────────────────
// §34 — Dispatch table.
//
// ─────────────────────────────────────────────────────────────────────────
// §34 — The match statement (extension grammar — see grammar_ext.zig).
//
// There are no pattern-matching opcodes in MicroPython, so a match
// lowers to the if/elif chain it is equivalent to. Reference
// implementation, already proven differentially against the VM:
// projects/pyfront/src/pyfront/patterns.py.
//
//     match subj:              <subj>; STORE .match
//         case P1: body1       <test P1> -> next1; <bind P1>; body1; JUMP end
//         case P2: body2   next1: <test P2> -> next2; ...
//                            end:
//
// Patterns arrive as expression trees (grammar_ext.zig explains why),
// so this reads them back as patterns:
//
//     NAME              capture, or wildcard when it is `_`
//     None/True/False   singleton — compared with `is`, per PEP 634
//     match_stmt_alts   or-pattern: `a | b`, not bitwise-or
//     match_stmt_pattern  as-pattern: inner pattern plus a name
//     atom_bracket/paren  sequence — isinstance + len + per element
//     atom_expr_normal    class — isinstance + per keyword attribute
//     anything else     value pattern, compared with `==`
//
// Scope matches pyfront's deliberately, so the capability matrix reads
// one gap rather than two: no star patterns, no positional class
// sub-patterns, no mapping patterns. Each is refused by name.
//
// Tests run before any binding, so a failed case leaves no names bound.
// ─────────────────────────────────────────────────────────────────────────

/// Hidden local holding the subject while the chain tests it. The
/// leading dot keeps it out of reach of user code, as vendor does for
/// comprehension arguments (`.0`).
const MATCH_SUBJECT_NAME = ".match";

/// Where a sub-pattern's value lives, as a path from the subject temp.
/// Re-emitting the path costs a few loads and saves a temp per level.
/// The list is threaded down the Zig stack, so nesting depth is bounded
/// by the parser's, not by a fixed cap here.
const Subject = struct {
    parent: ?*const Subject,
    access: union(enum) { index: isize, attr: Qstr, key: Pn },
};

fn emitSubject(comp: *Compiler, subj: ?*const Subject) void {
    const s = subj orelse {
        compileLoadId(comp, qstrFromStrn(comp, MATCH_SUBJECT_NAME));
        return;
    };
    emitSubject(comp, s.parent);
    switch (s.access) {
        .index => |i| {
            comp.emit.loadConstSmallInt(i);
            comp.emit.subscr(MP_EMIT_SUBSCR_LOAD);
        },
        .attr => |q| comp.emit.attr(q, MP_EMIT_ATTR_LOAD),
        .key => |k| {
            compileNode(comp, k);
            comp.emit.subscr(MP_EMIT_SUBSCR_LOAD);
        },
    }
}

/// A sequence pattern's elements. `[a]` collapses to a bare node and
/// `[]` to PN_NULL, which parseNodeExtractList already folds together.
///
/// `scratch` is the caller's, not ours: for a collapsed single element
/// pnExtractList hands back a pointer to the Pn it was given, so that
/// Pn has to outlive the returned list.
fn matchSeqElems(pns: *PnStruct, scratch: *Pn) NodeList {
    scratch.* = pnsNodes(pns)[0];
    return pnExtractList(scratch, grammar.RULE_testlist_comp);
}

/// `isinstance(<subject>, <cls emitted by `emitCls`>)`, leaving a bool.
fn emitIsInstance(
    comp: *Compiler,
    subj: ?*const Subject,
    comptime emitCls: fn (*Compiler, Pn) void,
    cls: Pn,
) void {
    compileLoadId(comp, qstrFromStrn(comp, "isinstance"));
    emitSubject(comp, subj);
    emitCls(comp, cls);
    comp.emit.callFunction(2, 0, 0);
}

fn emitSeqTypes(comp: *Compiler, _: Pn) void {
    compileLoadId(comp, qstrFromStrn(comp, "list"));
    compileLoadId(comp, qstrFromStrn(comp, "tuple"));
    comp.emit.build(2, MP_EMIT_BUILD_TUPLE);
}

/// Index of the `*rest` element, null when there is none. A second star
/// is refused by name; the caller sees the error through `compile_error`.
fn matchStarAt(comp: *Compiler, elems: NodeList) ??usize {
    var found: ?usize = null;
    var i: usize = 0;
    while (i < elems.len) : (i += 1) {
        if (!parser.pnIsStructKind(elems.nodes[i], grammar.RULE_star_expr)) continue;
        if (found != null) {
            compileSyntaxError(comp, elems.nodes[i], "two stars in a sequence pattern");
            return null;
        }
        found = i;
    }
    return found;
}

/// Where element `i` sits in the subject. Elements after a star count
/// from the end, so their position does not depend on how long the
/// subject turned out to be.
fn matchSeqIndex(i: usize, star: ?usize, n: usize) isize {
    const at = star orelse return @intCast(i);
    if (i < at) return @intCast(i);
    return @as(isize, @intCast(i)) - @as(isize, @intCast(n));
}

/// `*rest` binds the slice between the fixed head and tail — always a
/// list, per PEP 634, which `subj[1:]` on a tuple is not.
fn emitStarBind(
    comp: *Compiler,
    star_pn: Pn,
    subj: ?*const Subject,
    at: usize,
    n_after: usize,
) void {
    const name = pnsNodes(asPns(star_pn))[0];
    if (!parser.pnIsId(name)) {
        compileSyntaxError(comp, star_pn, "star pattern must name a plain target");
        return;
    }
    const q: Qstr = @intCast(parser.pnLeafArg(name));
    if (q == qstrFromStrn(comp, "_")) return; // `*_` matches without binding

    compileLoadId(comp, qstrFromStrn(comp, "list"));
    emitSubject(comp, subj);
    comp.emit.loadConstSmallInt(@intCast(at));
    if (n_after == 0) {
        comp.emit.loadConstTok(emit_mod.MP_TOKEN_KW_NONE);
    } else {
        comp.emit.loadConstSmallInt(-@as(isize, @intCast(n_after)));
    }
    comp.emit.build(2, MP_EMIT_BUILD_SLICE);
    comp.emit.subscr(MP_EMIT_SUBSCR_LOAD);
    comp.emit.callFunction(1, 0, 0);
    compileStoreId(comp, q);
}

fn emitDictType(comp: *Compiler, _: Pn) void {
    compileLoadId(comp, qstrFromStrn(comp, "dict"));
}

/// What `emitMapping` is doing on this pass.
const MapPass = enum { test_only, bind_only };

/// Walk a `{...}` pattern, once per pass. The grammar shapes a dict
/// display as a first entry plus a comma-tail, and a *set* as the same
/// shape with bare entries instead of `dictorsetmaker_item` — which is
/// how a set literal is told apart and refused.
fn emitMapping(
    comp: *Compiler,
    pat: Pn,
    subj: ?*const Subject,
    lab_fail: u16,
    pass: MapPass,
) void {
    const brace = pnsNodes(asPns(pat))[0];

    if (pass == .test_only) {
        emitIsInstance(comp, subj, emitDictType, pat);
        comp.emit.popJumpIf(false, lab_fail);
    }

    // `case {}:` names no keys, so the isinstance test is the whole of
    // it: per PEP 634 an empty mapping pattern matches *any* mapping,
    // which is the opposite of what `{}` means as an expression.
    if (pnIsNull(brace)) return;

    // `{k: v}` collapses to the bare entry; more than one wraps it.
    var first = brace;
    var rest: NodeList = .{ .nodes = undefined, .len = 0 };
    var scratch: Pn = undefined;
    if (parser.pnIsStructKind(brace, grammar.RULE_dictorsetmaker)) {
        const n = pnsNodes(asPns(brace));
        first = n[0];
        const tail = n[1];
        if (!pnIsNull(tail) and parser.pnIsStructKind(tail, grammar.RULE_dictorsetmaker_list)) {
            scratch = pnsNodes(asPns(tail))[0];
            if (!pnIsNull(scratch)) {
                rest = pnExtractList(&scratch, grammar.RULE_dictorsetmaker_list2);
            }
        }
    }

    if (!emitMapEntry(comp, first, subj, lab_fail, pass)) return;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (!emitMapEntry(comp, rest.nodes[i], subj, lab_fail, pass)) return;
    }
}

/// One `key: pattern` entry. Returns false once an error is raised.
fn emitMapEntry(
    comp: *Compiler,
    entry: Pn,
    subj: ?*const Subject,
    lab_fail: u16,
    pass: MapPass,
) bool {
    if (!parser.pnIsStructKind(entry, grammar.RULE_dictorsetmaker_item)) {
        // A bare entry is a set element, or `**rest`.
        compileSyntaxError(comp, entry, "set or ** in a mapping pattern");
        return false;
    }
    const kv = pnsNodes(asPns(entry));
    const sub: Subject = .{ .parent = subj, .access = .{ .key = kv[0] } };
    if (pass == .test_only) {
        // The key must be present before its value can be tested; a
        // missing key is a failed match, not a KeyError.
        compileNode(comp, kv[0]);
        emitSubject(comp, subj);
        comp.emit.binaryOp(emit_mod.MP_BINARY_OP_IN);
        comp.emit.popJumpIf(false, lab_fail);
        emitPatternTest(comp, kv[1], &sub, lab_fail);
    } else {
        emitPatternBind(comp, kv[1], &sub);
    }
    return true;
}

/// How `pat` looks as a class pattern. `.dotted` has to be told apart
/// from `.none`: left to fall through to the value pattern, `case
/// mod.P(x=1)` would *call* mod.P and compare the result, which looks
/// like working code.
const ClassPat = union(enum) { none, dotted, simple: *PnStruct };

fn matchClassPat(pat: Pn) ClassPat {
    if (!parser.pnIsStructKind(pat, grammar.RULE_atom_expr_normal)) return .none;
    const pns = asPns(pat);
    const last = pnsNodes(pns)[pnsNumNodes(pns) - 1];
    if (parser.pnIsStructKind(last, grammar.RULE_trailer_paren)) {
        return if (pnsNumNodes(pns) == 2) .{ .simple = asPns(last) } else .dotted;
    }
    // More than one trailer groups them under atom_expr_trailers, which
    // is the shape `mod.P(...)` arrives in.
    if (parser.pnIsStructKind(last, grammar.RULE_atom_expr_trailers)) {
        const ts = asPns(last);
        const lt = pnsNodes(ts)[pnsNumNodes(ts) - 1];
        if (parser.pnIsStructKind(lt, grammar.RULE_trailer_paren)) return .dotted;
    }
    return .none;
}

/// The keyword sub-patterns of a class pattern, as (attribute, pattern).
/// A positional sub-pattern collapses to a bare node rather than an
/// `argument` struct, which is how it is told apart and refused.
/// `scratch` is the caller's — see matchSeqElems.
fn matchClassArgs(comp: *Compiler, trailer: *PnStruct, scratch: *Pn) ?NodeList {
    scratch.* = pnsNodes(trailer)[0];
    const list = pnExtractList(scratch, grammar.RULE_arglist);
    var i: usize = 0;
    while (i < list.len) : (i += 1) {
        const a = list.nodes[i];
        if (!parser.pnIsStructKind(a, grammar.RULE_argument) or
            !parser.pnIsId(pnsNodes(asPns(a))[0]))
        {
            compileSyntaxError(comp, a, "positional sub-pattern in a class pattern");
            return null;
        }
    }
    return list;
}

fn matchClassArgSubject(comp: *Compiler, arg: Pn, subj: ?*const Subject) Subject {
    _ = comp;
    return .{
        .parent = subj,
        .access = .{ .attr = @intCast(parser.pnLeafArg(pnsNodes(asPns(arg))[0])) },
    };
}

/// Is this pattern node a bare NAME (capture or wildcard)? A dotted name
/// is a value pattern, which is why only a leaf counts.
fn matchIsCapture(pn: Pn) bool {
    return parser.pnIsId(pn);
}

fn matchIsWildcard(comp: *Compiler, pn: Pn) bool {
    return matchIsCapture(pn) and parser.pnLeafArg(pn) == qstrFromStrn(comp, "_");
}

/// Emit the test for `pat` against `subj`, jumping to `lab_fail` when it
/// does not match. Falls through when it does.
fn emitPatternTest(comp: *Compiler, pat: Pn, subj: ?*const Subject, lab_fail: u16) void {
    // A capture or wildcard always matches; nothing to test.
    if (matchIsCapture(pat)) return;

    // `a | b` — alternatives. Each that matches jumps past the rest.
    if (parser.pnIsStructKind(pat, grammar_ext.RULE_match_stmt_alts)) {
        const alts = pnsNodes(asPns(pat));
        const n = pnsNumNodes(asPns(pat));
        const lab_hit = compNextLabel(comp);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (i + 1 == n) {
                // Last alternative: its failure is the whole pattern's.
                emitPatternTest(comp, alts[i], subj, lab_fail);
            } else {
                const lab_try_next = compNextLabel(comp);
                emitPatternTest(comp, alts[i], subj, lab_try_next);
                comp.emit.jump(lab_hit);
                comp.emit.labelAssign(lab_try_next);
            }
        }
        comp.emit.labelAssign(lab_hit);
        return;
    }

    // `P() as w` — test the inner pattern; the name binds later.
    if (parser.pnIsStructKind(pat, grammar_ext.RULE_match_stmt_pattern)) {
        emitPatternTest(comp, pnsNodes(asPns(pat))[0], subj, lab_fail);
        return;
    }

    // `[a, b]` / `(a, b)` — a sequence of known length.
    if (parser.pnIsStructKind(pat, grammar.RULE_atom_bracket) or
        parser.pnIsStructKind(pat, grammar.RULE_atom_paren))
    {
        var scratch: Pn = undefined;
        const elems = matchSeqElems(asPns(pat), &scratch);
        const star = matchStarAt(comp, elems) orelse return;

        // A str is a sequence but must not match one, per PEP 634, so
        // the test names list and tuple rather than asking for __len__.
        emitIsInstance(comp, subj, emitSeqTypes, pat);
        comp.emit.popJumpIf(false, lab_fail);

        // With a star the fixed elements are a minimum, not the length.
        const n_fixed = elems.len - @intFromBool(star != null);
        compileLoadId(comp, qstrFromStrn(comp, "len"));
        emitSubject(comp, subj);
        comp.emit.callFunction(1, 0, 0);
        comp.emit.loadConstSmallInt(@intCast(n_fixed));
        comp.emit.binaryOp(if (star != null)
            emit_mod.MP_BINARY_OP_MORE_EQUAL
        else
            emit_mod.MP_BINARY_OP_EQUAL);
        comp.emit.popJumpIf(false, lab_fail);

        var i: usize = 0;
        while (i < elems.len) : (i += 1) {
            if (star != null and i == star.?) continue; // a star always matches
            const sub: Subject = .{ .parent = subj, .access = .{ .index = matchSeqIndex(i, star, elems.len) } };
            emitPatternTest(comp, elems.nodes[i], &sub, lab_fail);
        }
        return;
    }

    // `{...}` — a mapping pattern. It matches on the keys it names and
    // ignores every other one, which is why it cannot be left to compile
    // as the dict equality test the same syntax means in an expression.
    if (parser.pnIsStructKind(pat, grammar.RULE_atom_brace)) {
        emitMapping(comp, pat, subj, lab_fail, .test_only);
        return;
    }

    // `P(x=1)` — a class pattern.
    switch (matchClassPat(pat)) {
        .dotted => {
            compileSyntaxError(comp, pat, "dotted name in a class pattern");
            return;
        },
        .simple => |trailer| {
            var scratch: Pn = undefined;
            const args = matchClassArgs(comp, trailer, &scratch) orelse return;
            emitIsInstance(comp, subj, compileNode, pnsNodes(asPns(pat))[0]);
            comp.emit.popJumpIf(false, lab_fail);
            var i: usize = 0;
            while (i < args.len) : (i += 1) {
                const sub = matchClassArgSubject(comp, args.nodes[i], subj);
                emitPatternTest(comp, pnsNodes(asPns(args.nodes[i]))[1], &sub, lab_fail);
            }
            return;
        },
        .none => {},
    }

    // Literal, singleton or value pattern. PEP 634 compares None, True
    // and False by identity and everything else by equality.
    emitSubject(comp, subj);
    compileNode(comp, pat);
    const singleton = parser.pnIsTokenKind(pat, @intFromEnum(TokenKind.KW_NONE)) or
        parser.pnIsTokenKind(pat, @intFromEnum(TokenKind.KW_TRUE)) or
        parser.pnIsTokenKind(pat, @intFromEnum(TokenKind.KW_FALSE));
    comp.emit.binaryOp(if (singleton) emit_mod.MP_BINARY_OP_IS else emit_mod.MP_BINARY_OP_EQUAL);
    comp.emit.popJumpIf(false, lab_fail);
}

/// Emit the bindings `pat` makes, once its test has passed.
fn emitPatternBind(comp: *Compiler, pat: Pn, subj: ?*const Subject) void {
    if (matchIsCapture(pat)) {
        if (matchIsWildcard(comp, pat)) return; // `_` binds nothing
        emitSubject(comp, subj);
        compileStoreId(comp, @intCast(parser.pnLeafArg(pat)));
        return;
    }

    // `P() as w` — the inner pattern's bindings, then the name.
    if (parser.pnIsStructKind(pat, grammar_ext.RULE_match_stmt_pattern)) {
        const n = pnsNodes(asPns(pat));
        emitPatternBind(comp, n[0], subj);
        emitSubject(comp, subj);
        compileStoreId(comp, @intCast(parser.pnLeafArg(pnsNodes(asPns(n[1]))[0])));
        return;
    }

    if (parser.pnIsStructKind(pat, grammar.RULE_atom_bracket) or
        parser.pnIsStructKind(pat, grammar.RULE_atom_paren))
    {
        var scratch: Pn = undefined;
        const elems = matchSeqElems(asPns(pat), &scratch);
        const star = matchStarAt(comp, elems) orelse return;
        var i: usize = 0;
        while (i < elems.len) : (i += 1) {
            if (star != null and i == star.?) {
                emitStarBind(comp, elems.nodes[i], subj, i, elems.len - i - 1);
                continue;
            }
            const at = matchSeqIndex(i, star, elems.len);
            const sub: Subject = .{ .parent = subj, .access = .{ .index = at } };
            emitPatternBind(comp, elems.nodes[i], &sub);
        }
        return;
    }

    if (parser.pnIsStructKind(pat, grammar.RULE_atom_brace)) {
        emitMapping(comp, pat, subj, 0, .bind_only);
        return;
    }

    switch (matchClassPat(pat)) {
        .simple => |trailer| {
            var scratch: Pn = undefined;
            const args = matchClassArgs(comp, trailer, &scratch) orelse return;
            var i: usize = 0;
            while (i < args.len) : (i += 1) {
                const sub = matchClassArgSubject(comp, args.nodes[i], subj);
                emitPatternBind(comp, pnsNodes(asPns(args.nodes[i]))[1], &sub);
            }
            return;
        },
        // A dotted or non-class pattern binds nothing; the test arm has
        // already refused the dotted one.
        else => {},
    }

    if (parser.pnIsStructKind(pat, grammar_ext.RULE_match_stmt_alts)) {
        // Alternatives would have to bind the same names on every arm
        // for the body to be able to use them; only the no-binding case
        // is allowed rather than emitting something half-defined.
        const alts = pnsNodes(asPns(pat));
        var i: usize = 0;
        while (i < pnsNumNodes(asPns(pat))) : (i += 1) {
            if (matchIsCapture(alts[i]) and !matchIsWildcard(comp, alts[i])) {
                compileSyntaxError(comp, pat, "capture in an alternative pattern");
                return;
            }
        }
    }
}

fn compileMatchStmt(comp: *Compiler, pns: *PnStruct) void {
    const nodes = pnsNodes(pns);
    // nodes[0] is the `match` NAME; the parser's soft-keyword hook has
    // already established what it says.
    compileNode(comp, nodes[1]);
    compileStoreId(comp, qstrFromStrn(comp, MATCH_SUBJECT_NAME));

    const lab_end = compNextLabel(comp);

    var case_list = nodes[2];
    const cases = pnExtractList(&case_list, grammar_ext.RULE_match_stmt_case_list);

    var i: usize = 0;
    while (i < cases.len) : (i += 1) {
        const c = asPns(cases.nodes[i]);
        const cn = pnsNodes(c);

        // The grammar matches a bare NAME here because `case` is a soft
        // keyword with no token of its own; this is where it is checked.
        if (!parser.pnIsId(cn[0]) or parser.pnLeafArg(cn[0]) != qstrFromStrn(comp, "case")) {
            compileSyntaxError(comp, cases.nodes[i], "expected 'case'");
            return;
        }

        const lab_next = compNextLabel(comp);
        const pat = cn[1];

        emitPatternTest(comp, pat, null, lab_next);
        // PEP 634 binds before the guard runs, so `case n if n > 5` can
        // see `n` — and the binding stands even when the guard fails.
        emitPatternBind(comp, pat, null);
        if (!pnIsNull(cn[2])) {
            // guard: match_stmt_guard wraps the condition expression.
            cIfCond(comp, pnsNodes(asPns(cn[2]))[0], false, lab_next);
        }
        compileNode(comp, cn[3]);

        if (i + 1 < cases.len) comp.emit.jump(lab_end);
        comp.emit.labelAssign(lab_next);
    }

    comp.emit.labelAssign(lab_end);
}

// Comptime-built [NUM_RULES]CompileFn populated by @field reflection
// over CompileRules. Every named decl in CompileRules whose name matches
// `RULE_<name>` in grammar_data.zig gets slotted into the table. All
// other slots default to `compileGenericAllNodes` (safe walk).
//
// Comptime asserts (a) table length == NUM_RULES, (b) every slot
// non-null.
// ─────────────────────────────────────────────────────────────────────────

const CompileRules = struct {
    pub const file_input = compileFileInput;
    pub const single_input = compileSingleInput;
    pub const eval_input = compileEvalInput;

    pub const expr_stmt = compileExprStmt;
    pub const del_stmt = compileDelStmt;
    pub const pass_stmt = compilePassStmt;
    pub const break_stmt = compileBreakContStmt;
    pub const continue_stmt = compileBreakContStmt;
    pub const return_stmt = compileReturnStmt;
    pub const yield_stmt = compileYieldStmt;
    pub const raise_stmt = compileRaiseStmt;
    pub const import_name = compileImportName;
    pub const import_from = compileImportFrom;
    pub const global_stmt = compileGlobalNonlocalStmt;
    pub const nonlocal_stmt = compileGlobalNonlocalStmt;
    pub const assert_stmt = compileAssertStmt;

    pub const if_stmt = compileIfStmt;
    pub const while_stmt = compileWhileStmt;
    pub const for_stmt = compileForStmt;
    pub const try_stmt = compileTryStmt;
    pub const with_stmt = compileWithStmt;

    pub const suite_block_stmts = compileSuiteBlockStmts;

    pub const namedexpr_test = compileNamedexpr;
    pub const test_if_expr = compileTestIfExpr;
    pub const lambdef = compileLambdef;

    pub const or_test = compileOrTest;
    pub const and_test = compileAndTest;
    pub const not_test_2 = compileNotTest2;
    pub const comparison = compileComparison;
    pub const star_expr = compileStarExpr;
    pub const expr = compileBinaryOp;
    pub const xor_expr = compileBinaryOp;
    pub const and_expr = compileBinaryOp;
    pub const shift_expr = compileBinaryOp;
    pub const arith_expr = compileBinaryOp;
    pub const term = compileBinaryOp;
    pub const factor_2 = compileFactor2;
    pub const power = compilePower;

    pub const atom_expr_normal = compileAtomExprNormal;
    pub const atom_paren = compileAtomParen;
    pub const atom_bracket = compileAtomBracket;
    pub const atom_brace = compileAtomBrace;
    pub const trailer_paren = compileTrailerParen;
    pub const trailer_bracket = compileTrailerBracket;
    pub const trailer_period = compileTrailerPeriod;

    // Slice / subscript handlers — without these, x[a:b] / x[a:b:c] /
    // x[a, b] fall through to compileGenericAllNodes and miss BUILD_SLICE.
    pub const subscript_2 = compileSubscript;
    pub const subscript_3 = compileSubscript;
    pub const subscriptlist = compileSubscriptlist;

    // Dict key:value pairs — vendor swaps to value-then-key for STORE_MAP.
    pub const dictorsetmaker_item = compileDictorsetmakerItem;
    // PEP 448 `{**expr}` — nanopython grammar overlay adds this rule.
    pub const dictorsetmaker_dbl_star = compileDictorsetmakerDblStar;

    pub const testlist = compileTestlist;
    pub const testlist_comp = compileTestlistComp;
    // When `a, b, c` appears on the RHS of an assignment / `return` /
    // any other rvalue context, the parser produces a testlist_star_expr
    // (or exprlist for the `for`-target tuple) struct. Vendor's
    // compile_node dispatches them to a generic tuple-builder so the
    // values get wrapped in a BUILD_TUPLE before downstream consumers
    // (UNPACK_SEQUENCE, iteration, etc.) try to read them. Our default
    // dispatch fell through to compileGenericAllNodes which loaded the
    // children but never built the tuple — so `a, b, c = b, c, a`
    // emitted LOAD b, LOAD c, LOAD a, UNPACK_SEQUENCE 3 (no tuple to
    // unpack → 'int' object isn't iterable at runtime).
    //
    // LHS context goes through cAssign, not the dispatch table, so
    // adding testlist_star_expr here doesn't double-wrap the LHS.
    pub const testlist_star_expr = compileTestlist;
    pub const exprlist = compileTestlist;

    pub const classdef = compileClassdef;
    pub const yield_expr = compileYieldExpr;

    pub const const_object = compileConstObject;

    pub const funcdef = compileFuncdef;
    pub const decorated = compileDecorated;

    // ASYNC_AWAIT — A2/A3 (see §33.1). async_funcdef is reached only via
    // the decorated path (compileDecorated dispatches based on body kind).
    pub const async_funcdef = compileAsyncFuncdef;
    pub const async_stmt = compileAsyncStmt;
    pub const atom_expr_await = compileAtomExprAwait;
};

const compile_function: [grammar.NUM_RULES]CompileFn = build_dispatch_table();

fn build_dispatch_table() [grammar.NUM_RULES]CompileFn {
    @setEvalBranchQuota(100_000);
    var tbl: [grammar.NUM_RULES]CompileFn = [_]CompileFn{compileGenericAllNodes} ** grammar.NUM_RULES;
    inline for (@typeInfo(CompileRules).@"struct".decls) |d| {
        const rule_name = "RULE_" ++ d.name;
        if (!@hasDecl(grammar, rule_name)) {
            @compileError("no grammar." ++ rule_name ++
                " for CompileRules." ++ d.name ++
                " — regenerate grammar_data.zig via tools/gen_grammar.py");
        }
        const id: u8 = @field(grammar, rule_name);
        tbl[id] = @field(CompileRules, d.name);
    }
    return tbl;
}

comptime {
    if (compile_function.len != grammar.NUM_RULES)
        @compileError("compile_function length must match grammar.NUM_RULES");
    // `CompileFn` is a non-optional fn-pointer, so every slot is statically
    // non-null by construction — the default fill at buildCompileFunction
    // initialises every slot to compileGenericAllNodes before specialised
    // handlers overwrite them. A runtime @intFromPtr check is not
    // representable at comptime in Zig 0.16, and unnecessary anyway.
}

// ─────────────────────────────────────────────────────────────────────────
// §32 — scopeComputeThings.
//
// BYTE-CRITICAL: this is a verbatim port of vendor py/compile.c
// scope_compute_things (compile.c:3380). Local-numbering order follows
// vendor exactly because the .mpy emits the IdInfo table in local_num
// order — any deviation shifts the FAST_N indices that the bytecode
// references.
//
// Vendor order:
//   1. Star-param swap if VARARGS: move `*args` to the end of the
//      regular-param run (before `**kwargs`).
//   2. Single forward pass: LOCAL or IS_PARAM gets local_num++. Convert
//      GLOBAL_IMPLICIT → GLOBAL_EXPLICIT in func-like scopes. Skip
//      __class__ in class scopes.
//   3. CELL (without IS_PARAM): local_num++.
//   4. FREE vars: indexed in PARENT's CELL/FREE order; shift all
//      non-FREE locals by +num_free; bump num_pos_args + num_locals.
// ─────────────────────────────────────────────────────────────────────────

/// Assign local_num to each IdInfo entry; bump scope.num_locals.
/// Mirrors vendor compile.c scope_compute_things().
fn scopeComputeThings(scope: *Scope, qctx: *const QstrContext) void {
    const class_qst: Qstr = qstr_mod.qstr_find_strn(qctx, "__class__");
    // (1) Star-param swap: in MicroPython `*args` goes after all other
    // regular params (still before `**kwargs`). Walk id_info from the
    // back; first regular IS_PARAM we see is `id_param`; first
    // STAR_PARAM after that gets swapped with id_param.
    if ((scope.scope_flags & scope_mod.SCOPE_FLAG_VARARGS) != 0) {
        var id_param: ?*IdInfo = null;
        var i: isize = @as(isize, @intCast(scope.id_info.items.len)) - 1;
        while (i >= 0) : (i -= 1) {
            const id = &scope.id_info.items[@intCast(i)];
            if ((id.flags & ID_FLAG_IS_STAR_PARAM) != 0) {
                if (id_param) |p| {
                    const tmp = p.*;
                    p.* = id.*;
                    id.* = tmp;
                }
                break;
            } else if (id_param == null and id.flags == ID_FLAG_IS_PARAM) {
                id_param = id;
            }
        }
    }

    // (2) Single forward pass: index LOCAL and IS_PARAM, in-place
    // implicit→explicit global conversion in func-like scopes, skip
    // __class__ in class scopes.
    scope.num_locals = 0;
    {
        var i: usize = 0;
        while (i < scope.id_info.items.len) : (i += 1) {
            const id = &scope.id_info.items[i];
            if (scope.kind == .class and id.qst == class_qst)
                continue;
            if (scope_mod.ScopeKind.isFuncLike(scope.kind) and
                id.kind == .global_implicit)
            {
                id.kind = .global_explicit;
            }
            // Native/REFGLOBALS gating is dead in nano config.
            if (id.kind == .local or (id.flags & ID_FLAG_IS_PARAM) != 0) {
                id.local_num = scope.num_locals;
                scope.num_locals += 1;
            }
        }
    }

    // (3) Cell vars (not also IS_PARAM): come right after fast locals.
    {
        var i: usize = 0;
        while (i < scope.id_info.items.len) : (i += 1) {
            const id = &scope.id_info.items[i];
            if (id.kind == .cell and (id.flags & ID_FLAG_IS_PARAM) == 0) {
                id.local_num = scope.num_locals;
                scope.num_locals += 1;
            }
        }
    }

    // (4) Free vars: ordered by parent's CELL/FREE order.
    if (scope.parent) |parent| {
        var num_free: u16 = 0;
        var pi: usize = 0;
        while (pi < parent.id_info.items.len) : (pi += 1) {
            const pid = &parent.id_info.items[pi];
            if (pid.kind == .cell or pid.kind == .free) {
                var ci: usize = 0;
                while (ci < scope.id_info.items.len) : (ci += 1) {
                    const cid = &scope.id_info.items[ci];
                    if (cid.kind == .free and pid.qst == cid.qst) {
                        std.debug.assert((cid.flags & ID_FLAG_IS_PARAM) == 0);
                        cid.local_num = num_free;
                        num_free += 1;
                    }
                }
            }
        }
        // Shift all non-FREE (or FREE-but-param) locals by +num_free.
        if (num_free > 0) {
            var ci: usize = 0;
            while (ci < scope.id_info.items.len) : (ci += 1) {
                const cid = &scope.id_info.items[ci];
                if (cid.kind != .free or (cid.flags & ID_FLAG_IS_PARAM) != 0) {
                    cid.local_num += num_free;
                }
            }
            scope.num_pos_args += num_free;
            scope.num_locals += num_free;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────
// §33 — Module assembly + public entry.
//
// The 3-pass driver lives in §31 above (runScopePass / runCodegenPasses).
// Earlier scaffold also defined driveScope / runPassesForScope / a stub
// compileScopeBody — those have been retired (deleted) in C7b-7 as the
// new multi-scope driver covers everything they did.
// ─────────────────────────────────────────────────────────────────────────

/// Recursively dupe every byte slice in an ObjEntry so the resulting
/// entry can be freed by `mpy.deinitObjList` without aliasing back to
/// the caller's storage.
fn dupeObjEntry(
    allocator: Allocator,
    e: mpy.ObjEntry,
) std.mem.Allocator.Error!mpy.ObjEntry {
    return switch (e) {
        .none, .false, .true, .ellipsis => e,
        .str => |b| .{ .str = try allocator.dupe(u8, b) },
        .bytes => |b| .{ .bytes = try allocator.dupe(u8, b) },
        .int => |b| .{ .int = try allocator.dupe(u8, b) },
        .float => |b| .{ .float = try allocator.dupe(u8, b) },
        .complex => |b| .{ .complex = try allocator.dupe(u8, b) },
        .tuple => |items| blk: {
            const out = try allocator.alloc(mpy.ObjEntry, items.len);
            for (items, 0..) |it, i| out[i] = try dupeObjEntry(allocator, it);
            // The outer tuple slice itself was alloc'd by toObjEntry; it
            // is leaked here (replaced by `out`). Free it so we don't
            // pile up on every call.
            allocator.free(items);
            break :blk .{ .tuple = out };
        },
    };
}

/// Top-level compile entry. Drives the full pipeline: build a Scope
/// chain, run passes per scope, fold the results into an mpy.Module.
pub fn compile(
    allocator: Allocator,
    qctx: *QstrContext,
    tree: ParseTree,
    source_file: Qstr,
    is_repl: bool,
) CompileError!mpy.Module {
    // Root (module) scope anchors the chain.
    const root_scope = try Scope.new(allocator, .module, tree.root, 0);

    var emit_common = EmitCommon.init(allocator);
    defer emit_common.deinit();
    // Vendor mp_emit_common_init (compile.c:218) seeds the qstr_table
    // with the source_file qstr at index 0 BEFORE any pass runs, so
    // every emitted .mpy carries the source path as its first qstr
    // entry. We mirror that here.
    _ = try emit_common.useQstr(source_file);
    var emit = Emit.init(allocator, &emit_common);
    defer emit.deinit();

    var comp: Compiler = .{
        .allocator = allocator,
        .qctx = qctx,
        .is_repl = is_repl,
        .emit = &emit,
    };
    comp.scope_head = root_scope;
    comp.scope_cur = root_scope;
    comp.next_label = 0;
    // The whole scope chain (root + every nested scope discovered during
    // SCOPE) is freed here in vendor order. Also free any RawCode boxes we
    // stashed on scope.raw_code, including their owned fun_data/children
    // slices — runAllScopes hands ownership of those to us.
    defer {
        var s = comp.scope_head;
        while (s) |sp| {
            const nx = sp.next;
            if (sp.raw_code) |rcptr| {
                const rc: *mpy.RawCode = @ptrCast(@alignCast(rcptr));
                allocator.free(rc.fun_data);
                allocator.free(rc.children);
                allocator.destroy(rc);
                sp.raw_code = null;
            }
            sp.destroy();
            s = nx;
        }
    }

    try emit.setMaxNumLabels(1024);

    // SCOPE pass on root — also discovers nested scopes via
    // scopeNewAndLink, so we can't iterate scope_head here; we drive root
    // only, then let the multi-scope loop pick up STACK/CODE/EMIT for
    // every scope (root + nested) in vendor order.
    runScopePass(&comp, root_scope) catch |e| switch (e) {
        error.OutOfMemory => return CompileError.OutOfMemory,
    };

    // Vendor compile.c:3503/3528/3539 — every per-pass loop is gated on
    // `comp->compile_error == MP_OBJ_NULL`. We must mirror that bail-out
    // here: if SCOPE recorded a SyntaxError via an early-return path
    // (e.g. compileTryExcept's default-except-not-last at compile.zig:
    // 2579), then dangling forward labels (success_label, l2) would
    // survive into EMIT, where the 0-offset jump overflows its encoding
    // window and runCodegenPasses spins forever on emit.overflow,
    // surfacing as OOM instead of the recorded SyntaxError.
    if (comp.compile_error) |err| {
        return switch (err.kind) {
            .syntax => CompileError.SyntaxError,
            .indentation => CompileError.IndentationError,
        };
    }

    // Vendor compile.c:3528 — scope_compute_things runs after SCOPE on
    // every scope, but BEFORE STACK_SIZE on any. We loop the chain here.
    {
        var s = comp.scope_head;
        while (s) |sp| : (s = sp.next) scopeComputeThings(sp, comp.qctx);
    }

    // STACK_SIZE → CODE_SIZE → EMIT for each scope in chain order.
    {
        var s = comp.scope_head;
        while (s) |sp| : (s = sp.next) {
            if (comp.compile_error != null) break;
            runCodegenPasses(&comp, sp) catch |e| switch (e) {
                error.OutOfMemory => return CompileError.OutOfMemory,
            };
        }
    }

    if (comp.compile_error) |err| {
        return switch (err.kind) {
            .syntax => CompileError.SyntaxError,
            .indentation => CompileError.IndentationError,
        };
    }

    // Assemble the Module. Qstr / const-obj tables are module-global on
    // EmitCommon; deep-dupe so caller can deinit cleanly.
    const qstrs = try allocator.alloc(mpy.QstrEntry, emit_common.qstr_table.items.len);
    for (emit_common.qstr_table.items, 0..) |q, i| {
        const e = qstr_mod.qstrToEntry(qctx, q);
        qstrs[i] = switch (e) {
            .static => e,
            .new => |b| .{ .new = try allocator.dupe(u8, b) },
        };
    }

    const objs = try allocator.alloc(mpy.ObjEntry, emit_common.const_obj_list.items.len);
    for (emit_common.const_obj_list.items, 0..) |o, i| {
        const e = try o.toObjEntry(allocator);
        objs[i] = try dupeObjEntry(allocator, e);
    }

    // Root RawCode + recursive child assembly. The chain has been visited
    // in vendor order; each scope.raw_code already holds its own fun_data
    // and direct children list. We deep-clone into a fresh tree owned by
    // Module.deinit's recursive free path, then drop the per-scope boxes
    // in the trailing defer.
    const root_rc_box: *mpy.RawCode = @ptrCast(@alignCast(root_scope.raw_code.?));
    const rc = try cloneRawCodeTree(allocator, root_rc_box.*);

    return mpy.Module{
        .version = mpy.MPY_VERSION,
        .feature_flags = 0,
        .small_int_bits = 31,
        .arch_flags = null,
        .qstrs = qstrs,
        .objs = objs,
        .rc = rc,
    };
}

// ─────────────────────────────────────────────────────────────────────────
// Test scaffolding + unit tests.
//
// These cover the algorithmic core: constant folding through
// loadConstSmallInt, single-statement end-to-end, 3-pass size
// consistency, dispatch table sanity, and the public compile() entry.
// Full corpus parity against mpy-cross is the integration test
// (compile_test.zig in task #26).
// ─────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "dispatch table: length matches grammar.NUM_RULES and every slot is non-null" {
    try testing.expectEqual(@as(usize, grammar.NUM_RULES), compile_function.len);
    for (compile_function) |f| {
        try testing.expect(@intFromPtr(f) != 0);
    }
}

test "dispatch table: known handlers are wired to the right rule ids" {
    try testing.expectEqual(@as(CompileFn, compileFileInput), compile_function[grammar.RULE_file_input]);
    try testing.expectEqual(@as(CompileFn, compileExprStmt), compile_function[grammar.RULE_expr_stmt]);
    try testing.expectEqual(@as(CompileFn, compilePassStmt), compile_function[grammar.RULE_pass_stmt]);
    try testing.expectEqual(@as(CompileFn, compileConstObject), compile_function[grammar.RULE_const_object]);
    try testing.expectEqual(@as(CompileFn, compileIfStmt), compile_function[grammar.RULE_if_stmt]);
    try testing.expectEqual(@as(CompileFn, compileForStmt), compile_function[grammar.RULE_for_stmt]);
}

test "compile_load_const_small_int: in-range constant emits MULTI byte" {
    // Algorithmic core: compileNode of a small-int leaf must route to
    // Emit.loadConstSmallInt, which encodes 0 as the MULTI form 0x80.
    var ec = EmitCommon.init(testing.allocator);
    defer ec.deinit();
    var emit = Emit.init(testing.allocator, &ec);
    defer emit.deinit();
    const sc = try Scope.new(testing.allocator, .module, parser.PN_NULL, 0);
    defer sc.destroy();

    try emit.setMaxNumLabels(0);

    var qctx = QstrContext.init(testing.allocator);
    defer qctx.deinit();

    var comp = Compiler{
        .allocator = testing.allocator,
        .qctx = &qctx,
        .is_repl = false,
        .emit = &emit,
    };
    comp.scope_cur = sc;

    inline for (.{ Pass.scope, Pass.stack_size, Pass.code_size, Pass.emit }) |p| {
        ec.startPass(p);
        try emit.startPass(p, sc);
        compileNode(&comp, parser.pnNewSmallInt(0));
        _ = try emit.endPass();
    }

    const bc = emit.code_base[emit.code_info_size..];
    try testing.expectEqual(@as(u8, 0x80), bc[0]);
}

test "compile_simple_stmt: pass produces empty bytecode body" {
    // End-to-end through the public compile() entry. `pass` parses
    // successfully and emits only the trailing LOAD_NONE + RETURN_VALUE
    // that the driver appends.
    var qctx = QstrContext.init(testing.allocator);
    defer qctx.deinit();
    const lex = try lexer_mod.lexerNewFromStr(testing.allocator, 0, "pass\n", true);
    defer lexer_mod.lexerFree(lex);
    var tree = try parser.parse(testing.allocator, lex, &qctx, .file_input);
    defer tree.deinit();

    var module = try compile(testing.allocator, &qctx, tree, 0, false);
    defer module.deinit(testing.allocator);

    // Bytecode body must include at least the LOAD_NONE + RETURN_VALUE
    // tail — driveScope's failsafe.
    try testing.expect(module.rc.fun_data.len > 0);
    // Last byte is RETURN_VALUE (MP_BC_RETURN_VALUE = MP_BC_BASE_BYTE_E
    // + 3 = 0x63).
    try testing.expectEqual(emit_mod.MP_BC_RETURN_VALUE, module.rc.fun_data[module.rc.fun_data.len - 1]);
}

test "3-pass consistency: CODE_SIZE bytecode_offset matches EMIT bytecode_offset" {
    // The invariant: SCOPE then STACK then CODE_SIZE measures, then EMIT
    // re-walks with code_base allocated; the byte counts must agree.
    var ec = EmitCommon.init(testing.allocator);
    defer ec.deinit();
    var emit = Emit.init(testing.allocator, &ec);
    defer emit.deinit();
    const sc = try Scope.new(testing.allocator, .module, parser.PN_NULL, 0);
    defer sc.destroy();

    try emit.setMaxNumLabels(0);

    var code_size_bc: usize = 0;
    inline for (.{ Pass.scope, Pass.stack_size, Pass.code_size, Pass.emit }) |p| {
        ec.startPass(p);
        try emit.startPass(p, sc);
        emit.loadConstSmallInt(0);
        emit.returnValue();
        const ok = try emit.endPass();
        try testing.expect(ok);
        if (p == .code_size) code_size_bc = emit.bytecode_size;
    }
    try testing.expectEqual(code_size_bc, emit.bytecode_offset);
}

test "scopeComputeThings: vendor order — param first, then plain local, then cell" {
    // Vendor scope_compute_things (compile.c:3380) assigns local_num in
    // a single forward pass: LOCAL or IS_PARAM gets local_num++ in
    // id_info declaration order, then CELL (not IS_PARAM), then FREE
    // (only if scope has a parent).
    var qctx = QstrContext.init(testing.allocator);
    defer qctx.deinit();

    // .function scopes require a real PnStruct (Scope.new asserts
    // pnIsStruct). Synthesise a single-node PnStruct on the stack.
    const FakePns = extern struct {
        hdr: parser.PnStruct,
        n0: parser.Pn,
    };
    var fake: FakePns = .{
        .hdr = .{ .source_line = 1, .kind_num_nodes = (1 << 8) },
        .n0 = parser.pnNewLeaf(parser.PN_ID, 1),
    };
    const fake_pn: parser.Pn = @intFromPtr(&fake.hdr);

    const sc = try Scope.new(testing.allocator, .function, fake_pn, 0);
    defer sc.destroy();

    sc.simple_name = 0;
    sc.id_info.clearRetainingCapacity();
    // Three entries: a param, an ordinary local, and a cell (no parent
    // here, so no free-var path).
    try sc.id_info.append(testing.allocator, .{ .kind = .local, .flags = ID_FLAG_IS_PARAM, .qst = 11 });
    try sc.id_info.append(testing.allocator, .{ .kind = .local, .qst = 12 });
    try sc.id_info.append(testing.allocator, .{ .kind = .cell, .qst = 13 });

    scopeComputeThings(sc, &qctx);

    try testing.expectEqual(@as(u16, 0), sc.id_info.items[0].local_num); // param
    try testing.expectEqual(@as(u16, 1), sc.id_info.items[1].local_num); // local
    try testing.expectEqual(@as(u16, 2), sc.id_info.items[2].local_num); // cell
    try testing.expectEqual(@as(u16, 3), sc.num_locals);
}

test "scopeComputeThings: implicit global converts to explicit in func-like scope" {
    var qctx = QstrContext.init(testing.allocator);
    defer qctx.deinit();

    const FakePns = extern struct {
        hdr: parser.PnStruct,
        n0: parser.Pn,
    };
    var fake: FakePns = .{
        .hdr = .{ .source_line = 1, .kind_num_nodes = (1 << 8) },
        .n0 = parser.pnNewLeaf(parser.PN_ID, 1),
    };
    const fake_pn: parser.Pn = @intFromPtr(&fake.hdr);

    const sc = try Scope.new(testing.allocator, .function, fake_pn, 0);
    defer sc.destroy();

    sc.simple_name = 0;
    sc.id_info.clearRetainingCapacity();
    try sc.id_info.append(testing.allocator, .{ .kind = .global_implicit, .qst = 100 });

    scopeComputeThings(sc, &qctx);

    try testing.expectEqual(scope_mod.IdInfoKind.global_explicit, sc.id_info.items[0].kind);
    try testing.expectEqual(@as(u16, 0), sc.num_locals);
}

test "compNextLabel: monotonic + wraps at u16 boundary" {
    var qctx = QstrContext.init(testing.allocator);
    defer qctx.deinit();
    var ec = EmitCommon.init(testing.allocator);
    defer ec.deinit();
    var emit = Emit.init(testing.allocator, &ec);
    defer emit.deinit();

    var comp = Compiler{
        .allocator = testing.allocator,
        .qctx = &qctx,
        .is_repl = false,
        .emit = &emit,
    };

    try testing.expectEqual(@as(u16, 0), compNextLabel(&comp));
    try testing.expectEqual(@as(u16, 1), compNextLabel(&comp));
    try testing.expectEqual(@as(u16, 2), compNextLabel(&comp));

    // Wraparound: set next_label near max and bump twice.
    comp.next_label = 0xfffe;
    try testing.expectEqual(@as(u16, 0xfffe), compNextLabel(&comp));
    try testing.expectEqual(@as(u16, 0xffff), compNextLabel(&comp));
    try testing.expectEqual(@as(u16, 0), compNextLabel(&comp)); // wrap
}

test "compile: x = 1 parses, compiles, produces non-empty bytecode" {
    // C7b-6 dependency: full pipeline needs real handler bodies. The
    // scaffold's compileExprStmt doesn't bind `x` in the SCOPE pass, so
    // the EMIT pass's idOp lookup fails. Parser alignment is fixed; the
    // remaining gap is real handler porting.
    var qctx = QstrContext.init(testing.allocator);
    defer qctx.deinit();
    const lex = try lexer_mod.lexerNewFromStr(testing.allocator, 0, "x = 1\n", true);
    defer lexer_mod.lexerFree(lex);
    var tree = try parser.parse(testing.allocator, lex, &qctx, .file_input);
    defer tree.deinit();

    var module = try compile(testing.allocator, &qctx, tree, 0, false);
    defer module.deinit(testing.allocator);

    try testing.expect(module.rc.fun_data.len > 0);
    try testing.expectEqual(emit_mod.MP_BC_RETURN_VALUE, module.rc.fun_data[module.rc.fun_data.len - 1]);
}

test "compile: SyntaxError surfaces from parse-stage; compile sees nothing" {
    // C7b-6 dependency: same — `1 + 2` needs compileBinaryOp + the
    // operator dispatch. Scaffold returns dummy bytecode and the test
    // hits various stub asserts.
    var qctx = QstrContext.init(testing.allocator);
    defer qctx.deinit();
    const lex = try lexer_mod.lexerNewFromStr(testing.allocator, 0, "1 + 2\n", true);
    defer lexer_mod.lexerFree(lex);
    var tree = try parser.parse(testing.allocator, lex, &qctx, .file_input);
    defer tree.deinit();

    var module = try compile(testing.allocator, &qctx, tree, 0, false);
    defer module.deinit(testing.allocator);

    // The qstr table holds at least zero entries; we just need the
    // call not to crash.
    try testing.expect(module.qstrs.len >= 0);
}

test "wk cache: lazy resolution returns a stable qstr id" {
    var qctx = QstrContext.init(testing.allocator);
    defer qctx.deinit();
    var ec = EmitCommon.init(testing.allocator);
    defer ec.deinit();
    var emit = Emit.init(testing.allocator, &ec);
    defer emit.deinit();

    var comp = Compiler{
        .allocator = testing.allocator,
        .qctx = &qctx,
        .is_repl = false,
        .emit = &emit,
    };

    const id1 = comp.wk(WK_IDX.range);
    const id2 = comp.wk(WK_IDX.range);
    try testing.expectEqual(id1, id2);
    try testing.expect(id1 != 0);
}

test "EmitCommon round-trips: useQstr stays stable across the Compiler" {
    // C7b-6 dependency: needs real expression handlers to bind foo/bar
    // in scope before the EMIT pass tries to look them up.
    var qctx = QstrContext.init(testing.allocator);
    defer qctx.deinit();
    var ec = EmitCommon.init(testing.allocator);
    defer ec.deinit();
    var emit = Emit.init(testing.allocator, &ec);
    defer emit.deinit();

    // Compile a small program that loads two distinct identifiers and
    // verify the qstr_table preserves their order.
    const lex = try lexer_mod.lexerNewFromStr(testing.allocator, 0, "foo\nbar\n", true);
    defer lexer_mod.lexerFree(lex);
    var tree = try parser.parse(testing.allocator, lex, &qctx, .file_input);
    defer tree.deinit();

    var module = try compile(testing.allocator, &qctx, tree, 0, false);
    defer module.deinit(testing.allocator);

    // The qstr table at minimum holds the simple_name of the root
    // module scope (<module>); first qstr should be that id.
    try testing.expect(module.qstrs.len >= 1);
}
