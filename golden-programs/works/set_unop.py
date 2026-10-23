# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# test set unary operations

print(bool(set()))
print(bool(set('abc')))

print(len(set()))
print(len(set('abc')))

try:
    hash(set('abc'))
except TypeError:
    print('TypeError')
