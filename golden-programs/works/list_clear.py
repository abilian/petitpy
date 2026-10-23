# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# tests list.clear
x = [1, 2, 3, 4]
x.clear()
print(x)
