# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
for d in {}, {42:2}:
    print(d.get(42))
    print(d.get(42,2))
