# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# dict object with special methods

d = {}
d.__setitem__('2', 'two')
print(d.__getitem__('2'))
d.__delitem__('2')
print(d)
