# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,petitpy-native,petitpy-wasm
# Test subclassing built-in str

class S(str):
    pass

s = S('hello')
print(s == 'hello')
print('hello' == s)
print(s == 'Hello')
print('Hello' == s)
