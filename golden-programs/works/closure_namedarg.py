# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# test passing named arg to closed-over function

def f():
    x = 1
    def g(z):
        print(x, z)
    return g

f()(z=42)
