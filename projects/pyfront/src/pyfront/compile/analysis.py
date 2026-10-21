"""Questions about a subtree that the emitter has to answer before it starts.

Whether a scope is a generator, whether it contains a `match`, and which names
it takes from an enclosing scope. All three have to be known before the body is
emitted: a captured local needs STORE_DEREF from its first assignment, which can
precede the nested `def` that captures it.
"""

from __future__ import annotations

import ast

from astero.python.hygiene import free_names
from astero.python.lang import PY, VARS


class Analysis:
    """Static helpers, mixed into Compiler."""

    @staticmethod
    def _yields(node: ast.AST, body: list[ast.stmt] | None = None) -> bool:
        """True when this scope's own code yields, so it is a generator.

        A yield inside a *nested* function belongs to that function, so the
        walk stops at anything that opens a scope.
        """

        def walk(n: ast.AST) -> bool:
            for child in ast.iter_child_nodes(n):
                match child:
                    case ast.Yield() | ast.YieldFrom():
                        return True
                    case (
                        ast.FunctionDef()
                        | ast.AsyncFunctionDef()
                        | ast.Lambda()
                        | ast.ClassDef()
                    ):
                        continue
                    case _:
                        if walk(child):
                            return True
            return False

        if body is not None:
            return any(
                walk(stmt)
                or isinstance(getattr(stmt, "value", None), (ast.Yield, ast.YieldFrom))
                for stmt in body
            )
        return walk(node)

    @staticmethod
    def _has_match(node: ast.AST, body: list[ast.stmt] | None = None) -> bool:
        nodes = body if body is not None else [node]
        return any(isinstance(sub, ast.Match) for n in nodes for sub in ast.walk(n))

    @staticmethod
    def _captures(node: ast.AST) -> set[str]:
        """Names `node` needs from an enclosing scope.

        `free_names` alone is not enough: it counts a name that is both bound
        and used as bound, which is exactly what `nonlocal n; n = n + 1` looks
        like. The nonlocal declarations have to be added back.
        """
        declared = {
            name
            for sub in ast.walk(node)
            if isinstance(sub, ast.Nonlocal)
            for name in sub.names
        }
        return free_names(node, PY, VARS) | declared

    @staticmethod
    def _captured_by_children(node: ast.AST) -> set[str]:
        """Names the scopes nested directly in `node` use without binding."""
        captured: set[str] = set()

        def walk(n: ast.AST, top: bool) -> None:
            for child in ast.iter_child_nodes(n):
                if isinstance(
                    child,
                    (
                        ast.FunctionDef,
                        ast.AsyncFunctionDef,
                        ast.Lambda,
                        # Comprehensions are scopes for MicroPython even though
                        # CPython 3.12+ inlines them, so a name they capture has
                        # to become a cell here too.
                        ast.ListComp,
                        ast.SetComp,
                        ast.DictComp,
                        ast.GeneratorExp,
                    ),
                ):
                    captured.update(Analysis._captures(child))
                else:
                    walk(child, False)

        walk(node, True)
        return captured
