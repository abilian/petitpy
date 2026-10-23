# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
a = [1, 2, 3]
a.insert(1, 42)
print(a)
a.insert(-1, -1)
print(a)
a.insert(99, 99)
print(a)
a.insert(-99, -99)
print(a)
