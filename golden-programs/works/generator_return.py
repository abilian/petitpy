# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
def gen():
    yield 1
    return 42

g = gen()
print(next(g))
try:
    print(next(g))
except StopIteration as e:
    print(type(e), e.args)

# trying next again should raise StopIteration with no arguments
try:
    print(next(g))
except StopIteration as e:
    print(type(e), e.args)
