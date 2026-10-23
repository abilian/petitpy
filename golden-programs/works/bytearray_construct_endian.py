# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# test construction of bytearray from different objects
try:
    from array import array
except ImportError:
    print("SKIP")
    raise SystemExit

# arrays
print(bytearray(array('h', [1, 2])))
print(bytearray(array('I', [1, 2])))
