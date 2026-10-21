"""Tests for nanopython-lib/abc.py via pytest_lite."""

import sys

sys.path.insert(0, "nanopython-lib")

import pytest
from abc import ABC, abstractmethod


# ── instantiation rules ─────────────────────────────────────────────────


def test_abc_with_abstract_method_cannot_instantiate():
    class S(ABC):
        @abstractmethod
        def m(self):
            pass

    with pytest.raises(TypeError):
        S()


def test_abc_with_no_abstract_can_instantiate():
    class C(ABC):
        pass

    c = C()
    assert isinstance(c, C)


def test_subclass_that_overrides_can_instantiate():
    class Shape(ABC):
        @abstractmethod
        def area(self):
            pass

    class Square(Shape):
        def __init__(self, side):
            self.side = side

        def area(self):
            return self.side * self.side

    s = Square(5)
    assert s.area() == 25


def test_subclass_that_does_not_override_cannot_instantiate():
    class Shape(ABC):
        @abstractmethod
        def area(self):
            pass

    class Halfway(Shape):
        # doesn't override area()
        pass

    with pytest.raises(TypeError):
        Halfway()


def test_multiple_abstract_methods_all_listed():
    class A(ABC):
        @abstractmethod
        def alpha(self):
            pass

        @abstractmethod
        def beta(self):
            pass

    with pytest.raises(TypeError) as cm:
        A()
    msg = str(cm.value)
    assert "alpha" in msg
    assert "beta" in msg


def test_partial_override_still_abstract():
    class A(ABC):
        @abstractmethod
        def alpha(self):
            pass

        @abstractmethod
        def beta(self):
            pass

    class Half(A):
        def alpha(self):
            return 1

        # doesn't override beta

    with pytest.raises(TypeError) as cm:
        Half()
    assert "beta" in str(cm.value)
    assert "alpha" not in str(cm.value)


# ── concrete methods on the ABC are usable through subclasses ──────────


def test_concrete_methods_on_abc_work_in_subclass():
    class Base(ABC):
        @abstractmethod
        def do_work(self):
            pass

        def helper(self):
            return "helper"

    class Impl(Base):
        def do_work(self):
            return "work"

    i = Impl()
    assert i.do_work() == "work"
    assert i.helper() == "helper"


# ── marker behavior ────────────────────────────────────────────────────


def test_calling_marker_directly_raises():
    class A(ABC):
        @abstractmethod
        def foo(self):
            pass

    # Calling A.foo (the marker on the class itself) raises TypeError.
    with pytest.raises(TypeError):
        A.foo(None)


def test_marker_replaced_by_override():
    """After a subclass overrides, the marker is gone."""
    from abc import _AbstractMarker  # internal — for test only

    class Base(ABC):
        @abstractmethod
        def m(self):
            pass

    class Impl(Base):
        def m(self):
            return 42

    # Base.m is still a marker; Impl.m is the override.
    assert isinstance(Base.m, _AbstractMarker)
    assert not isinstance(Impl.m, _AbstractMarker)


# ── multi-level inheritance ────────────────────────────────────────────


def test_two_level_subclass():
    class A(ABC):
        @abstractmethod
        def foo(self):
            pass

    class B(A):
        @abstractmethod
        def bar(self):
            pass

    class C(B):
        def foo(self):
            return "f"

        def bar(self):
            return "b"

    c = C()
    assert c.foo() == "f"
    assert c.bar() == "b"


def test_intermediate_class_still_abstract():
    class A(ABC):
        @abstractmethod
        def foo(self):
            pass

    class B(A):
        # B doesn't override foo
        pass

    with pytest.raises(TypeError):
        B()


# ── realistic usage ───────────────────────────────────────────────────


def test_realistic_shape_hierarchy():
    class Shape(ABC):
        @abstractmethod
        def area(self):
            pass

        @abstractmethod
        def describe(self):
            pass

        def doc(self):
            return self.describe() + " has area " + str(self.area())

    class Circle(Shape):
        def __init__(self, r):
            self.r = r

        def area(self):
            return 3 * self.r * self.r

        def describe(self):
            return "circle"

    class Square(Shape):
        def __init__(self, side):
            self.side = side

        def area(self):
            return self.side * self.side

        def describe(self):
            return "square"

    c = Circle(5)
    s = Square(4)
    assert c.area() == 75
    assert s.area() == 16
    assert c.doc() == "circle has area 75"
    assert s.doc() == "square has area 16"


if __name__ == "__main__":
    pytest.run_self_tests(globals())
