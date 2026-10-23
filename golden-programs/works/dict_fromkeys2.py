# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
try:
    reversed
except:
    print("SKIP")
    raise SystemExit

# argument to fromkeys has no __len__
d = dict.fromkeys(reversed(range(1)))
#d = dict.fromkeys((x for x in range(1)))
print(d)
