# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# test builtin hex function

print(hex(1))
print(hex(-1))
print(hex(15))
print(hex(-15))

print(hex(12345))
print(hex(0x12345))
