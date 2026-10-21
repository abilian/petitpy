"""unittest.mock — minimal MagicMock + patch subset for nanopython.

Ships what CPython test suites written for pytest+mock typically use:

    m = MagicMock()             — auto-attribute-generating mock. Any
    m.foo.bar(1, x=2)             attribute access creates a child mock;
                                  any call is recorded on .call_args,
                                  .call_args_list, .called, .call_count.

    m.return_value = 42         — configure the value a call returns.
    m.side_effect = Exc         — raise on call.
    m.side_effect = [a, b]      — return successive values.
    m.assert_called()           — assert at least one call.
    m.assert_called_once()      — assert exactly one call.
    m.assert_called_with(*a)    — assert the last call's args match.
    m.assert_called_once_with()
    m.assert_not_called()

    with patch.object(mod, "attr", MagicMock()):
        ...                     — restore on exit.
    with patch.object(mod, "attr", side_effect=X):
        ...                     — auto-wraps in MagicMock.
    @patch.object(mod, "attr")  — decorator form.
    with patch("pkg.mod.name", …):
        ...                     — string-target form.

    ANY                         — sentinel that == anything.

Not shipped:
    - full CPython mock features (mock_open, PropertyMock, seal,
      auto-spec, spec_set, wraps)
    - MagicMock's magic-method double-underscore protocol (__len__,
      __iter__, etc.) — CPython's version adds these on demand; ours
      raises AttributeError for dunders you didn't set.
"""


class _Sentinel:
    """`ANY == x` is True for every `x`. Used in
    `assert_called_with(ANY, expected_second_arg)`."""

    def __eq__(self, other):
        return True

    def __ne__(self, other):
        return False

    def __hash__(self):
        return 0

    def __repr__(self):
        return "ANY"


ANY = _Sentinel()


class _Call:
    """One recorded call: `.args` = positional tuple, `.kwargs` = dict.
    Unpacks as `(args, kwargs)` — CPython's mock.call is a tuple
    subclass so `args, kwargs = mock.call_args` works. Compares equal
    to a plain tuple of that shape as well as to another _Call."""

    def __init__(self, args, kwargs):
        self.args = tuple(args)
        self.kwargs = dict(kwargs)

    def __eq__(self, other):
        if isinstance(other, _Call):
            return self.args == other.args and self.kwargs == other.kwargs
        # tuple form: (args, kwargs) — real mock.call's tuple shape.
        if isinstance(other, tuple) and len(other) == 2:
            a, kw = other
            return tuple(self.args) == tuple(a) and dict(self.kwargs) == dict(kw)
        return False

    def __ne__(self, other):
        return not self.__eq__(other)

    def __iter__(self):
        # Enables `args, kwargs = mock.call_args`.
        yield self.args
        yield self.kwargs

    def __len__(self):
        return 2

    def __getitem__(self, i):
        if i == 0 or i == -2:
            return self.args
        if i == 1 or i == -1:
            return self.kwargs
        raise IndexError("_Call index out of range")

    def __repr__(self):
        return "call(" + ", ".join(
            [repr(a) for a in self.args]
            + [k + "=" + repr(v) for k, v in self.kwargs.items()]
        ) + ")"


class MagicMock:
    """Attribute-magic mock. Any attribute access creates a child mock;
    calls are recorded and can be asserted on."""

    def __init__(self, return_value=None, side_effect=None, name=""):
        # `_children` maps attribute names → child MagicMocks so
        # `m.foo` is always the SAME mock across accesses (real mock
        # behaviour — call history persists).
        # Stored via object.__setattr__ so the __setattr__ override
        # below doesn't loop through itself.
        object.__setattr__(self, "_children", {})
        object.__setattr__(self, "_return_value", return_value)
        object.__setattr__(self, "_side_effect", side_effect)
        object.__setattr__(self, "_name", name)
        object.__setattr__(self, "call_args", None)
        object.__setattr__(self, "call_args_list", [])
        object.__setattr__(self, "called", False)
        object.__setattr__(self, "call_count", 0)

    def __call__(self, *args, **kwargs):
        object.__setattr__(self, "called", True)
        object.__setattr__(self, "call_count", self.call_count + 1)
        c = _Call(args, kwargs)
        object.__setattr__(self, "call_args", c)
        self.call_args_list.append(c)
        se = self._side_effect
        if se is not None:
            if isinstance(se, BaseException) or (
                isinstance(se, type) and issubclass(se, BaseException)
            ):
                raise se
            if callable(se):
                return se(*args, **kwargs)
            if isinstance(se, (list, tuple)):
                # iterable of successive return values
                idx = self.call_count - 1
                if idx < len(se):
                    v = se[idx]
                    if isinstance(v, BaseException) or (
                        isinstance(v, type) and issubclass(v, BaseException)
                    ):
                        raise v
                    return v
                raise StopIteration()
        return self._return_value

    def __getattr__(self, name):
        # __getattr__ only fires for MISSING attrs, so we don't clash
        # with the object.__setattr__-set instance attrs above.
        if name.startswith("__") and name.endswith("__"):
            # Dunder access — raise so isinstance / hash / etc. keep
            # working via type slots. Users who want e.g. __len__ on a
            # mock set it explicitly.
            raise AttributeError("no attribute " + repr(name))
        children = self._children
        if name not in children:
            children[name] = MagicMock(name=self._name + "." + name if self._name else name)
        return children[name]

    def __setattr__(self, name, value):
        # Direct assignment (e.g. m.return_value = 42, m.foo = 3) — the
        # test wants to configure a specific attr, so store it on the
        # instance's members map so __getattr__ doesn't override.
        # Special-case the well-known configure keys so they land on
        # the object.__setattr__ path (bypass the auto-child dict).
        if name in {
            "return_value", "side_effect", "call_args",
            "call_args_list", "called", "call_count",
            "_children", "_return_value", "_side_effect", "_name",
        }:
            if name == "return_value":
                object.__setattr__(self, "_return_value", value)
            elif name == "side_effect":
                object.__setattr__(self, "_side_effect", value)
            else:
                object.__setattr__(self, name, value)
            return
        # Anything else → treat like `m.foo = X`: replace the child
        # mock with the caller-supplied value.
        self._children[name] = value

    @property
    def return_value(self):
        # Auto-create a child MagicMock on first read so
        # `mock.return_value.some_attr = value` works — CPython's Mock
        # behaves the same way (return_value defaults to a fresh Mock,
        # not None, and callers configure attributes on it before
        # the mock is invoked).
        if self._return_value is None:
            object.__setattr__(self, "_return_value", MagicMock())
        return self._return_value

    @return_value.setter
    def return_value(self, v):
        object.__setattr__(self, "_return_value", v)

    @property
    def side_effect(self):
        return self._side_effect

    @side_effect.setter
    def side_effect(self, v):
        object.__setattr__(self, "_side_effect", v)

    # ── assertions ────────────────────────────────────────────────────
    def assert_called(self):
        if not self.called:
            raise AssertionError("expected mock to be called, but was not")

    def assert_not_called(self):
        if self.called:
            raise AssertionError(
                "expected mock NOT to be called, but was called "
                + str(self.call_count) + " times"
            )

    def assert_called_once(self):
        if self.call_count != 1:
            raise AssertionError(
                "expected exactly 1 call, got " + str(self.call_count)
            )

    def assert_called_with(self, *args, **kwargs):
        if self.call_args is None:
            raise AssertionError("expected mock to be called, but was not")
        expected = _Call(args, kwargs)
        if self.call_args != expected:
            raise AssertionError(
                "expected " + repr(expected) + ", got " + repr(self.call_args)
            )

    def assert_called_once_with(self, *args, **kwargs):
        self.assert_called_once()
        self.assert_called_with(*args, **kwargs)

    def reset_mock(self):
        object.__setattr__(self, "call_args", None)
        object.__setattr__(self, "call_args_list", [])
        object.__setattr__(self, "called", False)
        object.__setattr__(self, "call_count", 0)


# Mock is an alias — CPython distinguishes MagicMock (adds magic method
# support) from Mock (bare); for our purposes they're identical.
Mock = MagicMock


class _NoValueT:
    pass


_NO_VALUE = _NoValueT()


class _Patcher:
    """Context manager + decorator returned by `patch.object` / `patch`.
    On enter: replace `target.attr` with the configured mock; on exit:
    restore the original value.

    ``new`` may legitimately be ``None`` when the caller wants to
    replace the attribute with the None sentinel — we use a private
    _NO_VALUE marker so `patch.object(mod, "attr", None)` doesn't get
    silently swapped for a MagicMock."""

    def __init__(self, target, attr, new=_NO_VALUE, side_effect=None,
                 return_value=None, autospec=None, create=False):
        self.target = target
        self.attr = attr
        self.new_explicit = new
        self.side_effect = side_effect
        self.return_value = return_value
        self.create = create
        self._original = None
        self._had_attr = False
        self._new_mock = None

    def _build_mock(self):
        if self.new_explicit is not _NO_VALUE:
            return self.new_explicit
        m = MagicMock()
        if self.side_effect is not None:
            m.side_effect = self.side_effect
        if self.return_value is not None:
            m.return_value = self.return_value
        return m

    def __enter__(self):
        # Snapshot the original value so we can restore it.
        try:
            self._original = getattr(self.target, self.attr)
            self._had_attr = True
        except AttributeError:
            self._original = None
            self._had_attr = False
            if not self.create:
                raise AttributeError(
                    "target has no attribute " + repr(self.attr)
                )
        self._new_mock = self._build_mock()
        setattr(self.target, self.attr, self._new_mock)
        return self._new_mock

    def __exit__(self, exc_type, exc, tb):
        if self._had_attr:
            setattr(self.target, self.attr, self._original)
        else:
            try:
                delattr(self.target, self.attr)
            except (AttributeError, TypeError):
                pass
        return False

    def __call__(self, fn):
        # Decorator form: wrap `fn` so it runs inside the patch.
        patcher = self

        def wrapped(*args, **kwargs):
            with patcher as m:
                return fn(*args + (m,), **kwargs)

        return wrapped


class _PatchNamespace:
    """The `patch` object itself — callable (string-target form) with
    an `.object` attribute (module-target form)."""

    def __call__(self, target, new=_NO_VALUE, side_effect=None,
                 return_value=None, autospec=None, create=False):
        # `patch("pkg.mod.attr", …)` — dotted-string target. Real
        # CPython walks progressively shorter prefixes until an
        # `import` succeeds, then treats the rest as an attribute
        # chain — `patch("hop3_rootd.exec.shutil.which")` might land
        # `import hop3_rootd.exec` and then `.shutil.which`.
        if not isinstance(target, str):
            raise TypeError("patch() expects a dotted string target")
        idx = target.rfind(".")
        if idx < 0:
            raise ValueError("patch target must be dotted, got " + repr(target))
        parts = target.split(".")
        obj = None
        attr_chain = ()
        for i in range(len(parts) - 1, 0, -1):
            mod_name = ".".join(parts[:i])
            try:
                obj = __import__(mod_name)
                for piece in parts[1:i]:
                    obj = getattr(obj, piece)
            except (ImportError, AttributeError):
                continue
            attr_chain = tuple(parts[i:])
            break
        if obj is None or not attr_chain:
            raise ImportError("patch: can't import " + repr(target))
        # Walk everything except the last piece — those must already
        # exist and get us to the object whose attribute we replace.
        for piece in attr_chain[:-1]:
            obj = getattr(obj, piece)
        attr = attr_chain[-1]
        return _Patcher(
            obj, attr, new=new, side_effect=side_effect,
            return_value=return_value, autospec=autospec, create=create,
        )

    def object(self, target, attr, new=_NO_VALUE, side_effect=None,
               return_value=None, autospec=None, create=False):
        return _Patcher(
            target, attr, new=new, side_effect=side_effect,
            return_value=return_value, autospec=autospec, create=create,
        )


patch = _PatchNamespace()


def call(*args, **kwargs):
    """Construct a _Call for use in assert_called_with equality checks."""
    return _Call(args, kwargs)
