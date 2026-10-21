# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
# test construction of bytes from bytearray

print(bytes(bytearray(4)))
