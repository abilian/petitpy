#!/usr/bin/env python3
"""Which Python constructs each front-end compiles, and each VM then runs.

A single front-end cannot tell two failure classes apart. If `zigpy-compile`
refuses a construct, that says nothing about whether the VM could have executed
the bytecode. pyfront (projects/pyfront) parses with CPython's `ast`, so it
accepts everything the language has and will emit bytecode for constructs the
Zig parser rejects. Running that bytecode separates:

  FRONT-END GAP   valid Python; a VM executes it; only zigpy-compile refuses.
  BACK-END GAP    the bytecode is well formed and the VM refuses it.
  DIVERGENCE      the two VMs disagree, or a VM disagrees with CPython.

Columns:

  zigpy      zigpy-compile SOURCE -> .mpy           (the Zig front-end)
  pyfront    pyfront SOURCE -> .mpy                 (the Python front-end)
  vm         petitpy-vm                          (the Zig back-end)
  upy        vendor micropython                     (the C back-end)
  via        which .mpy the back-ends ran: z, p, or zp when both were tried

Each back-end runs EVERY .mpy that exists for the construct, so a construct only
one front-end compiles still gets its back-ends measured. The results are
reported in one column each because they have never differed by front-end: a
disagreement would mean one front-end emits bytecode the other does not, which
is reported separately as FRONT-END SPLIT rather than given standing columns.
That equivalence is separately gated by tools/quadrant_gate.py (ADR 017).

CPython's own output is the oracle: `yes` means the program printed what CPython
printed, not merely that it loaded.

Back-end cells carry three outcomes, because "did not print what CPython
prints" and "refused to run" are different findings:

  ok    ran, and printed exactly what CPython printed
  diff  ran to completion, printed something else
  FAIL  non-zero exit: refused the bytecode, raised, or crashed
  -     NOT MEASURED. No front-end produced a .mpy, so the question was never
        put. This is not the same as a failure.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ZIGPY = ROOT / "zig-out" / "bin" / "zigpy-compile"
VM = ROOT / "zig-out" / "bin" / "petitpy-vm"
UPY = ROOT / "vendor" / "micropython" / "ports" / "unix" / "build-standard" / "micropython"
PYFRONT = ROOT / "projects" / "pyfront"
KNOWN = ROOT / "corpus" / "capability-known.txt"

#: name -> a program that prints something deterministic.
CONSTRUCTS: dict[str, str] = {
    "assignment": "x = 1\nprint(x)\n",
    "arithmetic": "print(2 + 3 * 4)\n",
    "if_else": "x = 5\nif x > 3:\n    print('big')\nelse:\n    print('small')\n",
    "while_loop": "i = 0\nwhile i < 3:\n    i += 1\nprint(i)\n",
    "for_loop": "t = 0\nfor i in range(4):\n    t += i\nprint(t)\n",
    "function": "def f(a, b):\n    return a + b\nprint(f(1, 2))\n",
    "closure": "def o(n):\n    def i():\n        return n\n    return i()\nprint(o(7))\n",
    "class": "class C:\n    def m(self):\n        return 3\nprint(C().m())\n",
    "list_comp": "print([x * 2 for x in range(3)])\n",
    "dict_comp": "print(sorted({k: k for k in range(2)}.items()))\n",
    "generator": "def g():\n    yield 1\n    yield 2\nprint(list(g()))\n",
    "genexp": "print(sum(x for x in range(4)))\n",
    "try_except": "try:\n    raise ValueError()\nexcept ValueError:\n    print('caught')\n",
    "with_stmt": (
        "class M:\n"
        "    def __enter__(self):\n        return 1\n"
        "    def __exit__(self, a, b, c):\n        return False\n"
        "with M() as v:\n    print(v)\n"
    ),
    "fstring": "n = 2\nprint(f'n={n}')\n",
    "walrus": "if (n := 4) > 3:\n    print(n)\n",
    "chained_compare": "print(1 < 2 < 3)\n",
    "unpacking": "a, b = 1, 2\nprint(a, b)\n",
    "nonlocal_stmt": (
        "def o():\n    n = 1\n    def i():\n        nonlocal n\n        n = 2\n"
        "    i()\n    return n\nprint(o())\n"
    ),
    "lambda_expr": "print((lambda x: x + 1)(1))\n",
    "kwargs_call": "def f(a, b):\n    return a - b\nprint(f(b=1, a=5))\n",
    "star_args_def": "def f(*a):\n    return len(a)\nprint(f(1, 2, 3))\n",
    "default_args": "def f(a, b=2):\n    return a + b\nprint(f(1))\n",
    "decorator": "def d(f):\n    return f\n@d\ndef g():\n    return 1\nprint(g())\n",
    "try_finally": "try:\n    x = 1\nfinally:\n    print('fin')\n",
    "match_stmt": "x = 1\nmatch x:\n    case 1:\n        print('one')\n    case _:\n        print('other')\n",
    "match_or": "x = 2\nmatch x:\n    case 1 | 2:\n        print('low')\n    case _:\n        print('hi')\n",
    "match_sequence": "x = [1, 2]\nmatch x:\n    case [a, b]:\n        print(a + b)\n    case _:\n        print('no')\n",
    "match_guard": "x = 9\nmatch x:\n    case n if n > 5:\n        print('big', n)\n    case _:\n        print('small')\n",
    "match_star": "x = [1, 2, 3]\nmatch x:\n    case [a, *rest]:\n        print(a, rest)\n    case _:\n        print('no')\n",
    "match_mapping": "x = {'k': 1, 'j': 2}\nmatch x:\n    case {'k': v}:\n        print('k is', v)\n    case _:\n        print('no')\n",
    "fstring_spec": "x = 5\nprint(f'{x:>3}')\n",
    "multi_for_comp": "print([x + y for x in range(2) for y in range(2)])\n",
    "set_literal": "print(len({1, 2, 2}))\n",
    "slice_step": "print([1,2,3,4,5][::2])\n",
    "star_call": "def f(a, b):\n    return a + b\nargs = (1, 2)\nprint(f(*args))\n",
    "async_def": "async def f():\n    return 1\nprint(type(f).__name__)\n",
    # ── data model ──────────────────────────────────────────────────
    "dict_methods": "d = {'a': 1}\nprint(sorted(d.keys()), sorted(d.values()), d.get('z', 9))\n",
    "list_methods": "L = [3, 1, 2]\nL.sort()\nL.append(4)\nprint(L, len(L), L.index(2))\n",
    "str_methods": "s = ' Ab '\nprint(s.strip(), s.lower().strip(), 'a,b'.split(','))\n",
    "tuple_unpack_swap": "a, b = 1, 2\na, b = b, a\nprint(a, b)\n",
    "nested_index": "m = {'k': [1, {'j': 2}]}\nprint(m['k'][1]['j'])\n",
    "negative_index": "L = [1, 2, 3]\nprint(L[-1], L[-2:])\n",
    "slice_assign": "L = [1, 2, 3, 4]\nL[1:3] = [9]\nprint(L)\n",
    "bytes_literal": "b = b'ab'\nprint(len(b), b[0])\n",
    "int_ops": "print(7 // 2, -7 // 2, 7 % 3, -7 % 3, 2 ** 8)\n",
    "float_ops": "print(1 / 2, 7 / 2, round(2.5), abs(-1.5))\n",
    "bool_coercion": "print(bool(0), bool(''), bool([]), bool([0]))\n",
    "comparison_chain_mixed": "print(1 == 1.0, 'a' < 'b', [1] == [1])\n",
    # ── classes and protocols ───────────────────────────────────────
    "class_inheritance": (
        "class A:\n    def f(self):\n        return 'A'\n"
        "class B(A):\n    def f(self):\n        return 'B' + A.f(self)\n"
        "print(B().f())\n"
    ),
    "class_super": (
        "class A:\n    def f(self):\n        return 1\n"
        "class B(A):\n    def f(self):\n        return super().f() + 1\n"
        "print(B().f())\n"
    ),
    "dunder_str": (
        "class C:\n    def __str__(self):\n        return 'C!'\n"
        "print(str(C()))\n"
    ),
    "dunder_eq_len": (
        "class C:\n    def __len__(self):\n        return 3\n"
        "    def __eq__(self, o):\n        return True\n"
        "print(len(C()), C() == 1)\n"
    ),
    "class_attr_mutation": (
        "class C:\n    v = 1\nc = C()\nc.v = 2\nprint(C.v, c.v)\n"
    ),
    "property_like": (
        "class C:\n    @property\n    def v(self):\n        return 7\n"
        "print(C().v)\n"
    ),
    # ── control flow ────────────────────────────────────────────────
    "nested_loops_break": (
        "t = 0\nfor i in range(3):\n    for j in range(3):\n"
        "        if j == 2:\n            break\n        t += 1\nprint(t)\n"
    ),
    "while_else": "i = 0\nwhile i < 2:\n    i += 1\nelse:\n    print('done', i)\n",
    "try_nested": (
        "try:\n    try:\n        raise ValueError('v')\n"
        "    except KeyError:\n        print('wrong')\n"
        "except ValueError:\n    print('outer')\n"
    ),
    "raise_from_except": (
        "try:\n    raise ValueError('a')\nexcept ValueError as e:\n    print('got', e)\n"
    ),
    "generator_send_less": (
        "def g():\n    for i in range(3):\n        yield i * i\n"
        "print(list(g()))\n"
    ),
    # ── scoping ─────────────────────────────────────────────────────
    "closure_counter": (
        "def make():\n    n = 0\n    def inc():\n        nonlocal n\n        n += 1\n"
        "        return n\n    return inc\nc = make()\nprint(c(), c(), c())\n"
    ),
    "global_mutation": "g = 0\ndef f():\n    global g\n    g += 1\nf()\nf()\nprint(g)\n",
    "comprehension_scope": "x = 'outer'\nprint([x for x in range(2)], x)\n",
    # ── stdlib reach ────────────────────────────────────────────────
    "builtins_seq": "print(sorted([3,1,2]), sum([1,2,3]), min(3,1), max(3,1))\n",
    "builtins_map_filter": "print(list(map(lambda x: x*2, [1,2])), list(filter(None, [0,1])))\n",
    "enumerate_zip": "print(list(enumerate('ab')), list(zip([1,2], 'ab')))\n",
    "isinstance_checks": "print(isinstance(1, int), isinstance('a', str), isinstance([], list))\n",
}


def run(argv: list[str], timeout: int = 20, env: dict | None = None) -> tuple[int, bytes]:
    try:
        p = subprocess.run(
            argv, capture_output=True, timeout=timeout, check=False, env=env
        )
        return p.returncode, p.stdout
    except (subprocess.TimeoutExpired, OSError):
        return -1, b""


def run_upy(mpy: Path) -> tuple[int, bytes]:
    """Vendor MicroPython reads a .mpy given as argv[1] as *source*; a
    precompiled module has to be imported. Same shape tools/compile-exec-test.py
    uses."""
    import os

    env = dict(os.environ)
    env["MICROPYPATH"] = str(mpy.parent)
    return run([str(UPY), "-m", mpy.stem], env=env)


def compile_zigpy(src: Path, out: Path) -> bool:
    return run([str(ZIGPY), "-o", str(out), str(src)])[0] == 0 and out.exists()


def compile_pyfront(src: Path, out: Path) -> bool:
    """Exit 2 is a refusal by name, which is what this matrix measures.
    Any other non-zero exit is pyfront itself being broken — a stale
    astero import, a crash — and that has to stop the run. Read as a
    plain bool it looks like every construct is a front-end gap, and the
    gate passes, because a front-end gap is not a gated category."""
    argv = ["uv", "run", "--project", str(PYFRONT), "pyfront", str(src), "-o", str(out)]
    p = subprocess.run(argv, capture_output=True, timeout=60, check=False)
    if p.returncode not in (0, 2):
        sys.exit(
            f"pyfront is broken, not refusing: exit {p.returncode} on {src.name}\n"
            + p.stderr.decode(errors="replace").strip()
        )
    return p.returncode == 0 and out.exists()


def outcome(rc: int, out: bytes, want: bytes) -> str:
    """ok / diff / FAIL — a wrong answer and a refusal are different findings."""
    if rc != 0:
        return "FAIL"
    return "ok" if out == want else "diff"


def check(
    mpy: Path, compiled: bool, want: bytes, have_upy: bool
) -> tuple[str | None, str | None]:
    """Run both back-ends on one .mpy. (None, None) when it was never produced."""
    if not compiled:
        return None, None
    vm = outcome(*run([str(VM), str(mpy)]), want)
    upy = outcome(*run_upy(mpy), want) if have_upy else None
    return vm, upy


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--markdown", action="store_true", help="emit a markdown table")
    ap.add_argument(
        "--gate", action="store_true",
        help="exit non-zero on a back-end gap, a back-end split, or a "
             "front-end split; the known findings are baselined in "
             "corpus/capability-known.txt",
    )
    args = ap.parse_args(argv)

    for tool, label in ((ZIGPY, "zigpy-compile"), (VM, "petitpy-vm")):
        if not tool.exists():
            print(f"error: {tool.relative_to(ROOT)} not built", file=sys.stderr)
            return 2
    have_upy = UPY.exists()

    tmp = Path(tempfile.mkdtemp())
    # The .mpy lives in its own directory: MicroPython's `-m name` searches
    # MICROPYPATH and prefers a .py, so leaving the source alongside makes the
    # vendor column measure the source rather than the bytecode.
    mpydir = tmp / "mpy"
    mpydir.mkdir()
    rows = []
    for name, source in CONSTRUCTS.items():
        src = tmp / f"{name}.py"
        src.write_text(source)
        want = run([sys.executable, str(src)])[1]

        zig_mpy = mpydir / f"z_{name}.mpy"
        zig_ok = compile_zigpy(src, zig_mpy)
        py_mpy = mpydir / f"{name}.mpy"
        py_ok = compile_pyfront(src, py_mpy)

        vm_z, upy_z = check(zig_mpy, zig_ok, want, have_upy)
        vm_p, upy_p = check(py_mpy, py_ok, want, have_upy)
        split = (vm_z is not None and vm_p is not None
                 and (vm_z != vm_p or upy_z != upy_p))
        via = "".join(c for c, ok in (("z", zig_ok), ("p", py_ok)) if ok) or "-"
        rows.append((name, zig_ok, py_ok, vm_z or vm_p, upy_z or upy_p, via, split))

    def mark(v: object) -> str:
        if v is None:
            return "-"
        if v is True:
            return "yes"
        if v is False:
            return "NO"
        return str(v)

    if args.markdown:
        print("| construct | zigpy | pyfront | vm | upy | via |")
        print("|---|---|---|---|---|---|")
        for name, z, p, v, u, via, _ in rows:
            print(f"| `{name}` | {mark(z)} | {mark(p)} | {mark(v)} | {mark(u)} | {via} |")
    else:
        print(f"{'construct':22s} {'zigpy':>6s} {'pyfront':>8s} {'vm':>5s} "
              f"{'upy':>5s} {'via':>4s}")
        for name, z, p, v, u, via, _ in rows:
            print(f"{name:22s} {mark(z):>6s} {mark(p):>8s} {mark(v):>5s} "
                  f"{mark(u):>5s} {via:>4s}")

    def seen(row) -> set[str]:
        return {v for v in row[3:5] if v is not None}

    front = [r[0] for r in rows if not r[1] and r[2] and "ok" in seen(r)]
    back = [r[0] for r in rows if "FAIL" in seen(r)]
    diverge = [r[0] for r in rows if len(seen(r)) > 1]
    cpython_diff = [r[0] for r in rows if seen(r) == {"diff"}]
    unmeasured = [r[0] for r in rows if not seen(r)]
    fe_split = [r[0] for r in rows if r[6]]
    print()
    print(f"FRONT-END GAP  (pyfront + a VM run it; zigpy-compile will not): {len(front)}")
    for n in front:
        print(f"    {n}")
    print(f"BACK-END GAP   (a back-end refused bytecode a front-end made): {len(back)}")
    for n in back:
        print(f"    {n}")
    print(f"BACK-END SPLIT (the back-ends disagree with each other):       {len(diverge)}")
    for n in diverge:
        print(f"    {n}")
    print(f"CPYTHON DIFF   (back-ends agree, and differ from CPython):     {len(cpython_diff)}")
    for n in cpython_diff:
        print(f"    {n}")
    print(f"FRONT-END SPLIT (the two front-ends' bytecode behaves differently): {len(fe_split)}")
    for n in fe_split:
        print(f"    {n}")
    print(f"NOT MEASURED   (no front-end produced a .mpy to run):          {len(unmeasured)}")
    for n in unmeasured:
        print(f"    {n}")

    if not args.gate:
        return 0

    # Strict bidirectional against the baseline, like the other gates: a new
    # finding fails, and a baselined finding that has gone away fails too, so
    # closing one means deleting its line in the same commit.
    baseline = KNOWN.read_text().splitlines() if KNOWN.exists() else []
    known = {
        line.split("\t")[0].strip()
        for line in baseline
        if line.strip() and not line.startswith("#")
    }
    #: Only the categories that mean something is wrong. A front-end gap is a
    #: measurement, not a defect: it is the matrix doing its job.
    findings = set(back) | set(diverge) | set(fe_split)
    new = sorted(findings - known)
    gone = sorted(known - findings)
    print()
    if new:
        print(f"GATE: {len(new)} finding(s) not in {KNOWN.name}:")
        for n in new:
            print(f"    {n}")
    if gone:
        print(f"GATE: {len(gone)} baselined finding(s) no longer reproduce:")
        for n in gone:
            print(f"    {n}")
        print("  Remove them from the list in the same commit that fixed them.")
    if not new and not gone:
        print("GATE: GREEN (matches the baseline exactly)")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
