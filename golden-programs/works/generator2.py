# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
gen = (i for i in range(10))
for i in gen:
    print(i)
