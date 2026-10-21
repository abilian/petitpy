# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
# golden: micropython-cpython-divergence=true
# MicroPython behaviour only: builtin modules are read-only
import sys
try:
    sys.x = 1
except AttributeError:
    print("AttributeError")
