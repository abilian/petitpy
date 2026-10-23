# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
print(list(map(lambda x: x & 1, range(-3, 4))))
print(list(map(abs, range(-3, 4))))
print(list(map(tuple, [[i] for i in range(-3, 4)])))
print(list(map(pow, range(4), range(4))))
