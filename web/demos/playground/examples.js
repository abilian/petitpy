// Bundled example library — kept in JS (not fetched) so the demo works as
// a self-contained static drop on any host (no need to ship examples/*.py).
// Sources mirror the top-level examples/*.py — keep in sync by hand if they drift.

export const EXAMPLES = {
  fibonacci: `def fib(n, cache={}):
    if n in cache:
        return cache[n]
    if n < 2:
        return n
    cache[n] = fib(n - 1) + fib(n - 2)
    return cache[n]

for i in range(20):
    print(f"fib({i}) = {fib(i)}")
`,

  fizzbuzz: `for i in range(1, 21):
    if i % 15 == 0:
        print("FizzBuzz")
    elif i % 3 == 0:
        print("Fizz")
    elif i % 5 == 0:
        print("Buzz")
    else:
        print(i)
`,

  quicksort: `# Quicksort via slicing + recursion + comprehensions.

def quicksort(arr):
    if len(arr) <= 1:
        return arr
    pivot = arr[0]
    less    = [x for x in arr[1:] if x < pivot]
    equal   = [x for x in arr    if x == pivot]
    greater = [x for x in arr[1:] if x > pivot]
    return quicksort(less) + equal + quicksort(greater)


nums = [3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5, 8, 9, 7, 9]
print("input :", nums)
print("sorted:", quicksort(nums))

# Mixed strings.
words = ["pear", "apple", "banana", "cherry", "ant"]
print("words sorted:", quicksort(words))
`,

  closures: `# Closures, free variables, nonlocal.

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
    def f(): return i      # captures \`i\`, not its current value
    funcs.append(f)
print([f() for f in funcs]) # -> [2, 2, 2] (Python semantics)

# Snapshot via default arg:
funcs2 = []
for i in range(3):
    def f(i=i): return i   # default arg evaluated at def time
    funcs2.append(f)
print([f() for f in funcs2]) # -> [0, 1, 2]
`,

  generators: `# Generator basics + .send() + iterator protocol.

def counter(start=0):
    """Yield integers starting from \`start\`, accepting a new value via send()."""
    n = start
    while True:
        received = yield n
        n = received if received is not None else n + 1


g = counter()
print(next(g))      # 0
print(next(g))      # 1
print(g.send(100))  # we jumped to 100
print(next(g))      # 101
print(next(g))      # 102


def odd_squares(n):
    for i in range(n):
        if i % 2 == 1:
            yield i * i

print(list(odd_squares(8)))


class Countdown:
    def __init__(self, n):
        self.n = n
    def __iter__(self):
        return self
    def __next__(self):
        if self.n <= 0:
            raise StopIteration
        self.n -= 1
        return self.n + 1

print(list(Countdown(5)))
`,

  walrus: `# The walrus operator := (PEP 572).

# Single-assign + use in the same expression.
if (n := 10 * 5) > 25:
    print("big:", n)

# Avoid recomputing in a condition.
data = [1, 4, 7, 2, 9, 5]
if (m := max(data)) > 5:
    print("max is", m)

# Reading lines until a sentinel.
lines = iter(["hello", "world", "stop", "ignored"])
while (line := next(lines, None)) is not None and line != "stop":
    print("got:", line)
`,

  "echo (uses stdin)": `# Reads two lines from the stdin pane and echoes them.
# Try editing the stdin box above before clicking Run.

a = input()
b = input()
print("first :", a)
print("second:", b)
print("upper :", (a + " " + b).upper())
`,

  "JS interop (browser only)": `# Direct JS / DOM access from Python (ADR 006).
# 'import js' raises ImportError under native + wasmtime;
# js.is_browser() returns True only when the JS host bridge is live.

import js

if js.is_browser():
    js.console.log("hello from python in wasm!")
    # Use .set() for attribute writes: nano's port config disables
    # __setattr__ dispatch on user classes, so 'el.foo = x' is silently
    # a Python-side store and never pushes to JS.
    js.document.body.set("innerHTML", "<h1>Hello from Python</h1>")
    print("wrote heading via DOM. Look at the page!")
else:
    print("not in browser; js bridge not available")
`,
};

export const EXAMPLE_ORDER = [
  "fibonacci",
  "fizzbuzz",
  "quicksort",
  "closures",
  "generators",
  "walrus",
  "echo (uses stdin)",
  "JS interop (browser only)",
];
