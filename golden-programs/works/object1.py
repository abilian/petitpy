# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
# test builtin object()

# creation
object()

# printing
print(repr(object())[:7])
