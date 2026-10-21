# golden: source=p2w-internal; needs=
# golden: works-on=micropython
# golden: micropython-cpython-divergence=true
from __future__ import annotations

s = "aAbB$#"
print(s.lower())
print(s.upper())
print(s.capitalize())
print(s.title())
print(s.swapcase())
