# List comprehensions + sum + sort. Tests iterator + allocation paths.

N = 50000


def run():
    xs = [i * i for i in range(N)]
    ys = [x % 7 for x in xs]
    ys.sort()
    s = 0
    for y in ys:
        s += y
    return s


total = 0
for _ in range(20):
    total += run()
print(total)
