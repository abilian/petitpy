# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# set object with special methods

s = {1, 2}
print(s.__contains__(1))
print(s.__contains__(3))
