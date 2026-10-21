"""nanopython — pure-Python random for the frozen-tiny set (ADR-003 §D).

Replaces the upstream micropython-lib `random.py` which depends on `urandom`
(a C-side module we don't include — costs a few KB for a Mersenne Twister
implementation we don't need for any in-scope use case).

Implements a Park-Miller LCG. The state is a 31-bit signed int, mathematically
correct since wasm32-nano switched to LONGLONG;
on 64-bit native the smallint is 62-bit so the same code runs untouched.

API matches CPython's `random` module for the functions algorithms textbooks
and demos actually use:

    random()            -> float in [0.0, 1.0)
    uniform(a, b)       -> float in [a, b]
    randrange(stop)     -> int in [0, stop)
    randrange(a, b)     -> int in [a, b)
    randint(a, b)       -> int in [a, b] inclusive
    choice(seq)         -> element from seq
    shuffle(seq)        -> in-place; returns None
    sample(pop, k)      -> list of k unique elements from pop
    seed(x=None)        -> reseed
    getrandbits(n)      -> int with n random bits

Notable omissions: `Random` class, `triangular`, `gauss`, normal/expo
distributions, `choices` weighted variant. Add if a use case appears.

NOT cryptographically secure. Don't use for keys, tokens, salts, anything
adversarial. Use the host's `crypto.getRandomValues` via the JS bridge for that.
"""

# Park-Miller "minstd" — see https://en.wikipedia.org/wiki/Lehmer_random_number_generator
_M = 2147483647  # 2**31 - 1 (Mersenne prime)
_A = 48271       # multiplier
_state = 1


def seed(x=None):
    """Seed the RNG. `None` → derive from Date.now() if the JS bridge is
    available, else a fixed default. An explicit int seeds directly."""
    global _state
    if x is None:
        try:
            import js
            x = int(js.get("Date").now()) & 0x7FFFFFFF
        except (ImportError, AttributeError):
            x = 1
    if x == 0:
        x = 1
    _state = x & 0x7FFFFFFF


def _next():
    global _state
    _state = (_state * _A) % _M
    return _state


def random():
    """Float in [0.0, 1.0)."""
    return _next() / _M


def uniform(a, b):
    """Float in [a, b]. Same semantics as CPython."""
    return a + (b - a) * random()


def getrandbits(n):
    """Int with n random bits."""
    if n <= 0:
        raise ValueError("number of bits must be positive")
    bits = 0
    have = 0
    while have < n:
        # Each _next() gives ~31 random bits.
        bits = (bits << 31) | _next()
        have += 31
    return bits >> (have - n)


def randrange(start, stop=None, step=1):
    """randrange(stop) -> int in [0, stop); randrange(a, b[, step])."""
    if stop is None:
        if start <= 0:
            raise ValueError("empty range for randrange()")
        return _next() % start
    if step == 1:
        width = stop - start
        if width <= 0:
            raise ValueError("empty range for randrange()")
        return start + (_next() % width)
    n = (stop - start + step - (1 if step > 0 else -1)) // step
    if n <= 0:
        raise ValueError("empty range for randrange()")
    return start + step * (_next() % n)


def randint(a, b):
    """Int in [a, b] inclusive."""
    return randrange(a, b + 1)


def choice(seq):
    """Random element of seq."""
    if not seq:
        raise IndexError("Cannot choose from an empty sequence")
    return seq[_next() % len(seq)]


def shuffle(seq):
    """Fisher-Yates in place. Returns None."""
    for i in range(len(seq) - 1, 0, -1):
        j = _next() % (i + 1)
        seq[i], seq[j] = seq[j], seq[i]


def sample(population, k):
    """k unique elements from population. Returns a list."""
    n = len(population)
    if k < 0 or k > n:
        raise ValueError("Sample larger than population or is negative")
    # For small k vs n, partial Fisher-Yates on a copy is fine.
    pool = list(population)
    for i in range(k):
        j = i + (_next() % (n - i))
        pool[i], pool[j] = pool[j], pool[i]
    return pool[:k]
