# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# test construction of bytes from bytearray

print(bytes(bytearray(4)))
