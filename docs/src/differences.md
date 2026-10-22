# Differences from CPython

petitpy runs most everyday Python unchanged, but it builds on MicroPython and is still alpha software. This page lists what behaves differently from CPython 3.12+, so you can tell a bug from a known limit.

There are two builds:

- **native** (`pip install petitpy`, `uvx petitpy`; the command is `petitpy` or `ppy`): the `full` profile, with arbitrary-precision integers, Unicode strings, files, `os`, `subprocess` and sockets;
- **browser** (`npm install petitpy`, the [playground](https://petitpy.lab.abilian.com/play/demos/playground/)): the `nano` profile, smaller, with direct DOM access through the `js` module.

## Language and built-in types

| Area | petitpy | CPython |
|---|---|---|
| **dict order** | Iteration follows hash order: `list({"b": 1, "a": 2})` is `['a', 'b']`. Affects printing, `json.dumps`, `**kwargs`. Insertion order is planned after 0.8. | Insertion order. |
| `str.upper()` / `lower()` | ASCII letters only; no `unicodedata`. | Full Unicode case mapping. |
| Integers (browser) | 64-bit: `2**100` raises `OverflowError`. Native has arbitrary precision. | Arbitrary precision. |
| Float literals (browser) | A literal with 17 significant digits can parse one ulp off. Native parses correctly rounded; `repr` is the shortest round-trip form on both. | Correctly rounded. |
| Complex numbers | `2j` does not compile. | Supported. |
| `slice(a, b)` | The constructor is unavailable; slice syntax, including steps, works. | Available. |
| Implicit exception chaining | `__context__` is always `None`; `raise ... from` works, with `__cause__` and a chained traceback. | Recorded and printed. |
| Class `__annotations__` | An `OrderedDict` of the annotations' source text, as under `from __future__ import annotations`. | Evaluated objects (or lazy, 3.14). |
| `__mro__` | Not available on classes; multiple inheritance works. | Available. |
| Exception text | MicroPython's: `ValueError('x',)` as repr, `KeyError: x` unquoted, `divide by zero`. | `ValueError('x')`, `KeyError: 'x'`, `division by zero`. |
| Tracebacks | File names and functions, no line numbers or source lines. | Line numbers and source. |

## Library and platform

| Area | petitpy | CPython |
|---|---|---|
| Standard library | A subset: `json`, `re`, `math`, `itertools`, `functools`, `collections`, `dataclasses`, `datetime`, `pathlib`, `typing`, `enum`, `random`, `string`, `struct`, … ([what runs](COMPATIBILITY.md)). No `asyncio` (coroutines run, there is no event loop), `csv`, `decimal`, `fractions`, `unicodedata`, `sqlite3`, `ssl`. | The full library. |
| `sys.platform` | `"petitpy"`. | `"linux"`, `"darwin"`, … |
| `json.dumps` | Does not escape non-ASCII (`ensure_ascii` is not applied). | Escapes to `\u00e9` by default. |
| Files (native) | A write is visible to a reread only after `close()` or `flush()`. | Same rule, but CPython closes a dropped file at once (reference counting). |
| Files and `os` (browser) | No `open()` or `os`; programs see the files the page passes in. | Full file system and `os` module. |
| Threads | `_thread` is a stub. | Available. |
| Missing module | `import nope` and `import os.nope` raise `ImportError`; there is no `ModuleNotFoundError`. | Raises `ModuleNotFoundError`. |

## Reporting a difference

Anything else that behaves differently from CPython is a bug or an unknown gap. Please report it with the smallest program that shows it.
