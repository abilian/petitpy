# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
for d in {}, {42:2}:
    print(d.get(42))
    print(d.get(42,2))
