# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# golden: micropython-cpython-divergence=true
# Coverage test for unicode escape in a bytes literal.
# CPython issues a SyntaxWarning for this.
print(b"\u1234")
