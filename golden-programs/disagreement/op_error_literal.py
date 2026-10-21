# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
# golden: micropython-cpython-divergence=true
# test errors from bad operations with literals
# these raise a SyntaxWarning in CPython; see https://bugs.python.org/issue15248

# unsupported subscription
try:
    1[0]
except TypeError:
    print("TypeError")
try:
    ""[""]
except TypeError:
    print("TypeError")

# not callable
try:
    1()
except TypeError:
    print("TypeError")
