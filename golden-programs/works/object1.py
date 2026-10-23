# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# test builtin object()

# creation
object()

# printing
print(repr(object())[:7])
