# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
try:
    filter
except:
    print("SKIP")
    raise SystemExit

print(list(filter(lambda x: x & 1, range(-3, 4))))
print(list(filter(None, range(-3, 4))))
