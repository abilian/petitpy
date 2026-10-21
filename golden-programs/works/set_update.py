# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
s = {1}
s.update()
print(s)
s.update([2])
print(sorted(s))
s.update([1,3], [2,2,4])
print(sorted(s))
