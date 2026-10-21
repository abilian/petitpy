# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
def gen():
    print("sent:", (yield 1))
    yield 2

def gen2():
    print((yield from gen()))

g = gen2()
next(g)
print("yielded:", g.send("val"))
try:
    next(g)
except StopIteration:
    print("StopIteration")
