# The walrus operator := (PEP 572).

# Single-assign + use in the same expression.
if (n := 10 * 5) > 25:
    print("big:", n)

# Avoid recomputing in a condition.
data = [1, 4, 7, 2, 9, 5]
if (m := max(data)) > 5:
    print("max is", m)

# Reading lines until a sentinel.
lines = iter(["hello", "world", "stop", "ignored"])
while (line := next(lines, None)) is not None and line != "stop":
    print("got:", line)
