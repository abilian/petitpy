# golden: source=prescrypt-micropython; needs=
# golden: works-on=micropython
# golden: micropython-cpython-divergence=true
# parser tests

try:
    compile
except NameError:
    print("SKIP")
    raise SystemExit

# completely empty string
# MPy and CPy differ for this case
#try:
#    compile("", "stdin", "single")
#except SyntaxError:
#    print("SyntaxError")
try:
    compile("", "stdin", "eval")
except SyntaxError:
    print("SyntaxError")
compile("", "stdin", "exec")

# empty continued line
try:
    compile("\\\n", "stdin", "single")
except SyntaxError:
    print("SyntaxError")
try:
    compile("\\\n", "stdin", "eval")
except SyntaxError:
    print("SyntaxError")
compile("\\\n", "stdin", "exec")
