# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# golden: micropython-cpython-divergence=true
# Test slice unary operations.
# CPython allows hashing slices, but MicroPython does not.

try:
    t = [][:]
except:
    print("SKIP")
    raise SystemExit


# REVISIT: slice comparison operators are not implemented in MicroPython

# test that slice is not hashable, i.e. it can't be used to copy a dict
try:
    {}[:] = {}
except TypeError:
    print('TypeError')
