# Differences from CPython

petitpy runs most everyday Python unchanged, but it builds on MicroPython and is still alpha software. This page lists what behaves differently from CPython 3.12+, so you can tell a bug from a known limit.

There are two builds:

- **native** (`pip install petitpy`, `uvx petitpy`; the command is `petitpy` or `ppy`): the `full` profile, with arbitrary-precision integers, Unicode strings, files, `os`, `subprocess` and sockets;
- **browser** (`npm install petitpy`, the [playground](https://petitpy.lab.abilian.com/play/demos/playground/)): the `nano` profile, smaller, with direct DOM access through the `js` module.

## Language and built-in types

| Area | petitpy | CPython |
|---|---|---|
| dict order (browser) | Iteration follows hash order: `list({"b": 1, "a": 2})` is `['a', 'b']`. Affects printing, `json.dumps`, `**kwargs`. Native keeps insertion order. | Insertion order. |
| `str.upper()` / `lower()` | ASCII letters only; no `unicodedata`. | Full Unicode case mapping. |
| Integers (browser) | 64-bit: `2**100` raises `OverflowError`. Native has arbitrary precision. | Arbitrary precision. |
| Float literals (browser) | A literal with 17 significant digits can parse one ulp off. Native parses correctly rounded; `repr` is the shortest round-trip form on both. | Correctly rounded. |
| Complex numbers | `2j` does not compile. | Supported. |
| Keyword arguments to built-ins | Native takes them where CPython does, except `int(x, base=)`, `int.to_bytes` and `int.from_bytes`, which take positional arguments only and ignore `signed`. The browser build takes them only where MicroPython does (`sorted(key=)`, `print(sep=)`, …). | Taken by name wherever the signature allows. |
| `slice(a, b)` (browser) | The constructor is unavailable; slice syntax, including steps, works. Native has it. | Available. |
| Implicit exception chaining | `__context__` is always `None`; `raise ... from` works, with `__cause__` and a chained traceback. | Recorded and printed. |
| Annotations | A class's `__annotations__` is an `OrderedDict` of their source text, as under `from __future__ import annotations`; on native, `typing.get_type_hints()` evaluates them. Functions keep no annotations. The browser build cannot evaluate `list[str]` or `int \| None`. | Evaluated objects (or lazy, 3.14). |
| Enum classes (native) | Members are real (`.name`, `.value`, `Color(1)`, `Color.__members__`), but the class itself cannot be iterated, measured or subscripted: `for c in Color`, `len(Color)` and `Color["RED"]` fail. There are no metaclasses. | Supported. |
| Multiple inheritance (browser) | Bases are searched depth-first, as in MicroPython: in a diamond, the shared base's method can win over a sibling's override, and there is no `__mro__`. Native follows CPython's C3 order in lookup, `super()` and `__mro__`. | C3 order. |
| Exception text | MicroPython's: `ValueError('x',)` as repr, `KeyError: x` unquoted, `divide by zero`. | `ValueError('x')`, `KeyError: 'x'`, `division by zero`. |
| Tracebacks | File names and functions, no line numbers or source lines. | Line numbers and source. |

## Library and platform

| Area | petitpy | CPython |
|---|---|---|
| Standard library | A subset: `json`, `re`, `math`, `itertools`, `functools`, `collections`, `dataclasses`, `datetime`, `pathlib`, `typing`, `enum`, `random`, `string`, `struct`, … ([what runs](COMPATIBILITY.md)). No `asyncio` (coroutines run, there is no event loop), `csv`, `decimal`, `fractions`, `unicodedata`, `sqlite3`, `ssl`. | The full library. |
| Files (native) | A write is visible to a reread only after `close()` or `flush()`. | Same rule, but CPython closes a dropped file at once (reference counting). |
| Files and `os` (browser) | No `open()` or `os`; programs see the files the page passes in. | Full file system and `os` module. |
| Threads | `_thread` is a stub. | Available. |
| `subprocess` (native) | `run()`, `check_output()` and `call()` only, without `shell=True`; no `Popen`. A command that cannot be started gives return code 127. | `Popen`, and `FileNotFoundError` for a missing command. |
| Missing module (browser) | `import nope` raises `ImportError`; there is no `ModuleNotFoundError`. Native raises `ModuleNotFoundError` with CPython's message, but without its `name` attribute. | Raises `ModuleNotFoundError`. |

## Reporting a difference

Anything else that behaves differently from CPython is a bug or an unknown gap. Please report it with the smallest program that shows it.
