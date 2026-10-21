# Float arithmetic, math module, int↔float interop, format specs.

import math

print("pi:", math.pi)
print("e:", math.e)
print("sqrt(2):", math.sqrt(2))
print("log(e):", math.log(math.e))
print("sin(0):", math.sin(0))

print("0.1 + 0.2:", 0.1 + 0.2)
print("1/3:", 1/3)
print("10 // 3:", 10 // 3, "  10 % 3:", 10 % 3)
print("2.0 ** 10:", 2.0 ** 10)

# int↔float interop
print("3 * 0.5:", 3 * 0.5)
print("int(3.7):", int(3.7))
print("float(42):", float(42))

# format specs
print(f"{math.pi:.4f}")
print(f"{math.pi:e}")
print(f"{1234.5:,}")     # comma silently ignored on floats (matches upstream MicroPython)
print(f"{0.42:.2%}")
print(f"{-math.pi:+.3f}")
print(f"{math.pi:>12.3f}")
