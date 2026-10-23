# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# golden: micropython-cpython-divergence=true
# add a bytearray to itself
# This is not supported by CPython as of 3.11.18.

b = bytearray(b"123456789")
for _ in range(4):
    c = bytearray(b)  # extra allocation increases chance 'b' has to relocate
    b += b
print(b)
