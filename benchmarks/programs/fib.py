# Recursive Fibonacci. Tests call/return + integer arithmetic.
# fib(28) on CPython 3.14 ~0.05s, much slower on MicroPython/nanopython.


def fib(n):
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)


print(fib(32))
