# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
print(1 < 2 < 3)
print(1 < 2 < 3 < 4)
print(1 > 2 < 3)
print(1 < 2 > 3)
