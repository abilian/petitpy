# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# list copy tests
a = [1, 2, []]
b = a.copy()
a[-1].append(1)
a.append(4)
print(a)
print(b)
