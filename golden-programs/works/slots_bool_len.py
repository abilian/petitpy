# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
class A:
    def __bool__(self):
        print('__bool__')
        return True
    def __len__(self):
        print('__len__')
        return 1

class B:
    def __len__(self):
        print('__len__')
        return 0

print(bool(A()))
print(len(A()))
print(bool(B()))
print(len(B()))
