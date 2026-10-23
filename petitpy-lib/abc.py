"""abc — abstract base classes for petitpy.

Daily-CPython idiom::

    from abc import ABC, abstractmethod

    class Shape(ABC):
        @abstractmethod
        def area(self):
            pass

        @abstractmethod
        def describe(self):
            pass

    class Circle(Shape):
        def __init__(self, r):
            self.r = r
        def area(self):
            return 3 * self.r * self.r
        def describe(self):
            return "circle"

    Circle(5).area()       # 75
    Shape()                # TypeError — abstract methods not overridden

Subclasses that override every marked method instantiate normally;
subclasses that leave one or more methods unoverridden raise
``TypeError`` on instantiation, listing the methods that still need
implementations.

Implementation note: CPython's ``abc`` decorates the function with
``fn.__isabstractmethod__ = True``. Nano doesn't allow function
attribute assignment (and crashes the runtime if you try — see
ADR 011 work log). Our ``@abstractmethod`` wraps the function in a
marker object instead. Subclasses that override the method replace
the marker; instantiation walks the class with ``dir()`` looking
for any leftover markers and refuses if any are found.

Not supported (vs CPython abc):

  - ``ABCMeta`` (metaclass form) — nano lacks metaclass support
  - ``register()`` for virtual subclassing
  - ``abstractclassmethod`` / ``abstractstaticmethod`` (deprecated
    in CPython anyway; use the stack ``@classmethod`` /
    ``@staticmethod`` over ``@abstractmethod``)
  - ``__abstractmethods__`` introspection set

See ADR 011 for the design rationale.
"""


class _AbstractMarker:
    """Marker wrapping an abstract method. Returned by @abstractmethod
    in place of the function itself. Any subclass that overrides the
    method replaces the marker; if a marker remains at instantiation
    time, the class is still abstract.

    Calling the marker directly raises TypeError — a defensive guard
    against ``Base.foo(instance)`` style invocations that would
    bypass override-checking."""

    def __init__(self, fn):
        self.fn = fn

    def __call__(self, *args, **kwargs):
        raise TypeError(
            "abstract method called directly; override it in a subclass"
        )


def abstractmethod(fn):
    """Mark ``fn`` as abstract. Subclasses must override the method."""
    return _AbstractMarker(fn)


def _find_abstract_names(cls):
    """Return sorted list of method names on ``cls`` that are still
    abstract (i.e. still wrapped in the marker, meaning the class
    didn't override them)."""
    abstracts = []
    for name in dir(cls):
        if name.startswith("_"):
            continue
        try:
            value = getattr(cls, name)
        except AttributeError:
            continue
        if isinstance(value, _AbstractMarker):
            abstracts.append(name)
    abstracts.sort()
    return abstracts


class ABC:
    """Base class for abstract types.

    Cannot be instantiated directly if any method is marked
    ``@abstractmethod`` and hasn't been overridden by a subclass.
    Subclasses inherit the abstractness check; once every abstract
    method is overridden, instantiation works normally.
    """

    def __new__(cls, *args, **kwargs):
        abstracts = _find_abstract_names(cls)
        if abstracts:
            raise TypeError(
                "Can't instantiate abstract class "
                + cls.__name__
                + " with abstract method(s) "
                + ", ".join(abstracts)
            )
        return super().__new__(cls)
