# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
print(sorted({1,2}.symmetric_difference({2,3})))
print(sorted({1,2}.symmetric_difference([2,3])))
s = {1,2}
print(s.symmetric_difference_update({2,3}))
print(sorted(s))
