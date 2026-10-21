# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython
# test builtin hex function

print(hex(12345678901234567890))
print(hex(0x12345678901234567890))
