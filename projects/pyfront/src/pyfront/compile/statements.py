"""One method per statement production."""

from __future__ import annotations

import ast

from astero.scopes import Block

from ..emit import bytecode as bc
from ..emit.scopes import Loop
from ..errors import Unsupported


class StatementsMixin:
    # ── statements ─────────────────────────────────────────────────────
    def _Expr(self, node: ast.Expr) -> None:
        self._expr(node.value)
        code = self._ctx.code
        code.op(bc.POP_TOP)
        code.pop()

    def _Pass(self, node: ast.Pass) -> None:
        return

    def _Assign(self, node: ast.Assign) -> None:
        self._expr(node.value)
        code = self._ctx.code
        for extra in node.targets[:-1]:
            code.op(bc.DUP_TOP)
            code.push()
            self._target(extra)
        self._target(node.targets[-1])

    def _AnnAssign(self, node: ast.AnnAssign) -> None:
        """The annotation is discarded; the runtime has no __annotations__."""
        if node.value is None:
            return
        self._expr(node.value)
        self._target(node.target)

    def _Delete(self, node: ast.Delete) -> None:
        for target in node.targets:
            self._delete(target)

    def _AugAssign(self, node: ast.AugAssign) -> None:
        op = type(node.op).__name__
        if op not in bc.INPLACE_OPS:
            raise Unsupported(f"augmented operator {op}")
        code = self._ctx.code
        match node.target:
            case ast.Name(id=name):
                self._load(name)
                self._expr(node.value)
                code.op(bc.BINARY_OP_MULTI + bc.INPLACE_OPS[op])
                code.pop()
                self._store(name)

            # obj.attr op= v  /  obj[k] op= v: evaluate the object once.
            case ast.Attribute(value=obj, attr=attr):
                qstr = bc.uint(self.qstrs.intern(attr))
                self._expr(obj)
                code.op(bc.DUP_TOP)
                code.push()
                code.op(bc.LOAD_ATTR, qstr)
                self._expr(node.value)
                code.op(bc.BINARY_OP_MULTI + bc.INPLACE_OPS[op])
                code.pop()
                code.op(bc.ROT_TWO)
                code.op(bc.STORE_ATTR, qstr)
                code.pop(2)

            case ast.Subscript(value=obj, slice=key):
                self._expr(obj)
                self._expr(key)
                code.op(bc.DUP_TOP_TWO)
                code.push(2)
                code.op(bc.LOAD_SUBSCR)
                code.pop()
                self._expr(node.value)
                code.op(bc.BINARY_OP_MULTI + bc.INPLACE_OPS[op])
                code.pop()
                code.op(bc.ROT_THREE)
                code.op(bc.STORE_SUBSCR)
                code.pop(3)

            case _:
                raise Unsupported(
                    f"augmented assignment to {type(node.target).__name__}"
                )

    def _Return(self, node: ast.Return) -> None:
        code = self._ctx.code
        if node.value is None:
            code.op(bc.LOAD_CONST_NONE)
            code.push()
        else:
            self._expr(node.value)
        code.op(bc.RETURN_VALUE)
        code.pop()

    def _If(self, node: ast.If) -> None:
        code = self._ctx.code
        self._expr(node.test)
        code.pop()
        else_site = code.jump(bc.POP_JUMP_IF_FALSE)
        for stmt in node.body:
            self._stmt(stmt)
        if node.orelse:
            end_site = code.jump(bc.JUMP)
            code.patch(else_site)
            for stmt in node.orelse:
                self._stmt(stmt)
            code.patch(end_site)
        else:
            code.patch(else_site)

    def _While(self, node: ast.While) -> None:
        code = self._ctx.code
        loop = Loop()
        top = code.here()
        self._expr(node.test)
        code.pop()
        exit_site = code.jump(bc.POP_JUMP_IF_FALSE)
        self._ctx.loops.append(loop)
        for stmt in node.body:
            self._stmt(stmt)
        self._ctx.loops.pop()
        for site in loop.continue_sites:
            code.patch_to(site, top)
        code.patch_to(code.jump(bc.JUMP), top)
        code.patch(exit_site)
        for stmt in node.orelse:
            self._stmt(stmt)
        for site in loop.break_sites:
            code.patch(site)

    def _For(self, node: ast.For) -> None:
        code = self._ctx.code
        self._expr(node.iter)
        # GET_ITER_STACK replaces the iterable with a 4-slot iterator buffer.
        code.op(bc.GET_ITER_STACK)
        code.push(bc.ITER_BUF_NSLOTS - 1)
        top = code.here()
        exit_site = code.ujump(bc.FOR_ITER)  # forward-only, unsigned
        code.push()
        self._target(node.target)
        loop = Loop(unwind_iter=True)
        self._ctx.loops.append(loop)
        for stmt in node.body:
            self._stmt(stmt)
        self._ctx.loops.pop()
        for site in loop.continue_sites:
            code.patch_to(site, top)
        code.patch_to(code.jump(bc.JUMP), top)
        code.upatch(exit_site)
        # FOR_ITER pops the buffer itself when the iterator is exhausted.
        code.pop(bc.ITER_BUF_NSLOTS)
        for stmt in node.orelse:
            self._stmt(stmt)
        for site in loop.break_sites:
            code.patch(site)

    def _Break(self, node: ast.Break) -> None:
        if not self._ctx.loops:
            raise Unsupported("break outside a loop")
        loop = self._ctx.loops[-1]
        code = self._ctx.code
        if loop.unwind_iter:
            # UNWIND_JUMP's trailing byte: exception handlers to unwind, with
            # 0x80 asking the VM to drop the iterator buffer (vm.c). The
            # opcode PUSHes the destination ip and the unwind count before
            # consuming them, so n_state has to cover those two slots.
            code.push(2)
            code.pop(2)
            loop.break_sites.append(code.jump(bc.UNWIND_JUMP, trailer=b"\x80"))
        else:
            loop.break_sites.append(code.jump(bc.JUMP))

    def _Continue(self, node: ast.Continue) -> None:
        if not self._ctx.loops:
            raise Unsupported("continue outside a loop")
        self._ctx.loops[-1].continue_sites.append(self._ctx.code.jump(bc.JUMP))

    def _Try(self, node: ast.Try) -> None:
        """try/except/else/finally.

        Shape follows compile_try_except in vendor compile.c. Entering a
        handler the VM has the exception instance plus room for UNWIND_JUMP
        state, which emitbc.c accounts for as +4 on entry and -3 on exit; the
        same reservation is made here or n_state comes out too small.
        """
        if node.finalbody:
            # SETUP_FINALLY wraps whatever else the statement does; the body
            # runs, then the finally block, then END_FINALLY re-raises if the
            # body left an exception pending.
            code = self._ctx.code
            self._ctx.exc_depth += 1
            self._ctx.max_exc_depth = max(self._ctx.max_exc_depth, self._ctx.exc_depth)
            fin = code.ujump(bc.SETUP_FINALLY)
            inner = ast.Try(
                body=node.body,
                handlers=node.handlers,
                orelse=node.orelse,
                finalbody=[],
            )
            if node.handlers:
                self._Try(inner)
            else:
                for stmt in node.body:
                    self._stmt(stmt)
            code.op(bc.LOAD_CONST_NONE)
            code.push()
            code.upatch(fin)
            code.push(2)
            for stmt in node.finalbody:
                self._stmt(stmt)
            code.op(bc.END_FINALLY)
            code.pop(3)
            self._ctx.exc_depth -= 1
            return
        if not node.handlers:
            raise Unsupported("try without except")
        code = self._ctx.code
        self._ctx.exc_depth += 1
        self._ctx.max_exc_depth = max(self._ctx.max_exc_depth, self._ctx.exc_depth)

        setup = code.ujump(bc.SETUP_EXCEPT)
        for stmt in node.body:
            self._stmt(stmt)
        success = [code.ujump(bc.POP_EXCEPT_JUMP)]
        code.upatch(setup)

        code.push(4)  # exception instance + UNWIND_JUMP state
        for i, handler in enumerate(node.handlers):
            nxt = None
            if handler.type is not None:
                code.op(bc.DUP_TOP)
                code.push()
                self._expr(handler.type)
                code.op(bc.BINARY_OP_MULTI + bc.EXCEPTION_MATCH)
                code.pop()
                nxt = code.jump(bc.POP_JUMP_IF_FALSE)
                code.pop()
            elif i + 1 != len(node.handlers):
                raise Unsupported("bare except that is not the last handler")
            if handler.name:
                self._store(handler.name)
            else:
                code.op(bc.POP_TOP)
                code.pop()
            for stmt in handler.body:
                self._stmt(stmt)
            success.append(code.ujump(bc.POP_EXCEPT_JUMP))
            if nxt is not None:
                code.patch(nxt)
        code.op(bc.END_FINALLY)  # nothing matched: re-raise
        code.pop()
        code.pop(3)
        self._ctx.exc_depth -= 1
        for site in success:
            code.upatch(site)
        for stmt in node.orelse:
            self._stmt(stmt)

    def _ClassDef(self, node: ast.ClassDef) -> None:
        """LOAD_BUILD_CLASS, the class body as a function, its name, then bases.

        Follows compile_classdef_helper in vendor compile.c. The body runs in
        its own scope whose locals become the class namespace, so it compiles
        as a nested code object like any other.
        """
        if node.decorator_list:
            raise Unsupported("class decorators")
        if node.keywords:
            raise Unsupported("class keyword arguments (metaclass=)")
        code = self._ctx.code
        code.op(bc.LOAD_BUILD_CLASS)
        code.push()
        block = Block(
            kind="class",
            name=node.name,
            node=node,
            bound={
                t.id
                for st in node.body
                for t in getattr(st, "targets", [])
                if isinstance(t, ast.Name)
            }
            | {st.name for st in node.body if isinstance(st, ast.FunctionDef)},
        )
        child = self._scope(node, block, node.name, [])
        children = self._ctx.children
        index = len(children)
        children.append(child)
        code.op(bc.MAKE_FUNCTION, bc.uint(index))
        code.push()
        code.op(bc.LOAD_CONST_STRING, bc.uint(self.qstrs.intern(node.name)))
        code.push()
        for base in node.bases:
            self._expr(base)
        code.op(bc.CALL_FUNCTION, bc.uint(2 + len(node.bases)))
        code.pop(2 + len(node.bases))
        self._store(node.name)

    def _With(self, node: ast.With) -> None:
        """SETUP_WITH pops the manager and pushes __exit__, ctx, as-value."""
        if len(node.items) != 1:
            raise Unsupported("with statement with more than one item")
        item = node.items[0]
        code = self._ctx.code
        self._ctx.exc_depth += 1
        self._ctx.max_exc_depth = max(self._ctx.max_exc_depth, self._ctx.exc_depth)
        self._expr(item.context_expr)
        cleanup = code.ujump(bc.SETUP_WITH)
        code.push(2)  # __exit__ + ctx on top of the as-value
        if item.optional_vars is not None:
            self._target(item.optional_vars)
        else:
            code.op(bc.POP_TOP)
            code.pop()
        for stmt in node.body:
            self._stmt(stmt)
        code.op(bc.LOAD_CONST_NONE)  # normal-exit sentinel
        code.push()
        code.upatch(cleanup)
        code.push(2)  # room to call __exit__
        code.op(bc.WITH_CLEANUP)
        code.pop(4)
        code.op(bc.END_FINALLY)
        code.pop()
        self._ctx.exc_depth -= 1

    def _Nonlocal(self, node: ast.Nonlocal) -> None:
        """No code, like Global: astero excludes declared names from owns(), so
        the name resolves to the enclosing scope's cell through the free path."""

    def _Raise(self, node: ast.Raise) -> None:
        code = self._ctx.code
        if node.exc is None:
            code.op(bc.RAISE_LAST)
            return
        self._expr(node.exc)
        if node.cause is None:
            code.op(bc.RAISE_OBJ)
        else:
            self._expr(node.cause)
            code.op(bc.RAISE_FROM)
            code.pop()
        code.pop()

    def _Assert(self, node: ast.Assert) -> None:
        code = self._ctx.code
        self._expr(node.test)
        code.pop()
        ok = code.jump(bc.POP_JUMP_IF_TRUE)
        self._load("AssertionError")
        if node.msg is not None:
            self._expr(node.msg)
            code.op(bc.CALL_FUNCTION, bc.uint(1))
            code.pop()
        code.op(bc.RAISE_OBJ)
        code.pop()
        code.patch(ok)

    def _Global(self, node: ast.Global) -> None:
        """No code. astero's Block.owns() already excludes declared names, so
        the store path picks STORE_GLOBAL without any help here."""

    def _Import(self, node: ast.Import) -> None:
        code = self._ctx.code
        for alias in node.names:
            code.op(bc.LOAD_CONST_SMALL_INT, bc.sint(0))  # level
            code.push()
            code.op(bc.LOAD_CONST_NONE)  # fromlist
            code.push()
            code.op(bc.IMPORT_NAME, bc.uint(self.qstrs.intern(alias.name)))
            code.pop()
            if alias.asname:
                self._store(alias.asname)
            else:
                # `import a.b` binds the top package.
                self._store(alias.name.split(".")[0])

    def _ImportFrom(self, node: ast.ImportFrom) -> None:
        # `from __future__ import ...` is a compiler directive, not an
        # import: CPython's compiler consumes it and emits nothing. Every
        # feature it can name is already the default here, so the whole
        # statement is a no-op — matching what compile.zig does, so the
        # capability matrix does not read a front-end split.
        if node.level == 0 and node.module == "__future__":
            return
        code = self._ctx.code
        code.op(bc.LOAD_CONST_SMALL_INT, bc.sint(node.level or 0))
        code.push()
        star = len(node.names) == 1 and node.names[0].name == "*"
        if star:
            code.op(bc.LOAD_CONST_NONE)
            code.push()
        else:
            for alias in node.names:
                code.op(bc.LOAD_CONST_STRING, bc.uint(self.qstrs.intern(alias.name)))
                code.push()
            code.op(bc.BUILD_TUPLE, bc.uint(len(node.names)))
            code.pop(len(node.names))
            code.push()
        code.op(bc.IMPORT_NAME, bc.uint(self.qstrs.intern(node.module or "")))
        code.pop()
        if star:
            code.op(bc.IMPORT_STAR)
            code.pop()
            return
        for alias in node.names:
            code.op(bc.IMPORT_FROM, bc.uint(self.qstrs.intern(alias.name)))
            code.push()
            self._store(alias.asname or alias.name)
        code.op(bc.POP_TOP)
        code.pop()

    def _FunctionDef(self, node: ast.FunctionDef) -> None:
        a = node.args
        if a.posonlyargs or a.kwonlyargs or a.kw_defaults:
            raise Unsupported("positional-only or keyword-only parameters")
        block = self._blocks.get(id(node))
        if block is None:
            raise Unsupported("function whose scope astero did not resolve")
        # *args and **kwargs take slots after the named parameters and are
        # flagged in the prelude signature; they are not positional args, so
        # they stay out of n_pos_args and out of the prelude's name section.
        names = [arg.arg for arg in a.args]
        tail: list[str] = []
        flags = 0
        if a.vararg:
            tail.append(a.vararg.arg)
            flags |= bc.SCOPE_FLAG_VARARGS
        if a.kwarg:
            tail.append(a.kwarg.arg)
            flags |= bc.SCOPE_FLAG_VARKEYWORDS
        self._emit_child(
            node,
            block,
            node.name,
            names,
            defaults=list(a.defaults),
            sig_flags=flags,
            extra_slots=tail,
        )
        for dec in reversed(node.decorator_list):
            self._expr(dec)
            code = self._ctx.code
            code.op(bc.ROT_TWO)
            code.op(bc.CALL_FUNCTION, bc.uint(1))
            code.pop()
        self._store(node.name)
