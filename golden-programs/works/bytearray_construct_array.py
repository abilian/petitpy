# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# test construction of bytearray from different objects
try:
    from array import array
except ImportError:
    print("SKIP")
    raise SystemExit

# arrays
print(bytearray(array('b', [1, 2])))
print(bytearray(array('h', [0x101, 0x202])))
