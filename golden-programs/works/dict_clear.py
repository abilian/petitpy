# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
d = {1: 2, 3: 4}
print(len(d))
d.clear()
print(d)
d[2] = 42
print(d)
