# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
# golden: micropython-cpython-divergence=true
# Test invalid escape characters.
# CPython issues a SyntaxWarning for this.

print("\z")
