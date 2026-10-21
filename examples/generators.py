# Generator basics + .send() + .throw() + .close().

def counter(start=0):
    """Yield integers starting from `start`, accepting a new value via send()."""
    n = start
    while True:
        received = yield n
        n = received if received is not None else n + 1


g = counter()
print(next(g))      # 0
print(next(g))      # 1
print(g.send(100))  # we jumped to 100
print(next(g))      # 101
print(next(g))      # 102


# Iterator protocol — `for x in gen` calls next() under the hood.

def odd_squares(n):
    for i in range(n):
        if i % 2 == 1:
            yield i * i

print(list(odd_squares(8)))


# Custom iterator via class.

class Countdown:
    def __init__(self, n):
        self.n = n
    def __iter__(self):
        return self
    def __next__(self):
        if self.n <= 0:
            raise StopIteration
        self.n -= 1
        return self.n + 1

print(list(Countdown(5)))


# next() with a default — never raises StopIteration.
it = iter([1, 2, 3])
print(next(it, "done"), next(it, "done"), next(it, "done"), next(it, "done"))
