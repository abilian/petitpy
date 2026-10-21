# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython
# test bignum unary operations

i = 1 << 65

print(bool(i))
print(+i)
print(-i)
print(~i)
