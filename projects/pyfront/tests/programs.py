"""The shared construct corpus.

Two tiers assert different things about the same programs. The unit tier
compiles each and checks the container it produces is well formed — no VM,
no subprocess. The e2e tier runs them on petitpy-vm and compares against
CPython, which is the only way to say the bytecode is *right*.

One corpus, so a construct added for either tier is measured by both.
"""

from __future__ import annotations

PROGRAMS = {
    "constants": 'print(1, -1, 0, True, False, None, "s")\n',
    "arithmetic": "print(2 + 3 * 4 - 1, 17 // 5, 17 % 5, 2 ** 10)\n",
    "comparison": "print(1 < 2, 2 <= 2, 3 > 4, 3 != 4, 5 == 5)\n",
    "globals": "x = 10\ny = x * 2\nprint(x, y)\n",
    "if_elif_else": (
        "def c(n):\n"
        "    if n < 10:\n        return 'small'\n"
        "    elif n < 100:\n        return 'mid'\n"
        "    return 'big'\n"
        "print(c(1), c(50), c(500))\n"
    ),
    "while_loop": "i = 0\nt = 0\nwhile i < 5:\n    t += i\n    i += 1\nprint(t)\n",
    "function_locals": (
        "def f(a, b):\n    c = a + b\n    return c * 2\nprint(f(3, 4))\n"
    ),
    "global_from_function": "G = 7\ndef f():\n    return G + 1\nprint(f())\n",
    "nested_calls": "def d(n):\n    return n * 2\nprint(d(d(d(1))))\n",
    "fib": (
        "def fib(n):\n"
        "    a = 0\n    b = 1\n    i = 0\n"
        "    while i < n:\n        t = a + b\n        a = b\n        b = t\n        i += 1\n"
        "    return a\n"
        "print(fib(0), fib(1), fib(10), fib(25))\n"
    ),
    "unary": "print(-5, not True, not False)\n",
    "sequences": "print([1, 2, 3], (4, 5), [], ())\n",
    "attributes": 'class_free = "abc"\nprint(class_free.upper(), "A B".split(" "))\n',
    "subscript": "d = [10, 20, 30]\nprint(d[0], d[2], d[-1])\nd[1] = 99\nprint(d)\n",
    "slicing": "x = [1,2,3,4,5]\nprint(x[1:3], x[:2], x[3:], x[::2])\n",
    "dicts": 'm = {"a": 1, "b": 2}\nprint(m["a"], m["b"], len(m))\nm["c"] = 3\nprint(len(m))\n',
    "sets": "s = {1, 2, 3, 2}\nprint(len(s), 2 in s, 9 in s)\n",
    "boolop": "print(1 and 2, 0 or 3, None or 'x', 1 and 0 or 5)\n",
    "ifexp": "print(1 if True else 2, 1 if False else 2)\n",
    "chained": "print(1 < 2 < 3, 1 < 5 < 3, 3 > 2 > 1)\n",
    "unpack": "a, b = 1, 2\nprint(a, b)\nc, d, e = [3, 4, 5]\nprint(c, d, e)\n",
    "multi_assign": "x = y = 7\nprint(x, y)\n",
    "augassign_subscript": "L = [1, 2]\nL[0] += 10\nprint(L)\n",
    "del_stmt": "d = {'k': 1, 'j': 2}\ndel d['k']\nprint(list(d.keys()))\n",
    "walrus": "if (n := 5) > 3:\n    print('big', n)\n",
    "for_range": "t = 0\nfor i in range(5):\n    t += i\nprint(t)\n",
    "for_list": "for x in [1, 2, 3]:\n    print(x)\n",
    "for_break": "for i in range(10):\n    if i == 3:\n        break\n    print(i)\n",
    "for_continue": "for i in range(6):\n    if i % 2 == 0:\n        continue\n    print(i)\n",
    "while_break": "i = 0\nwhile True:\n    i += 1\n    if i > 3:\n        break\nprint(i)\n",
    "while_continue": "i = 0\nt = 0\nwhile i < 6:\n    i += 1\n    if i % 2:\n        continue\n    t += i\nprint(t)\n",
    "for_else": "for i in range(3):\n    pass\nelse:\n    print('done')\n",
    "nested_for": "for i in range(3):\n    for j in range(2):\n        print(i, j)\n",
    "for_break_nested": "for i in range(3):\n    for j in range(3):\n        if j == 1:\n            break\n        print(i, j)\n",
    "import_stmt": "import sys\nprint(type(sys.path) is list)\n",
    "import_from": "from sys import path\nprint(type(path) is list)\n",
    "import_as": "import sys as s\nprint(hasattr(s, 'path'))\n",
    "raise_caught_by_vm": "print('before')\n",
    "assert_passes": "assert 1 == 1\nassert True, 'never'\nprint('ok')\n",
    "lambda_simple": "f = lambda x: x * 2\nprint(f(21))\n",
    "lambda_two_args": "g = lambda a, b: a + b\nprint(g(3, 4))\n",
    "kwargs_call": "def f(a, b):\n    return a - b\nprint(f(b=1, a=10))\n",
    "global_stmt": "c = 0\ndef bump():\n    global c\n    c = c + 1\nbump()\nbump()\nprint(c)\n",
    "fstring": 'n = 42\ns = "x"\nprint(f"n={n} s={s}")\n',
    "fstring_expr": 'a = 3\nb = 4\nprint(f"{a} + {b} = {a + b}")\n',
    "fstring_empty_and_literal": 'print(f"", f"plain", f"{1}")\n',
    "try_no_raise": "try:\n    x = 1\nexcept Exception:\n    x = 2\nprint(x)\n",
    "try_catches": "try:\n    raise ValueError('boom')\nexcept ValueError:\n    print('caught')\n",
    "try_binds_name": "try:\n    raise ValueError('msg')\nexcept ValueError as e:\n    print('got', e)\n",
    "try_bare_except": "try:\n    1 / 0\nexcept:\n    print('any')\n",
    "try_picks_handler": (
        "try:\n    raise KeyError('k')\n"
        "except ValueError:\n    print('wrong')\n"
        "except KeyError:\n    print('right')\n"
    ),
    "try_else": "try:\n    x = 1\nexcept Exception:\n    print('no')\nelse:\n    print('else ran')\n",
    "try_in_function": (
        "def f(d, k):\n"
        "    try:\n        return d[k]\n"
        "    except KeyError:\n        return 'missing'\n"
        "print(f({'a': 1}, 'a'), f({}, 'z'))\n"
    ),
    "listcomp": "print([x * 2 for x in range(5)])\n",
    "listcomp_filter": "print([x for x in range(10) if x % 3 == 0])\n",
    "listcomp_expr": "ys = [1, 2, 3]\nprint([y + 1 for y in ys])\n",
    "setcomp": "print(sorted({x % 3 for x in range(10)}))\n",
    "dictcomp": "print(sorted({k: k * k for k in range(4)}.items()))\n",
    "listcomp_in_function": (
        "def f(n):\n    return [i * i for i in range(n)]\nprint(f(4))\n"
    ),
    "listcomp_captures": (
        "def f(m):\n    return [i * m for i in range(4)]\nprint(f(3))\n"
    ),
    "class_simple": (
        "class C:\n    v = 5\n    def get(self):\n        return self.v\n"
        "print(C().get(), C.v)\n"
    ),
    "class_init": (
        "class P:\n"
        "    def __init__(self, x, y):\n        self.x = x\n        self.y = y\n"
        "    def total(self):\n        return self.x + self.y\n"
        "p = P(3, 4)\nprint(p.x, p.y, p.total())\n"
    ),
    "class_inheritance": (
        "class A:\n    def who(self):\n        return 'A'\n"
        "class B(A):\n    def who(self):\n        return 'B' + A.who(self)\n"
        "print(A().who(), B().who())\n"
    ),
    "with_stmt": (
        "class CM:\n"
        "    def __enter__(self):\n        print('enter')\n        return 42\n"
        "    def __exit__(self, a, b, c):\n        print('exit')\n        return False\n"
        "with CM() as v:\n    print('body', v)\nprint('after')\n"
    ),
    "nonlocal_stmt": (
        "def outer():\n"
        "    n = 1\n"
        "    def bump():\n        nonlocal n\n        n = n + 1\n"
        "    bump()\n    bump()\n    return n\n"
        "print(outer())\n"
    ),
    "generator": (
        "def count(n):\n    i = 0\n    while i < n:\n        yield i\n        i += 1\n"
        "print(list(count(4)))\n"
    ),
    "generator_for": (
        "def g(xs):\n    for x in xs:\n        yield x * 2\nprint(list(g([1, 2, 3])))\n"
    ),
    "genexp": "print(sum(x * 2 for x in range(5)))\n",
    "genexp_filter": "print(list(x for x in range(8) if x % 2))\n",
    "yield_from": (
        "def inner():\n    yield 1\n    yield 2\n"
        "def outer():\n    yield 0\n    yield from inner()\n"
        "print(list(outer()))\n"
    ),
    "match_value": (
        "def f(x):\n    match x:\n        case 0:\n            return 'zero'\n"
        "        case _:\n            return 'other'\n"
        "print(f(0), f(9))\n"
    ),
    "match_or_pattern": (
        "def f(x):\n    match x:\n        case 1 | 2 | 3:\n            return 'small'\n"
        "        case _:\n            return 'big'\n"
        "print(f(2), f(50))\n"
    ),
    "match_sequence_pattern": (
        "def f(x):\n    match x:\n        case [a, b]:\n            return a + b\n"
        "        case _:\n            return -1\n"
        "print(f([3, 4]), f([1]))\n"
    ),
    "match_singleton": (
        "def f(x):\n    match x:\n        case None:\n            return 'none'\n"
        "        case _:\n            return 'some'\n"
        "print(f(None), f(1))\n"
    ),
    "match_guard_capture": (
        "def f(x):\n    match x:\n        case n if n > 100:\n            return 'huge'\n"
        "        case n:\n            return 'n=' + str(n)\n"
        "print(f(500), f(7))\n"
    ),
    "match_class_pattern": (
        "class P:\n    def __init__(self, x):\n        self.x = x\n"
        "def f(v):\n    match v:\n        case P(x=1):\n            return 'one'\n"
        "        case P():\n            return 'other P'\n"
        "        case _:\n            return 'not P'\n"
        "print(f(P(1)), f(P(2)), f(3))\n"
    ),
    "default_args": "def f(a, b=10):\n    return a + b\nprint(f(1), f(1, 2))\n",
    "default_args_two": "def f(a=1, b=2):\n    return a * b\nprint(f(), f(3), f(3, 4))\n",
    "varargs": "def f(*a):\n    return len(a)\nprint(f(), f(1), f(1, 2, 3))\n",
    "varargs_mixed": "def f(x, *a):\n    return x + len(a)\nprint(f(10), f(10, 1, 2))\n",
    "kwargs_collect": "def f(**k):\n    return sorted(k.keys())\nprint(f(b=1, a=2))\n",
    "decorator_simple": (
        "def d(f):\n    def w():\n        return f() + 1\n    return w\n"
        "@d\ndef g():\n    return 1\nprint(g())\n"
    ),
    "decorator_identity": "def d(f):\n    return f\n@d\ndef g():\n    return 7\nprint(g())\n",
    "default_closure": (
        "def make(k):\n    def f(x, y=k):\n        return x + y\n    return f\n"
        "print(make(5)(1))\n"
    ),
    "multi_for_comp": "print([x + y for x in range(2) for y in range(3)])\n",
    "multi_for_filter": "print([(a, b) for a in range(3) for b in range(3) if a < b])\n",
    "fstring_spec_align": "x = 5\nprint(f'{x:>4}|')\n",
    "fstring_spec_zero": "x = 5\nprint(f'{x:03d}')\n",
    "fstring_spec_float": "v = 1 / 3\nprint(f'{v:.3f}')\n",
    "try_finally": "try:\n    x = 1\nfinally:\n    print('fin')\nprint(x)\n",
    "try_finally_return": (
        "def f():\n    try:\n        return 'body'\n    finally:\n        print('fin')\n"
        "print(f())\n"
    ),
    "try_except_finally": (
        "try:\n    raise ValueError('v')\nexcept ValueError:\n    print('caught')\n"
        "finally:\n    print('fin')\n"
    ),
    "star_call_args": "def f(a, b):\n    return a + b\nt = (1, 2)\nprint(f(*t))\n",
    "star_call_mixed": "def f(a, b, c):\n    return a + b + c\nt = (1, 2)\nprint(f(*t, 3))\n",
    "double_star_call": "def f(a, b):\n    return a - b\nd = {'a': 5, 'b': 1}\nprint(f(**d))\n",
    "star_and_double": (
        "def f(a, b, c=0):\n    return a + b + c\nt = (1, 2)\n"
        "print(f(*t, **{'c': 10}))\n"
    ),
    "strings": 'print("a" + "b", "x" * 3, len("hello"))\n',
}

MATCH_PATTERNS = {
    "match_star_tail": (
        "def f(xs):\n"
        "    match xs:\n"
        "        case []:\n            return 'empty'\n"
        "        case [only]:\n            return f'one {only}'\n"
        "        case [first, *_, last]:\n            return f'{first}..{last}'\n"
        "for v in ([], [1], [1, 2], [1, 2, 3], (9, 8, 7)):\n    print(f(v))\n"
    ),
    "match_star_binds_a_list": (
        # A tuple subject still binds the star to a list, per PEP 634.
        "def f(xs):\n"
        "    match xs:\n"
        "        case [a, *rest]:\n            return (a, rest)\n"
        "        case _:\n            return None\n"
        "print(f([1, 2, 3]))\nprint(f((1, 2, 3)))\nprint(f([1]))\n"
    ),
    "match_star_head": (
        "def f(xs):\n"
        "    match xs:\n"
        "        case [*rest, last]:\n            return (rest, last)\n"
        "        case _:\n            return None\n"
        "print(f([1, 2, 3]))\nprint(f([1]))\nprint(f([]))\n"
    ),
    "match_mapping": (
        "def f(cmd):\n"
        "    match cmd:\n"
        '        case {"action": "quit"}:\n            return "quitting"\n'
        '        case {"action": "move", "x": x, "y": y}:\n            return f"to ({x},{y})"\n'
        '        case {"action": a}:\n            return f"unknown {a}"\n'
        '        case _:\n            return "invalid"\n'
        'for v in ({"action": "quit"}, {"action": "move", "x": 1, "y": 2},\n'
        '          {"action": "jump"}, "nope", {"action": "quit", "extra": 9}):\n'
        "    print(f(v))\n"
    ),
    "match_mapping_ignores_extra_keys": (
        # The whole reason a mapping pattern is not a dict comparison.
        'match {"a": 1, "b": 2}:\n'
        '    case {"a": 1}:\n        print("matched on a subset")\n'
        "    case _:\n        print("
        '"no")\n'
    ),
    "match_empty_mapping_matches_any": (
        'for v in ({"a": 1}, {}, [1], 5):\n'
        "    match v:\n"
        '        case {}:\n            print("mapping", v)\n'
        '        case _:\n            print("not", v)\n'
    ),
}

UNSUPPORTED = {
    "async_def": "async def f():\n    pass\n",
    "await_expr": "async def f():\n    await g()\n",
    "async_for": "async def f():\n    async for x in y:\n        pass\n",
    "async_with": "async def f():\n    async with y:\n        pass\n",
}

CLOSURES = {
    "closure_read": (
        "def outer(n):\n"
        "    def inner():\n        return n * 2\n"
        "    return inner()\n"
        "print(outer(21))\n"
    ),
    "closure_returned": (
        "def make(n):\n"
        "    def add(x):\n        return x + n\n"
        "    return add\n"
        "f = make(10)\n"
        "print(f(1), f(5))\n"
    ),
    "closure_two_vars": (
        "def outer(a, b):\n"
        "    def inner():\n        return a - b\n"
        "    return inner()\n"
        "print(outer(10, 4))\n"
    ),
    "closure_over_local": (
        "def outer():\n"
        "    t = 7\n"
        "    def inner():\n        return t + 1\n"
        "    return inner()\n"
        "print(outer())\n"
    ),
    "closure_lambda": ("def make(n):\n    return lambda x: x * n\nprint(make(3)(5))\n"),
    "nested_functions_no_capture": (
        "def outer():\n"
        "    def inner():\n        return 5\n"
        "    return inner()\n"
        "print(outer())\n"
    ),
}

PROGRAMS.update(MATCH_PATTERNS)
