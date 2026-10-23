# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
def foo(x: int, y: list) -> dict:
    return {x: y}

print(foo(1, [2, 3]))
