# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# test str of function

def f():
    pass
print(str(f)[:8])
