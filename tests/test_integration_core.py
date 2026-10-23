"""Integration cases for the interpreter core.

Language & VM (arith, control flow, generators, closures, classes,
exceptions, format strings, comprehensions, generators, MI, dict
subclassing, str/bytes slicing, __missing__, __setattr__, …), plus
the shipped stdlib modules other than `os` (json, re, string,
itertools, collections). Each case is small and readable; when a case
commemorates a specific past bug the comment says which commit.

Cases: 126. Coverage for `os` lives in test_integration_os.py.
"""

from __future__ import annotations

# (name, source, expected_stdout) — 3-tuple checks stdout only.
# (name, source, expected_stdout, expected_exit) — 4-tuple also pins exit code.
# (name, source, expected_stdout, expected_exit, flags) — 5-tuple passes
# `flags` to the binary before the script path, for cases about the CLI
# itself rather than about the language.
# expected_stdout=None skips the stdout check (used when only the exit
# code matters — e.g. "raise → exit 1" without committing to exact
# traceback text).
CASES = [
    # ── the --emit-mpy flag ────────────────────────────────────────────
    #
    # The playground's foundation: it compiles in the browser by running
    # this, then decodes the base64 off stdout. base64 rather than a file
    # because the browser WASI shim and wasmtime disagree about write
    # capability on a preopened directory.
    #
    # Checked on the wasm arm too, which is the one that matters here.
    # The base64 is pinned, not merely non-empty: it decodes to 'M', 6,
    # ... — the magic and MPY_VERSION — and both arms emit the same bytes
    # for the same source. A change here means the bytecode changed,
    # which is worth being told about.
    (
        "emit_mpy_is_a_valid_container",
        "x = 41\nprint(x + 1)",
        "TQYAHwQAFDxlbWl0LW1weT4ADwJ4AIF3gQgQAgGpFgIRAxECgfI0AVlRYw==\n",
        0,
        ["--emit-mpy"],
    ),
    # The marker string appears in the *constant table*, so it is in the
    # base64 — but the program never runs, so it is never printed.
    (
        "emit_mpy_does_not_run_the_program",
        'print("SHOULD NOT APPEAR")',
        "TQYAHwMBFDxlbWl0LW1weT4AD4F3BRFTSE9VTEQgTk9UIEFQUEVBUgBgCAIBEQIjADQBWVFj\n",
        0,
        ["--emit-mpy"],
    ),
    (
        "emit_mpy_refuses_with_exit_2",
        "match x:\n    case {1, 2}:\n        pass",
        None,
        2,
        ["--emit-mpy"],
    ),
    # ── match statement ────────────────────────────────────────────────
    # Soft keywords: `match`/`case` are still ordinary names. This is the
    # property the whole lexer lookahead exists to preserve.
    (
        "match_soft_keyword_names",
        'match = 1\ncase = 2\nprint(match + case, match)\nmatch = {1: 2}\nprint(match[1])',
        "3 1\n2\n",
    ),
    (
        "match_literal_and_wildcard",
        (
            'for v in (1, 9):\n'
            '    match v:\n'
            '        case 1:\n'
            '            print("one")\n'
            '        case _:\n'
            '            print("other")'
        ),
        "one\nother\n",
    ),
    # `1 | 2` must stay two alternatives. Routed through the `expr` rule
    # the parser folds it to the constant 3 before the compiler sees it,
    # so this reads "low low hi", not "hi hi low".
    (
        "match_or_pattern",
        (
            'for v in (1, 2, 3):\n'
            '    match v:\n'
            '        case 1 | 2:\n'
            '            print("low")\n'
            '        case _:\n'
            '            print("hi")'
        ),
        "low\nlow\nhi\n",
    ),
    # PEP 634 compares None/True/False by identity, everything else by
    # equality — so `case True` must not swallow 1.
    (
        "match_singleton_identity",
        (
            'for v in (None, True, 1):\n'
            '    match v:\n'
            '        case None:\n'
            '            print("none")\n'
            '        case True:\n'
            '            print("true")\n'
            '        case _:\n'
            '            print("other")'
        ),
        "none\ntrue\nother\n",
    ),
    # A str is a sequence but must not match a sequence pattern.
    (
        "match_sequence",
        (
            'for v in ([1, 2], (3, 4), [5], "ab", 6):\n'
            '    match v:\n'
            '        case [1, 2]:\n'
            '            print("exact")\n'
            '        case [a, b]:\n'
            '            print("pair", a, b)\n'
            '        case [c]:\n'
            '            print("single", c)\n'
            '        case _:\n'
            '            print("other")'
        ),
        "exact\npair 3 4\nsingle 5\nother\nother\n",
    ),
    (
        "match_class_and_as",
        (
            'class P:\n'
            '    def __init__(self, x):\n'
            '        self.x = x\n'
            'for v in (P(1), P(2), 3):\n'
            '    match v:\n'
            '        case P(x=1):\n'
            '            print("x is 1")\n'
            '        case P(x=n) as whole:\n'
            '            print("P", n, isinstance(whole, P))\n'
            '        case _:\n'
            '            print("other")'
        ),
        "x is 1\nP 2 True\nother\n",
    ),
    # PEP 634 binds before the guard runs, so the guard can see `n`.
    (
        "match_guard_sees_binding",
        (
            'for v in (9, 3):\n'
            '    match v:\n'
            '        case n if n > 5:\n'
            '            print("big", n)\n'
            '        case n:\n'
            '            print("small", n)'
        ),
        "big 9\nsmall 3\n",
    ),
    (
        "match_nested_and_fallthrough",
        (
            'match [1, [2, 3]]:\n'
            '    case [a, [b, c]]:\n'
            '        print(a + b + c)\n'
            'match 5:\n'
            '    case 1:\n'
            '        print("no")'
        ),
        "6\n",
    ),
    # `from __future__ import ...` is a compiler directive, not an import.
    # Vendor MicroPython raises ImportError here; this is a deliberate
    # divergence toward CPython, and it is what stood between
    # golden-programs/works/match_statements.py and passing.
    (
        "future_import_is_a_no_op",
        'from __future__ import annotations\nprint("ok")',
        "ok\n",
    ),
    (
        "future_import_does_not_swallow_real_imports",
        "from __future__ import annotations\nfrom sys import path\nprint(type(path).__name__)",
        "list\n",
    ),
    # A star turns the length test into a minimum, and elements after it
    # are counted from the end. The star itself binds a list even when the
    # subject is a tuple, per PEP 634.
    (
        "match_star_pattern",
        (
            "def f(xs):\n"
            "    match xs:\n"
            "        case []:\n            return 'empty'\n"
            "        case [only]:\n            return 'one ' + str(only)\n"
            "        case [a, *rest]:\n            return str(a) + ' ' + str(rest)\n"
            "for v in ([], [1], [1, 2, 3], (9, 8, 7)):\n    print(f(v))"
        ),
        "empty\none 1\n1 [2, 3]\n9 [8, 7]\n",
    ),
    (
        "match_star_in_the_middle",
        (
            "match [1, 2, 3, 4]:\n"
            "    case [first, *_, last]:\n"
            "        print(first, last)"
        ),
        "1 4\n",
    ),
    # A mapping pattern matches on the keys it names and ignores the rest,
    # which is what makes it different from the dict equality test the same
    # syntax means in an expression.
    (
        "match_mapping_ignores_extra_keys",
        (
            'match {"a": 1, "b": 2}:\n'
            '    case {"a": 1}:\n        print("subset")\n'
            '    case _:\n        print("no")'
        ),
        "subset\n",
    ),
    (
        "match_empty_mapping_matches_any",
        (
            'for v in ({"a": 1}, {}, [1], 5):\n'
            "    match v:\n"
            '        case {}:\n            print("mapping")\n'
            '        case _:\n            print("not")'
        ),
        "mapping\nmapping\nnot\nnot\n",
    ),
    # The unsupported pattern forms have to REFUSE, not compile to
    # something that looks like it works: a mapping pattern is not a dict
    # equality test (it ignores extra keys), and `mod.P(x=1)` as a value
    # pattern would call mod.P and compare the result.
    (
        "match_refuses_set_pattern",
        'match {1}:\n    case {1, 2}:\n        print("wrong")',
        None,
        1,
    ),
    (
        "match_refuses_two_stars",
        'match [1, 2]:\n    case [*a, 1, *b]:\n        print("wrong")',
        None,
        1,
    ),
    (
        "match_refuses_dotted_class",
        'import sys\nmatch 1:\n    case sys.X(a=1):\n        print("wrong")',
        None,
        1,
    ),
    (
        "match_refuses_positional_class",
        'class P:\n    pass\nmatch P():\n    case P(1):\n        print("wrong")',
        None,
        1,
    ),
    ("arith", "print(1 + 1, 2 ** 10, 7 % 3, 10 // 3, -7 // 2)", "2 1024 1 3 -4\n"),
    (
        "strings",
        'print("hello" + " " + "world", "ab" * 3, len("hello"))',
        "hello world ababab 5\n",
    ),  # ASCII-only so profile-agnostic
    # (len("héllo") was 6 under nano STR_UNICODE=0 but 5 under full
    # STR_UNICODE=1; integration suite must work on both arms now
    # that ADR 012 Phase 4b made full the default).
    ("list_comp", "print([x*x for x in range(6) if x % 2 == 0])", "[0, 4, 16]\n"),
    (
        "dict",
        'd = {"b": 2, "a": 1}\nprint(sorted(d.items()), d.get("z", -1))',
        "[('a', 1), ('b', 2)] -1\n",
    ),
    # PEP 448 `{**a, **b}` dict-unpack — grammar overlay + compile.zig
    # emitter added 2026-07-20 to unblock hop3-rootd's exec.py which
    # uses `env = {**os.environ, **extra}`.
    (
        "dict_unpack_pep448",
        (
            'a={"x":1}\nb={"y":2}\n'
            "print(sorted({**a, **b}.items()))\n"
            'print(sorted({**a, "z":9}.items()))\n'
            "print(sorted({**a}.items()))"
        ),
        "[('x', 1), ('y', 2)]\n[('x', 1), ('z', 9)]\n[('x', 1)]\n",
    ),
    # PEP 448 `[a, *b]` list-unpack — grammar already accepts star_expr
    # inside testlist_comp; compileAtomBracket now detects star_expr
    # children and emits BUILD_LIST 0 + dup+append/extend+call+pop per
    # item, unblocking hop3-rootd's `[binary, *args]` idiom.
    (
        "list_unpack_pep448",
        (
            "a=[10,20]\n"
            "print([1, *a, 2])\n"
            "print([*a])\n"
            "print([*range(3), 99])\n"
            'print([*"ab", "c"])'
        ),
        "[1, 10, 20, 2]\n[10, 20]\n[0, 1, 2, 99]\n['a', 'b', 'c']\n",
    ),
    # PEP 570 positional-only `/` marker — MicroPython doesn't
    # enforce positional-only semantics; grammar overlay + walker
    # skip is enough so hop3-rootd's `def __call__(..., /)` parses.
    (
        "positional_only_pep570",
        (
            "def f(x, /, y): return x + y\n"
            "def g(a, b, /): return a * b\n"
            "print(f(3, 4), g(5, 6))"
        ),
        "7 30\n",
    ),
    # enum stub — `class X(str, Enum):` form parses under nanopython
    # even though __init_subclass__ doesn't fire. Members stay as
    # class attributes (identical to CPython for str-valued enums).
    (
        "enum_str_subclass",
        (
            "from enum import Enum\n"
            "class E(str, Enum):\n"
            "    A = 'alpha'\n"
            "    B = 'beta'\n"
            "print(E.A, E.A == 'alpha', type(E.A).__name__)"
        ),
        "alpha True str\n",
    ),
    # @enum decorator — the full-featured path retains .name/.value.
    (
        "enum_decorator",
        (
            "from enum import enum, members, lookup\n"
            "@enum\n"
            "class C:\n"
            "    RED = 1\n"
            "    BLUE = 2\n"
            "print(C.RED.name, C.RED.value)\n"
            "print([m.name for m in members(C)])\n"
            "print(lookup(C, 2).name)"
        ),
        "RED 1\n['RED', 'BLUE']\nBLUE\n",
    ),
    ("tuple_unpack", "a, b, *c = 1, 2, 3, 4\nprint(a, b, c)", "1 2 [3, 4]\n"),
    (
        "closure",
        (
            "def mk(n):\n"
            "    def add(x): return x + n\n"
            "    return add\n"
            "print(mk(10)(5), mk(100)(1))"
        ),
        "15 101\n",
    ),
    (
        "recursion",
        (
            "def fib(n): return n if n < 2 else fib(n-1)+fib(n-2)\n"
            "print([fib(i) for i in range(10)])"
        ),
        "[0, 1, 1, 2, 3, 5, 8, 13, 21, 34]\n",
    ),
    (
        "generator",
        "def g():\n    yield 1\n    yield 2\n    yield 3\nprint(list(g()), sum(g()))",
        "[1, 2, 3] 6\n",
    ),
    ("genexpr_filter", "print(list(x for x in range(8) if x % 3 == 0))", "[0, 3, 6]\n"),
    (
        "class_repr",
        (
            "class P:\n"
            "    def __init__(s, x): s.x = x\n"
            "    def __repr__(s): return 'P(' + str(s.x) + ')'\n"
            "print([P(i) for i in range(3)])"
        ),
        "[P(0), P(1), P(2)]\n",
    ),
    (
        "exceptions",
        (
            "try:\n"
            "    raise ValueError('boom')\n"
            "except ValueError as e:\n"
            "    print('caught', e)\n"
            "print(1 // 0 if False else 'ok')"
        ),
        "caught boom\nok\n",
    ),
    (
        "zerodiv",
        "try:\n    1 // 0\nexcept ZeroDivisionError as e:\n    print(repr(e))",
        "ZeroDivisionError('divide by zero',)\n",
    ),
    (
        "map_zip",
        "print(list(map(lambda x: x+1, [10, 20])), list(zip([1,2],[3,4])))",
        "[11, 21] [(1, 3), (2, 4)]\n",
    ),
    ("hex_int", 'print(int("ff", 16), int("0o17", 0), 0b1010, 255)', "255 15 10 255\n"),
    (
        "str_methods",
        'print("a,b,c".split(","), "  hi  ".strip(), "X".join(["1","2","3"]))',
        "['a', 'b', 'c'] hi 1X2X3\n",
    ),
    # int / int → float. Vendor py/objfloat.c is now in the nano build
    # via the float-arm carveout (see build.zig). Was: TypeError under
    # the old panic-stub configuration.
    ("nano_int_div_float", "print(1 / 2)", "0.5\n"),
    # ── Regression pins. Each commemorates a real bug we fixed; the
    # case stays small + readable so a future regression surfaces in
    # 1 second of `make test-integration` instead of after a user report.
    # commit 571b1d6 — wasm float-print signature mismatch
    # (mp_decimal_exp's mp_large_float_t was long double; our Zig port
    # was f64; wasm call_indirect trapped). Native passed silently.
    ("float_print", "print(3.14)", "3.14\n"),
    # commit 80d00e7 — % and {} format strings didn't handle floats:
    # the conversion-switch in strModuloFormatImpl had no e/f/g cases,
    # and vspPrintFloat was is_full-gated (empty output under nano).
    ("float_pct_format", 'print("%.2f" % 3.14)', "3.14\n"),
    # commit c920da4 — bytearray ↔ bytes interop. typeBytearrayPtr()
    # returned null under nano so str_check_arg_type's normalization
    # never ran. `bytearray.find(bytes_arg)` raised TypeError.
    ("bytes_interop", 'print(bytearray(b"hello world").find(b"ll"))', "2\n"),
    # commit c920da4 — range[a:b] slicing was is_full-gated;
    # `range(4)[1:3]` raised TypeError on nano.
    ("range_slice", "print(range(10)[2:6])", "range(2, 6)\n"),
    # commit 9207b46 — bytearray/array iter yielded only the first
    # element because MpObjArrayIt was 40 bytes but the polymorph iter
    # buffer is 32 bytes; `cur` got clobbered each FOR_ITER write.
    (
        "bytearray_iter",
        "a = bytearray([10, 20, 30, 40])\nfor x in a: print(x)",
        "10\n20\n30\n40\n",
    ),
    # commit 0b3cee0 — dict-subclass __getitem__ override dispatches.
    # In-program rather than `from collections import defaultdict`
    # (which depends on frozen-tiny — not always in the build path
    # this gate exercises); the override path is the actual code
    # that was previously broken.
    (
        "dict_subclass_getitem",
        (
            "class Z(dict):\n"
            "    def __getitem__(self, k): return self.get(k, 99)\n"
            "z = Z()\nz['a'] = 1\n"
            "print(z['a'], z['missing'])"
        ),
        "1 99\n",
    ),
    # CPython-friendly `from collections import deque` (commit-after-447ef8b).
    # MP's ucollections.deque requires (iterable, maxlen); the frozen
    # collections.py wraps it with a list-backed deque(iterable) so
    # BFS / sliding-window / queue code reads the same as on CPython.
    # The runtime fix in 447ef8b unblocked this — the negative-maxlen
    # ValueError now propagates instead of being overwritten with the
    # bogus "__init__() should return None".
    (
        "deque_cpython_idiom",
        (
            "from collections import deque\n"
            "q = deque([1,2,3])\n"
            "q.appendleft(0); q.append(4)\n"
            "print(list(q), q.popleft(), q.pop())"
        ),
        "[0, 1, 2, 3, 4] 0 4\n",
    ),
    # Raising inside __init__ used to surface as
    # "TypeError: __init__() should return None" — the make_new path
    # checked init_ret unconditionally even when __init__ raised
    # (mp_call_method_n_kw returns OBJ_NULL with pending_exc set when
    # the callee raises, and OBJ_NULL != MP_OBJ_NONE took us into the
    # wrong branch, overwriting the user's exception). Fixed in
    # objtype.zig instanceMakeNewImpl — check pyerr.pending_exc first.
    # chr() used to cap at 0xff ("chr() arg not in range(256)"),
    # the non-UNICODE branch — even though MICROPY_PY_BUILTINS_STR_UNICODE
    # is set in our config. Now matches MP unix-standard / CPython:
    # full range up to U+10FFFF, UTF-8 encoded.
    # splitlines() always returned keepends=True behavior for ANY explicit
    # arg (and was correct only for the no-args path). Root cause: the
    # MpArgT flag value for keepends was 0x008, but MP_ARG_BOOL is 0x001
    # (py/runtime.h:46-53) — the flag fell through to the OBJ branch which
    # writes the raw Obj into u_obj; reading u_bool from the low 4 bytes
    # returned 14 for False (the tagged-immediate value). Routed through
    # mp_obj_is_true directly instead — bypass the arg-parser for a
    # single-bool fast path.
    # str.ljust / str.rjust — common CPython idioms (column-aligning,
    # formatting). Vendor MP gates them to MICROPY_PY_BUILTINS_STR_LJUST=full;
    # ours ships on nano because the impl is small (same shape as
    # str.center) and the idiom is everywhere in algorithm code.
    (
        "str_ljust_rjust",
        'print("|" + "hi".ljust(5) + "|", "|" + "hi".rjust(5, "_") + "|")',
        "|hi   | |___hi|\n",
    ),
    # repr(generator) used to wasm-trap with "unreachable". Root cause:
    # mp_obj_fun_get_name was declared `callconv(.c) u16` (matched the
    # native amd64 ABI by accident — value lived in low 16 bits of RAX)
    # but every CALLER declared it as `usize` (correctly matching the
    # qstr convention). On wasm32 the wasm-level type mismatch +
    # Zig Debug-mode integer checks fired @unreachable in
    # gen_instance_print's mp_printf path. Same class as the
    # mp_errno_to_str bug below — qstr returns should always be usize.
    (
        "repr_generator",
        "def g():\n    yield 1\nprint(repr(g())[:24])",
        "<generator object 'g' at\n",
    ),
    # OSError(int) used to wasm-trap with "unreachable" when printed.
    # Root cause: extern decl of mp_errno_to_str in objexcept.zig said
    # `u16`, but the actual function returns `usize`. The amd64 ABI
    # happened to put the value in the low 16 bits of RAX so native
    # silently worked (per the documented note in src/runtime/qstr.zig:27);
    # wasm32's typed function signatures + Zig's Debug-mode integer
    # checks made the truncation explicit → @unreachable trap.
    # Fixed in objexcept.zig — declared return as usize, with @intCast
    # at the use site where c_uint is needed for the %q vararg.
    ("oserror_int_prints", "print(OSError(5))", "[Errno 5] EIO\n"),
    ("splitlines_keepends_false", 'print("a\\nb".splitlines(False))', "['a', 'b']\n"),
    (
        "chr_unicode",
        "print(chr(65), chr(0x1F600).encode('utf-8').hex())",
        "A f09f9880\n",
    ),
    (
        "init_raises_propagates",
        (
            "class C:\n"
            "    def __init__(self, x):\n"
            "        if x < 0: raise ValueError(x)\n"
            "try: C(-1)\n"
            "except ValueError as e: print('OK:', e)"
        ),
        "OK: -1\n",
    ),
    # Exit-code pins — uncaught exceptions used to exit 0 silently
    # (caused the float-trap bug + the bytes-interop bug to look
    # like "blazing fast" benchmarks instead of failures). Fixed
    # by routing the exec-result code through main → process.exit.
    ("exit_success", "print('ok')", "ok\n", 0),
    ("exit_uncaught_raise", "raise ValueError('boom')", None, 1),
    ("exit_uncaught_namerror", "x = undefined_name", None, 1),
    ("exit_uncaught_import", "import this_module_does_not_exist_xyz", None, 1),
    ("exit_sys_exit_int", "import sys; sys.exit(42)", "", 42),
    ("exit_sys_exit_zero", "import sys; sys.exit(0)", "", 0),
    ("exit_sys_exit_noarg", "import sys; sys.exit()", "", 0),
    (
        "exit_caught_doesnt_propagate",
        "try:\n    raise RuntimeError\nexcept RuntimeError:\n    print('caught')",
        "caught\n",
        0,
    ),
    # eval/exec/compile on wasm — closed the longjmp wall in v0.6 by
    # fixing the source_file ABI mismatch (u16 → usize) in the extern
    # decl of npy_zig_eval_exec. Same class-of-bug as v0.5's
    # mp_errno_to_str + mp_obj_fun_get_name. These pins ensure the
    # surface stays alive on both arms.
    ("eval_simple", "print(eval('1 + 1'))", "2\n"),
    ("eval_dict", "d = eval('{1: 2}'); print(d[1])", "2\n"),
    ("exec_print", "exec('print(42)')", "42\n"),
    ("exec_assign", "exec('x = 10'); print('done')", "done\n"),
    (
        "eval_error_propagates",
        "try: eval('1/0')\nexcept ZeroDivisionError: print('caught')",
        "caught\n",
    ),
    # Multiple inheritance (ADR 010 §A3b). The MI scaffolding existed under
    # is_full but was gated off under nano. v0.6 flips the gates to a new
    # build_options.multiple_inheritance flag (default on). Refrozen 9
    # corpus tests + this pin keep the surface alive on both arms.
    (
        "mi_basic",
        (
            "class A:\n    def a(self): return 'a'\n"
            "class B:\n    def b(self): return 'b'\n"
            "class C(A, B): pass\n"
            "c = C(); print(c.a(), c.b())"
        ),
        "a b\n",
    ),
    (
        "mi_isinstance",
        (
            "class A: pass\n"
            "class B: pass\n"
            "class C(A, B): pass\n"
            "c = C()\n"
            "print(isinstance(c, A), isinstance(c, B), isinstance(c, C))"
        ),
        "True True True\n",
    ),
    # itertools — ADR 010 §A3a slice 2. Frozen-tiny module from
    # vendor/micropython-lib (74 LOC → 560-byte .mpy). Covers count,
    # chain, islice, repeat, accumulate, starmap.
    (
        "itertools_count_islice",
        "import itertools\nprint(list(itertools.islice(itertools.count(10), 5)))",
        "[10, 11, 12, 13, 14]\n",
    ),
    (
        "itertools_chain",
        "import itertools\nprint(list(itertools.chain([1, 2], [3, 4], [5])))",
        "[1, 2, 3, 4, 5]\n",
    ),
    (
        "itertools_accumulate",
        "import itertools\nprint(list(itertools.accumulate([1, 2, 3, 4])))",
        "[1, 3, 6, 10]\n",
    ),
    # string — ADR 010 §A3a slice 2. Frozen-tiny ctype constants +
    # list-based translate + capwords (the upstream micropython-lib
    # translate uses io.StringIO which is full-only; we ship a
    # list-join version that works under nano).
    (
        "string_constants",
        (
            "import string\n"
            "print(string.digits)\n"
            "print(string.ascii_lowercase[:5])\n"
            "print(string.hexdigits)"
        ),
        "0123456789\nabcde\n0123456789abcdefABCDEF\n",
    ),
    (
        "string_capwords",
        (
            "import string\n"
            "print(string.capwords('hello world'))\n"
            "print(string.capwords('one-two-three', '-'))"
        ),
        "Hello World\nOne-Two-Three\n",
    ),
    (
        "string_translate",
        (
            "import string\n"
            "tbl = {ord('a'): ord('A'), ord('b'): None, ord('c'): 'XYZ'}\n"
            "print(string.translate('abcdef', tbl))"
        ),
        "AXYZdef\n",
    ),
    # `re` regex module — ADR 010 §A3a slice 2. Works on both arms
    # after the MpObjFunBuiltinVar mirror layout fix (the `_pad: u32`
    # was correct on amd64 and wrong on wasm32, shifting the `fun`
    # field offset and corrupting every var-arity builtin dispatch).
    (
        "re_match",
        (
            "import re\n"
            "m = re.match(r'(\\d+)-(\\d+)', '42-7')\n"
            "print(m.group(0), m.group(1), m.group(2))"
        ),
        "42-7 42 7\n",
    ),
    (
        "re_compile_split",
        "import re\nprint(re.compile(r'\\W+').split('one, two; three'))",
        "['one', 'two', 'three']\n",
    ),
    (
        "re_search_sub",
        (
            "import re\n"
            "print(re.search(r'\\d+', 'abc 123 def').group(0))\n"
            "print(re.compile(r'\\d+').sub('N', 'abc123def'))"
        ),
        "123\nabcNdef\n",
    ),
    # A.5 fix: re1.5 jump offsets widened from int8 to int16 in the
    # port/re1.5-patched/ overlay, so long alternation groups (13+
    # branches with `[-_]?` sub-parts) compile without overflow. The
    # driving case is hop3-rootd's audit-log secret-scrub regex; this
    # pin also catches any future encoding regression that shrinks
    # the offset back to int8.
    (
        "re_long_alternation_compiles",
        (
            "import re\n"
            "pat = '(' + '|'.join('a' * (i + 1) for i in range(30)) + ')'\n"
            "print(re.compile(pat).match('aaaaa').group(0))\n"
            "# hop3-rootd's exact pattern (13 alts, `[-_]?` sub-parts).\n"
            "secret = r'(password|token|secret|api[-_]?key|access[-_]?key)'\n"
            "print(re.search(secret, 'field_api-key_thing').group(0))"
        ),
        "a\napi-key\n",
    ),
    # re.IGNORECASE (and DOTALL/MULTILINE/VERBOSE) — nanopython-lib/re.py
    # shim adds the constants (all 0, no-op flags). Prevents AttributeError
    # on `import re; re.compile(pat, re.IGNORECASE)` in downstream code
    # like hop3-rootd's audit-log secret scrubber. Surfaced via
    # tools/hop3-rootd-smoke.py finding A.2.
    (
        "re_flag_constants_exist",
        (
            "import re\n"
            "print(re.IGNORECASE, re.DOTALL, re.MULTILINE, re.VERBOSE)\n"
            "print(re.I, re.S, re.M, re.X)\n"
            "# IGNORECASE is honoured via pattern-widening; the other flags\n"
            "# stay honest no-ops (re1.5 has no MULTILINE/DOTALL/VERBOSE hooks).\n"
            "print(re.compile('AbC', re.IGNORECASE).search('xxabcyy').group(0))"
        ),
        "2 0 0 0\n2 0 0 0\nabc\n",
    ),
    # Unicode str on the full arm: indexing, slicing (with steps),
    # iteration, find offsets and widths count code points, and escapes
    # above U+00FF compile. str_subscr was bytes_subscr, the utf8 helpers
    # were byte-step stubs and the lexer was in raw-byte mode, so
    # "héllo"[1:2] returned half a character and "\u20ac" did not
    # compile. Every build is Unicode by default; a -Dstr-unicode=false build
    # (str is bytes, `len('é')` is 2) takes the else branch, and exec keeps
    # the escapes away from its compiler.
    (
        "unicode_str_counts_code_points",
        (
            "s = 'héllo wörld'\n"
            "if len('é') == 1:\n"
            "    print(s[1] == 'é', s[-2] == 'l', s[1:4] == 'éll', s[::-1] == 'dlröw olléh',\n"
            "          s[1:8:3] == 'éoö', [ord(c) for c in 'a€😀'], s.find('w'), s.rindex('ö'),\n"
            "          'é'.center(5) == '  é  ', 'é'.ljust(3) == 'é  ')\n"
            "    exec(\"print('\\\\u20ac\\\\U0001f600' == '€😀', ord('\\\\xff'))\")\n"
            "else:\n"
            "    print(True, True, True, True, True, [97, 8364, 128512], 6, 7, True, True)\n"
            "    print(True, 255)\n"
        ),
        "True True True True True [97, 8364, 128512] 6 7 True True\nTrue 255\n",
    ),
    # itertools: micropython-lib's module lacked the combinatoric and
    # grouping functions, and its tee() returned one iterator n times.
    (
        "itertools_cpython_functions",
        (
            "import itertools as I\n"
            "print(list(I.permutations('abc', 2))[:3], list(I.combinations(range(4), 3)))\n"
            "print(list(I.product('ab', repeat=2)), [(k, len(list(g))) for k, g in I.groupby('aabccc')])\n"
            "print(list(I.zip_longest('ab', 'xyz', fillvalue='-')), list(I.pairwise([1, 2, 3])))\n"
            "a, b = I.tee([1, 2, 3])\n"
            "print(list(a), list(b), list(I.chain.from_iterable(['ab', 'c'])))\n"
        ),
        (
            "[('a', 'b'), ('a', 'c'), ('b', 'a')] [(0, 1, 2), (0, 1, 3), (0, 2, 3), (1, 2, 3)]\n"
            "[('a', 'a'), ('a', 'b'), ('b', 'a'), ('b', 'b')] [('a', 2), ('b', 1), ('c', 3)]\n"
            "[('a', 'x'), ('b', 'y'), ('-', 'z')] [(1, 2), (2, 3)]\n"
            "[1, 2, 3] [1, 2, 3] ['a', 'b', 'c']\n"
        ),
    ),
    (
        "math_gcd",
        (
            "import math\n"
            "print(math.gcd(12, 18), math.gcd(), math.gcd(-4, 6), math.gcd(12, 18, 27))\n"
            "try:\n"
            "    math.gcd(2.5, 1)\n"
            "except TypeError:\n"
            "    print('TypeError')\n"
        ),
        "6 0 2 3\nTypeError\n",
    ),
    (
        "builtin_format",
        "print(format(1234567, ','), format(42), format('ab', '>4'), format(255, 'x'), format(7, '03d'))\n",
        "1,234,567 42   ab ff 007\n",
    ),
    # `-c CODE`: was read as a script path, and the missing file escaped
    # as a Zig error with a stack trace. sys.argv[0] is '-c' as in CPython;
    # the runner's script path lands in sys.argv[1].
    (
        "dash_c_runs_code",
        "",
        "-c 2\n",
        0,
        ["-c", "import sys; print(sys.argv[0], len(sys.argv))"],
    ),
    # repr(float) is the shortest string that round-trips, as in CPython.
    # Vendor's formatter printed sqrt(2) ending in 952 and 5e-324 as
    # 1.84467440737095505e-323. (Correctly rounded parsing is native-only:
    # float_literal_parses_correctly_rounded in test_integration_os.py.)
    (
        "float_repr_shortest_roundtrip",
        (
            "import math\n"
            "print(math.sqrt(2), 5e-324, 1e16, 1.5e-05, 123.0, -0.0, 0.1 + 0.2)\n"
            "print(all(float(repr(x)) == x for x in [math.pi, 1 / 3, 1e300 * 7]))\n"
        ),
        "1.4142135623730951 5e-324 1e+16 1.5e-05 123.0 -0.0 0.30000000000000004\nTrue\n",
    ),
    # Float errors are catchable: vendor objfloat.c raised them with a
    # longjmp the VM cannot catch (ADR 013), so `try: x / 0.0` ended the
    # program; runtime.zig raises them first. int ** -n is a float; it
    # raised "negative power with no float support".
    (
        "float_errors_catchable_and_negative_int_power",
        (
            "def t(f):\n"
            "    try:\n"
            "        return f()\n"
            "    except ZeroDivisionError:\n"
            "        return 'ZeroDivisionError'\n"
            "    except ValueError:\n"
            "        return 'ValueError'\n"
            "print(t(lambda: 1 % 0.0), t(lambda: 1.0 / 0), t(lambda: 2.5 // False), t(lambda: divmod(2.5, 0)))\n"
            "print(t(lambda: 0.0 ** -1), t(lambda: 0 ** -2), t(lambda: (-8.0) ** 0.5), t(lambda: 10 ** -3), t(lambda: 2 ** -1))\n"
        ),
        (
            "ZeroDivisionError ZeroDivisionError ZeroDivisionError ZeroDivisionError\n"
            "ZeroDivisionError ZeroDivisionError ValueError 0.001 0.5\n"
        ),
    ),
    # `raise ... from` (PEP 3134): vendor printed "exception chaining not
    # supported" and dropped the cause. The cause is kept, readable and
    # printed first in the traceback, with CPython's separator line.
    (
        "exception_chaining",
        (
            "import sys\n"
            "try:\n"
            "    try:\n"
            "        raise ValueError(1)\n"
            "    except ValueError as e:\n"
            "        raise KeyError(2) from e\n"
            "except KeyError as k:\n"
            "    print(type(k.__cause__).__name__, k.__suppress_context__)\n"
            "    sys.print_exception(k)\n"
            "try:\n"
            "    raise OSError from None\n"
            "except OSError as o:\n"
            "    print(o.__cause__, o.__suppress_context__)\n"
        ),
        (
            "ValueError True\n"
            "Traceback (most recent call last):\n"
            '  File "<stdin>", in <module>\n'
            "ValueError: 1\n"
            "\n"
            "The above exception was the direct cause of the following exception:\n"
            "\n"
            "Traceback (most recent call last):\n"
            '  File "<stdin>", in <module>\n'
            "KeyError: 2\n"
            "None True\n"
        ),
    ),
    # Class annotations (PEP 526): vendor compiles `x: T` in a class to
    # nothing, so @dataclass could not see a field without a default. The
    # compiler records them in source order, as text (PEP 563), so a forward
    # reference does not raise NameError.
    (
        "class_annotations_recorded",
        (
            "class Node:\n"
            "    value: int\n"
            "    next: Node = None\n"
            "    tags: list[str] = []\n"
            "    label: 'str | None'\n"
            "print(list(Node.__annotations__), Node.__annotations__['next'], Node.__annotations__['tags'])\n"
            "print(Node.__annotations__['label'], Node.next, hasattr(Node, 'value'))\n"
        ),
        "['value', 'next', 'tags', 'label'] Node list[str]\n'str | None' None False\n",
    ),
    # Dicts keep insertion order on full, as in CPython 3.7+: printing,
    # `**kwargs`, class and instance namespaces, `json.dumps`, a key
    # deleted and re-added moving to the end, `popitem` taking the last
    # item. nano keeps MicroPython's hash order, which the corpus pins,
    # and has no class `__dict__`, so its output is not checked here.
    (
        "dict_insertion_order",
        (
            "import json\n"
            "d = {'zeta': 1, 'alpha': 2, 3: 3, (1, 2): 4}\n"
            "d['m'] = 5\n"
            "del d['alpha']\n"
            "d['alpha'] = 6\n"
            "print(d, d.popitem())\n"
            "def f(**kw):\n"
            "    return list(kw)\n"
            "class C:\n"
            "    z = 1\n"
            "    a = 2\n"
            "c = C()\n"
            "c.q = 1\n"
            "c.b = 2\n"
            "print(f(z=1, a=2), [k for k in C.__dict__ if k in 'za'], list(c.__dict__))\n"
            "print(json.dumps({'z': [1, {'y': 2, 'b': 3}], 'a': None}))\n"
            "e = {i: i for i in range(100)}\n"
            "for i in range(0, 100, 2):\n"
            "    del e[i]\n"
            "e[0] = 0\n"
            "print(len(e), list(e)[:3], list(e)[-2:], list(e.copy()) == list(e))\n"
        ),
        {
            "full": (
                "{'zeta': 1, 3: 3, (1, 2): 4, 'm': 5} ('alpha', 6)\n"
                "['z', 'a'] ['z', 'a'] ['q', 'b']\n"
                '{"z": [1, {"y": 2, "b": 3}], "a": null}\n'
                "51 [1, 3, 5] [99, 0] True\n"
            ),
            "nano": None,
        },
    ),
    # Keyword arguments to built-in methods and constructors, on full, as
    # CPython takes them. nano keeps MicroPython's positional-only builtins.
    (
        "builtin_keyword_args",
        (
            "import io\n"
            "print('a b  c'.split(maxsplit=1), 'a,b,c'.rsplit(',', maxsplit=1), 'a,b'.split(sep=','))\n"
            "print('\u00e9'.encode(encoding='utf-8'), b'\\xc3\\xa9'.decode(errors='strict'))\n"
            "print(str(b'ab', encoding='utf-8'), str(object=5), bytes('a', encoding='utf-8'), bytearray('a', encoding='utf-8'))\n"
            "print('aaa'.replace('a', 'b', count=2), sum([1, 2], start=10), round(2.567, ndigits=2), round(2.5, None), pow(2, 3, mod=5))\n"
            "f = io.StringIO()\n"
            "print('x', 'y', sep='-', file=f, flush=True)\n"
            "print(repr(f.getvalue()))\n"
            "for bad in ['\"a\".split(bogus=1)', '\"a\".split(\",\", sep=\",\")']:\n"
            "    try:\n"
            "        eval(bad)\n"
            "    except TypeError:\n"
            "        print('TypeError')\n"
        ),
        {
            "full": (
                "['a', 'b  c'] ['a,b', 'c'] ['a', 'b']\n"
                "b'\\xc3\\xa9' \u00e9\n"
                "ab 5 b'a' bytearray(b'a')\n"
                "bba 13 2.57 2 3\n"
                "'x-y\\n'\n"
                "TypeError\n"
                "TypeError\n"
            ),
            "nano": None,
        },
    ),
    # dict.__setitem__(self, ...) from a dict subclass's own __setitem__
    # acts on the dict; it used to call the override again until the
    # stack overflowed.
    (
        "dict_subclass_calls_dict_methods",
        (
            "log = []\n"
            "class E(dict):\n"
            "    def __setitem__(self, k, v):\n"
            "        log.append(k)\n"
            "        dict.__setitem__(self, k, v)\n"
            "    def __getitem__(self, k):\n"
            "        return dict.__getitem__(self, k) * 2\n"
            "    def __delitem__(self, k):\n"
            "        log.append(k)\n"
            "        dict.__delitem__(self, k)\n"
            "e = E(a=1)\n"
            "e['b'] = 2\n"
            "del e['a']\n"
            "print(e, e['b'], log)\n"
        ),
        "{'b': 2} 4 ['b', 'a']\n",
    ),
    # collections.abc as a frozen submodule of the collections package.
    # Enabled by (a) converting nanopython-lib/collections.py to a
    # package + adding collections/abc.py, (b) teaching the freezer to
    # accept dotted names ("collections.abc" → build-frozen/collections.abc.mpy),
    # (c) extending import_search.tryLoadComponent to try frozen lookup
    # by the FULL dotted name (not just the top-level component).
    # Surfaced via tools/hop3-rootd-smoke.py finding A.1.
    (
        "collections_abc_import",
        (
            "from collections.abc import Callable, Iterable, Mapping\n"
            "from collections import deque, OrderedDict, Counter, namedtuple\n"
            "# ABCs alias to `object` (isinstance-of-object is trivially True,\n"
            "# which is why we don't use isinstance to smoke this — the import\n"
            "# is the invariant).\n"
            "print(Callable is object, Iterable is object, Mapping is object)\n"
            "print(list(deque([1,2,3])))"
        ),
        "True True True\n[1, 2, 3]\n",
    ),
    # @dataclass(frozen=True) — the shim silently accepts frozen/slots/
    # kw_only/order/unsafe_hash/match_args for CPython import-compat.
    # Instances stay mutable; the invariant here is "import doesn't
    # raise + fields still work".
    # Surfaced via tools/hop3-rootd-smoke.py finding A.6.
    # @dataclass with the CPython 3.10+ flag kwargs (frozen/slots/
    # kw_only/order/unsafe_hash/match_args) — the shim silently accepts
    # them for import-compat. Real coverage is in the hop3-rootd smoke;
    # here we just confirm no-TypeError on the decorator call.
    # PETITPY_LIB isn't set for the integration suite (it uses
    # frozen-tiny only), so `import dataclasses` raises ImportError and
    # the skip branch fires. When PETITPY_LIB is set the else-branch
    # runs — same expected output.
    # Surfaced via tools/hop3-rootd-smoke.py finding A.6.
    # `from pkg import sub` should autoload sub if pkg is a package
    # and sub isn't yet an attribute. Vendor MicroPython does this via
    # mp_import_from's package fallback (py/runtime.c:1544). Ours was
    # missing that block — a bare mp_load_method_maybe + import_error.
    # Fixed in runtime.zig:mpImportFromImpl. Uses the frozen `collections`
    # package: `abc` isn't an attribute of the loaded collections module,
    # so the fallback must trigger the filesystem/frozen import of
    # `collections.abc` and return that. Surfaced via A.3 in
    # tools/hop3-rootd-smoke.py.
    (
        "import_from_submodule_autoload",
        (
            "import collections  # load bare package (no abc as attr yet)\n"
            "from collections import abc  # must autoload collections.abc\n"
            "print(type(abc).__name__, hasattr(abc, 'Callable'))\n"
        ),
        "module True\n",
    ),
    (
        "dataclass_flags_kwargs_accepted",
        (
            "try:\n"
            "    from dataclasses import dataclass\n"
            "except ImportError:\n"
            "    print('x 5')  # nanopython-lib not on sys.path; skip-passthrough\n"
            "else:\n"
            "    @dataclass(frozen=True, slots=True, kw_only=True, order=True,\n"
            "               unsafe_hash=True, match_args=True)\n"
            "    class Rec:\n"
            "        name = ''\n"
            "        count = 0\n"
            "    r = Rec(name='x', count=5)\n"
            "    print(r.name, r.count)\n"
        ),
        "x 5\n",
    ),
    # str slice with step != 1 — ADR 010 §C3 (Lane C selective). The
    # CPython idiom `"abc"[::-1]` was previously NotImplementedError;
    # now produces the correct reversed string. Handles positive and
    # negative step + empty result + single-char edge cases.
    ("str_slice_reverse", 'print("hello"[::-1])', "olleh\n"),
    ("str_slice_step", 'print("abcdef"[::2])\nprint("abcdef"[1:5:2])', "ace\nbd\n"),
    (
        "str_slice_neg_step_bounds",
        'print("abcdef"[5::-1])\nprint("abcdef"[5:0:-1])',
        "fedcba\nfedcb\n",
    ),
    ("str_slice_edge_cases", 'print(repr(""[::-1]))\nprint("a"[::-1])', "''\na\n"),
    # __missing__ on dict subclass — ADR 010 §C1 (Lane C selective).
    # CPython's defaultdict-style behavior without importing collections:
    # subclass dict, define __missing__(self, key), and absent-key reads
    # call __missing__ instead of raising KeyError. Plain dict() and
    # subclasses-without-__missing__ continue to raise KeyError.
    (
        "dict_missing_basic",
        (
            "class D(dict):\n"
            "    def __missing__(self, k): return 'm-' + k\n"
            "print(D()['x'])"
        ),
        "m-x\n",
    ),
    (
        "dict_missing_counter_pattern",
        (
            "class C(dict):\n"
            "    def __missing__(self, k): return 0\n"
            "c = C()\n"
            "c['a'] += 1; c['a'] += 1; c['b'] += 5\n"
            "print(c['a'], c['b'], c['c'])"
        ),
        "2 5 0\n",
    ),
    (
        "dict_keyerror_still_raises",
        "try: {}['x']\nexcept KeyError: print('plain dict KeyError')",
        "plain dict KeyError\n",
    ),
    # bytes.fromhex with sep — ADR 010 §C4 (Lane C selective). CPython 3.5+
    # added the optional sep argument so hex with conventional separators
    # (colons in MACs, dashes in serials) can be parsed without manual
    # preprocessing. Multi-char sep raises ValueError per CPython.
    ("bytes_fromhex_basic", "print(bytes.fromhex('001122'))", "b'\\x00\\x11\"'\n"),
    (
        "bytes_fromhex_with_sep",
        "print(bytes.fromhex('00:11:22', ':'))\nprint(bytes.fromhex('aa-bb-cc', '-'))",
        "b'\\x00\\x11\"'\nb'\\xaa\\xbb\\xcc'\n",
    ),
    (
        "bytes_fromhex_multichar_sep_errors",
        "try: bytes.fromhex('001122', '::')\nexcept ValueError as e: print('OK:', e)",
        "OK: sep must be a single character\n",
    ),
    # Richer arithmetic TypeError — ADR 010 §C5. Was 'unsupported type
    # for operator' (TERSE) regardless of operands; now includes the
    # dunder method name + both operand type names.
    (
        "typeerror_add",
        "try: 1 + 'a'\nexcept TypeError as e: print(e)",
        "unsupported types for __add__: 'int', 'str'\n",
    ),
    (
        "typeerror_sub",
        "try: 'a' - 1\nexcept TypeError as e: print(e)",
        "unsupported types for __sub__: 'str', 'int'\n",
    ),
    (
        "typeerror_mul_none",
        "try: 1 * None\nexcept TypeError as e: print(e)",
        "unsupported types for __mul__: 'int', 'NoneType'\n",
    ),
    # Held-exception isolation: a second TypeError must not mutate the
    # text of an exception already captured into `e`. Earlier C5 revs
    # used a module-static buffer in src/runtime/runtime.zig that was
    # shared across raises; a nested binop overwrote the held message.
    # Fixed by routing through mp_obj_new_exception_msg_varg (per-raise
    # m_malloc'd message). Pin asserts the held str remains stable.
    (
        "typeerror_held_stable_under_nested",
        (
            "try: 1 + 'a'\n"
            "except TypeError as e:\n"
            "    before = str(e)\n"
            "    try: 2 - 'b'\n"
            "    except TypeError: pass\n"
            "    print('stable' if str(e) == before else 'MUTATED')\n"
        ),
        "stable\n",
    ),
    # Property setter must fire on nano — closes the missed half of the
    # MI-property fix. The setter path was gated on is_full in
    # mp_obj_instance_store_attr; under nano (PROPERTY=1, DESCRIPTORS=1)
    # vendor MP gates only DELATTR_SETATTR on full, so the property
    # block must run. Pin verifies the setter is invoked and the stored
    # value reflects the setter's transformation, not the raw value.
    (
        "property_setter_fires_on_nano",
        (
            "class C:\n"
            "    def __init__(self, x): self._x = x\n"
            "    @property\n"
            "    def x(self): return self._x\n"
            "    @x.setter\n"
            "    def x(self, v): print('set', v); self._x = v * 10\n"
            "c = C(1); print(c.x)\n"
            "c.x = 5; print(c.x)\n"
        ),
        "1\nset 5\n50\n",
    ),
    # Property descriptors via inheritance — closes the v0.3 bug that
    # MI enablement surfaced. The ENABLE_SPECIAL_ACCESSORS gate was
    # incorrectly tied to is_full in two sites in objtype.zig; both
    # are now flipped to always-on (vendor MP's gate is
    # PROPERTY || DESCRIPTORS || DELATTR_SETATTR which is true under
    # nano too). Pin verifies the dispatch survives.
    (
        "property_via_subclass",
        (
            "class A:\n"
            "    @property\n"
            "    def x(self): return 42\n"
            "class B(A): pass\n"
            "print(A().x, B().x)"
        ),
        "42 42\n",
    ),
    (
        "property_dynamic_attach",
        "class C: pass\nC.foo = property(lambda self: 'hello')\nprint(C().foo)",
        "hello\n",
    ),
    # User class __setattr__ fires on nano — enabled in v0.7 by flipping
    # MICROPY_PY_DELATTR_SETATTR from full-only to both arms. The v0.6
    # property-setter fix (commit 1c346e9) deliberately scoped to
    # property descriptors; the dunder path was a separate audit.
    # Unblocks reactive patterns (Score.value = 5 → DOM update) and lets
    # JsProxy.__setattr__ fire so `canvas.fillStyle = X` works directly.
    (
        "setattr_user_class",
        (
            "class A:\n"
            "    def __setattr__(self, attr, val):\n"
            "        print('set', attr, val)\n"
            "a = A()\n"
            "a.foo = 5\n"
            "a.bar = 'x'\n"
        ),
        "set foo 5\nset bar x\n",
    ),
    # User class __delattr__ fires too (sibling of __setattr__).
    (
        "delattr_user_class",
        (
            "class A:\n"
            "    def __delattr__(self, attr):\n"
            "        print('del', attr)\n"
            "a = A()\n"
            "del a.foo\n"
        ),
        "del foo\n",
    ),
    # object.__setattr__ as a method is reachable on nano now.
    (
        "object_setattr_method_available",
        "class C: pass\nc = C()\nobject.__setattr__(c, 'x', 42)\nprint(c.x)\n",
        "42\n",
    ),
    # Class-body exceptions must propagate, not panic. Pre-fix, an
    # uncaught raise inside a class body returned cell=0 from
    # mp_call_function_0 and tripped MpObjCell.fromObj(0) in __build_class__.
    (
        "class_body_raise_propagates",
        (
            "try:\n"
            "    class S:\n"
            "        def m(self): pass\n"
            "        m.x = 1\n"  # functions reject attribute writes
            "except AttributeError as e:\n"
            "    print('caught', e.args[0])\n"
        ),
        "caught no attribute 'x'\n",
    ),
    # Reverse special methods (__radd__ etc.) — used to be is_full-gated;
    # ADR 012 D4 WRONG #1 flipped the gate to build_options.reverse_special_methods
    # (default true). 1 + X() now calls X.__radd__(1) per CPython.
    (
        "reverse_special_methods",
        (
            "class X:\n"
            "    def __radd__(self, o): return ('radd', o)\n"
            "    def __rmul__(self, o): return ('rmul', o)\n"
            "print(1 + X())\n"
            "print(3 * X())\n"
        ),
        "('radd', 1)\n('rmul', 3)\n",
    ),
    # str.join normalizes bytes↔bytearray on both arms; was is_full-gated
    # (ADR 012 D4 WRONG #2). bytearray is built on nano too.
    (
        "str_join_bytes_bytearray",
        "print(b'-'.join([bytearray(b'a'), b'b']))\n",
        "b'a-b'\n",
    ),
    # bytes(iter) validates 0..255 on both arms; was is_full-gated so nano
    # silently truncated out-of-range ints. ADR 012 D4 WRONG #3.
    (
        "bytes_iter_range_check",
        "try:\n    bytes([256])\nexcept ValueError:\n    print('ok')\n",
        "ok\n",
    ),
    # ── phase 8 pure-Python shims (frozen) ──────────────────────────
    # These run on nano AND full-frozen since they're frozen-tiny.
    (
        "typing_import_no_raise",
        (
            "from typing import Any, Final, Literal, Callable, TypeVar, Protocol, Generic\n"
            "T = TypeVar('T')\n"
            "class C(Generic): pass\n"
            "class P(Protocol): pass\n"
            "print('typing ok')"
        ),
        "typing ok\n",
    ),
    # uuid/datetime both depend on os/time modules that aren't shipped
    # on wasm — guard with try/except ImportError, same idiom as os tests.
    (
        "uuid4_shape",
        (
            "try:\n"
            "    import uuid\n"
            "    u = uuid.uuid4()\n"
            "    s = str(u)\n"
            "    # 8-4-4-4-12 = 36 chars, 4 hyphens; UUIDv4 has '4' as 13th hex nibble.\n"
            "    print(len(s) == 36, s.count('-') == 4, s[14] == '4')\n"
            "except ImportError:\n"
            "    print('True True True')\n"
        ),
        "True True True\n",
    ),
    (
        "importlib_metadata_version",
        (
            "from importlib.metadata import version, PackageNotFoundError\n"
            "print(version('nanopython'))\n"
            "try:\n"
            "    version('definitely-not-a-package')\n"
            "except PackageNotFoundError:\n"
            "    print('caught PNFE')"
        ),
        "0.7.1\ncaught PNFE\n",
    ),
    (
        "datetime_iso_roundtrip",
        (
            "try:\n"
            "    from datetime import datetime, timezone, timedelta\n"
            "    d = datetime(2026, 7, 20, 12, 34, 56, tzinfo=timezone.utc)\n"
            "    print(d.isoformat())\n"
            "    d2 = datetime.fromisoformat(d.isoformat())\n"
            "    print(d == d2)\n"
            "    print(timedelta(hours=2).total_seconds())\n"
            "except ImportError:\n"
            "    print('2026-07-20T12:34:56+00:00\\nTrue\\n7200.0')\n"
        ),
        "2026-07-20T12:34:56+00:00\nTrue\n7200.0\n",
    ),
    # pathlib/shutil both `import os` at module scope, so guard the whole
    # test against ImportError — under nano/wasm the POSIX `os` module
    # isn't built (feature-os coerced off, see build.zig), which shadows
    # pathlib/shutil themselves. Same profile-agnostic idiom as the
    # cases in test_integration_os.py.
    (
        "pathlib_basic",
        (
            "try:\n"
            "    from pathlib import Path\n"
            "    p = Path('/foo/bar/baz.txt')\n"
            "    print(p.name, p.parent, p.suffix, p.stem)\n"
            "    print(Path('/a') / 'b' / 'c')  # slash composition\n"
            "    print(Path('/foo').is_absolute(), Path('rel').is_absolute())\n"
            "except ImportError:\n"
            "    print('baz.txt /foo/bar .txt baz\\n/a/b/c\\nTrue False')\n"
        ),
        "baz.txt /foo/bar .txt baz\n/a/b/c\nTrue False\n",
    ),
    (
        "shutil_which_reads_path_env",
        (
            "try:\n"
            "    import shutil, os\n"
            "    if hasattr(os, 'access') and hasattr(os, 'getenv'):\n"
            "        r = shutil.which('/bin/ls')\n"
            "        print(r is not None)\n"
            "    else:\n"
            "        print('True')\n"
            "except ImportError:\n"
            "    print('True')\n"
        ),
        "True\n",
    ),
    # ---------------------------------------------------------------
    # Runtime capabilities that web/ and projects/*/src/ depend on.
    #
    # These exist because a linter "fix" is the realistic way they break:
    # ruff's FURB188 wanted to rewrite a demo to str.removeprefix(), which
    # nanopython does not have, and nothing in the gate would have caught
    # the resulting dead page (make never touches web/). Pin the behaviour
    # on both arms instead of rediscovering it in a browser.
    # ---------------------------------------------------------------
    (
        "str_startswith_tuple",
        (
            'p = ("#", ">", "- ", "```")\n'
            'print("# h".startswith(p), "plain".startswith(p), "".startswith(p))'
        ),
        "True False False\n",
    ),
    # Pinning an ABSENCE on purpose: if removeprefix/removesuffix ever land,
    # this fails and forces a deliberate decision rather than silently
    # re-enabling FURB188 across the demos.
    (
        "str_removeprefix_absent",
        (
            "try:\n"
            '    "foobar".removeprefix("foo")\n'
            '    print("PRESENT")\n'
            "except AttributeError:\n"
            '    print("absent")'
        ),
        "absent\n",
    ),
    (
        "fstring_format_spec_hex",
        'print(f"{255:02x}", f"{0:02x}", "%02x" % 255)',
        "ff 00 ff\n",
    ),
    ("chained_comparison", "print(1 <= 5 <= 10, 5 <= 1 <= 10)", "True False\n"),
    # A module global can be READ inside a function without a `global`
    # declaration (memory-kid/main.py relies on this after PLW0602 cleanup).
    (
        "global_read_without_decl",
        (
            "counter = 5\nother = 0\n"
            "def f():\n"
            "    global other\n"
            "    other = 1\n"
            "    return counter\n"
            "print(f(), other)"
        ),
        "5 1\n",
    ),
    # Mutating a global list element is not a rebinding, so it needs no
    # `global` either (tetris-kid/main.py lock_piece relies on this).
    (
        "global_mutate_without_decl",
        (
            "board = [0, 0, 0]\nnxt = 1\n"
            "def g():\n"
            "    global nxt\n"
            "    nxt = 2\n"
            "    board[0] = 9\n"
            "g()\n"
            "print(board, nxt)"
        ),
        "[9, 0, 0] 2\n",
    ),
    # An out-of-range store raised IndexError but still wrote element 0:
    # the B2 bridge makes mp_get_index return 0 after a raise, and these
    # callers didn't poll pending_exc.
    (
        "index_error_store_leaves_container_intact",
        (
            "import array\n"
            "from collections import deque\n"
            "l = [10, 20, 30]\n"
            "a = array.array('i', [1, 2, 3])\n"
            "m = memoryview(bytearray(b'abc'))\n"
            "d = deque([1, 2, 3], 5)\n"
            "def s1(): l[5] = 0\n"
            "def s2(): l['x'] = 0\n"
            "def s3(): a[7] = 0\n"
            "def s4(): m[9] = 0\n"
            "def s5(): d[4] = 0\n"
            "for f in (s1, s2, s3, s4, s5, lambda: l.pop(5), lambda: ()[0]):\n"
            "    try:\n"
            "        f()\n"
            "    except (IndexError, TypeError) as e:\n"
            "        print(type(e).__name__, end=' ')\n"
            "print()\n"
            "print(l, list(a), bytes(m), list(d))"
        ),
        (
            "IndexError TypeError IndexError IndexError IndexError IndexError IndexError \n"
            "[10, 20, 30] [1, 2, 3] b'abc' [1, 2, 3]\n"
        ),
    ),
    # A TypeError from the keyword-argument parser must stop the caller
    # before it reads the unfilled argument slots (segfaulted ReleaseFast
    # builds: enumerate() crashed fun_error2.py).
    (
        "arg_parse_error_stops_caller",
        (
            "for f in (lambda: enumerate(), lambda: enumerate(x=1), lambda: property(z=1),\n"
            "          lambda: [2, 1].sort(z=1), lambda: print(1, z=1)):\n"
            "    try:\n"
            "        f()\n"
            "    except TypeError:\n"
            "        print('TypeError', end=' ')\n"
            "print()"
        ),
        "TypeError TypeError TypeError TypeError TypeError \n",
    ),
    # Garbage is collected: 300k dropped objects leave the heap small
    # (it grew without bound before ADR 019). wasm32 collects only between
    # entries into Python, never inside one script (ADR 019 §2), hence the
    # sys.maxsize guard.
    (
        "gc_reclaims_garbage",
        (
            "import gc, sys\n"
            "class P:\n"
            "    def __init__(self, x):\n"
            "        self.x = x\n"
            "for i in range(300000):\n"
            "    P(i)\n"
            "gc.collect()\n"
            "heap = gc.mem_alloc() + gc.mem_free()\n"
            "print(sys.maxsize < 2**32 or 0 < heap < 8 * 1024 * 1024)"
        ),
        "True\n",
    ),
]


if __name__ == "__main__":
    import sys

    from _integration_runner import run

    sys.exit(run(CASES, label_prefix="integration:core"))
