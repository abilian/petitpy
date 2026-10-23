# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# test assignments

a = 1
print(a)

a = b = 2
print(a, b)

a = b = c = 3
print(a, b, c)
