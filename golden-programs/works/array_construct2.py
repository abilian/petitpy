# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
try:
    from array import array
except ImportError:
    print("SKIP")
    raise SystemExit

# construct from something with unknown length (requires generators)
print(array('i', (i for i in range(10))))
