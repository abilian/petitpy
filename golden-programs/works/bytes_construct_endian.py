# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# test construction of bytes from different objects

try:
    from array import array
except ImportError:
    print("SKIP")
    raise SystemExit

# arrays
print(bytes(array('h', [1, 2])))
print(bytes(array('I', [1, 2])))
