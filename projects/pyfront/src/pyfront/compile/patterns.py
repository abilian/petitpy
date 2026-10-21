"""`match`, desugared to if/elif.

No front-end in the ecosystem parses `match`: not vendor MicroPython, not
mpy-cross, not zigpy-compile. The desugaring here needs no opcode that is not
already in the VM, which is what makes it a measurement rather than a feature.
See notes/14-capability-matrix.md.
"""

from __future__ import annotations

import ast

from ..errors import Unsupported


def _always_true(node: ast.expr) -> bool:
    """Is this the literal `True` the pattern tests use to mean 'no test'?"""
    match node:
        case ast.Constant(value=True):
            return True
        case _:
            return False


class MatchMixin:
    #: Holds the subject while the chain tests it.
    _MATCH_TMP = ".m"

    @staticmethod
    def _star_bind(
        star: ast.MatchStar, subj: ast.expr, at: int, n_after: int
    ) -> list[ast.stmt]:
        """`*rest` binds the slice between the fixed head and tail.

        Always a list, even when the subject is a tuple — PEP 634 says the
        star target is a list, and `subj[1:]` on a tuple is not one.
        """
        if star.name is None:
            return []  # `*_` matches without binding
        upper = ast.Constant(value=-n_after) if n_after else ast.Constant(value=None)
        return [
            ast.Assign(
                targets=[ast.Name(id=star.name, ctx=ast.Store())],
                value=ast.Call(
                    func=ast.Name(id="list", ctx=ast.Load()),
                    args=[
                        ast.Subscript(
                            value=subj,
                            slice=ast.Slice(lower=ast.Constant(value=at), upper=upper),
                            ctx=ast.Load(),
                        )
                    ],
                    keywords=[],
                ),
            )
        ]

    def _pattern_test(
        self, pat: ast.pattern, subj: ast.expr
    ) -> tuple[ast.expr, list[ast.stmt]]:
        """Return (condition, bindings) for `pat` against `subj`."""
        true = ast.Constant(value=True)
        match pat:
            case ast.MatchValue(value=v):
                return ast.Compare(left=subj, ops=[ast.Eq()], comparators=[v]), []

            case ast.MatchSingleton(value=v):
                return ast.Compare(
                    left=subj, ops=[ast.Is()], comparators=[ast.Constant(value=v)]
                ), []

            case ast.MatchAs(name=name, pattern=inner_pat):
                binds: list[ast.stmt] = []
                if name:
                    binds.append(
                        ast.Assign(
                            targets=[ast.Name(id=name, ctx=ast.Store())], value=subj
                        )
                    )
                if inner_pat is None:
                    return true, binds  # `case x:` / `case _:` always match
                inner, inner_binds = self._pattern_test(inner_pat, subj)
                return inner, inner_binds + binds

            case ast.MatchOr(patterns=alts):
                tests, binds = [], []
                for alt in alts:
                    t, b = self._pattern_test(alt, subj)
                    tests.append(t)
                    binds.extend(b)
                return ast.BoolOp(op=ast.Or(), values=tests), binds

            case ast.MatchSequence(patterns=subpats):
                stars = [i for i, x in enumerate(subpats) if isinstance(x, ast.MatchStar)]
                if len(stars) > 1:
                    raise Unsupported("more than one star in a match sequence")
                star = stars[0] if stars else None
                # A star turns the length test from `==` into `>=`: the
                # fixed elements before and after it are the minimum.
                n_fixed = len(subpats) - (1 if star is not None else 0)
                conds: list[ast.expr] = [
                    ast.Call(
                        func=ast.Name(id="isinstance", ctx=ast.Load()),
                        args=[
                            subj,
                            ast.Tuple(
                                elts=[
                                    ast.Name(id="list", ctx=ast.Load()),
                                    ast.Name(id="tuple", ctx=ast.Load()),
                                ],
                                ctx=ast.Load(),
                            ),
                        ],
                        keywords=[],
                    ),
                    ast.Compare(
                        left=ast.Call(
                            func=ast.Name(id="len", ctx=ast.Load()),
                            args=[subj],
                            keywords=[],
                        ),
                        ops=[ast.GtE()] if star is not None else [ast.Eq()],
                        comparators=[ast.Constant(value=n_fixed)],
                    ),
                ]
                binds = []
                n_after = 0 if star is None else len(subpats) - star - 1
                for i, sub in enumerate(subpats):
                    if i == star:
                        binds.extend(self._star_bind(sub, subj, star, n_after))
                        continue
                    # Elements after the star are counted from the end, so
                    # their position does not depend on the subject length.
                    at = i if star is None or i < star else i - len(subpats)
                    item = ast.Subscript(
                        value=subj, slice=ast.Constant(value=at), ctx=ast.Load()
                    )
                    t, b = self._pattern_test(sub, item)
                    if not _always_true(t):
                        conds.append(t)
                    binds.extend(b)
                return ast.BoolOp(op=ast.And(), values=conds), binds

            case ast.MatchMapping(keys=keys, patterns=vals, rest=rest):
                if rest is not None:
                    raise Unsupported("** capture in a mapping pattern")
                # A mapping pattern is not a dict comparison: it matches when
                # the named keys are present, and ignores every other key.
                conds = [
                    ast.Call(
                        func=ast.Name(id="isinstance", ctx=ast.Load()),
                        args=[subj, ast.Name(id="dict", ctx=ast.Load())],
                        keywords=[],
                    )
                ]
                binds = []
                for key, sub in zip(keys, vals):
                    conds.append(
                        ast.Compare(left=key, ops=[ast.In()], comparators=[subj])
                    )
                    item = ast.Subscript(value=subj, slice=key, ctx=ast.Load())
                    t, b = self._pattern_test(sub, item)
                    if not _always_true(t):
                        conds.append(t)
                    binds.extend(b)
                return ast.BoolOp(op=ast.And(), values=conds), binds

            case ast.MatchClass(
                cls=cls, patterns=pos, kwd_attrs=attrs, kwd_patterns=kwd_pats
            ):
                if pos:
                    raise Unsupported("positional sub-patterns in a class pattern")
                conds = [
                    ast.Call(
                        func=ast.Name(id="isinstance", ctx=ast.Load()),
                        args=[subj, cls],
                        keywords=[],
                    )
                ]
                binds = []
                for attr, sub in zip(attrs, kwd_pats):
                    got = ast.Attribute(value=subj, attr=attr, ctx=ast.Load())
                    t, b = self._pattern_test(sub, got)
                    if not _always_true(t):
                        conds.append(t)
                    binds.extend(b)
                return (
                    conds[0]
                    if len(conds) == 1
                    else ast.BoolOp(op=ast.And(), values=conds)
                ), binds

            case _:
                raise Unsupported(f"match pattern {type(pat).__name__}")

    def _Match(self, node: ast.Match) -> None:
        subj = ast.Name(id=self._MATCH_TMP, ctx=ast.Load())
        stmts: list[ast.stmt] = [
            ast.Assign(
                targets=[ast.Name(id=self._MATCH_TMP, ctx=ast.Store())],
                value=node.subject,
            )
        ]
        chain: ast.If | None = None
        tail: ast.If | None = None
        for case in node.cases:
            test, binds = self._pattern_test(case.pattern, subj)
            if case.guard is not None:
                # `case n if n > 100` reads the capture in the guard, which is
                # evaluated as part of the test, so the binding has to happen
                # there too. A one-element list is always truthy, so it carries
                # the walrus assignments without changing the condition.
                values: list[ast.expr] = [test]
                if binds:
                    values.append(
                        ast.List(
                            elts=[
                                ast.NamedExpr(target=b.targets[0], value=b.value)
                                for b in binds
                                if isinstance(b, ast.Assign)
                            ],
                            ctx=ast.Load(),
                        )
                    )
                    binds = []
                values.append(case.guard)
                test = ast.BoolOp(op=ast.And(), values=values)
            branch = ast.If(test=test, body=[*binds, *case.body], orelse=[])
            if chain is None:
                chain = tail = branch
            else:
                tail.orelse = [branch]
                tail = branch
        if chain is not None:
            stmts.append(chain)
        module = ast.Module(body=stmts, type_ignores=[])
        ast.fix_missing_locations(module)
        # The temporary is a real local of the enclosing scope; it was included
        # when the scope's slots were computed because _match_temps saw it.
        for stmt in stmts:
            self._stmt(stmt)
