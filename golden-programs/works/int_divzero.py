# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
try:
    1 // 0
except ZeroDivisionError:
    print("ZeroDivisionError")

try:
    1 % 0
except ZeroDivisionError:
    print("ZeroDivisionError")
