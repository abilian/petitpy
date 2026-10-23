"""petitpy — typing, mostly as import-compat placeholders.

Class annotations are kept as source text, as under `from __future__
import annotations`; get_type_hints() evaluates them. On full, the
runtime builds `list[str]` with _class_getitem() and `int | None` with
_union(), as GenericAlias and UnionType objects.

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


class _UnionForm(_Subscriptable):
    """`Union[a, b]` and `Optional[a]`, as `a | b` and `a | None`."""
    def __getitem__(self, item):
        items = item if isinstance(item, tuple) else (item,)
        if self._name == "Optional":
            items += (None,)
        r = items[0]
        for x in items[1:]:
            r = _union(r, x)
        return r


Optional = _UnionForm("Optional")
Union = _UnionForm("Union")
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


def _name(t):
    if t is None or t is type(None):
        return "None"
    if t is Ellipsis:
        return "..."
    if isinstance(t, list):
        return "[" + ", ".join(_name(a) for a in t) + "]"
    if isinstance(t, type):
        mod = getattr(t, "__module__", "builtins")
        return t.__name__ if mod == "builtins" else mod + "." + t.__name__
    return repr(t)


class GenericAlias:
    """`list[str]`: a class with type arguments."""
    def __init__(self, origin, args):
        self.__origin__ = origin
        self.__args__ = args if isinstance(args, tuple) else (args,)
    def __call__(self, *a, **kw): return self.__origin__(*a, **kw)
    def __eq__(self, o):
        return isinstance(o, GenericAlias) and self.__origin__ is o.__origin__ and self.__args__ == o.__args__
    def __hash__(self): return hash((self.__origin__, self.__args__))
    def __or__(self, o): return _union(self, o)
    def __ror__(self, o): return _union(o, self)
    def __repr__(self):
        return _name(self.__origin__) + "[" + ", ".join(_name(a) for a in self.__args__) + "]"


class UnionType:
    """`int | None`."""
    def __init__(self, args): self.__args__ = args
    def __eq__(self, o):
        return isinstance(o, UnionType) and set(self.__args__) == set(o.__args__)
    def __hash__(self): return hash(frozenset(self.__args__))
    def __or__(self, o): return _union(self, o)
    def __ror__(self, o): return _union(o, self)
    def __repr__(self): return " | ".join(_name(a) for a in self.__args__)


def _class_getitem(cls, item):
    f = getattr(cls, "__class_getitem__", None)
    if f is None:
        return GenericAlias(cls, item)
    # A plain function unless declared @classmethod; CPython makes it one.
    return f(item) if type(f) is _bound_method else f(cls, item)


_bound_method = type(GenericAlias(None, ()).__repr__)


def _union(a, b):
    args = []
    for t in (a, b):
        if t is None:
            t = type(None)
        elif not isinstance(t, (type, GenericAlias, UnionType)):
            raise TypeError("unsupported operand type(s) for |")
        for x in t.__args__ if isinstance(t, UnionType) else (t,):
            if x not in args:
                args.append(x)
    return args[0] if len(args) == 1 else UnionType(tuple(args))


def _bases(cls, out):
    if cls not in out:
        out.append(cls)
        for b in cls.__bases__:
            _bases(b, out)
    return out


def get_type_hints(obj, globalns=None, localns=None, include_extras=False):
    """Evaluate a class's annotations, its bases' first, as CPython does.

    Function annotations are not kept, so a function gives {}.
    """
    import sys
    hints = {}
    if not isinstance(obj, type):
        return hints
    for base in reversed(_bases(obj, [])):
        ann = base.__dict__.get("__annotations__")
        if not ann:
            continue
        g = globalns
        if g is None:
            m = base.__module__
            g = (sys.modules.get(m) or __import__(m)).__dict__
        l = dict(base.__dict__) if localns is None else localns
        for k, v in ann.items():
            v = eval(v, g, l)
            if isinstance(v, str):
                v = eval(v, g, l)
            hints[k] = type(None) if v is None else v
    return hints
