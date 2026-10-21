# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython
print(bytearray(2**65 - (2**65 - 1)))
