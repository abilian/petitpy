# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
d = {}
print(d.setdefault(1))
print(d.setdefault(1))
print(d.setdefault(5, 42))
print(d.setdefault(5, 1))
print(d[1])
print(d[5])
d.pop(5)
print(d.setdefault(5, 1))
print(d[1])
print(d[5])
