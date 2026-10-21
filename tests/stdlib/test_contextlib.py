"""Tests for nanopython-lib/contextlib.py via pytest_lite."""

import sys

sys.path.insert(0, "nanopython-lib")

import pytest
from contextlib import contextmanager, closing, suppress, nullcontext


# ── @contextmanager basics ──────────────────────────────────────────────


def test_contextmanager_setup_yield_teardown():
    events = []

    @contextmanager
    def cm():
        events.append("setup")
        yield "the value"
        events.append("teardown")

    with cm() as v:
        assert v == "the value"
        events.append("body")

    assert events == ["setup", "body", "teardown"]


def test_contextmanager_yields_none_by_default():
    @contextmanager
    def cm():
        yield  # bare yield → yields None

    with cm() as v:
        assert v is None


def test_contextmanager_args_forwarded_to_generator():
    @contextmanager
    def cm(x, y):
        yield x + y

    with cm(3, 4) as v:
        assert v == 7


def test_contextmanager_kwargs_forwarded():
    @contextmanager
    def cm(*, multiplier):
        yield multiplier * 10

    with cm(multiplier=5) as v:
        assert v == 50


# ── exception handling inside the cm ────────────────────────────────────


def test_contextmanager_teardown_runs_on_exception():
    events = []

    @contextmanager
    def cm():
        events.append("setup")
        try:
            yield
        finally:
            events.append("teardown")

    with pytest.raises(ValueError):
        with cm():
            events.append("body")
            raise ValueError("from body")

    assert events == ["setup", "body", "teardown"]


def test_contextmanager_can_swallow_exception():
    @contextmanager
    def silencer():
        try:
            yield
        except ValueError:
            pass  # swallow it

    # No exception propagates because silencer caught it.
    with silencer():
        raise ValueError("intentional")

    # Reaching here means the cm suppressed the exception.
    assert True


def test_contextmanager_no_yield_is_runtime_error():
    @contextmanager
    def bad():
        if False:
            yield
        return  # never yields

    with pytest.raises(RuntimeError):
        with bad():
            pass


# ── closing() ───────────────────────────────────────────────────────────


def test_closing_calls_close_on_normal_exit():
    class T:
        def __init__(self):
            self.closed = False

        def close(self):
            self.closed = True

    t = T()
    with closing(t) as ct:
        assert ct is t
        assert not t.closed
    assert t.closed


def test_closing_calls_close_on_exception_exit():
    class T:
        def __init__(self):
            self.closed = False

        def close(self):
            self.closed = True

    t = T()
    with pytest.raises(ValueError):
        with closing(t):
            raise ValueError("from body")
    assert t.closed


# ── suppress() ──────────────────────────────────────────────────────────


def test_suppress_swallows_specified_type():
    with suppress(ValueError):
        raise ValueError("intentional")
    # Reaching here means it was suppressed.
    assert True


def test_suppress_propagates_other_types():
    with pytest.raises(TypeError):
        with suppress(ValueError):
            raise TypeError("not in the list")


def test_suppress_passes_through_with_no_exception():
    x = 0
    with suppress(ValueError):
        x = 42
    assert x == 42


def test_suppress_multiple_types():
    with suppress(ValueError, TypeError):
        raise ValueError("caught")
    with suppress(ValueError, TypeError):
        raise TypeError("also caught")


def test_suppress_subclass_caught():
    class Special(ValueError):
        pass

    with suppress(ValueError):
        raise Special("subclass")


# ── nullcontext ─────────────────────────────────────────────────────────


def test_nullcontext_does_nothing():
    with nullcontext() as v:
        assert v is None


def test_nullcontext_carries_value():
    with nullcontext(42) as v:
        assert v == 42


def test_nullcontext_propagates_exception():
    with pytest.raises(ValueError):
        with nullcontext():
            raise ValueError("not caught")


# ── A realistic combined pattern ────────────────────────────────────────


def test_pattern_lockable_or_not():
    """Common idiom: use a real cm when locking is needed, else nullcontext."""

    @contextmanager
    def lock():
        # Just a stand-in for actual locking.
        yield "held"

    for cm in (lock(), nullcontext()):
        with cm:
            x = 1 + 1
            assert x == 2


if __name__ == "__main__":
    pytest.run_self_tests(globals())
