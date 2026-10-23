# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# test builtin bin function

print(bin(1))
print(bin(-1))
print(bin(15))
print(bin(-15))

print(bin(12345))
print(bin(0b10101))

print(bin(0b10101010101010101010))
