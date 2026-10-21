# Sieve of Eratosthenes up to N. Tests list indexing + integer ops.

N = 200000


def sieve(n):
    flags = [True] * (n + 1)
    flags[0] = False
    flags[1] = False
    i = 2
    while i * i <= n:
        if flags[i]:
            j = i * i
            while j <= n:
                flags[j] = False
                j += i
        i += 1
    count = 0
    for k in range(n + 1):
        if flags[k]:
            count += 1
    return count


# Run multiple times so the workload is non-trivial.
total = 0
for _ in range(10):
    total += sieve(N)
print(total)
