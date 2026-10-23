# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
s = {1, 2, 3, 4}
print(s.clear())
print(list(s))
