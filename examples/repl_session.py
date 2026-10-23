# A piped REPL session — feed this on stdin to ./petitpy (no args)
# to demonstrate multi-line input.
#
#   ./zig-out/bin/petitpy < examples/repl_session.py
#
# This file is itself runnable as a script too:
#   ./zig-out/bin/petitpy examples/repl_session.py

def greet(name):
    return f"Hello, {name}!"

class Box:
    def __init__(self, x): self.x = x
    def __repr__(self): return f"Box({self.x})"

# REPL would echo each bare-expression. As a script, no echo:
print(greet("world"))
print(Box(42))

# Multi-line for/list-comp.
nums = [
    1, 2, 3,
    4, 5, 6,
]
print([n * n for n in nums])
