# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# golden: micropython-cpython-divergence=true
# PEP-0498 specifies that '\\' and '#' must be disallowed explicitly, whereas
# MicroPython relies on the syntax error as a result of the substitution.

print(f"\\")
print(f"#")
try:
    eval("f'{\}'")
except SyntaxError:
    print("SyntaxError")
try:
    eval("f'{#}'")
except SyntaxError:
    print("SyntaxError")
