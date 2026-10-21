# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
s = {1, 2, 3, 4}
print(s.clear())
print(list(s))
