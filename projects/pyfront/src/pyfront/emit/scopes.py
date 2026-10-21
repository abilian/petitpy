"""Per-scope compiler state: the loop stack and the scope context."""

from __future__ import annotations

from dataclasses import dataclass, field

from .code import Code
from .mpy import RawCode


@dataclass
class Loop:
    """Where `break` and `continue` go, and what they must unwind."""

    continue_to: int | None = None  # back-edge target, patched later
    continue_sites: list[int] = field(default_factory=list)
    break_sites: list[int] = field(default_factory=list)
    #: A `for` keeps a 4-slot iterator buffer on the stack that `break` must pop.
    unwind_iter: bool = False


@dataclass
class Ctx:
    is_function: bool
    slots: dict[str, int]
    code: Code
    children: list[RawCode]
    loops: list[Loop] = field(default_factory=list)
    exc_depth: int = 0
    max_exc_depth: int = 0
    #: Locals of this scope that a nested scope closes over. The prelude lists
    #: their slot numbers, and the runtime boxes them into cells on entry.
    cells: set[str] = field(default_factory=set)
    #: Names this scope closes over, in the order the parent pushes them. They
    #: occupy the first local slots, because closure_call prepends them to args.
    free: tuple[str, ...] = ()
