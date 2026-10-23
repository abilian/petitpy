"""enum — enumerations for nanopython.

`class Color(Enum):`, `IntEnum`, `StrEnum`, `auto()` and `@unique` follow
CPython on the full build, except that the class itself cannot be
iterated, measured or subscripted (no metaclasses): use
`Color.__members__`. See the comment above `Enum` below.

The older `@enum` decorator works on every build, nano included::

    from enum import enum, members, lookup

    @enum
    class Color:
        RED = 1
        GREEN = 2

    Color.RED.name, Color.RED.value   # "RED", 1
    members(Color)                    # [<Color.RED: 1>, <Color.GREEN: 2>]
    lookup(Color, 1)                  # <Color.RED: 1>; None if not found
"""


class _Member:
    """One enum member. Carries (name, value, parent class name).

    Equality is by identity, not value — matching CPython's enum
    semantics so ``Color.RED != 1`` and ``Color.RED == Color.RED``.
    """

    def __init__(self, name, value, cls_name):
        self._name_ = name
        self._value_ = value
        self._cls_name_ = cls_name

    @property
    def name(self):
        return self._name_

    @property
    def value(self):
        return self._value_

    def __repr__(self):
        return "<" + self._cls_name_ + "." + self._name_ + ": " + repr(self._value_) + ">"

    def __str__(self):
        return self._cls_name_ + "." + self._name_

    def __eq__(self, other):
        return self is other

    def __ne__(self, other):
        return self is not other

    def __hash__(self):
        return id(self)


def enum(cls):
    """Class decorator: convert ``cls`` into an enum-like type.

    Walks ``cls``'s attributes. For each non-dunder, non-callable
    attribute, creates a member instance bound to (name, value) and
    replaces the class attribute. Methods and staticmethods on the
    class are preserved (skipped during the walk because they're
    callable).
    """
    member_list = []
    cls_name = cls.__name__
    for name in list(dir(cls)):
        if name.startswith("_"):
            continue
        value = getattr(cls, name)
        if callable(value):
            continue
        m = _Member(name, value, cls_name)
        member_list.append(m)
        setattr(cls, name, m)
    cls._member_names_ = [m._name_ for m in member_list]
    cls._members_ = member_list
    cls._value2member_map_ = {m._value_: m for m in member_list}
    return cls


def members(cls):
    """Return a fresh list of the member instances of an enum class."""
    return list(cls._members_)


def member_names(cls):
    """Return a fresh list of the member names of an enum class."""
    return list(cls._member_names_)


def lookup(cls, value):
    """Look up an enum member by its value. Return None if not found."""
    return cls._value2member_map_.get(value)


# ── `class Color(Enum):` ──────────────────────────────────────────────
#
# On full, `Enum.__init_subclass__` turns the class body's plain
# attributes into members, instances of the class, as CPython does. There
# are no metaclasses, so the class itself cannot be iterated, measured or
# subscripted: `Color.__members__` stands in for `list(Color)` and
# `Color["RED"]`. Nano has neither `__init_subclass__` nor class
# `__dict__`, so there the attributes stay plain values.


class auto:
    """A member value chosen for you: the next integer (from 1), or for a
    StrEnum the member's name in lower case."""


def _lookup_new(cls, value):
    # Installed as `__new__` once the members exist: `Color(1)` looks a
    # member up by value.
    member = cls._value2member_map_.get(value)
    if member is None:
        member = cls._missing_(value)
    if member is None:
        raise ValueError(repr(value) + " is not a valid " + cls.__name__)
    return member


class Enum:
    """Base class for enumerations, written `class Color(Enum):`."""

    def __init_subclass__(cls, **kwargs):
        mixin = None
        for t in (int, str, float):
            if issubclass(cls, t):
                mixin = t
                break
        cls._member_names_ = []
        cls._member_map_ = {}
        cls._value2member_map_ = {}
        last = 0
        for name, value in list(cls.__dict__.items()):
            if name.startswith("_") or callable(value) or isinstance(value, (property, classmethod, staticmethod)):
                continue
            if isinstance(value, auto):
                value = name.lower() if issubclass(cls, StrEnum) else last + 1
            if isinstance(value, int):
                last = value
            member = cls._value2member_map_.get(value)
            if member is None:
                args = value if isinstance(value, tuple) else (value,)
                if mixin is not None:
                    member = cls(*args)
                else:
                    member = object.__new__(cls)
                    if "__init__" in cls.__dict__:
                        member.__init__(*args)
                member._name_ = name
                member._value_ = value
                cls._member_names_.append(name)
                cls._value2member_map_[value] = member
            cls._member_map_[name] = member
            setattr(cls, name, member)
        cls.__members__ = cls._member_map_
        if mixin is not None:
            # The mixin's methods come first in the MRO; members print as
            # the enum does, as in CPython.
            for name in ("__repr__", "__str__", "__format__"):
                if name not in cls.__dict__:
                    for base in cls.__bases__:
                        if issubclass(base, Enum):
                            setattr(cls, name, getattr(base, name))
                            break
        if cls._member_names_:
            cls.__new__ = _lookup_new

    @classmethod
    def _missing_(cls, value):
        return None

    @property
    def name(self):
        return self._name_

    @property
    def value(self):
        return self._value_

    def __repr__(self):
        return "<" + type(self).__name__ + "." + self._name_ + ": " + repr(self._value_) + ">"

    def __str__(self):
        return type(self).__name__ + "." + self._name_

    def __format__(self, spec):
        return format(str(self), spec)

    def __hash__(self):
        return hash(self._name_)

    def __reduce__(self):
        return (type(self), (self._value_,))


class IntEnum(int, Enum):
    """Members are ints, and print as their value."""

    def __str__(self):
        return repr(self._value_)

    def __format__(self, spec):
        return format(self._value_, spec)


class StrEnum(str, Enum):
    """Members are strings, and print as their value."""

    def __str__(self):
        return self._value_

    def __format__(self, spec):
        return format(self._value_, spec)


def unique(cls):
    """Class decorator: refuse members that are aliases of another."""
    aliases = [name for name, m in cls.__members__.items() if m._name_ != name]
    if aliases:
        raise ValueError("duplicate values found in " + repr(cls) + ": " + ", ".join(aliases))
    return cls
