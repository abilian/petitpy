# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# test continue within exception handler

def f():
    lst = [1, 2, 3]
    for x in lst:
        print('a', x)
        try:
            if x == 2:
                raise Exception
        except Exception:
            continue
        print('b', x)
f()
