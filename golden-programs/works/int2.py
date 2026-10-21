# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
# test basic int operations

# test conversion of bool on RHS of binary op
a = False
print(1 + a)
a = True
print(1 + a)
