"""Tests for petitpy-lib/functools.py via pytest_lite."""

import sys

sys.path.insert(0, "petitpy-lib")

import pytest
from functools import partial, wraps, reduce, lru_cache


# ── partial ─────────────────────────────────────────────────────────────


def test_partial_binds_positional():
    add = lambda a, b: a + b
    add5 = partial(add, 5)
    assert add5(3) == 8
    assert add5(10) == 15


def test_partial_binds_keyword():
    def fn(a, b, c=0):
        return (a, b, c)

    p = partial(fn, c=100)
    assert p(1, 2) == (1, 2, 100)


def test_partial_kwarg_override_at_call_time():
    def fn(a, b=10):
        return (a, b)

    p = partial(fn, b=20)
    assert p(1) == (1, 20)
    assert p(1, b=99) == (1, 99)


def test_partial_mixed_positional_and_kwargs():
    def fn(a, b, *, c, d):
        return (a, b, c, d)

    p = partial(fn, 1, c=3)
    assert p(2, d=4) == (1, 2, 3, 4)


def test_partial_with_no_extra_args():
    p = partial(lambda: 42)
    assert p() == 42


def test_partial_callable_independently():
    # Multiple invocations of the same partial don't interfere.
    add5 = partial(lambda a, b: a + b, 5)
    assert add5(1) == 6
    assert add5(2) == 7
    assert add5(3) == 8


# ── wraps (no-op on nano) ───────────────────────────────────────────────


def test_wraps_does_not_crash():
    def original():
        return 1

    @wraps(original)
    def wrapper():
        return 2

    # The wrapper still works (wraps just doesn't copy metadata).
    assert wrapper() == 2


def test_wraps_accepts_extra_kwargs():
    # CPython's wraps takes `assigned=` and `updated=` kwargs.
    # Our no-op should accept them without error so user code
    # using the full CPython API stays portable.
    def original():
        return 1

    @wraps(original, assigned=("__name__",), updated=())
    def wrapper():
        return 2

    assert wrapper() == 2


# ── reduce ──────────────────────────────────────────────────────────────


def test_reduce_sum():
    assert reduce(lambda a, b: a + b, [1, 2, 3, 4]) == 10


def test_reduce_product():
    assert reduce(lambda a, b: a * b, [2, 3, 4]) == 24


def test_reduce_with_initial():
    assert reduce(lambda a, b: a + b, [1, 2, 3], 100) == 106


def test_reduce_single_element_no_initial():
    assert reduce(lambda a, b: a * b, [42]) == 42


def test_reduce_empty_with_initial():
    assert reduce(lambda a, b: a + b, [], 0) == 0


def test_reduce_empty_no_initial_raises():
    with pytest.raises(TypeError):
        reduce(lambda a, b: a + b, [])


def test_reduce_with_generator():
    def gen():
        for i in range(1, 5):
            yield i

    assert reduce(lambda a, b: a + b, gen()) == 10


# ── lru_cache ───────────────────────────────────────────────────────────


def test_lru_cache_caches_repeated_calls():
    calls = []

    @lru_cache
    def slow(x):
        calls.append(x)
        return x * 2

    assert slow(5) == 10
    assert slow(5) == 10  # cached
    assert slow(6) == 12
    assert calls == [5, 6]


def test_lru_cache_decorator_with_parens_no_args():
    calls = []

    @lru_cache()
    def f(x):
        calls.append(x)
        return x + 1

    f(1)
    f(1)
    f(2)
    assert calls == [1, 2]


def test_lru_cache_decorator_with_maxsize():
    calls = []

    @lru_cache(maxsize=2)
    def f(x):
        calls.append(x)
        return x + 100

    f(1)
    f(2)
    f(3)  # evicts 1 (FIFO)
    calls.clear()
    f(1)  # not in cache anymore, recomputed
    assert calls == [1]


def test_lru_cache_unbounded():
    calls = []

    @lru_cache(maxsize=None)
    def f(x):
        calls.append(x)
        return x

    for i in range(200):
        f(i)
    calls.clear()
    for i in range(200):
        f(i)
    assert calls == []  # all cached


def test_lru_cache_distinguishes_kwargs():
    @lru_cache
    def f(x, *, mult=1):
        return x * mult

    assert f(5) == 5
    assert f(5, mult=2) == 10
    assert f(5, mult=3) == 15


def test_lru_cache_kwargs_order_normalized():
    """Calling with the same kwargs in different order hits the same cache slot."""
    calls = []

    @lru_cache
    def f(*, a, b):
        calls.append((a, b))
        return a + b

    f(a=1, b=2)
    f(b=2, a=1)  # same cache key
    assert calls == [(1, 2)]


if __name__ == "__main__":
    pytest.run_self_tests(globals())
