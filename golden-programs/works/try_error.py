# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# test bad exception match

try:
    try:
        a
    except 1:
        pass
except TypeError:
    print("TypeError")

try:
    try:
        a
    except (1,):
        pass
except TypeError:
    print("TypeError")
