# String build + split + join. Tests qstr / interning paths.

N = 4000


def run():
    # Build a long string by append.
    parts = []
    for i in range(N):
        parts.append("word" + str(i))
    s = " ".join(parts)
    # Split it back.
    toks = s.split(" ")
    # Count tokens starting with "word1".
    c = 0
    for t in toks:
        if t.startswith("word1"):
            c += 1
    return c


total = 0
for _ in range(50):
    total += run()
print(total)
