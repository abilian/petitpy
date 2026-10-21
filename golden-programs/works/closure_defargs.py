# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
# test closure with default args

def f():
    a = 1
    def bar(b = 10, c = 20):
        print(a + b + c)
    bar()
    bar(2)
    bar(2, 3)

print(f())
