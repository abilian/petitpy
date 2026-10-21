# Fannkuch-redux, small N. Tests list slicing + integer arithmetic.
# Source: https://benchmarksgame-team.pages.debian.net/benchmarksgame/
# Adapted to be a single self-contained script with a deterministic output.

N = 9


def fannkuch(n):
    count = list(range(1, n + 1))
    max_flips = 0
    m = n - 1
    r = n
    perm1 = list(range(n))
    perm = list(range(n))
    while True:
        while r != 1:
            count[r - 1] = r
            r -= 1
        if perm1[0] != 0 and perm1[m] != m:
            perm = perm1[:]
            flips_count = 0
            k = perm[0]
            while k:
                perm[: k + 1] = perm[k::-1]
                flips_count += 1
                k = perm[0]
            if flips_count > max_flips:
                max_flips = flips_count
        while r != n:
            perm1.insert(r, perm1.pop(0))
            count[r] -= 1
            if count[r] > 0:
                break
            r += 1
        else:
            return max_flips


print(fannkuch(N))
