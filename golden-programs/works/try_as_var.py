# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
try:
    raise ValueError(534)
except ValueError as e:
    print(type(e), e.args)

# Var bound in except block is automatically deleted
try:
    e
except NameError:
    print("NameError")
