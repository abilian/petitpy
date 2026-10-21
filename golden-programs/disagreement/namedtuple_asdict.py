# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython,nanopython-native,nanopython-wasm
# golden: micropython-cpython-divergence=true
try:
    from collections import namedtuple
except ImportError:
    print("SKIP")
    raise SystemExit

t = namedtuple("Tup", ["baz", "foo", "bar"])(3, 2, 5)

try:
    t._asdict
except AttributeError:
    print("SKIP")
    raise SystemExit

d = t._asdict()
print(list(d.keys()))
print(list(d.values()))
