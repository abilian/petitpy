# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
s = {1, 2}
print(s.discard(1))
print(list(s))
