# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
# Test calling non-special method inherited from native type

class mylist(list):
    pass

l = mylist([1, 2, 3])
print(l)
l.append(10)
print(l)
