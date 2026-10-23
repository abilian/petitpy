# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
i = iter(iter({1, 2, 3}))
print(sorted(i))
