# golden: source=p2w-internal; needs=async
# golden: works-on=micropython,nanopython-native,nanopython-wasm
# golden: micropython-cpython-divergence=true
from __future__ import annotations


async def f(x):
    return x + 1
