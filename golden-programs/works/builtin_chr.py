# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# test builtin chr (whether or not we support unicode)

print(chr(65))

try:
    chr(0x110000)
except ValueError:
    print("ValueError")
