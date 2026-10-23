# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# test construction of array.array from different objects

try:
    from array import array
except ImportError:
    print("SKIP")
    raise SystemExit

# raw copy from bytes, bytearray
print(array('h', b'12'))
