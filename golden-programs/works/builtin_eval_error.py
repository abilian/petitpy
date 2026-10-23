# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# test if eval raises SyntaxError

try:
    eval
except NameError:
    print("SKIP")
    raise SystemExit

try:
    print(eval("[1,,]"))
except SyntaxError:
    print("SyntaxError")
