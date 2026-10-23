# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
try:
    print(bytearray(b'').decode())
    print(bytearray(b'abc').decode())
except AttributeError:
    print("SKIP")
    raise SystemExit
