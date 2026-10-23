# golden: source=prescrypt-internal; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# golden: micropython-cpython-divergence=true
from __future__ import annotations


class A:
    def __init__(self):
        self.a = 1

    def f(self, x):
        return x * 2

    def mutate(self):
        self.a += 1

a = A()
print(a.a)
print(a.f(1))
a.mutate()
print(a.a)
