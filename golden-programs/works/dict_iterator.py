# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
d = {1: 2, 3: 4}
els = []
for i in d:
    els.append((i, d[i]))
print(sorted(els))
