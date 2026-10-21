"""The constant table and the `.mpy` container, tested directly.

`encode_obj` was the least-covered function in the package at 61%, reached
only through whatever constants a differential program happened to use. It is
also where a real bug shipped: object-table `str` and `bytes` payloads carry a
NUL terminator the loader skips, and omitting it left the reader one byte
behind for every entry that followed. The program compiled, ran, and printed
nothing. It took a full compile-and-execute probe to find; the tests below
would have named it in milliseconds.
"""

from __future__ import annotations

import pytest

from pyfront.emit.bytecode import uint
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
    SMALL_INT_BITS_64,
    RawCode,
    Table,
    encode_obj,
    write,
)

# ── singletons ────────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    ("value", "tag"),
    [(None, OBJ_NONE), (True, OBJ_TRUE), (False, OBJ_FALSE), (..., OBJ_ELLIPSIS)],
)
def test_singleton_is_a_tag_byte_with_no_payload(value: object, tag: int) -> None:
    assert encode_obj(value) == bytes([tag])


def test_bool_is_not_encoded_as_int() -> None:
    """bool subclasses int, so `case True` has to be reached before
    `case int()`. Reorder the match and this is the test that fails."""
    assert encode_obj(True) == bytes([OBJ_TRUE])
    assert encode_obj(False) == bytes([OBJ_FALSE])
    assert encode_obj(1) != encode_obj(True)
    assert encode_obj(0) != encode_obj(False)


# ── the NUL terminator: the bug this file exists for ──────────────────────


def test_str_payload_ends_in_nul() -> None:
    assert encode_obj("ab") == bytes([OBJ_STR]) + uint(2) + b"ab\x00"


def test_bytes_payload_ends_in_nul() -> None:
    assert encode_obj(b"ab") == bytes([OBJ_BYTES]) + uint(2) + b"ab\x00"


@pytest.mark.parametrize("text", ["", "a", "hello", "x" * 200])
def test_declared_length_excludes_the_terminator(text: str) -> None:
    """The length counts the payload, not the NUL. Counting it would push
    every following read one byte late — the original bug, mirrored."""
    assert encode_obj(text)[1:] == uint(len(text)) + text.encode() + b"\x00"


def test_a_later_entry_still_decodes() -> None:
    """What the missing NUL actually broke: not the entry itself, but
    everything after it."""
    assert (encode_obj("ab") + encode_obj(7)).endswith(
        bytes([OBJ_INT]) + uint(1) + b"7"
    )


def test_embedded_nul_is_not_a_terminator() -> None:
    """A NUL inside the payload is data; the length is what delimits."""
    assert encode_obj(b"a\x00b") == bytes([OBJ_BYTES]) + uint(3) + b"a\x00b\x00"


# ── numbers ───────────────────────────────────────────────────────────────


def test_int_is_stored_as_decimal_text() -> None:
    assert encode_obj(7) == bytes([OBJ_INT]) + uint(1) + b"7"


def test_big_int_survives_as_text() -> None:
    """The point of the decimal-text encoding: no 64-bit ceiling."""
    big = 2**200 + 1
    want = bytes([OBJ_INT]) + uint(len(str(big))) + str(big).encode()
    assert encode_obj(big) == want


def test_negative_int() -> None:
    assert encode_obj(-42) == bytes([OBJ_INT]) + uint(3) + b"-42"


def test_float() -> None:
    assert encode_obj(1.5) == bytes([OBJ_FLOAT]) + uint(3) + b"1.5"


# ── tuples ────────────────────────────────────────────────────────────────


def test_empty_tuple() -> None:
    assert encode_obj(()) == bytes([OBJ_TUPLE]) + uint(0)


def test_tuple_elements_follow_the_count() -> None:
    want = bytes([OBJ_TUPLE]) + uint(2) + encode_obj(1) + encode_obj(None)
    assert encode_obj((1, None)) == want


def test_tuple_nests() -> None:
    assert encode_obj(((1,),)) == bytes([OBJ_TUPLE]) + uint(1) + encode_obj((1,))


def test_unencodable_type_is_refused_by_name() -> None:
    """Silence here would mean a truncated constant table, not a crash."""
    with pytest.raises(TypeError, match="set"):
        encode_obj({1, 2})


# ── the interning pool ────────────────────────────────────────────────────


def test_repeated_values_share_a_slot() -> None:
    t = Table()
    assert t.intern("a") == t.intern("a")
    assert len(t) == 1


def test_equal_values_of_different_types_do_not_share_a_slot() -> None:
    """1, True and 1.0 all compare equal. Sharing a slot would decode one
    of them as another."""
    t = Table()
    assert t.intern(1) != t.intern(True)
    assert t.intern(1.0) != t.intern(1)
    assert len(t) == 3


# ── the container ─────────────────────────────────────────────────────────


def test_header_is_the_four_bytes_the_loader_expects() -> None:
    blob = write([], [], RawCode(fun_data=b"\x51\x63"))
    assert blob[0] == MPY_MAGIC
    assert blob[1] == MPY_VERSION
    assert blob[2] == 0  # no native code
    # 63, not 64: one bit of the word is the small-int tag.
    assert blob[3] == SMALL_INT_BITS_64 == 63


def test_qstrs_are_length_prefixed_and_nul_terminated() -> None:
    """Same terminator rule as the object table, a separate code path.
    The low bit of the length marks a new string rather than a static id."""
    blob = write(["ab"], [], RawCode(fun_data=b"\x51\x63"))
    assert uint(2 << 1) + b"ab\x00" in blob
