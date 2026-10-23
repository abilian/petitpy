# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
try:
    bytearray.partition
except AttributeError:
    print("SKIP")
    raise SystemExit

print(bytearray(b"asdsf").partition(b"s"))
print(bytearray(b"asdsf").rpartition(b"s"))
