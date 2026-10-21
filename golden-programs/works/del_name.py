# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
# del name

x = 1
print(x)
del x
try:
    print(x)
except NameError:
    print("NameError")
try:
    del x
except: # NameError:
    # FIXME MicroPython returns KeyError for this
    print("NameError")

class C:
    def f():
        pass
