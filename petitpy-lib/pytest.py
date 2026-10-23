"""pytest — re-export shim for petitpy.

``import pytest`` works without ``pip install pytest`` because the
petitpy stdlib ships a pytest-lite runner. CPython users who try
to install pytest will find a small subset of the upstream API; the
docstring of ``pytest_lite`` lists what's covered and what isn't.

`pytest.fixture` and `pytest.mark` are shipped as SEMANTIC NO-OPS so
CPython test suites that decorate with `@pytest.fixture` or
`@pytest.mark.parametrize(...)` can at least IMPORT. A fixture used
as an actual pytest-managed dependency won't get its usual injection
behaviour — the decorator leaves the function unchanged so the runner
can still call it, but you have to pass args explicitly.
"""

from pytest_lite import (
    TestResult,
    main,
    raises,
    run_module,
    run_self_tests,
    skip,
    summarize,
)


def fixture(*args, **kwargs):
    """No-op stub. Accepts either `@fixture` (positional func) or
    `@fixture(scope='...')` (parameterised) forms. Returns the function
    unchanged so pytest_lite's runner can still call it, but no
    parameter injection / cleanup happens."""
    if len(args) == 1 and callable(args[0]) and not kwargs:
        return args[0]

    def _decorator(fn):
        return fn

    return _decorator


class _MarkChain:
    """Attribute proxy so `@pytest.mark.parametrize(...)`,
    `@pytest.mark.skipif(...)`, etc. all resolve to no-op decorators."""

    def __getattr__(self, name):
        return _MarkChain()

    def __call__(self, *args, **kwargs):
        # Called form: `@pytest.mark.skipif(condition, reason=...)` — the
        # decorated function passes through unchanged.
        if len(args) == 1 and callable(args[0]) and not kwargs:
            return args[0]

        def _decorator(fn):
            return fn

        return _decorator


mark = _MarkChain()


__all__ = (
    "TestResult",
    "fixture",
    "main",
    "mark",
    "raises",
    "run_module",
    "run_self_tests",
    "skip",
    "summarize",
)
