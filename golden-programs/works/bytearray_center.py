# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
try:
    bytearray.center
except AttributeError:
    print("SKIP")
    raise SystemExit

print(bytearray(b"foo").center(6))
print(type(bytearray(b"foo").center(6)))
