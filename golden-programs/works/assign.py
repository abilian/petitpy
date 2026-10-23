# golden: source=p2w-internal; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# golden: micropython-cpython-divergence=true
from __future__ import annotations

a = 1
a = a + 1
a += 1
print(a)
