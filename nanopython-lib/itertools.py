"""itertools — micropython-lib's itertools plus the CPython functions it lacks.

From micropython-lib (MIT): count, cycle, repeat, chain, islice, starmap,
accumulate. Added from the pure-Python equivalents in CPython's itertools
documentation: permutations, combinations, combinations_with_replacement,
product, groupby, zip_longest, takewhile, dropwhile, filterfalse, compress,
pairwise, chain.from_iterable. tee() is rewritten: the vendor version
returned the same iterator n times, so the copies consumed each other.
"""


def count(start=0, step=1):
    while True:
        yield start
        start += step


def cycle(p):
    try:
        len(p)
    except TypeError:
        # len() is not defined for this type. Assume it is
        # a finite iterable so we must cache the elements.
        cache = []
        for i in p:
            yield i
            cache.append(i)
        p = cache
    while p:
        yield from p


def repeat(el, n=None):
    if n is None:
        while True:
            yield el
    else:
        for i in range(n):
            yield el


def _chain(iterables):
    for it in iterables:
        yield from it


# A class, not a generator function, so it can carry from_iterable:
# functions take no attributes here.
class chain:
    def __init__(self, *iterables):
        self._it = _chain(iterables)

    def __iter__(self):
        return self

    def __next__(self):
        return next(self._it)

    @classmethod
    def from_iterable(cls, iterables):
        return _chain(iterables)


def islice(p, start, stop=(), step=1):
    if stop == ():
        stop = start
        start = 0
    # TODO: optimizing or breaking semantics?
    if start >= stop:
        return
    it = iter(p)
    for i in range(start):
        next(it)

    while True:
        yield next(it)
        for i in range(step - 1):
            next(it)
        start += step
        if start >= stop:
            return


def tee(iterable, n=2):
    it = iter(iterable)
    buffers = [[] for _ in range(n)]

    def gen(mine):
        while True:
            if not mine:
                try:
                    value = next(it)
                except StopIteration:
                    return
                for b in buffers:
                    b.append(value)
            yield mine.pop(0)

    return tuple(gen(b) for b in buffers)


def starmap(function, iterable):
    for args in iterable:
        yield function(*args)


def accumulate(iterable, func=lambda x, y: x + y):
    it = iter(iterable)
    try:
        acc = next(it)
    except StopIteration:
        return
    yield acc
    for element in it:
        acc = func(acc, element)
        yield acc


def permutations(iterable, r=None):
    pool = tuple(iterable)
    n = len(pool)
    r = n if r is None else r
    if r > n:
        return
    indices = list(range(n))
    cycles = list(range(n, n - r, -1))
    yield tuple(pool[i] for i in indices[:r])
    while n:
        for i in reversed(range(r)):
            cycles[i] -= 1
            if cycles[i] == 0:
                indices[i:] = indices[i + 1 :] + indices[i : i + 1]
                cycles[i] = n - i
            else:
                j = cycles[i]
                indices[i], indices[-j] = indices[-j], indices[i]
                yield tuple(pool[i] for i in indices[:r])
                break
        else:
            return


def combinations(iterable, r):
    pool = tuple(iterable)
    n = len(pool)
    if r > n:
        return
    indices = list(range(r))
    yield tuple(pool[i] for i in indices)
    while True:
        for i in reversed(range(r)):
            if indices[i] != i + n - r:
                break
        else:
            return
        indices[i] += 1
        for j in range(i + 1, r):
            indices[j] = indices[j - 1] + 1
        yield tuple(pool[i] for i in indices)


def combinations_with_replacement(iterable, r):
    pool = tuple(iterable)
    n = len(pool)
    if not n and r:
        return
    indices = [0] * r
    yield tuple(pool[i] for i in indices)
    while True:
        for i in reversed(range(r)):
            if indices[i] != n - 1:
                break
        else:
            return
        indices[i:] = [indices[i] + 1] * (r - i)
        yield tuple(pool[i] for i in indices)


def product(*iterables, repeat=1):
    pools = [tuple(pool) for pool in iterables] * repeat
    result = [[]]
    for pool in pools:
        result = [x + [y] for x in result for y in pool]
    for prod in result:
        yield tuple(prod)


def groupby(iterable, key=None):
    keyfunc = (lambda x: x) if key is None else key
    it = iter(iterable)
    exhausted = False
    try:
        value = next(it)
    except StopIteration:
        return
    curr_key = keyfunc(value)

    def _grouper(target):
        nonlocal value, curr_key, exhausted
        yield value
        for value in it:
            curr_key = keyfunc(value)
            if curr_key != target:
                return
            yield value
        exhausted = True

    while not exhausted:
        target = curr_key
        group = _grouper(target)
        yield target, group
        if curr_key == target:
            for _ in group:
                pass


def zip_longest(*iterables, fillvalue=None):
    iterators = [iter(it) for it in iterables]
    remaining = len(iterators)
    while remaining:
        values = []
        for i, it in enumerate(iterators):
            try:
                value = next(it)
            except StopIteration:
                remaining -= 1
                if not remaining:
                    return
                iterators[i] = repeat(fillvalue)
                value = fillvalue
            values.append(value)
        yield tuple(values)


def takewhile(predicate, iterable):
    for x in iterable:
        if not predicate(x):
            return
        yield x


def dropwhile(predicate, iterable):
    it = iter(iterable)
    for x in it:
        if not predicate(x):
            yield x
            break
    for x in it:
        yield x


def filterfalse(predicate, iterable):
    if predicate is None:
        predicate = bool
    for x in iterable:
        if not predicate(x):
            yield x


def compress(data, selectors):
    return (d for d, s in zip(data, selectors) if s)


def pairwise(iterable):
    it = iter(iterable)
    try:
        a = next(it)
    except StopIteration:
        return
    for b in it:
        yield a, b
        a = b
