# golden: source=prescrypt-internal; needs=grammar.walrus
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# golden: micropython-cpython-divergence=true
"""Test walrus operator (:=) with pre-declared variables."""
from __future__ import annotations

# Walrus with pre-declared variable
x = 0
print((x := 10))
print(x)

# Walrus in if with pre-declared variable
y = 0
if (y := 5) > 3:
    print("y is", y)

# Walrus in expression
n = 0
result = (n := 7) * 2
print(result)
print(n)

# Multiple walrus (nested) with pre-declared
a = 0
b = 0
a = (b := 3) + 1
print(a, b)
