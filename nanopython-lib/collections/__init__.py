"""nanopython — collections module for the frozen-tiny set.

Re-exports OrderedDict / namedtuple from the C `ucollections` module
(always available under nano — MICROPY_PY_COLLECTIONS=1). Upstream
micropython-lib's collections/__init__.py does `from .defaultdict
import defaultdict` wrapped in try/except, but nanopython's __import__
raises NotImplementedError on relative imports which the try/except
doesn't catch — so we provide our own light-weight __init__ here.

Adds:
  - Counter and defaultdict (pure Python). Both use __getitem__ override
    rather than the __missing__ protocol — our dict subscr dispatches
    to subclass __getitem__ but not to subclass __missing__, so the
    override approach is what works.
  - deque (pure Python, list-backed). Vendor MP's ucollections.deque
    requires both (iterable, maxlen) and preallocates a fixed buffer
    — incompatible with the CPython `deque(iterable)` idiom that
    BFS / sliding-window / queue code uses everywhere. The list-backed
    variant is O(1) for append/pop and O(N) for appendleft/popleft.
    Matches MP's behavior on (iterable, maxlen) and CPython's on
    (iterable) — the corpus deque1 test runs both shapes and passes.
"""

from ucollections import OrderedDict, namedtuple  # noqa: F401


class Counter(dict):
    """A dict subclass for counting hashable objects.

    Subset of CPython's `collections.Counter`. Supports __init__,
    update, most_common, total, and `c[absent_key]` returning 0
    (via __getitem__ override).

    Arithmetic ops on Counters (+, -, &, |) are not implemented;
    add if a use case appears.
    """

    def __init__(self, iterable_or_mapping=None):
        super().__init__()
        if iterable_or_mapping is not None:
            self.update(iterable_or_mapping)

    def __getitem__(self, key):
        return self.get(key, 0)

    def update(self, iterable_or_mapping):
        # Distinguish mapping (has .items()) from iterable.
        items = getattr(iterable_or_mapping, "items", None)
        if items is not None:
            for k, v in items():
                self[k] = self.get(k, 0) + v
        else:
            for x in iterable_or_mapping:
                self[x] = self.get(x, 0) + 1

    def most_common(self, n=None):
        # Return list of (element, count) pairs, descending by count.
        pairs = sorted(self.items(), key=lambda kv: -kv[1])
        if n is None:
            return pairs
        return pairs[:n]

    def total(self):
        return sum(self.values())


class defaultdict(dict):
    """A dict subclass that calls a factory function for missing keys.

    Subset of CPython's `collections.defaultdict`. Uses __getitem__
    override (not __missing__) because our dict subscr only dispatches
    to subclass __getitem__.
    """

    def __init__(self, default_factory=None):
        super().__init__()
        self.default_factory = default_factory

    # Sentinel used to detect "absent" without recursing through self[key]
    # — get() doesn't dispatch to subclass __getitem__, so it's safe.
    _ABSENT = object()

    def __getitem__(self, key):
        v = self.get(key, defaultdict._ABSENT)
        if v is not defaultdict._ABSENT:
            return v
        if self.default_factory is None:
            raise KeyError(key)
        v = self.default_factory()
        self[key] = v
        return v


class deque(list):
    """A list-backed deque. Subset of CPython's `collections.deque`.

    Why this exists: vendor MP's `ucollections.deque` requires
    `(iterable, maxlen)` and preallocates a fixed-size ring. CPython's
    `deque(iterable)` is unbounded by default, which is the idiom
    BFS / sliding-window / queue code uses everywhere. This list-backed
    wrapper accepts both shapes.

    Performance: O(1) append/pop on the right, O(N) on the left.
    Acceptable for the algorithm-test programs we want to run; for
    a left-heavy hot path on a large deque, use `ucollections.deque`
    with an explicit maxlen.
    """

    def __init__(self, iterable=(), maxlen=None):
        if maxlen is not None and maxlen < 0:
            # CPython + MP's ucollections.deque both raise ValueError
            # for negative maxlen. The corpus deque1 test pins this.
            raise ValueError("maxlen must be non-negative")
        super().__init__(iterable)
        self.maxlen = maxlen
        if maxlen is not None and len(self) > maxlen:
            del self[: len(self) - maxlen]

    def append(self, x):
        super().append(x)
        if self.maxlen is not None and len(self) > self.maxlen:
            del self[0]

    def appendleft(self, x):
        self.insert(0, x)
        if self.maxlen is not None and len(self) > self.maxlen:
            del self[-1]

    def popleft(self):
        if not self:
            raise IndexError("pop from an empty deque")
        return super().pop(0)

    def extend(self, iterable):
        for x in iterable:
            self.append(x)

    def extendleft(self, iterable):
        for x in iterable:
            self.appendleft(x)

    def rotate(self, n=1):
        if not self:
            return
        n %= len(self)
        if n:
            tail = self[-n:]
            del self[-n:]
            for x in reversed(tail):
                self.insert(0, x)

    def clear(self):
        del self[:]


