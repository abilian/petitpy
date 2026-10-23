"""Tests for petitpy-lib/dataclasses.py via pytest_lite."""

import sys

sys.path.insert(0, "petitpy-lib")

import pytest
from dataclasses import dataclass, field, asdict, fields


# ── Test dataclasses ────────────────────────────────────────────────────


@dataclass
class Point:
    x = 0
    y = 0


@dataclass
class Person:
    name = ""
    age = 0
    nickname = "Anonymous"


@dataclass
class Bin:
    label = ""
    items = field(default_factory=list)


@dataclass
class Required:
    a = field()  # no default — must be supplied
    b = 0


# ── basic instantiation ─────────────────────────────────────────────────


def test_positional_args():
    p = Point(3, 4)
    assert p.x == 3
    assert p.y == 4


def test_keyword_args():
    p = Point(x=10, y=20)
    assert p.x == 10
    assert p.y == 20


def test_mixed_args():
    p = Point(5, y=6)
    assert p.x == 5
    assert p.y == 6


def test_defaults_applied():
    p = Point()
    assert p.x == 0
    assert p.y == 0


def test_partial_construction_uses_defaults():
    p = Person(name="Ada")
    assert p.name == "Ada"
    assert p.age == 0
    assert p.nickname == "Anonymous"


# ── __repr__ ────────────────────────────────────────────────────────────


def test_repr_basic():
    p = Point(3, 4)
    assert repr(p) == "Point(x=3, y=4)"


def test_repr_strings_quoted():
    p = Person(name="Ada", age=42)
    assert repr(p) == "Person(name='Ada', age=42, nickname='Anonymous')"


# ── __eq__ ──────────────────────────────────────────────────────────────


def test_equal_when_fields_match():
    assert Point(3, 4) == Point(3, 4)


def test_not_equal_when_field_differs():
    assert Point(3, 4) != Point(3, 5)
    assert Point(3, 4) != Point(99, 4)


def test_not_equal_across_types():
    @dataclass
    class P2:
        x = 0
        y = 0

    p1 = Point(3, 4)
    p2 = P2()
    p2.x = 3
    p2.y = 4
    assert p1 != p2  # different classes, even if same fields


def test_eq_with_unrelated_type_is_false():
    # Equality with an unrelated type returns False (not NotImplemented).
    # See the docstring of _make_eq in dataclasses.py for why this
    # differs from CPython.
    p = Point(3, 4)
    assert (p == "not a point") is False


# ── default_factory for mutables ────────────────────────────────────────


def test_default_factory_creates_independent_instances():
    a = Bin(label="A")
    b = Bin(label="B")
    a.items.append("x")
    assert a.items == ["x"]
    assert b.items == []  # NOT shared


def test_default_factory_with_explicit_value():
    a = Bin(label="A", items=["pre"])
    assert a.items == ["pre"]


# ── required fields ─────────────────────────────────────────────────────


def test_required_field_raises_when_missing():
    with pytest.raises(TypeError):
        Required()


def test_required_field_accepts_value():
    r = Required(a=42)
    assert r.a == 42
    assert r.b == 0


# ── asdict + fields ─────────────────────────────────────────────────────


def test_asdict_returns_field_dict():
    p = Point(3, 4)
    assert asdict(p) == {"x": 3, "y": 4}


def test_asdict_reflects_current_state():
    p = Point(1, 2)
    p.x = 99
    assert asdict(p) == {"x": 99, "y": 2}


def test_fields_on_instance():
    names = fields(Point(1, 2))
    assert set(names) == {"x", "y"}


def test_fields_on_class():
    names = fields(Point)
    assert set(names) == {"x", "y"}


# ── decorator-with-args form ────────────────────────────────────────────


def test_decorator_with_args_skips_repr():
    @dataclass(repr=False)
    class Quiet:
        v = 0

    q = Quiet(5)
    # Quiet shouldn't have a synthesized __repr__; falls back to the
    # generic <object at 0x...> form.
    assert repr(q).startswith("<")


def test_decorator_with_args_skips_eq():
    @dataclass(eq=False)
    class NoEq:
        v = 0

    a = NoEq(1)
    b = NoEq(1)
    # Without synthesized __eq__, equality falls back to identity.
    assert (a == b) is False
    assert a == a


# ── methods on the class are preserved ──────────────────────────────────


@dataclass
class WithMethod:
    x = 0
    y = 0

    def distance(self):
        return self.x * self.x + self.y * self.y


def test_methods_preserved_through_decoration():
    w = WithMethod(3, 4)
    assert w.distance() == 25



# ── Annotated fields (the compiler records class __annotations__) ───────


@dataclass
class Annotated:
    name: str
    size: int
    tags: list = field(default_factory=list)
    kind: str = "box"
    registry: "ClassVar[int]" = 0
    parent: "Annotated" = None


def test_bare_annotations_are_fields_in_source_order():
    a = Annotated("a", 3)
    assert (a.name, a.size, a.tags, a.kind) == ("a", 3, [], "box")
    assert fields(a) == ["name", "size", "tags", "kind", "parent"]


def test_missing_bare_field_raises():
    with pytest.raises(TypeError):
        Annotated("only-name")


def test_classvar_is_not_a_field():
    assert "registry" not in asdict(Annotated("a", 1))


def test_annotations_are_source_text():
    assert Annotated.__annotations__["parent"] == "'Annotated'"
    assert list(Annotated.__annotations__)[:2] == ["name", "size"]

if __name__ == "__main__":
    pytest.run_self_tests(globals())
