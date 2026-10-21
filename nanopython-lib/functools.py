"""functools — subset of the CPython functools module for nanopython.

Supported:
    partial(fn, *args, **kw)        — partial function application
    wraps(orig)                     — no-op decorator (see note below)
    reduce(fn, iterable[, initial]) — left fold over an iterable
    lru_cache(maxsize=128)          — memoization with FIFO eviction

Not supported (vs CPython functools):
    - cached_property, total_ordering, singledispatch
    - cache (use lru_cache(None) for unbounded)
    - partialmethod
    - update_wrapper (replaced by no-op wraps)

Note on ``wraps``: CPython copies ``__name__``, ``__doc__``,
``__qualname__`` etc. from the wrapped function to the wrapper.
Nano doesn't allow function attribute assignment (the slots aren't
writable — see pytest_lite.py for the same limitation), so wraps
is a no-op here. User code that uses ``@wraps(orig)`` still parses
and runs; the metadata-copying step just doesn't happen.

See ADR 011 for the design rationale.
"""


def partial(fn, *bound_args, **bound_kwargs):
    """Return a callable that's ``fn`` with some positional and keyword
    arguments pre-bound. Additional args at call time get appended;
    additional kwargs override the bound ones."""

    def _bound(*extra_args, **extra_kwargs):
        kw = dict(bound_kwargs)
        kw.update(extra_kwargs)
        return fn(*bound_args, *extra_args, **kw)

    return _bound


def wraps(orig, *args, **kwargs):
    """No-op decorator on nano. See the module docstring for why.

    Accepts the optional ``assigned`` / ``updated`` arguments that
    CPython supports so call-sites stay portable; both are ignored.
    """

    def decorator(fn):
        return fn

    return decorator


def reduce(fn, iterable, *initial):
    """Apply ``fn`` cumulatively from the left over ``iterable``.

    With no ``initial`` argument, the first item of the iterable is
    used as the initial accumulator value; raises TypeError on an
    empty iterable. With ``initial``, that value seeds the fold and
    an empty iterable is fine.
    """
    it = iter(iterable)
    if initial:
        acc = initial[0]
    else:
        try:
            acc = next(it)
        except StopIteration:
            raise TypeError("reduce() of empty sequence with no initial value")
    for x in it:
        acc = fn(acc, x)
    return acc


def lru_cache(maxsize=128, typed=False):
    """Memoization decorator with size-limited FIFO eviction.

    Can be used as ``@lru_cache``, ``@lru_cache()``, or
    ``@lru_cache(maxsize=N)``. ``maxsize=None`` means unbounded;
    ``typed`` is accepted for CPython API compatibility but ignored
    (nano doesn't separate type-distinguished entries).

    Cache key is ``(args, sorted(kwargs.items()))``. Eviction is FIFO
    on insertion order (slightly looser than CPython's LRU semantics,
    but predictable and small enough to ship).
    """
    # `@lru_cache` form (no parens): first arg is the function.
    if callable(maxsize):
        fn = maxsize
        return _make_cached(fn, 128)

    # `@lru_cache(...)` form: returns a decorator.
    limit = maxsize if maxsize is not None else 0  # 0 = unbounded

    def decorator(fn):
        return _make_cached(fn, limit)

    return decorator


def _make_cached(fn, limit):
    """Build the wrapped function that does the actual memoization.
    Factored out so both `@lru_cache` and `@lru_cache(...)` forms
    end up using the same code."""
    cache = {}
    order = []  # insertion order for FIFO eviction

    def wrapper(*args, **kwargs):
        if kwargs:
            key = (args, tuple(sorted(kwargs.items())))
        else:
            key = args
        if key in cache:
            return cache[key]
        result = fn(*args, **kwargs)
        cache[key] = result
        order.append(key)
        if limit > 0 and len(order) > limit:
            oldest = order.pop(0)
            del cache[oldest]
        return result

    return wrapper
