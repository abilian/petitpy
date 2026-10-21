# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
# converting user instance to buffer
class C:
    pass

c = C()
try:
    d = bytes(c)
except TypeError:
    print('TypeError')
