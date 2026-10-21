# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
# Reraising last exception with raise w/o args

def f():
    try:
        raise ValueError("val", 3)
    except:
        raise

try:
    f()
except ValueError as e:
    print(repr(e))


# Can reraise only in except block
try:
    raise
except RuntimeError:
    print("RuntimeError")
