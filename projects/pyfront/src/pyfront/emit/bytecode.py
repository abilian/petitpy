"""Opcodes and the var-int / prelude encodings of MicroPython bytecode v6.

Numbers come from `vendor/micropython_embed/py/bc0.h` and `runtime0.h`; the
prelude encoders are the inverse of `read_prelude_sig` / `read_prelude_size` in
`sandbox/micropython/tools/mpy-tool.py`, cross-checked against the Zig
implementation in `src/compiler/emit.zig` (`preludeSigEncode`,
`preludeSizeEncode`), which the corpus gates keep honest.
"""

from __future__ import annotations

# ── opcodes (vendor/micropython_embed/py/bc0.h) ────────────────────────
#
# Generated from the header and checked against it by
# tests/test_opcodes_match_vendor.py, which covers every name below.
# Five of these were wrong when hand-written; none are hand-written now.

FORMAT_BYTE = 0x00
FORMAT_QSTR = 0x01
FORMAT_VAR_UINT = 0x02
FORMAT_OFFSET = 0x03
LOAD_CONST_SMALL_INT_MULTI_EXCESS = 0x10
LOAD_FAST_MULTI_NUM = 0x10
STORE_FAST_MULTI_NUM = 0x10
LOAD_CONST_STRING = 0x10
LOAD_NAME = 0x11
LOAD_GLOBAL = 0x12
LOAD_ATTR = 0x13
LOAD_METHOD = 0x14
LOAD_SUPER_METHOD = 0x15
STORE_NAME = 0x16
STORE_GLOBAL = 0x17
STORE_ATTR = 0x18
DELETE_NAME = 0x19
DELETE_GLOBAL = 0x1A
IMPORT_NAME = 0x1B
IMPORT_FROM = 0x1C
MAKE_CLOSURE = 0x20
MAKE_CLOSURE_DEFARGS = 0x21
LOAD_CONST_SMALL_INT = 0x22
LOAD_CONST_OBJ = 0x23
LOAD_FAST_N = 0x24
LOAD_DEREF = 0x25
STORE_FAST_N = 0x26
STORE_DEREF = 0x27
DELETE_FAST = 0x28
DELETE_DEREF = 0x29
BUILD_TUPLE = 0x2A
BUILD_LIST = 0x2B
BUILD_MAP = 0x2C
BUILD_SET = 0x2D
BUILD_SLICE = 0x2E
STORE_COMP = 0x2F
UNPACK_SEQUENCE = 0x30
UNPACK_EX = 0x31
MAKE_FUNCTION = 0x32
MAKE_FUNCTION_DEFARGS = 0x33
CALL_FUNCTION = 0x34
CALL_FUNCTION_VAR_KW = 0x35
CALL_METHOD = 0x36
CALL_METHOD_VAR_KW = 0x37
LOAD_CONST_SMALL_INT_MULTI_NUM = 0x40
UNWIND_JUMP = 0x40
JUMP = 0x42
POP_JUMP_IF_TRUE = 0x43
POP_JUMP_IF_FALSE = 0x44
JUMP_IF_TRUE_OR_POP = 0x45
JUMP_IF_FALSE_OR_POP = 0x46
SETUP_WITH = 0x47
SETUP_EXCEPT = 0x48
SETUP_FINALLY = 0x49
POP_EXCEPT_JUMP = 0x4A
FOR_ITER = 0x4B
LOAD_CONST_FALSE = 0x50
LOAD_CONST_NONE = 0x51
LOAD_CONST_TRUE = 0x52
LOAD_NULL = 0x53
LOAD_BUILD_CLASS = 0x54
LOAD_SUBSCR = 0x55
STORE_SUBSCR = 0x56
DUP_TOP = 0x57
DUP_TOP_TWO = 0x58
POP_TOP = 0x59
ROT_TWO = 0x5A
ROT_THREE = 0x5B
WITH_CLEANUP = 0x5C
END_FINALLY = 0x5D
GET_ITER = 0x5E
GET_ITER_STACK = 0x5F
STORE_MAP = 0x62
RETURN_VALUE = 0x63
RAISE_LAST = 0x64
RAISE_OBJ = 0x65
RAISE_FROM = 0x66
YIELD_VALUE = 0x67
YIELD_FROM = 0x68
IMPORT_STAR = 0x69
LOAD_CONST_SMALL_INT_MULTI = 0x70
LOAD_FAST_MULTI = 0xB0
STORE_FAST_MULTI = 0xC0
UNARY_OP_MULTI = 0xD0
BINARY_OP_MULTI = 0xD7
#: mp_obj_iter_buf_t is a base plus buf[3]; GET_ITER_STACK reserves that many.
ITER_BUF_NSLOTS = 4

BINARY_OP_MULTI = 0xD7
UNARY_OP_MULTI = 0xD0

# ── mp_binary_op_t, in enum order (runtime0.h) ──────────────────────────
BINARY_OPS = {
    "Lt": 0,
    "Gt": 1,
    "Eq": 2,
    "LtE": 3,
    "GtE": 4,
    "NotEq": 5,
    "In": 6,
    "Is": 7,
}
#: mp_binary_op_t index for `except X` matching, not reachable from a Python
#: operator token so it sits outside BINARY_OPS.
EXCEPTION_MATCH = 8
BINARY_OPS |= {
    "BitOr": 22,
    "BitXor": 23,
    "BitAnd": 24,
    "LShift": 25,
    "RShift": 26,
    "Add": 27,
    "Sub": 28,
    "Mult": 29,
    "MatMult": 30,
    "FloorDiv": 31,
    "Div": 32,
    "Mod": 33,
    "Pow": 34,
}
# In-place forms sit at 9..21, in the same order as OR..POWER at 22..34.
INPLACE_OPS = {k: v - 13 for k, v in BINARY_OPS.items() if v >= 22}

UNARY_OPS = {"UAdd": 0, "USub": 1, "Invert": 2, "Not": 3}

# Scope flags (scope.h). Only the ones a signature carries.
SCOPE_FLAG_GENERATOR = 0x01
SCOPE_FLAG_VARKEYWORDS = 0x02
SCOPE_FLAG_VARARGS = 0x04
SCOPE_FLAG_DEFKWARGS = 0x08


def uint(value: int) -> bytes:
    """Unsigned var-int, 7 bits per byte, high bit continues, big-endian."""
    if value < 0:
        raise ValueError(f"uint() is unsigned, got {value}")
    out = bytearray([value & 0x7F])
    value >>= 7
    while value:
        out.insert(0, 0x80 | (value & 0x7F))
        value >>= 7
    return bytes(out)


def sint(value: int) -> bytes:
    """Signed var-int, as `mp_encode_int`: 7 bits per byte, sign-extended."""
    out = bytearray([value & 0x7F])
    value >>= 7
    while value not in (0, -1) or bool(out[0] & 0x40) != (value == -1):
        out.insert(0, 0x80 | (value & 0x7F))
        value >>= 7
    return bytes(out)


def prelude_sig(
    n_state: int,
    n_exc_stack: int,
    scope_flags: int,
    n_pos_args: int,
    n_kwonly_args: int,
    n_def_pos_args: int,
) -> bytes:
    """Inverse of mpy-tool's `read_prelude_sig`. First byte is xSSSSEAA."""
    s = n_state - 1
    e, f = n_exc_stack, scope_flags
    a, k, d = n_pos_args, n_kwonly_args, n_def_pos_args
    out = bytearray()
    z = ((s & 0xF) << 3) | ((e & 1) << 2) | (a & 3)
    s >>= 4
    e >>= 1
    a >>= 2
    while s | e | f | a | k | d:
        out.append(0x80 | z)
        z = (
            ((f & 1) << 6)
            | ((s & 3) << 4)
            | ((k & 1) << 3)
            | ((a & 1) << 2)
            | ((e & 1) << 1)
            | (d & 1)
        )
        s >>= 2
        e >>= 1
        f >>= 1
        a >>= 1
        k >>= 1
        d >>= 1
    out.append(z)
    return bytes(out)


def prelude_size(n_info: int, n_cell: int) -> bytes:
    """Inverse of mpy-tool's `read_prelude_size`. Each byte is xIIIIIIC."""
    i, c = n_info, n_cell
    out = bytearray()
    while True:
        z = ((i & 0x3F) << 1) | (c & 1)
        c >>= 1
        i >>= 6
        if c | i:
            z |= 0x80
        out.append(z)
        if not (c | i):
            return bytes(out)
