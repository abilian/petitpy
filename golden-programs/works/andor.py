# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# test short circuit expressions outside if conditionals
print(() or 1)
print((1,) or 1)
print(() and 1)
print((1,) and 1)
