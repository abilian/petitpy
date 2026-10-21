# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
# test builtin exec with a buffer (bytearray/memoryview) input

try:
    exec
    bytearray
    memoryview
except:
    print("SKIP")
    raise SystemExit

exec(bytearray(b'print(1)'))
exec(memoryview(b'print(2)'))
