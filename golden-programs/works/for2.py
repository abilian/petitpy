# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
i = 'init'
for i in range(0):
    pass
print(i) # should not have been modified

for i in range(10):
    pass
print(i) # should be last successful value of loop
