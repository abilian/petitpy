# Dict insertion + lookup + iteration. Tests hash-table paths.

N = 20000


def run():
    d = {}
    for i in range(N):
        d[i] = i * 3
    # Lookup pass.
    s = 0
    for i in range(N):
        s += d[i]
    # Iterate values.
    t = 0
    for v in d.values():
        t += v
    return s + t


total = 0
for _ in range(50):
    total += run()
print(total)
