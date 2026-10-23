# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
gen = (i for i in range(10))
for i in gen:
    print(i)
