# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
# basic exceptions
x = 1
try:
    x.a()
except:
    print(x)

try:
    raise IndexError
except IndexError:
    print("caught")
