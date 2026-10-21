# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
s = {1, 2, 3, 4}
t = s.copy()
s.add(5)
t.add(7)
for i in s, t:
    print(sorted(i))
