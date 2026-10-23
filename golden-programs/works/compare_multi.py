# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
print(1 < 2 < 3)
print(1 < 2 < 3 < 4)
print(1 > 2 < 3)
print(1 < 2 > 3)
