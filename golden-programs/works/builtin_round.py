# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
# test round() with integral values

tests = [
    False, True,
    0, 1, -1, 10
]
for t in tests:
    print(round(t))
