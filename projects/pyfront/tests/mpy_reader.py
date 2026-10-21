"""A minimal `.mpy` reader, for tests only.

The point is not to load bytecode — it is to say whether a blob pyfront
produced is self-consistent. Every length in the format is declared before its
payload, so walking the whole file and landing exactly on the final byte is a
strong check that costs no VM: a truncated payload, a mis-encoded var-int, or
a missing NUL terminator all knock the cursor out of step and surface here.

That is the bug class this file exists for. Omitting the NUL after an
object-table string once left the reader one byte behind for every entry that
followed; the program still compiled and still ran.
"""

from __future__ import annotations

from pyfront.emit.mpy import (
    MPY_MAGIC,
    MPY_VERSION,
    OBJ_BYTES,
    OBJ_ELLIPSIS,
    OBJ_FALSE,
    OBJ_FLOAT,
    OBJ_INT,
    OBJ_NONE,
    OBJ_STR,
    OBJ_TRUE,
    OBJ_TUPLE,
)


class MalformedError(Exception):
    """The blob does not decode as a `.mpy`."""


#: Tags that are the whole value.
SINGLETONS = {OBJ_NONE: None, OBJ_TRUE: True, OBJ_FALSE: False, OBJ_ELLIPSIS: ...}

#: Tags followed by a length and that many bytes.
SIZED = frozenset({OBJ_STR, OBJ_BYTES, OBJ_INT, OBJ_FLOAT})

#: ...of which these two also carry the terminator the loader skips.
NUL_TERMINATED = frozenset({OBJ_STR, OBJ_BYTES})


def _uint(blob: bytes, i: int) -> tuple[int, int]:
    """The inverse of `bytecode.uint`: 7 bits a byte, high bit continues."""
    value = 0
    while blob[i] & 0x80:
        value = (value << 7) | (blob[i] & 0x7F)
        i += 1
    return (value << 7) | blob[i], i + 1


def _read_sized(blob: bytes, tag: int, i: int) -> tuple[object, int]:
    length, i = _uint(blob, i)
    payload, i = blob[i : i + length], i + length
    if len(payload) != length:
        msg = f"payload short: wanted {length}, got {len(payload)}"
        raise MalformedError(msg)
    if tag in NUL_TERMINATED:
        if blob[i] != 0:
            msg = f"payload {payload!r} is not NUL-terminated"
            raise MalformedError(msg)
        i += 1
        return (payload.decode() if tag == OBJ_STR else payload), i
    text = payload.decode()
    return (int(text) if tag == OBJ_INT else float(text)), i


def _read_obj(blob: bytes, i: int) -> tuple[object, int]:
    tag, i = blob[i], i + 1
    if tag in SINGLETONS:
        return SINGLETONS[tag], i
    if tag == OBJ_TUPLE:
        count, i = _uint(blob, i)
        items = []
        for _ in range(count):
            item, i = _read_obj(blob, i)
            items.append(item)
        return tuple(items), i
    if tag not in SIZED:
        msg = f"unknown object tag {tag}"
        raise MalformedError(msg)
    return _read_sized(blob, tag, i)


def _read_raw_code(blob: bytes, i: int) -> tuple[int, int]:
    """Returns how many code objects the subtree holds, and the new cursor."""
    header, i = _uint(blob, i)
    i += header >> 3  # fun_data
    count = 1
    if (header >> 2) & 1:
        n_children, i = _uint(blob, i)
        for _ in range(n_children):
            sub, i = _read_raw_code(blob, i)
            count += sub
    return count, i


def _walk(blob: bytes) -> tuple[list[str], list[object], int, int]:
    i = 4
    n_qstr, i = _uint(blob, i)
    n_obj, i = _uint(blob, i)

    qstrs = []
    for _ in range(n_qstr):
        raw, i = _uint(blob, i)
        length = raw >> 1  # low bit: 0 = a new string, 1 = a static id
        name, i = blob[i : i + length], i + length
        if blob[i] != 0:
            msg = f"qstr {name!r} is not NUL-terminated"
            raise MalformedError(msg)
        qstrs.append(name.decode())
        i += 1

    objs = []
    for _ in range(n_obj):
        obj, i = _read_obj(blob, i)
        objs.append(obj)

    n_codes, i = _read_raw_code(blob, i)
    return qstrs, objs, n_codes, i


def parse(blob: bytes) -> tuple[list[str], list[object], int]:
    """Walk a whole `.mpy`. Raises `MalformedError` on anything inconsistent.

    Returns (qstrs, objects, number of code objects).
    """
    if len(blob) < 4:
        msg = "shorter than the header"
        raise MalformedError(msg)
    if blob[0] != MPY_MAGIC or blob[1] != MPY_VERSION:
        msg = f"bad header {blob[:2]!r}"
        raise MalformedError(msg)

    try:
        qstrs, objs, n_codes, i = _walk(blob)
    except IndexError as exc:
        msg = "ran off the end of the buffer"
        raise MalformedError(msg) from exc

    if i != len(blob):
        msg = f"{len(blob) - i} trailing byte(s) after the code tree"
        raise MalformedError(msg)
    return qstrs, objs, n_codes
