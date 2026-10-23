# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
try:
    bytearray.count
except AttributeError:
    print("SKIP")
    raise SystemExit

print(bytearray(b"aaaa").count(b"a"))
