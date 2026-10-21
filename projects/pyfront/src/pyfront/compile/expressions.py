"""One method per expression production, plus assignment targets."""

from __future__ import annotations

import ast

from astero.python.lang import PY, SCOPES, VARS, mangle
from astero.scopes import Block, scope_tree

from ..emit import bytecode as bc
from ..errors import Unsupported


class ExpressionsMixin:
    # ── expressions ────────────────────────────────────────────────────
    def _Constant(self, node: ast.Constant) -> None:
        code = self._ctx.code
        value = node.value
        match value:
            case None:
                code.op(bc.LOAD_CONST_NONE)
            case True:
                code.op(bc.LOAD_CONST_TRUE)
            case False:
                code.op(bc.LOAD_CONST_FALSE)
            case int():
                code.op(bc.LOAD_CONST_SMALL_INT, bc.sint(value))
            case str():
                code.op(bc.LOAD_CONST_STRING, bc.uint(self.qstrs.intern(value)))
            case _:
                code.op(bc.LOAD_CONST_OBJ, bc.uint(self.objs.intern(value)))
        code.push()

    def _Name(self, node: ast.Name) -> None:
        if not isinstance(node.ctx, ast.Load):
            raise Unsupported(f"Name in {type(node.ctx).__name__} context")
        self._load(node.id)

    def _BinOp(self, node: ast.BinOp) -> None:
        op = type(node.op).__name__
        if op not in bc.BINARY_OPS:
            raise Unsupported(f"binary operator {op}")
        self._expr(node.left)
        self._expr(node.right)
        code = self._ctx.code
        code.op(bc.BINARY_OP_MULTI + bc.BINARY_OPS[op])
        code.pop()

    def _UnaryOp(self, node: ast.UnaryOp) -> None:
        op = type(node.op).__name__
        if op not in bc.UNARY_OPS:
            raise Unsupported(f"unary operator {op}")
        self._expr(node.operand)
        self._ctx.code.op(bc.UNARY_OP_MULTI + bc.UNARY_OPS[op])

    def _Compare(self, node: ast.Compare) -> None:
        for op in node.ops:
            if type(op).__name__ not in bc.BINARY_OPS:
                raise Unsupported(f"comparison {type(op).__name__}")
        code = self._ctx.code
        self._expr(node.left)
        self._expr(node.comparators[0])
        code.op(bc.BINARY_OP_MULTI + bc.BINARY_OPS[type(node.ops[0]).__name__])
        code.pop()
        if len(node.ops) == 1:
            return
        # a < b < c: short-circuit, keeping the middle operand for the next test.
        sites = []
        for op, right in zip(node.ops[1:], node.comparators[1:]):
            sites.append(code.ujump(bc.JUMP_IF_FALSE_OR_POP))
            code.pop()
            self._expr(node.comparators[node.comparators.index(right) - 1])
            self._expr(right)
            code.op(bc.BINARY_OP_MULTI + bc.BINARY_OPS[type(op).__name__])
            code.pop()
        for site in sites:
            code.upatch(site)

    def _Call(self, node: ast.Call) -> None:
        """CALL_FUNCTION, or CALL_FUNCTION_VAR_KW when the call unpacks.

        The operand packs both counts as (n_keyword << 8) | n_positional. With
        unpacking there is one extra small-int on the stack, a bitmap marking
        which positional slots are starred; `**kw` sets bit `i` for its keyword
        slot the same way (compile.c compile_trailer_paren_helper).
        """
        code = self._ctx.code
        # Zero-argument super() desugars to super(__class__, self) in the
        # vendor compiler (compile.c "handle special super() call"). That needs
        # the class body to bind __class__ as a cell the methods close over,
        # which pyfront's class body does not do: its body compiles as a plain
        # function whose locals become the namespace. Emitting the rewrite
        # without the cell produces a NameError at run time, so refuse instead.
        if (
            isinstance(node.func, ast.Name)
            and node.func.id == "super"
            and not node.args
            and not node.keywords
        ):
            raise Unsupported("zero-argument super(); use super(Class, self)")
        star_args = 0
        has_star = False
        n_pos = 0
        self._expr(node.func)
        for arg in node.args:
            if isinstance(arg, ast.Starred):
                star_args |= 1 << n_pos
                has_star = True
                self._expr(arg.value)
            else:
                self._expr(arg)
            n_pos += 1
        n_kw = 0
        for kw in node.keywords:
            if kw.arg is None:
                # **mapping is stored as a keyword whose key is NULL, and it
                # sets no bitmap bit — only the flag that selects the opcode
                # (compile.c PN_arglist_dbl_star).
                has_star = True
                code.op(bc.LOAD_NULL)
                code.push()
                self._expr(kw.value)
            else:
                code.op(bc.LOAD_CONST_STRING, bc.uint(self.qstrs.intern(kw.arg)))
                code.push()
                self._expr(kw.value)
            n_kw += 1
        if has_star:
            code.op(bc.LOAD_CONST_SMALL_INT, bc.sint(star_args))
            code.push()
            code.op(bc.CALL_FUNCTION_VAR_KW, bc.uint((n_kw << 8) | n_pos))
            code.pop(n_pos + 2 * n_kw + 1)
        else:
            code.op(bc.CALL_FUNCTION, bc.uint((n_kw << 8) | n_pos))
            code.pop(n_pos + 2 * n_kw)

    def _Tuple(self, node: ast.Tuple) -> None:
        if not isinstance(node.ctx, ast.Load):
            raise Unsupported(f"Tuple in {type(node.ctx).__name__} context")
        for item in node.elts:
            self._expr(item)
        code = self._ctx.code
        code.op(bc.BUILD_TUPLE, bc.uint(len(node.elts)))
        code.pop(len(node.elts))
        code.push()

    def _List(self, node: ast.List) -> None:
        if not isinstance(node.ctx, ast.Load):
            raise Unsupported(f"List in {type(node.ctx).__name__} context")
        for item in node.elts:
            self._expr(item)
        code = self._ctx.code
        code.op(bc.BUILD_LIST, bc.uint(len(node.elts)))
        code.pop(len(node.elts))
        code.push()

    # ── assignment targets ─────────────────────────────────────────────
    def _target(self, node: ast.expr) -> None:
        """Store TOS into `node`. Value is already on the stack."""
        code = self._ctx.code
        match node:
            case ast.Name():
                self._store(node.id)
            case ast.Attribute():
                self._expr(node.value)
                code.op(bc.STORE_ATTR, bc.uint(self.qstrs.intern(node.attr)))
                code.pop(2)
            case ast.Subscript():
                self._expr(node.value)
                self._expr(node.slice)
                code.op(bc.STORE_SUBSCR)
                code.pop(3)
            case ast.Tuple() | ast.List():
                starred = [i for i, e in enumerate(node.elts) if isinstance(e, ast.Starred)]
                if starred:
                    raise Unsupported("starred target in unpacking")
                code.op(bc.UNPACK_SEQUENCE, bc.uint(len(node.elts)))
                code.pop()
                code.push(len(node.elts))
                for elt in node.elts:
                    self._target(elt)
            case _:
                raise Unsupported(f"assignment target {type(node).__name__}")

    def _delete(self, node: ast.expr) -> None:
        is_function, slots, code = (
            self._ctx.is_function,
            self._ctx.slots,
            self._ctx.code,
        )
        match node:
            case ast.Name():
                if is_function and node.id in slots:
                    code.op(bc.DELETE_FAST, bc.uint(slots[node.id]))
                elif is_function:
                    code.op(bc.DELETE_GLOBAL, bc.uint(self.qstrs.intern(node.id)))
                else:
                    code.op(bc.DELETE_NAME, bc.uint(self.qstrs.intern(node.id)))
            case ast.Attribute():
                # vendor emitbc.c mp_emit_bc_attr: LOAD_NULL, ROT_TWO, STORE_ATTR.
                self._expr(node.value)
                code.op(bc.LOAD_NULL)
                code.push()
                code.op(bc.ROT_TWO)
                code.op(bc.STORE_ATTR, bc.uint(self.qstrs.intern(node.attr)))
                code.pop(2)
            case ast.Subscript():
                # vendor mp_emit_bc_subscr: LOAD_NULL, ROT_THREE, STORE_SUBSCR.
                self._expr(node.value)
                self._expr(node.slice)
                code.op(bc.LOAD_NULL)
                code.push()
                code.op(bc.ROT_THREE)
                code.op(bc.STORE_SUBSCR)
                code.pop(3)
            case _:
                raise Unsupported(f"del of {type(node).__name__}")

    def _Attribute(self, node: ast.Attribute) -> None:
        if not isinstance(node.ctx, ast.Load):
            raise Unsupported(f"Attribute in {type(node.ctx).__name__} context")
        self._expr(node.value)
        self._ctx.code.op(bc.LOAD_ATTR, bc.uint(self.qstrs.intern(node.attr)))

    def _Subscript(self, node: ast.Subscript) -> None:
        if not isinstance(node.ctx, ast.Load):
            raise Unsupported(f"Subscript in {type(node.ctx).__name__} context")
        self._expr(node.value)
        self._expr(node.slice)
        code = self._ctx.code
        code.op(bc.LOAD_SUBSCR)
        code.pop()

    def _Slice(self, node: ast.Slice) -> None:
        code = self._ctx.code
        for part in (node.lower, node.upper):
            if part is None:
                code.op(bc.LOAD_CONST_NONE)
                code.push()
            else:
                self._expr(part)
        n = 2
        if node.step is not None:
            self._expr(node.step)
            n = 3
        code.op(bc.BUILD_SLICE, bc.uint(n))
        code.pop(n)
        code.push()

    def _Dict(self, node: ast.Dict) -> None:
        if any(k is None for k in node.keys):
            raise Unsupported("** unpacking in a dict display")
        code = self._ctx.code
        code.op(bc.BUILD_MAP, bc.uint(len(node.keys)))
        code.push()
        for key, value in zip(node.keys, node.values):
            self._expr(value)
            self._expr(key)
            code.op(bc.STORE_MAP)
            code.pop(2)

    def _Set(self, node: ast.Set) -> None:
        for item in node.elts:
            self._expr(item)
        code = self._ctx.code
        code.op(bc.BUILD_SET, bc.uint(len(node.elts)))
        code.pop(len(node.elts))
        code.push()

    def _BoolOp(self, node: ast.BoolOp) -> None:
        code = self._ctx.code
        opcode = (
            bc.JUMP_IF_TRUE_OR_POP
            if isinstance(node.op, ast.Or)
            else bc.JUMP_IF_FALSE_OR_POP
        )
        sites = []
        for value in node.values[:-1]:
            self._expr(value)
            sites.append(code.ujump(opcode))
            code.pop()
        self._expr(node.values[-1])
        for site in sites:
            code.upatch(site)

    def _IfExp(self, node: ast.IfExp) -> None:
        code = self._ctx.code
        self._expr(node.test)
        code.pop()
        else_site = code.jump(bc.POP_JUMP_IF_FALSE)
        self._expr(node.body)
        end_site = code.jump(bc.JUMP)
        code.pop()
        code.patch(else_site)
        self._expr(node.orelse)
        code.patch(end_site)

    def _NamedExpr(self, node: ast.NamedExpr) -> None:
        code = self._ctx.code
        self._expr(node.value)
        code.op(bc.DUP_TOP)
        code.push()
        self._target(node.target)

    def _comprehension(self, node: ast.expr, kind: str) -> None:
        """[x for x in it], {..}, {k: v for ..}, and the generator form.

        Python makes each of these its own scope, and astero's scope tree says
        the same, so they compile as a nested function taking the outermost
        iterable as its single argument. That is also how CPython and vendor
        MicroPython do it, which is why the leaked-loop-variable behaviour
        matches without any special handling.
        """
        gens = node.generators
        gen = gens[0]
        if any(getattr(g, "is_async", 0) for g in gens):
            raise Unsupported("async comprehension")

        arg = ".0"  # CPython's name for the passed iterable
        match kind:
            case "list":
                init: list[ast.stmt] = [
                    ast.Assign(
                        targets=[ast.Name(id=".r", ctx=ast.Store())],
                        value=ast.List(elts=[], ctx=ast.Load()),
                    )
                ]
                append = ast.Expr(
                    value=ast.Call(
                        func=ast.Attribute(
                            value=ast.Name(id=".r", ctx=ast.Load()),
                            attr="append",
                            ctx=ast.Load(),
                        ),
                        args=[node.elt],
                        keywords=[],
                    )
                )
            case "set":
                init = [
                    ast.Assign(
                        targets=[ast.Name(id=".r", ctx=ast.Store())],
                        value=ast.Call(
                            func=ast.Name(id="set", ctx=ast.Load()), args=[], keywords=[]
                        ),
                    )
                ]
                append = ast.Expr(
                    value=ast.Call(
                        func=ast.Attribute(
                            value=ast.Name(id=".r", ctx=ast.Load()),
                            attr="add",
                            ctx=ast.Load(),
                        ),
                        args=[node.elt],
                        keywords=[],
                    )
                )
            case "dict":
                init = [
                    ast.Assign(
                        targets=[ast.Name(id=".r", ctx=ast.Store())],
                        value=ast.Dict(keys=[], values=[]),
                    )
                ]
                append = ast.Assign(
                    targets=[
                        ast.Subscript(
                            value=ast.Name(id=".r", ctx=ast.Load()),
                            slice=node.key,
                            ctx=ast.Store(),
                        )
                    ],
                    value=node.value,
                )
            case _:
                raise Unsupported(f"comprehension kind {kind}")

        body: ast.stmt = append
        # Inner `for` clauses nest inside the outer one, innermost first. Only
        # the outermost iterable is passed in as an argument, as CPython does.
        for extra in reversed(gens[1:]):
            for cond in reversed(extra.ifs):
                body = ast.If(test=cond, body=[body], orelse=[])
            body = ast.For(
                target=extra.target, iter=extra.iter, body=[body], orelse=[]
            )
        for cond in reversed(gen.ifs):
            body = ast.If(test=cond, body=[body], orelse=[])
        loop = ast.For(
            target=gen.target,
            iter=ast.Name(id=arg, ctx=ast.Load()),
            body=[body],
            orelse=[],
        )
        stmts = [*init, loop, ast.Return(value=ast.Name(id=".r", ctx=ast.Load()))]
        synthetic = ast.Module(body=stmts, type_ignores=[])
        ast.fix_missing_locations(synthetic)

        # astero reports comprehensions as non-scopes on 3.12+, matching
        # CPython's inlining. MicroPython still compiles them as functions, so
        # resolve the synthetic body on its own rather than looking for a block
        # that correctly does not exist.
        resolved = scope_tree(synthetic, PY, SCOPES, VARS, mangle=mangle)
        block = Block(
            kind="function",
            name=f"<{kind}comp>",
            node=synthetic,
            bound=set(resolved.bound) | {".r", arg},
        )
        self._expr(gen.iter)
        self._emit_child(synthetic, block, f"<{kind}comp>", [arg], body=stmts)
        code = self._ctx.code
        code.op(bc.ROT_TWO)
        code.op(bc.CALL_FUNCTION, bc.uint(1))
        code.pop()

    def _ListComp(self, node: ast.ListComp) -> None:
        self._comprehension(node, "list")

    def _SetComp(self, node: ast.SetComp) -> None:
        self._comprehension(node, "set")

    def _DictComp(self, node: ast.DictComp) -> None:
        self._comprehension(node, "dict")

    def _GeneratorExp(self, node: ast.GeneratorExp) -> None:
        """Same desugaring as the other comprehensions, but the body yields, so
        _yields marks the synthetic scope as a generator."""
        gens = node.generators
        if len(gens) != 1:
            raise Unsupported("generator expression with more than one `for`")
        gen = gens[0]
        arg = ".0"
        body: ast.stmt = ast.Expr(value=ast.Yield(value=node.elt))
        for cond in reversed(gen.ifs):
            body = ast.If(test=cond, body=[body], orelse=[])
        stmts = [
            ast.For(
                target=gen.target,
                iter=ast.Name(id=arg, ctx=ast.Load()),
                body=[body],
                orelse=[],
            )
        ]
        synthetic = ast.Module(body=stmts, type_ignores=[])
        ast.fix_missing_locations(synthetic)
        resolved = scope_tree(synthetic, PY, SCOPES, VARS, mangle=mangle)
        block = Block(
            kind="function",
            name="<genexpr>",
            node=synthetic,
            bound=set(resolved.bound) | {arg},
        )
        self._expr(gen.iter)
        self._emit_child(synthetic, block, "<genexpr>", [arg], body=stmts)
        code = self._ctx.code
        code.op(bc.ROT_TWO)
        code.op(bc.CALL_FUNCTION, bc.uint(1))
        code.pop()

    def _JoinedStr(self, node: ast.JoinedStr) -> None:
        """f-strings, built by concatenation.

        CPython's ast has already split the literal into parts, so there is no
        mini-language to parse here. Conversions (!r/!s/!a) and format specs are
        refused rather than approximated: `f"{x:>10}"` silently losing its
        padding would be worse than not compiling.
        """
        code = self._ctx.code
        parts = node.values or [ast.Constant(value="")]
        for i, part in enumerate(parts):
            if isinstance(part, ast.Constant):
                self._expr(part)
            else:
                self._FormattedValue(part)
            if i:
                code.op(bc.BINARY_OP_MULTI + bc.BINARY_OPS["Add"])
                code.pop()

    def _FormattedValue(self, node: ast.FormattedValue) -> None:
        if node.format_spec is not None:
            # "{:spec}".format(value). The runtime has str.format, so the spec
            # mini-language stays on its side instead of being reimplemented.
            parts = getattr(node.format_spec, "values", [])
            if not all(isinstance(x, ast.Constant) for x in parts):
                raise Unsupported("f-string format spec with a nested expression")
            spec = "".join(x.value for x in parts)
            self._expr(
                ast.Call(
                    func=ast.Attribute(
                        value=ast.Constant(value="{:" + spec + "}"),
                        attr="format",
                        ctx=ast.Load(),
                    ),
                    args=[node.value],
                    keywords=[],
                )
            )
            return
        if node.conversion not in (-1, ord("s")):
            raise Unsupported(f"f-string conversion !{chr(node.conversion)}")
        code = self._ctx.code
        self._load("str")
        self._expr(node.value)
        code.op(bc.CALL_FUNCTION, bc.uint(1))
        code.pop()

    def _Yield(self, node: ast.Yield) -> None:
        code = self._ctx.code
        if node.value is None:
            code.op(bc.LOAD_CONST_NONE)
            code.push()
        else:
            self._expr(node.value)
        code.op(bc.YIELD_VALUE)  # pops the value, pushes what was sent in

    def _YieldFrom(self, node: ast.YieldFrom) -> None:
        code = self._ctx.code
        self._expr(node.value)
        code.op(bc.GET_ITER)
        code.op(bc.LOAD_CONST_NONE)
        code.push()
        code.op(bc.YIELD_FROM)
        code.pop()

    def _Lambda(self, node: ast.Lambda) -> None:
        block = self._blocks.get(id(node))
        if block is None:
            raise Unsupported("lambda whose scope astero did not resolve")
        a = node.args
        if a.posonlyargs or a.kwonlyargs or a.vararg or a.kwarg or a.defaults:
            raise Unsupported("lambda signature beyond plain positional args")
        self._emit_child(
            node,
            block,
            "<lambda>",
            [arg.arg for arg in a.args],
            body=[ast.Return(value=node.body)],
        )
