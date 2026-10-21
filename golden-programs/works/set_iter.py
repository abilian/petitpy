# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
s = {1, 2, 3, 4}
l = list(s)
l.sort()
print(l)
