# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# test builtin eval with a buffer (bytearray/memoryview) input

try:
    eval
    bytearray
    memoryview
except:
    print("SKIP")
    raise SystemExit

print(eval(bytearray(b'1 + 1')))
print(eval(memoryview(b'2 + 2')))
