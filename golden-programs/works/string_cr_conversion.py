# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
# this file has CR line endings to test lexer's conversion of them to LF
# in triple quoted strings
print(repr("""abc
def"""))
