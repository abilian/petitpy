# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# test closure with lots of closed over variables

def f():
    a, b, c, d, e, f, g, h = [i for i in range(8)]
    def x():
        print(a, b, c, d, e, f, g, h)
    x()

f()
