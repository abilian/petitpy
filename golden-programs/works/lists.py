# golden: source=p2w-internal; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
# golden: micropython-cpython-divergence=true
from __future__ import annotations

print(list(range(10)))
print(list(range(0, 10, 2)))
print([1, 2, 3] + [4, 5, 6])
print([1, 2, 3] * 2)
