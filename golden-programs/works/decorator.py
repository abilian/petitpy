# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
# test decorators

def dec(f):
    print('dec')
    return f

def dec_arg(x):
    print(x)
    return lambda f:f

# plain decorator
@dec
def f():
    pass

# decorator with arg
@dec_arg('dec_arg')
def g():
    pass

# decorator of class
@dec
class A:
    pass
