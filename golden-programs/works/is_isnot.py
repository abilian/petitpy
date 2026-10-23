# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
print([1, 2] is [1, 2])
a = [1, 2]
b = a
print(b is a)
