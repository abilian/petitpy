# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# test builtin hash function, on generators

def gen():
    yield

print(type(hash(gen)))
print(type(hash(gen())))
