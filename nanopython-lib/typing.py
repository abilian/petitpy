"""nanopython — no-op typing stub.

Runtime type hints are erased on MicroPython. This module provides
the CPython names so `from typing import X` doesn't raise at import,
and `X[...]` annotations don't blow up when evaluated (they usually
aren't, under `from __future__ import annotations`).

Ships:
  * Subscriptable placeholders: Any, Final, Literal, Callable,
    Iterable, Mapping, Sequence, Optional, Union, ClassVar, IO, TextIO,
    BinaryIO, TypeVar-returning names, etc.
  * Class-shaped placeholders (inheritable): Protocol, Generic.
  * Runtime functions: TypeVar, NewType, cast, overload, final,
    runtime_checkable, get_type_hints.
  * TYPE_CHECKING = False.

Not a substitute for CPython typing at runtime — isinstance(x, Callable)
etc. don't match. This is import-compat only.
"""


class _Subscriptable:
    """X[...] returns self; isinstance safe; str shows type name."""
    def __init__(self, name="_Subscriptable"): self._name = name
    def __getitem__(self, item): return self
    def __call__(self, *a, **kw): return None
    def __repr__(self): return "typing." + self._name
    __instancecheck__ = staticmethod(lambda self, other: False)


class _Subclassable:
    """Base for Protocol/Generic — `class X(Protocol):` needs a class."""
    def __class_getitem__(cls, item): return cls


class Protocol(_Subclassable): pass
class Generic(_Subclassable): pass


Any = _Subscriptable("Any")
Final = _Subscriptable("Final")
Literal = _Subscriptable("Literal")
Self = _Subscriptable("Self")
TextIO = _Subscriptable("TextIO")
BinaryIO = _Subscriptable("BinaryIO")
IO = _Subscriptable("IO")
ClassVar = _Subscriptable("ClassVar")
NoReturn = _Subscriptable("NoReturn")
Never = _Subscriptable("Never")
TypeAlias = _Subscriptable("TypeAlias")
Optional = _Subscriptable("Optional")
Union = _Subscriptable("Union")
Callable = _Subscriptable("Callable")
Iterable = _Subscriptable("Iterable")
Iterator = _Subscriptable("Iterator")
Mapping = _Subscriptable("Mapping")
MutableMapping = _Subscriptable("MutableMapping")
Sequence = _Subscriptable("Sequence")
MutableSequence = _Subscriptable("MutableSequence")
Awaitable = _Subscriptable("Awaitable")
Coroutine = _Subscriptable("Coroutine")
Generator = _Subscriptable("Generator")
AsyncGenerator = _Subscriptable("AsyncGenerator")
ContextManager = _Subscriptable("ContextManager")
AsyncContextManager = _Subscriptable("AsyncContextManager")

# Builtin-collection aliases (CPython's legacy typing.List etc.).
List = list
Dict = dict
Tuple = tuple
Set = set
FrozenSet = frozenset
Type = type
TYPE_CHECKING = False


def TypeVar(name, *args, **kw): return object
def NewType(name, tp): return tp
def cast(tp, val): return val
def overload(fn): return fn
def final(fn): return fn
def runtime_checkable(cls): return cls
def get_type_hints(obj): return {}
