# Closures, free variables, nonlocal.

def make_counter(start=0):
    count = start
    def incr(by=1):
        nonlocal count
        count += by
        return count
    def get():
        return count
    return incr, get


bump, peek = make_counter()
bump()
bump()
bump(5)
print("count is", peek())   # 7


# Closure over a loop variable is the captured cell, not a snapshot.
funcs = []
for i in range(3):
    def f(): return i      # captures `i`, not its current value
    funcs.append(f)
print([f() for f in funcs]) # → [2, 2, 2] (Python semantics)

# Snapshot via default arg:
funcs2 = []
for i in range(3):
    def f(i=i): return i   # default arg evaluated at def time
    funcs2.append(f)
print([f() for f in funcs2]) # → [0, 1, 2]
