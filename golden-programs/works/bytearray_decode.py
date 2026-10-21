# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
try:
    print(bytearray(b'').decode())
    print(bytearray(b'abc').decode())
except AttributeError:
    print("SKIP")
    raise SystemExit
