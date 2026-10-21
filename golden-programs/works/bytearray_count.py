# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
try:
    bytearray.count
except AttributeError:
    print("SKIP")
    raise SystemExit

print(bytearray(b"aaaa").count(b"a"))
