# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
# test str of function

def f():
    pass
print(str(f)[:8])
