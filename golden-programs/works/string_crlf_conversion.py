# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# this file has CRLF line endings to test lexer's conversion of them to LF
# in triple quoted strings
print(repr("""abc
def"""))
