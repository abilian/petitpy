# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# golden: micropython-cpython-divergence=true
# Test invalid escape characters.
# CPython issues a SyntaxWarning for this.

print("\z")
