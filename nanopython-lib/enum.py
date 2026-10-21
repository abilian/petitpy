"""enum — minimal enumerations for nanopython.

Use the ``@enum`` *decorator*, not subclassing, because nano lacks
``__init_subclass__`` and metaclass support that CPython's ``class
Color(Enum):`` form would require. The decorator walks the class
dict at decoration time, replaces each non-dunder non-callable
class attribute with a member instance.

Example::

    from enum import enum, members, lookup

    @enum
    class Color:
        RED = 1
        GREEN = 2
        BLUE = 3

    Color.RED              # <Color.RED: 1>
    Color.RED.name         # "RED"
    Color.RED.value        # 1
    Color.RED == Color.RED # True (identity)
    Color.RED == 1         # False — members compare by identity, not value
    members(Color)         # [<Color.RED: 1>, <Color.GREEN: 2>, <Color.BLUE: 3>]
    lookup(Color, 1)       # <Color.RED: 1>  — by value; None if not found

What's NOT supported (vs CPython enum):

  - ``class Color(Enum):`` subclass syntax (requires ``__init_subclass__``)
  - ``IntEnum``, ``StrEnum``, ``Flag``, ``IntFlag``
  - ``auto()``
  - ``@unique`` decorator (no aliasing check)
  - Aliasing (defining two members with the same value)
  - ``Color(1)`` for lookup-by-value — use ``lookup(Color, 1)`` instead
  - ``Color["RED"]`` for lookup-by-name — use ``getattr(Color, "RED")``
  - ``_missing_`` hook
  - Mixin types
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


# ── CPython-compat stub — `class X(Enum):` subclass form ─────────────────
#
# nanopython lacks the `__init_subclass__` / metaclass hooks CPython's
# real Enum needs to walk the class body, so subclassing does NOT convert
# class attributes to member instances. What you get:
#
#     class ErrorCode(str, Enum):
#         KERNEL_ERROR = "kernel_error"
#     ErrorCode.KERNEL_ERROR   # → "kernel_error" (plain string, since
#                              #   str is the first base in MRO)
#
# The whole `class Enum: pass` body is intentional — the class exists so
# imports like `from enum import Enum` work and `class X(str, Enum):`
# parses, but the enum-transform behaviour is opt-in via the `@enum`
# decorator above. Use `@enum class X:` for real member semantics
# (.name, .value, identity equality, `members()` / `lookup()`).
#
# For str-valued enums used only as opaque tokens (hop3-rootd pattern),
# the stub is enough — `ErrorCode.KERNEL_ERROR == "kernel_error"` and
# any code that just passes members around gets the right string.

class Enum:
    """CPython-compat stub. Members become plain class attributes;
    for real enum semantics, use the ``@enum`` decorator instead."""
    pass


class IntEnum(int, Enum):
    """Same as Enum — attribute values are ints via int base."""
    pass


class StrEnum(str, Enum):
    """Same as Enum — attribute values are strings via str base."""
    pass
