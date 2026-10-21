# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
# test bytes + other
try:
    import array
except ImportError:
    print("SKIP")
    raise SystemExit

print(b"123" + array.array('i', [1]))
