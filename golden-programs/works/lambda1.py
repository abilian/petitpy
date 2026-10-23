# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# lambda

f = lambda x, y: x + 3 * y
print(f(3, 5))
