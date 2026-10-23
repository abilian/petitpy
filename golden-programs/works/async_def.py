# golden: source=prescrypt-micropython; needs=async
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# test async def

def dec(f):
    print('decorator')
    return f

# test definition with a decorator
@dec
async def foo():
    print('foo')

coro = foo()
try:
    coro.send(None)
except StopIteration:
    print('StopIteration')
