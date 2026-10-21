# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython
# Test class special methods, that use a bigint.

class A:
    def __int__(self):
        return 1 << 100


print(int(A()))
