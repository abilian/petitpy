def fib(n, cache={}):
    if n in cache:
        return cache[n]
    if n < 2:
        return n
    cache[n] = fib(n - 1) + fib(n - 2)
    return cache[n]

for i in range(20):
    print(f"fib({i}) = {fib(i)}")
