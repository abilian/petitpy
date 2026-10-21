# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
a = []
for i in range(100):
    a.append(i)
    a.reverse()
print(a)
