"""The `ast` side: one method per production, dispatched by node class name.

Everything here works through `emit`; nothing writes bytes directly.
"""
from __future__ import annotations

from .driver import Compiler, compile_source

__all__ = ["Compiler", "compile_source"]
