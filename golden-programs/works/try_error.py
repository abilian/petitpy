# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
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
