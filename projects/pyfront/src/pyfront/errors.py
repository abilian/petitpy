"""The one exception pyfront raises on purpose."""

from __future__ import annotations


class Unsupported(Exception):
    """A production this front-end does not compile.

    Every raise site names the construct. A refusal is the contract: pyfront
    compiles a subset, and the alternative to saying so is bytecode that runs
    and computes the wrong answer.
    """
