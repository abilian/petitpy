# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# test errors from bad function calls
try:
    enumerate
except:
    print("SKIP")
    raise SystemExit

# function with keyword args not given a specific keyword arg
try:
    enumerate()
except TypeError:
    print('TypeError')
