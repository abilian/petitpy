# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# test builtin oct function

print(oct(1))
print(oct(-1))
print(oct(15))
print(oct(-15))

print(oct(12345))
print(oct(0o12345))
