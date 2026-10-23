# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# test builtin abs

print(abs(False))
print(abs(True))
print(abs(1))
print(abs(-1))
