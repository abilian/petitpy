# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
# construct a bytes object from a generator
def gen():
    for i in range(4):
        yield i
print(bytes(gen()))
