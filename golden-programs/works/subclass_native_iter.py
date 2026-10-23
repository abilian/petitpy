# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# test subclassing a native type which can be iterated over

class mymap(map):
    pass

m = mymap(lambda x: x + 10, range(4))
print(list(m))
