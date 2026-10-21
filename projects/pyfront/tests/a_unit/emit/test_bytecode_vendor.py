"""Every opcode constant must match vendor's bc0.h.

Three of these were wrong when first written, because they were guessed from
the neighbouring lines rather than read. The bytecode they produced was valid
enough to load and then failed at runtime with `object not callable`, which
points nowhere near the actual mistake. Parsing the header is cheap and the
failure mode is not.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from pyfront.emit import bytecode as bc

BC0 = Path(__file__).resolve().parents[5] / "vendor/micropython_embed/py/bc0.h"


#: Checked automatically: every `NAME = 0x..` in bytecode.py must equal
#: MP_BC_NAME in bc0.h. No hand-maintained list to fall out of date.
def emitted_names() -> list[str]:
    return [
        n
        for n in dir(bc)
        if n.isupper()
        and isinstance(getattr(bc, n), int)
        and not n.startswith(("BASE_", "SCOPE_FLAG_", "MPY_", "SMALL_INT"))
        and not n.endswith(("_OPS", "_MULTI_NUM", "_NSLOTS"))
        and n != "EXCEPTION_MATCH"
    ]


def vendor_opcodes() -> dict[str, int]:
    """Evaluate the `#define MP_BC_*` lines, resolving the BASE_* names."""
    if not BC0.exists():
        pytest.skip(f"{BC0} not present (needs `make port`)")
    text = BC0.read_text()
    env: dict[str, int] = {}
    define = re.compile(r"^#define\s+(MP_BC_\w+)\s+\(([^)]*)\)", re.MULTILINE)
    for _ in range(3):  # a couple of passes: bases resolve before their users
        for name, expr in define.findall(text):
            try:
                env[name] = int(eval(expr, {"__builtins__": {}}, env))
            except (NameError, TypeError, SyntaxError):
                continue
    return env


def test_every_opcode_matches_vendor() -> None:
    vendor = vendor_opcodes()
    wrong, unknown = [], []
    names = emitted_names()
    assert len(names) > 60, f"expected the full opcode table, found {len(names)}"
    for ours in names:
        theirs = f"MP_BC_{ours}"
        if theirs not in vendor:
            unknown.append(ours)
            continue
        mine = getattr(bc, ours)
        if mine != vendor[theirs]:
            wrong.append(f"{ours}: pyfront {mine:#04x}, vendor {vendor[theirs]:#04x}")
    assert not unknown, "not in bc0.h: " + ", ".join(sorted(unknown))
    assert not wrong, "opcode drift:\n  " + "\n  ".join(wrong)


def test_binary_op_numbering_matches_runtime0() -> None:
    """MP_BINARY_OP_* are an enum, so position is the value."""
    header = BC0.parent / "runtime0.h"
    if not header.exists():
        pytest.skip("runtime0.h not present")
    names = re.findall(r"^\s*(MP_BINARY_OP_\w+),", header.read_text(), re.MULTILINE)
    order = {n: i for i, n in enumerate(names)}
    for op, value in bc.BINARY_OPS.items():
        key = {
            "Lt": "LESS",
            "Gt": "MORE",
            "Eq": "EQUAL",
            "LtE": "LESS_EQUAL",
            "GtE": "MORE_EQUAL",
            "NotEq": "NOT_EQUAL",
            "In": "IN",
            "Is": "IS",
            "BitOr": "OR",
            "BitXor": "XOR",
            "BitAnd": "AND",
            "LShift": "LSHIFT",
            "RShift": "RSHIFT",
            "Add": "ADD",
            "Sub": "SUBTRACT",
            "Mult": "MULTIPLY",
            "MatMult": "MAT_MULTIPLY",
            "FloorDiv": "FLOOR_DIVIDE",
            "Div": "TRUE_DIVIDE",
            "Mod": "MODULO",
            "Pow": "POWER",
        }[op]
        assert order[f"MP_BINARY_OP_{key}"] == value, f"{op} -> {key}"


def test_exception_match_index_matches_runtime0() -> None:
    header = BC0.parent / "runtime0.h"
    if not header.exists():
        pytest.skip("runtime0.h not present")
    names = re.findall(r"^\s*(MP_BINARY_OP_\w+),", header.read_text(), re.MULTILINE)
    assert names.index("MP_BINARY_OP_EXCEPTION_MATCH") == bc.EXCEPTION_MATCH


def test_unary_op_numbering_matches_runtime0() -> None:
    """MP_UNARY_OP_* are an enum too. USub was wrong here, and the symptom was
    `-5` evaluating to `-6`, i.e. it had been emitting INVERT."""
    header = BC0.parent / "runtime0.h"
    if not header.exists():
        pytest.skip("runtime0.h not present")
    names = re.findall(r"^\s*(MP_UNARY_OP_\w+),", header.read_text(), re.MULTILINE)
    order = {n: i for i, n in enumerate(names)}
    for op, value in bc.UNARY_OPS.items():
        key = {
            "UAdd": "POSITIVE",
            "USub": "NEGATIVE",
            "Invert": "INVERT",
            "Not": "NOT",
        }[op]
        assert order[f"MP_UNARY_OP_{key}"] == value, f"{op} -> {key}"


def test_iter_buf_nslots_matches_obj_h() -> None:
    """GET_ITER_STACK reserves this many slots; a drift corrupts the stack."""
    header = BC0.parent / "obj.h"
    if not header.exists():
        pytest.skip("obj.h not present")
    text = header.read_text()
    m = re.search(r"typedef struct _mp_obj_iter_buf_t \{(.*?)\}", text, re.DOTALL)
    assert m, "mp_obj_iter_buf_t not found"
    body = m.group(1)
    slots = 1  # mp_obj_base_t
    buf = re.search(r"mp_obj_t\s+buf\[(\d+)\]", body)
    assert buf, "buf[] not found in mp_obj_iter_buf_t"
    slots += int(buf.group(1))
    assert slots == bc.ITER_BUF_NSLOTS, f"pyfront {bc.ITER_BUF_NSLOTS}, vendor {slots}"
