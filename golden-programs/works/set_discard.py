# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
s = {1, 2}
print(s.discard(1))
print(list(s))
