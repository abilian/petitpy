# f-string features.

name, age = "Alice", 30
print(f"Hello, {name}! You are {age} years old.")

# Expression evaluation
x = 7
print(f"x={x}, doubled={x*2}, squared={x**2}")

# Method calls
s = "hello"
print(f"upper: {s.upper()}, len: {len(s)}")

# Debug form: f'{var=}' expands to 'var=<repr>'
items = [1, 2, 3]
print(f"{items=}")
print(f"{len(items)=}")

# Format specs
import math
print(f"pi = {math.pi:.4f}")
print(f"{0.42:.1%}")

# Nested data
person = {"name": "Bob", "scores": [90, 85, 92]}
print(f"{person['name']}'s avg = {sum(person['scores'])/len(person['scores']):.1f}")
