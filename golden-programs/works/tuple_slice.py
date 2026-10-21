# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
# tuple slicing

x = (1, 2, 3 * 4)

print(x[1:])
print(x[:-1])
print(x[2:3])
