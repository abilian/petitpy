# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
# test builtin abs

print(abs(False))
print(abs(True))
print(abs(1))
print(abs(-1))
