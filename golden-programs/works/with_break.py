# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
class CtxMgr:

    def __enter__(self):
        print("__enter__")
        return self

    def __exit__(self, a, b, c):
        print("__exit__", repr(a), repr(b))

for i in range(5):
    print(i)
    with CtxMgr():
        if i == 3:
            break
