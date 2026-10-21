# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
try:
    import array
except ImportError:
    print("SKIP")
    raise SystemExit

print(array.array('b', [1, 2]) in b'\x01\x02\x03')
# CPython gives False here
#print(b"\x01\x02\x03" == array.array("B", [1, 2, 3]))
