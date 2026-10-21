# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
# closures

def f(x):
    y = 2 * x
    def g(z):
        return y + z
    return g

print(f(1)(1))

x = f(2)
y = f(3)
print(x(1), x(2), x(3))
print(y(1), y(2), y(3))
print(x(1), x(2), x(3))
print(y(1), y(2), y(3))
