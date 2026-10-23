# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
i = iter(iter((1, 2, 3)))
print(list(i))
i = iter(iter([1, 2, 3]))
print(list(i))
i = iter(iter({1:2, 3:4, 5:6}))
print(sorted(i))
# set, see set_iter_of_iter.py
