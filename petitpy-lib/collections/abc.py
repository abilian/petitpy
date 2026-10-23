"""collections.abc — no-op ABC stubs for MicroPython-shape isinstance
and type-annotation compatibility.

CPython's collections.abc ships real abstract base classes with
__subclasshook__ machinery so `isinstance(obj, Iterable)` walks
protocols. MicroPython's object model doesn't support that; the
practical CPython idioms are:

  1. Type annotations — `def f(x: Callable) -> Mapping[str, int]:`.
     Under `from __future__ import annotations` these are strings
     at runtime; the names just need to be importable.
  2. isinstance guards for duck-type dispatch (rarer). These will
     return False here, callers that rely on the check must fall
     back to hasattr/EAFP.

Every ABC is bound to `object` so isinstance(x, ABC) evaluates False
(no user class inherits object-with-mro-slot as its base) but never
raises. Rebinding to a real class would need a MicroPython
`__subclasshook__` we don't have.
"""

Callable = object
Hashable = object
Iterable = object
Iterator = object
Reversible = object
Generator = object
Sized = object
Container = object
Collection = object
Sequence = object
MutableSequence = object
ByteString = object
Set = object
MutableSet = object
Mapping = object
MutableMapping = object
MappingView = object
ItemsView = object
KeysView = object
ValuesView = object
Awaitable = object
Coroutine = object
AsyncIterable = object
AsyncIterator = object
AsyncGenerator = object
