// Example programs for the playground demo. Lifted (with minimal edits) from
// sandbox/prescrypt/demos/python-playground/src/playground.py — the original
// shipped these as a list of dicts in Python; here they're a JS object so the
// page can populate without running any Python at startup.

export const EXAMPLES = [
  {
    name: "hello",
    title: "Hello World",
    code: `# Hello World - Your First Program
print("Hello, World!")
print("Welcome to nanopython!")
print()
print("This Python runs in a WebAssembly sandbox")
print("compiled from the nanopython interpreter.")
`,
  },
  {
    name: "fibonacci",
    title: "Fibonacci",
    code: `# Fibonacci Sequence
def fibonacci(n):
    """Generate first n Fibonacci numbers."""
    fib = [0, 1]
    for i in range(2, n):
        fib.append(fib[i-1] + fib[i-2])
    return fib[:n]

result = fibonacci(15)
print("Fibonacci sequence (first 15 numbers):")
print(result)
print()
print("Sum:", sum(result))
`,
  },
  {
    name: "factorial",
    title: "Factorial",
    code: `# Factorial with Recursion
def factorial(n):
    """Calculate n! recursively."""
    if n <= 1:
        return 1
    return n * factorial(n - 1)

print("Factorials from 0 to 10:")
for i in range(11):
    print(str(i) + "! = " + str(factorial(i)))
`,
  },
  {
    name: "primes",
    title: "Prime Sieve",
    code: `# Sieve of Eratosthenes
def sieve(limit):
    """Find all primes up to limit."""
    is_prime = [True] * (limit + 1)
    is_prime[0] = False
    is_prime[1] = False

    i = 2
    while i * i <= limit:
        if is_prime[i]:
            j = i * i
            while j <= limit:
                is_prime[j] = False
                j += i
        i += 1

    result = []
    for i in range(limit + 1):
        if is_prime[i]:
            result.append(i)
    return result

primes = sieve(50)
print("Prime numbers up to 50:")
print(primes)
print()
print("Count:", len(primes))
`,
  },
  {
    name: "sorting",
    title: "Quicksort",
    code: `# Quicksort Algorithm
def quicksort(arr):
    """Classic quicksort implementation."""
    if len(arr) <= 1:
        return arr
    pivot = arr[len(arr) // 2]
    left = [x for x in arr if x < pivot]
    middle = [x for x in arr if x == pivot]
    right = [x for x in arr if x > pivot]
    return quicksort(left) + middle + quicksort(right)

numbers = [64, 34, 25, 12, 22, 11, 90, 42, 88, 7]
print("Original:", numbers)
print("Sorted:  ", quicksort(numbers))
`,
  },
  {
    name: "classes",
    title: "Classes",
    code: `# Classes and Inheritance
class Animal:
    def __init__(self, name, sound):
        self.name = name
        self.sound = sound

    def speak(self):
        return self.name + " says " + self.sound + "!"

class Dog(Animal):
    def __init__(self, name):
        super().__init__(name, "Woof")

    def fetch(self):
        return self.name + " fetches the ball!"

class Cat(Animal):
    def __init__(self, name):
        super().__init__(name, "Meow")

rex = Dog("Rex")
print(rex.speak())
print(rex.fetch())
print()

whiskers = Cat("Whiskers")
print(whiskers.speak())
`,
  },
  {
    name: "comprehensions",
    title: "Comprehensions",
    code: `# Python Comprehensions

# List comprehension
squares = [x * x for x in range(1, 11)]
print("Squares 1-10:", squares)

# Filtered comprehension
evens = [x for x in range(20) if x % 2 == 0]
print("Even numbers:", evens)

# Dict-like counts
word = "hello"
counts = {}
for c in word:
    counts[c] = word.count(c)
print("Letter counts in 'hello':", counts)
`,
  },
  {
    name: "fizzbuzz",
    title: "FizzBuzz",
    code: `# FizzBuzz - Classic Interview Problem
result = []
for i in range(1, 31):
    if i % 15 == 0:
        result.append("FizzBuzz")
    elif i % 3 == 0:
        result.append("Fizz")
    elif i % 5 == 0:
        result.append("Buzz")
    else:
        result.append(str(i))

print("FizzBuzz 1-30:")
print(result)
`,
  },
];
