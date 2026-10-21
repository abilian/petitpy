"""The `.mpy` v6 container: header, qstr table, constant table, raw-code tree.

Layout (vendor/micropython_embed/py/persistentcode.c, and the comment at the
top of src/compiler/mpy.zig):

    byte 0   'M'
    byte 1   version (6)
    byte 2   native arch + sub-version flags (0 = no native code)
    byte 3   MP_SMALL_INT_BITS
    vlen     n_qstr
    vlen     n_obj
    qstrs    static: vlen (id << 1) | 1     new: vlen (len << 1), bytes, NUL
    objs     tagged, see ObjKind
    raw_code vlen (len << 3) | (has_children << 2) | (kind - BYTECODE)
             bytes fun_data
             if has_children: vlen n_children, then each child

Every qstr is written as `new`. The runtime interns on load, so a name that is
already a static qstr resolves to the same id; the file is a few bytes larger
and the writer needs no copy of the static table, which would have to be kept
in sync with the vendor build. src/compiler/qstr.zig carries that table for the
Zig front-end and a comptime assert to catch drift; this front-end declines the
obligation instead.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from types import EllipsisType

from .bytecode import uint

MPY_MAGIC = ord("M")
MPY_VERSION = 6
#: 64-bit builds use 63; nanopython's wasm32 arm uses 31. The runtime checks
#: this against its own, so it has to match the target that will load the file.
SMALL_INT_BITS_64 = 63
SMALL_INT_BITS_32 = 31

# Constant-table tags (ObjKind in mpy.zig).
OBJ_NONE, OBJ_FALSE, OBJ_TRUE, OBJ_ELLIPSIS = 1, 2, 3, 4
OBJ_STR, OBJ_BYTES, OBJ_INT, OBJ_FLOAT, OBJ_COMPLEX, OBJ_TUPLE = 5, 6, 7, 8, 9, 10


@dataclass
class RawCode:
    """One code object: its bytecode, and the code objects nested in it."""

    fun_data: bytes
    children: list[RawCode] = field(default_factory=list)

    def encode(self) -> bytes:
        has_children = 1 if self.children else 0
        # kind - MP_CODE_BYTECODE == 0 for bytecode.
        out = bytearray(uint((len(self.fun_data) << 3) | (has_children << 2)))
        out += self.fun_data
        if self.children:
            out += uint(len(self.children))
            for child in self.children:
                out += child.encode()
        return bytes(out)


class Table:
    """Append-only pool that returns a stable index per distinct entry."""

    def __init__(self) -> None:
        self._index: dict[object, int] = {}
        self.entries: list[object] = []

    def intern(self, value: object) -> int:
        key = (type(value).__name__, value)
        if key not in self._index:
            self._index[key] = len(self.entries)
            self.entries.append(value)
        return self._index[key]

    def __len__(self) -> int:
        return len(self.entries)


def encode_obj(value: object) -> bytes:
    """One constant-table entry, tag byte then payload."""
    # Order matters: bool is a subclass of int, so True/False have to be
    # claimed before `int()` sees them.
    match value:
        case None:
            return bytes([OBJ_NONE])
        case True:
            return bytes([OBJ_TRUE])
        case False:
            return bytes([OBJ_FALSE])
        case EllipsisType():
            return bytes([OBJ_ELLIPSIS])
        # str and bytes payloads carry a NUL terminator that the loader skips
        # (persistentcode.c: "it needs to be there for ROM str objects").
        # Omitting it leaves the reader one byte behind for all that follows.
        case str():
            raw = value.encode()
            return bytes([OBJ_STR]) + uint(len(raw)) + raw + b"\x00"
        case bytes():
            return bytes([OBJ_BYTES]) + uint(len(value)) + value + b"\x00"
        case int():
            # Vendor stores big ints as their decimal text.
            raw = repr(value).encode()
            return bytes([OBJ_INT]) + uint(len(raw)) + raw
        case float():
            raw = repr(value).encode()
            return bytes([OBJ_FLOAT]) + uint(len(raw)) + raw
        case tuple():
            out = bytearray([OBJ_TUPLE]) + uint(len(value))
            for item in value:
                out += encode_obj(item)
            return bytes(out)
        case _:
            raise TypeError(f"cannot put {type(value).__name__} in the constant table")


def write(
    qstrs: list[str],
    objs: list[object],
    top: RawCode,
    small_int_bits: int = SMALL_INT_BITS_64,
) -> bytes:
    """Serialise a whole .mpy file."""
    out = bytearray([MPY_MAGIC, MPY_VERSION, 0, small_int_bits])
    out += uint(len(qstrs))
    out += uint(len(objs))
    for name in qstrs:
        raw = name.encode()
        out += uint(len(raw) << 1)  # low bit 0 = a new string, not a static id
        out += raw + b"\x00"
    for value in objs:
        out += encode_obj(value)
    out += top.encode()
    return bytes(out)
