# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
try:
    1 // 0
except ZeroDivisionError:
    print("ZeroDivisionError")

try:
    1 % 0
except ZeroDivisionError:
    print("ZeroDivisionError")
