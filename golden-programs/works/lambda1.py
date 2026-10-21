# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
# lambda

f = lambda x, y: x + 3 * y
print(f(3, 5))
