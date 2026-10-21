# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
# test builtin "all" and "any"

tests = (
    (),
    [],
    [False],
    [True],
    [False, True],
    [True, False],
    [False, False],
    [True, True],
    range(10),
)

for test in tests:
    print(all(test))

for test in tests:
    print(any(test))
