# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
for i in 1, 2:
    for o in {}, {1}, {2}:
        print("{} in {}: {}".format(i, o, i in o))
        print("{} not in {}: {}".format(i, o, i not in o))
