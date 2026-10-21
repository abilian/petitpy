"""dataclasses — @dataclass decorator for nanopython.

Synthesizes ``__init__``, ``__repr__``, and ``__eq__`` from the fields
declared on a class. Designed for the daily-CPython case::

    from dataclasses import dataclass

    @dataclass
    class Point:
        x: int
        y: int = 0

    p = Point(3, 4)
    p.x                  # 3
    print(p)             # Point(x=3, y=4)
    p == Point(3, 4)     # True
    p == Point(3, 5)     # False

Fields are the annotated names, in source order: the compiler records
class annotations in ``__annotations__`` as text (PEP 563), so ``x: int``
without a default is a required field and ``ClassVar[...]`` names are
skipped. A class compiled without annotations (vendor ``mpy-cross``, or
the legacy ``x = 0`` style) falls back to its non-callable class
attributes, in ``dir()`` order.

What's NOT supported (vs CPython dataclasses):

  - ``InitVar``
  - ``__post_init__`` hook
  - ``replace()`` and ``make_dataclass()`` factory APIs
  - ``field(metadata=...)``

Silent no-ops (accepted for import-compat, semantics NOT enforced):

  - ``frozen=True`` — instances stay mutable; ``dataclass.field = X``
    won't raise. Real frozen would need ``__setattr__`` enforcement.
  - ``slots=True`` — MicroPython silently ignores ``__slots__``.
  - ``kw_only=True`` — synthesised ``__init__`` accepts positional too.
  - ``order=True`` — no ``__lt__``/``__le__``/etc. synthesis; the four
    ordering ops fall back to identity (`object` default).
  - ``unsafe_hash=True`` — hash follows Python defaults.

These are relevant when porting CPython packages whose type hints /
frozen-ness are structural but not load-bearing. Callers who need
real enforcement should not rely on these flags under nanopython.

Supported helpers:

  - ``field(default=X)`` — explicit default for a single field
  - ``field(default_factory=list)`` — mutable default via callable
  - ``asdict(obj)`` — convert instance to dict
  - ``fields(obj_or_cls)`` — list field names

See ADR 011 for the design rationale.
"""

# Sentinel for "no default was provided" so we can distinguish None
# (a valid default) from "user didn't say."
_MISSING = object()


class _Field:
    """A field declaration created by ``field(default=...)``."""

    def __init__(self, default=_MISSING, default_factory=None):
        self.default = default
        self.default_factory = default_factory


def field(*, default=_MISSING, default_factory=None):
    """Declare a field with explicit default behavior.

    Used inside a class body when the simple ``x = value`` form
    won't do — typically for mutable defaults that should not be
    shared across instances::

        @dataclass
        class Bin:
            items = field(default_factory=list)
    """
    return _Field(default=default, default_factory=default_factory)


def _collect_fields(cls):
    """Walk ``cls``'s attributes via dir() + getattr(). Return a list
    of (name, _Field) tuples in the order they appear via dir() —
    sorted, but deterministic.

    Without ``__annotations__`` support on nano, we infer fields from
    class-level assignments. Skip dunders and callables (methods,
    staticmethods, classmethods, builtins).
    """
    # The compiler records class annotations as text (PEP 563), so a
    # field without a default is visible: CPython's rule, every annotated
    # name except ClassVar ones, its default the class attribute if any.
    annotations = getattr(cls, "__annotations__", None)
    if annotations:
        fields_list = []
        for name, text in annotations.items():
            bare = text.strip("'\"") if text is not None else ""
            if bare.startswith("ClassVar") or bare.startswith("typing.ClassVar"):
                continue
            raw = getattr(cls, name, _MISSING)
            fields_list.append((name, raw if isinstance(raw, _Field) else _Field(default=raw)))
        return fields_list
    fields_list = []
    # Nanopython's dir() returns hash-map iteration order rather than
    # source or alphabetical order; a build-time patcher can inject
    # `_nanopy_fields_order = [name, name, …]` as a source-ordered
    # hint so positional-arg construction matches the source class
    # body. Fall back to dir() when the hint is absent (CPython's
    # dir() is sorted — good enough there).
    order_hint = getattr(cls, "_nanopy_fields_order", None)
    if order_hint is not None:
        names_iter = order_hint
    else:
        names_iter = list(dir(cls))
    for name in names_iter:
        if name.startswith("_"):
            continue
        raw = getattr(cls, name, _MISSING)
        if callable(raw):
            continue
        # Skip descriptors — @property in particular walks into
        # dir() but assigning through the descriptor at instance
        # __init__ time either overrides the read-only accessor
        # (Anonymous field masking) or raises AttributeError
        # (no setter). Both break real code (hop3-rootd's
        # CommandResult exposes `.success` this way).
        type_name = type(raw).__name__
        if type_name in ("property", "classmethod", "staticmethod"):
            continue
        if isinstance(raw, _Field):
            fields_list.append((name, raw))
        else:
            # Plain value treated as a default.
            fields_list.append((name, _Field(default=raw)))
    return fields_list


def _make_init(fields_list):
    """Return a closure that's ``__init__`` for the dataclass.

    Nanopython drops annotation-only class attributes at compile time
    (`x: T` with no `= default`) and provides no ``__annotations__``
    dict, so ``_collect_fields`` only sees fields that carry a default.
    To keep ``@dataclass`` usable in that world we accept any leftover
    kwarg as an attribute — semantics differ from CPython (which would
    raise TypeError on unknown kwargs) but keep the common
    ``E(name=value, …)`` construction working."""
    field_names = [name for name, _ in fields_list]
    field_specs = [spec for _, spec in fields_list]
    known = set(field_names)

    def __init__(self, *args, **kwargs):
        for i, name in enumerate(field_names):
            if i < len(args):
                setattr(self, name, args[i])
            elif name in kwargs:
                setattr(self, name, kwargs[name])
            else:
                spec = field_specs[i]
                if spec.default is not _MISSING:
                    setattr(self, name, spec.default)
                elif spec.default_factory is not None:
                    setattr(self, name, spec.default_factory())
                else:
                    raise TypeError(
                        "__init__() missing required argument: " + name
                    )
        # Fallback: any kwarg the field list didn't know about is
        # bound as an attribute. Covers annotation-only fields that
        # nanopython's compiler didn't expose to dir().
        for k, v in kwargs.items():
            if k not in known:
                setattr(self, k, v)
        # __post_init__ hook. CPython dataclasses call this after
        # field assignment so `@dataclass` classes can enforce
        # invariants without needing a custom __init__.
        post = getattr(self, "__post_init__", None)
        if callable(post):
            post()

    return __init__


def _make_repr(fields_list):
    """Return a closure that's ``__repr__`` for the dataclass."""
    field_names = [name for name, _ in fields_list]

    def __repr__(self):
        parts = []
        for name in field_names:
            parts.append(name + "=" + repr(getattr(self, name)))
        return type(self).__name__ + "(" + ", ".join(parts) + ")"

    return __repr__


def _make_eq(fields_list):
    """Return a closure that's ``__eq__`` for the dataclass.

    Returns False (not NotImplemented) for type mismatches. CPython
    convention is to return NotImplemented and let the other side's
    __eq__ be tried, but nano's micropython doesn't propagate
    NotImplemented through the ``==`` operator — returning it leaves
    the expression evaluating to NotImplemented instead of False,
    which breaks the reflexive idiom ``x != y`` returning True. False
    is what users practically observe anyway.
    """
    field_names = [name for name, _ in fields_list]

    def __eq__(self, other):
        if type(self) is not type(other):
            return False
        for name in field_names:
            if getattr(self, name) != getattr(other, name):
                return False
        return True

    return __eq__


def dataclass(_cls=None, *, init=True, repr=True, eq=True,
              frozen=False, slots=False, kw_only=False, order=False,
              unsafe_hash=False, match_args=True):
    """Class decorator. Synthesize ``__init__``, ``__repr__``, ``__eq__``.

    Can be used with or without parentheses::

        @dataclass
        class Point:
            x = 0
            y = 0

        @dataclass(repr=False)
        class Quiet:
            ...

    Silent no-ops: ``frozen``, ``slots``, ``kw_only``, ``order``,
    ``unsafe_hash``, ``match_args``. See module docstring for the
    non-enforcement caveat.
    """
    # Silence unused-arg warnings — every no-op kwarg is intentional
    # for import-compat.
    _ = (frozen, slots, kw_only, order, unsafe_hash, match_args)

    def wrap(cls):
        fields_list = _collect_fields(cls)
        if init:
            cls.__init__ = _make_init(fields_list)
        if repr:
            cls.__repr__ = _make_repr(fields_list)
        if eq:
            cls.__eq__ = _make_eq(fields_list)
        # Stash the field metadata for asdict() / fields() / introspection.
        cls.__dataclass_fields__ = fields_list
        return cls

    if _cls is None:
        return wrap
    return wrap(_cls)


def asdict(obj):
    """Return a dict mapping field names to their current values."""
    return {name: getattr(obj, name) for name, _ in obj.__dataclass_fields__}


def fields(obj_or_cls):
    """Return a list of field names of a dataclass instance or class."""
    cls = obj_or_cls if isinstance(obj_or_cls, type) else type(obj_or_cls)
    return [name for name, _ in cls.__dataclass_fields__]
