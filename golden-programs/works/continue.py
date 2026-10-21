# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
for i in range(4):
    print('one', i)
    if i > 2:
        continue
    print('two', i)

for i in range(4):
    print('one', i)
    if i < 2:
        continue
    print('two', i)

for i in [1, 2, 3, 4]:
    if i == 3:
        continue
    print(i)
