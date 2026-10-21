# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
# test that we can override a class method with an instance method

class A:
    def foo(self):
        return 1

a = A()
print(a.foo())
a.foo = lambda:2
print(a.foo())
