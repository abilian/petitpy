"""Python `ast` to MicroPython bytecode.

The compiler proper: scope construction, the dispatch table, and name access.
Everything else is a mixin, because a production's code has nothing to say to
another production's and the single class was 992 lines:

    code.py         the bytecode buffer, stack accounting and jump patching
    scopes.py       per-scope state: the loop stack, the scope context
    analysis.py     questions answered before a scope's body is emitted
    statements.py   one method per statement production
    expressions.py  one method per expression production, plus targets
    patterns.py     `match`, desugared to if/elif

Dispatch is on node class name, so a production without a `_Name` method raises
`Unsupported` rather than emitting something wrong; tests/test_coverage.py uses
astero to fail when the AST grows a production that is neither handled nor
listed as out of scope.

Two simplifications worth naming, both bought with size rather than
correctness:

- Jumps always take the two-byte form. The one-byte form exists, but a
  variable-width offset means the emitter has to iterate to a fixpoint (the Zig
  front-end runs three passes for this). Fixed width needs one pass.
- Every qstr is written to the file's table, never referenced as a static id,
  so the writer needs no copy of the vendor static-qstr table.
"""

from __future__ import annotations

import ast

from astero.python.lang import PY, SCOPES, VARS, mangle
from astero.scopes import Block, scope_tree

from ..emit import bytecode as bc
from ..emit.code import Code
from ..emit.mpy import RawCode, Table, write
from ..emit.scopes import Ctx
from ..errors import Unsupported
from .analysis import Analysis
from .expressions import ExpressionsMixin
from .patterns import MatchMixin
from .statements import StatementsMixin

__all__ = ["Compiler", "Unsupported", "compile_source"]


class Compiler(Analysis, StatementsMixin, ExpressionsMixin, MatchMixin):
    def __init__(self) -> None:
        self.qstrs = Table()
        self.objs = Table()

    # ── entry point ────────────────────────────────────────────────────
    def compile(self, source: str, filename: str = "<string>") -> bytes:
        tree = ast.parse(source, filename)
        root = scope_tree(tree, PY, SCOPES, VARS, mangle=mangle)
        self._blocks = {id(b.node): b for b in root.walk()}
        self._enclosing_locals: set[str] = set()
        top = self._scope(tree, root, name="<module>", args=[])
        return write(
            [e for e in self.qstrs.entries],  # type: ignore[misc]
            list(self.objs.entries),
            top,
        )

    # ── one scope ──────────────────────────────────────────────────────
    def _scope(
        self,
        node: ast.AST,
        block: Block,
        name: str,
        args: list[str],
        body: list[ast.stmt] | None = None,
        sig_flags: int = 0,
        extra_slots: list[str] | None = None,
        n_def_pos: int = 0,
    ) -> RawCode:
        is_function = block.kind == "function"
        # Closed-over cells are prepended to the args by closure_call, so free
        # variables take the first slots and count toward n_pos_args.
        free = tuple(sorted(self._free_of(node, block))) if is_function else ()
        extra = {MatchMixin._MATCH_TMP} if self._has_match(node, body) else set()
        locals_ = (
            list(free)
            + list(args)
            + sorted((block.owns() | extra) - set(args) - set(free))
            if is_function
            else []
        )
        code = Code()
        prev = getattr(self, "_ctx", None)
        self._ctx = Ctx(is_function, {n: i for i, n in enumerate(locals_)}, code, [])
        self._ctx.free = free
        # Which of this scope's locals a nested scope captures. Computed here,
        # not as children are emitted: `t = 7` before `def inner(): return t`
        # must already know that `t` is a cell, or it stores over the cell
        # instead of into it.
        self._ctx.cells = set(locals_) & self._captured_by_children(node)
        outer_enclosing = self._enclosing_locals
        if is_function:
            self._enclosing_locals = outer_enclosing | set(locals_)
        stmts = body if body is not None else getattr(node, "body", [])
        for stmt in stmts:
            self._stmt(stmt)
        # Every code object falls off the end returning None.
        code.op(bc.LOAD_CONST_NONE)
        code.push()
        code.op(bc.RETURN_VALUE)
        # Read the finished scope's state before restoring the parent's.
        children = self._ctx.children
        n_state = len(locals_) + max(code.max_depth, 1)
        n_exc_stack = self._ctx.max_exc_depth
        slots = {n: i for i, n in enumerate(locals_)}
        cell_slots = sorted(slots[c] for c in self._ctx.cells)
        self._enclosing_locals = outer_enclosing
        self._ctx = prev

        flags = sig_flags
        if self._yields(node, body):
            flags |= bc.SCOPE_FLAG_GENERATOR
        prelude = bytearray(
            bc.prelude_sig(
                n_state, n_exc_stack, flags, len(free) + len(args), 0, n_def_pos
            )
        )
        info = bytearray(bc.uint(self.qstrs.intern(name)))
        for arg in args:
            info += bc.uint(self.qstrs.intern(arg))
        prelude += bc.prelude_size(len(info), len(cell_slots))
        closure = bytes(cell_slots)
        return RawCode(bytes(prelude + info + closure + code.buf), children)

    def _free_of(self, node: ast.AST, block: Block) -> set[str]:
        """Names `node` uses without binding, that an enclosing scope binds.

        astero's free_names is the safe approximation: it never reports a name
        that is not free. Intersecting with what the enclosing *function*
        scopes bind is what separates a closure variable from a global, since
        module-level names reach a nested function through LOAD_GLOBAL and
        need no cell.
        """
        return self._captures(node) & self._enclosing_locals

    # ── dispatch ───────────────────────────────────────────────────────
    def _stmt(self, node: ast.stmt) -> None:
        self._dispatch(node)

    def _expr(self, node: ast.expr) -> None:
        self._dispatch(node)

    def _dispatch(self, node: ast.AST) -> None:
        handler = getattr(self, f"_{type(node).__name__}", None)
        if handler is None:
            raise Unsupported(
                f"{type(node).__name__} at line {getattr(node, 'lineno', '?')}"
            )
        handler(node)

    def _emit_child(
        self,
        node: ast.AST,
        block: Block,
        name: str,
        args: list[str],
        body: list[ast.stmt] | None = None,
        defaults: list[ast.expr] | None = None,
        sig_flags: int = 0,
        extra_slots: list[str] | None = None,
    ) -> None:
        """Compile a nested scope, then push a function or a closure for it."""
        child_free = tuple(sorted(self._free_of(node, block)))
        defaults = defaults or []
        # The CHILD's prelude carries how many of its positional args are
        # optional (compile.c close_over_variables_etc sets num_def_pos_args);
        # without it the runtime rejects a short call as an arity mismatch.
        child = self._scope(node, block, name, args, body=body,
                            sig_flags=sig_flags, extra_slots=extra_slots,
                            n_def_pos=len(defaults))
        code, children = self._ctx.code, self._ctx.children
        index = len(children)
        children.append(child)
        if defaults:
            # MAKE_FUNCTION_DEFARGS takes the default tuple then an empty dict
            # for keyword defaults (emitbc.c mp_emit_bc_make_function).
            for d in defaults:
                self._expr(d)
            code.op(bc.BUILD_TUPLE, bc.uint(len(defaults)))
            code.pop(len(defaults))
            code.push()
            code.op(bc.BUILD_MAP, bc.uint(0))
            code.push()
        if not child_free:
            if defaults:
                code.op(bc.MAKE_FUNCTION_DEFARGS, bc.uint(index))
                code.pop()
            else:
                code.op(bc.MAKE_FUNCTION, bc.uint(index))
                code.push()
            return
        # The parent's own locals become cells; LOAD_FAST on a cell slot yields
        # the cell object, which is what MAKE_CLOSURE consumes.
        for cname in child_free:
            # LOAD_FAST, not LOAD_DEREF: MAKE_CLOSURE wants the cell object
            # itself, not the value inside it.
            code.op(bc.LOAD_FAST_N, bc.uint(self._ctx.slots[cname]))
            code.push()
        if defaults:
            code.op(bc.MAKE_CLOSURE_DEFARGS, bc.uint(index) + bytes([len(child_free)]))
            code.pop(len(child_free) + 1)
        else:
            code.op(bc.MAKE_CLOSURE, bc.uint(index) + bytes([len(child_free)]))
            code.pop(len(child_free))
            code.push()

    # ── name access ────────────────────────────────────────────────────
    def _load(self, name: str) -> None:
        is_function, slots, code = (
            self._ctx.is_function,
            self._ctx.slots,
            self._ctx.code,
        )
        if is_function and (name in self._ctx.free or name in self._ctx.cells):
            code.op(bc.LOAD_DEREF, bc.uint(slots[name]))
        elif is_function and name in slots:
            code.op(bc.LOAD_FAST_N, bc.uint(slots[name]))
        elif is_function:
            code.op(bc.LOAD_GLOBAL, bc.uint(self.qstrs.intern(name)))
        else:
            code.op(bc.LOAD_NAME, bc.uint(self.qstrs.intern(name)))
        code.push()

    def _store(self, name: str) -> None:
        is_function, slots, code = (
            self._ctx.is_function,
            self._ctx.slots,
            self._ctx.code,
        )
        if is_function and (name in self._ctx.free or name in self._ctx.cells):
            code.op(bc.STORE_DEREF, bc.uint(slots[name]))
        elif is_function and name in slots:
            code.op(bc.STORE_FAST_N, bc.uint(slots[name]))
        elif is_function:
            code.op(bc.STORE_GLOBAL, bc.uint(self.qstrs.intern(name)))
        else:
            code.op(bc.STORE_NAME, bc.uint(self.qstrs.intern(name)))
        code.pop()


def compile_source(source: str, filename: str = "<string>") -> bytes:
    return Compiler().compile(source, filename)
