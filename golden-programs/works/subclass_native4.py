# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# Test calling non-special method inherited from native type

class mylist(list):
    pass

l = mylist([1, 2, 3])
print(l)
l.append(10)
print(l)
