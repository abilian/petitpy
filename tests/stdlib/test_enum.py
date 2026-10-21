"""Tests for nanopython-lib/enum.py via pytest_lite."""

import sys

sys.path.insert(0, "nanopython-lib")

import pytest
from enum import enum, members, member_names, lookup


# ── Test enums ──────────────────────────────────────────────────────────


@enum
class Color:
    RED = 1
    GREEN = 2
    BLUE = 3


@enum
class Status:
    OK = "ok"
    FAIL = "fail"
    SKIP = "skip"


@enum
class Op:
    ADD = 1
    SUB = 2

    @staticmethod
    def helper():
        return 42


# ── basic attribute access ──────────────────────────────────────────────


def test_member_name_attr():
    assert Color.RED.name == "RED"
    assert Color.GREEN.name == "GREEN"
    assert Color.BLUE.name == "BLUE"


def test_member_value_attr():
    assert Color.RED.value == 1
    assert Color.GREEN.value == 2
    assert Color.BLUE.value == 3


def test_string_valued_enum():
    assert Status.OK.value == "ok"
    assert Status.FAIL.value == "fail"


# ── identity-based equality ─────────────────────────────────────────────


def test_member_equal_to_self():
    assert Color.RED == Color.RED


def test_different_members_not_equal():
    assert Color.RED != Color.GREEN
    assert Color.RED != Color.BLUE


def test_member_not_equal_to_raw_value():
    # CPython semantic: a member is not equal to its raw value.
    assert Color.RED != 1
    assert Status.OK != "ok"


def test_members_across_enums_not_equal():
    # A member of Color is not equal to a member of Op even with the
    # same value.
    assert Color.RED != Op.ADD


def test_members_are_hashable():
    # Used as dict keys.
    d = {Color.RED: "one", Color.GREEN: "two"}
    assert d[Color.RED] == "one"
    assert d[Color.GREEN] == "two"


# ── repr + str ──────────────────────────────────────────────────────────


def test_member_repr():
    assert repr(Color.RED) == "<Color.RED: 1>"
    assert repr(Status.OK) == "<Status.OK: 'ok'>"


def test_member_str():
    assert str(Color.RED) == "Color.RED"
    assert str(Status.OK) == "Status.OK"


# ── enumeration helpers ─────────────────────────────────────────────────


def test_members_returns_all_in_order():
    ms = members(Color)
    assert len(ms) == 3
    assert ms[0] is Color.RED
    assert ms[1] is Color.GREEN
    assert ms[2] is Color.BLUE


def test_member_names_returns_strings():
    names = member_names(Color)
    assert set(names) == {"RED", "GREEN", "BLUE"}
    assert len(names) == 3


def test_members_returns_independent_list():
    # Caller mutating the returned list shouldn't affect the enum.
    ms = members(Color)
    ms.clear()
    assert len(members(Color)) == 3


# ── lookup by value ─────────────────────────────────────────────────────


def test_lookup_finds_member():
    assert lookup(Color, 1) is Color.RED
    assert lookup(Color, 3) is Color.BLUE


def test_lookup_works_for_string_values():
    assert lookup(Status, "ok") is Status.OK


def test_lookup_missing_returns_none():
    assert lookup(Color, 999) is None
    assert lookup(Status, "nope") is None


# ── methods on the class are preserved ──────────────────────────────────


def test_staticmethod_preserved():
    # `helper` is callable, so it should be skipped during member
    # collection and remain callable.
    assert callable(Op.helper)
    assert Op.helper() == 42


def test_staticmethod_not_in_members():
    names = member_names(Op)
    assert "helper" not in names
    assert set(names) == {"ADD", "SUB"}


# ── iteration via `for m in members(cls)` ───────────────────────────────


def test_iteration_pattern():
    seen = []
    for m in members(Color):
        seen.append(m.name)
    assert seen == ["RED", "GREEN", "BLUE"]


if __name__ == "__main__":
    pytest.run_self_tests(globals())
