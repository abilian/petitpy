"""pytest_lite — minimal pytest-shaped test runner for nanopython.

Discovers functions named ``test_*`` in a module, runs each, reports
pass/fail/skip. Plain ``assert`` is the assertion mechanism; on failure
the exception message is shown (no AST rewriting, no intermediate-value
introspection — bare CPython assert semantics).

Supports:
  - ``def test_*():`` discovery in any imported module
  - ``with pytest.raises(ExcType):`` — assert the block raises
  - ``pytest.skip(reason)`` — skip the current test (called inside)
  - ``@pytest.skip`` — decorator form (skip unconditionally)
  - ``run_module(module)``, ``run_self_tests(name)`` — programmatic
  - ``main([file_or_dir])`` — CLI entry; ``python -m pytest_lite tests/``

Not supported (vs CPython pytest):
  - ``@pytest.fixture``, ``conftest.py``, plugin system
  - ``@pytest.mark.parametrize``, ``@pytest.mark.skipif``
  - Class-based tests (``class TestSomething:``)
  - capsys / monkeypatch / tmp_path / caplog
  - AST-rewritten assertions (intermediate value reporting)

See ADR 011 for the design rationale and the v0.7 stdlib plan.
"""

import sys


# ── outcomes ──────────────────────────────────────────────────────────────

_PASS = "PASS"
_FAIL = "FAIL"
_SKIP = "SKIP"


class TestResult:
    """One test's outcome. ``outcome`` is one of "PASS" / "FAIL" / "SKIP";
    ``message`` is the failure or skip reason (empty for PASS)."""

    def __init__(self, name, outcome, message=""):
        self.name = name
        self.outcome = outcome
        self.message = message

    def __repr__(self):
        return "<TestResult " + self.name + ": " + self.outcome + ">"


# ── helpers callers use inside tests ──────────────────────────────────────


def _match_pattern(pattern, text):
    """Real pytest uses ``re.search(pattern, text)``; we call our re
    shim, and if that fails to compile the pattern we degrade to a
    plain substring check so tests using literal strings still pass."""
    try:
        import re as _re
        return _re.search(pattern, text) is not None
    except Exception:
        return pattern in text


class raises:
    """Context manager: assert the block raises an exception of the given type.

    Usage::

        with pytest.raises(ValueError):
            int("not a number")

        with pytest.raises(ValueError, match="expected"):
            raise ValueError("expected substring in msg")

    The captured exception is available as ``.value`` after the block
    exits. ``match`` is a substring-in-str(exc) check (real pytest uses
    ``re.search``; we skip the regex escape cost — plain-substring is
    what nearly every use in the wild wants)."""

    def __init__(self, exc_type, match=None):
        self.exc_type = exc_type
        self.match = match
        self.value = None

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        if exc_type is None:
            raise AssertionError(
                "DID NOT RAISE " + self.exc_type.__name__
            )
        if not issubclass(exc_type, self.exc_type):
            return False
        if self.match is not None:
            msg = str(exc)
            if not _match_pattern(self.match, msg):
                raise AssertionError(
                    "expected pattern " + repr(self.match)
                    + " in " + repr(msg)
                )
        self.value = exc
        return True


class _SkipException(Exception):
    """Internal: raised by skip() to mark a test as skipped."""


def skip(reason_or_fn=""):
    """Skip the current test. Can be called inline or used as a decorator.

    Inline::
        if some_condition:
            pytest.skip("reason")

    Decorator::
        @pytest.skip
        def test_not_ready():
            ...
    """
    if callable(reason_or_fn):
        # Used as `@skip` (no args). We don't bother trying to copy
        # `__name__` to the wrapper — nano doesn't support function-
        # attribute assignment, and the test runner discovers tests
        # by their position in the namespace, not by `fn.__name__`.
        def wrapper(*args, **kw):
            raise _SkipException("@skip decorator")

        return wrapper
    raise _SkipException(str(reason_or_fn) or "(no reason given)")


# ── discovery + execution ─────────────────────────────────────────────────


def _walk_module(module):
    """Yield (name, fn) for each test_* function in the module, and for
    each test_* method of a Test* class, bound to a fresh instance per
    test as pytest does."""
    for name in dir(module):
        obj = getattr(module, name)
        if name.startswith("Test") and isinstance(obj, type):
            for meth in dir(obj):
                if meth.startswith("test_"):
                    yield meth, getattr(obj(), meth)
        elif name.startswith("test_") and callable(obj):
            yield name, obj


def _run_test(name, fn, fixtures=None, module=None):
    """Run a single test function, return a TestResult.

    ``fixtures`` is a dict {test_name: [param_name, …]} — usually supplied
    by an outer runner that parses the test file's source (nanopython
    doesn't expose ``__code__.co_varnames``). Each param name is resolved
    via ``_resolve_fixture`` — built-in pytest fixtures (``tmp_path``,
    ``monkeypatch``) get a stub, user fixtures pulled from ``module`` by
    matching name. Unresolvable params fall through to ``fn()`` and
    produce the usual TypeError."""
    # Per-test fixture cache: real pytest resolves each fixture once
    # per test-run so the value the test sees as `save_spy` is the
    # same instance that the fixture-of-fixture `ctx(save_spy)`
    # closed over.
    cache = {}
    kwargs = {}
    if fixtures:
        params = fixtures.get(name)
        if params:
            for p in params:
                v = _resolve_fixture(p, module, fixtures, cache=cache)
                if v is _UNRESOLVED:
                    kwargs = None
                    break
                kwargs[p] = v
    return _call(name, fn, kwargs or {}, cache)


def _call(label, fn, kwargs, cache):
    """Run one test and return its TestResult. Monkeypatches are undone
    afterwards, as pytest does, so they cannot leak into later tests."""
    try:
        fn(**kwargs)
    except _SkipException as e:
        return TestResult(label, _SKIP, str(e))
    except AssertionError as e:
        return TestResult(label, _FAIL, str(e) or "(no message)")
    except Exception as e:
        return TestResult(label, _FAIL, type(e).__name__ + ": " + str(e))
    finally:
        if "monkeypatch" in cache:
            cache["monkeypatch"].undo()
    return TestResult(label, _PASS)


# ── minimal fixture surface ───────────────────────────────────────────────

class _Monkeypatch:
    """Miniature pytest monkeypatch — records what it changed and
    undoes it in ``undo()``. Enough for the common
    ``monkeypatch.setattr(obj, 'name', value)`` /
    ``monkeypatch.setenv(k, v)`` idiom."""

    def __init__(self):
        self._attr_stack = []
        self._env_stack = []

    def setattr(self, target, name=None, value=None, raising=True):
        # Two call shapes: monkeypatch.setattr(obj, "name", val) and the
        # dotted-string form monkeypatch.setattr("pkg.mod.name", val)
        # where CPython takes (dotted, value) with `name` absent — we
        # detect via `value is None and name is not None and target is
        # a str`. Everything else is the object form.
        if isinstance(target, str) and value is None and name is not None:
            dotted = target
            value = name
            # CPython's monkeypatch tries progressively shorter module
            # prefixes: for "a.b.c.d" it imports "a.b.c" and treats "d"
            # as an attribute, then falls back to importing "a.b" and
            # treating "c.d" as an attribute chain, etc. Copy that
            # behaviour so `setattr("hop3_rootd.audit.os.fsync", boom)`
            # walks through `import hop3_rootd.audit` → `.os.fsync`.
            parts = dotted.split(".")
            obj = None
            attr_chain = []
            for i in range(len(parts) - 1, 0, -1):
                mod_path = ".".join(parts[:i])
                try:
                    obj = __import__(mod_path)
                    for piece in parts[1:i]:
                        obj = getattr(obj, piece)
                except (ImportError, AttributeError):
                    continue
                attr_chain = parts[i:]
                break
            if obj is None or not attr_chain:
                raise ValueError("dotted setattr: cannot locate module in "
                                 + repr(dotted))
            # Walk all but the last attr — these must already exist.
            for piece in attr_chain[:-1]:
                obj = getattr(obj, piece)
            attr = attr_chain[-1]
            had = hasattr(obj, attr)
            original = getattr(obj, attr, None) if had else None
            setattr(obj, attr, value)
            self._attr_stack.append((obj, attr, had, original))
            return
        had = hasattr(target, name)
        original = getattr(target, name, None) if had else None
        setattr(target, name, value)
        self._attr_stack.append((target, name, had, original))

    def setenv(self, name, value):
        import os
        had = name in getattr(os, "environ", {})
        prev = os.getenv(name, None) if had else None
        self._env_stack.append((name, had, prev))
        if hasattr(os, "putenv"):
            os.putenv(name, value)

    def delenv(self, name, raising=True):
        import os
        prev = os.getenv(name, None)
        self._env_stack.append((name, prev is not None, prev))
        if prev is not None and hasattr(os, "unsetenv"):
            os.unsetenv(name)

    def undo(self):
        while self._attr_stack:
            target, name, had, original = self._attr_stack.pop()
            if had:
                setattr(target, name, original)
            else:
                try:
                    delattr(target, name)
                except (AttributeError, TypeError):
                    pass
        while self._env_stack:
            import os
            name, had, prev = self._env_stack.pop()
            if had and prev is not None and hasattr(os, "putenv"):
                os.putenv(name, prev)
            elif hasattr(os, "unsetenv"):
                os.unsetenv(name)


class _UnresolvedT:
    """Sentinel — a param the runner can't resolve."""


_UNRESOLVED = _UnresolvedT()


def _make_tmp_path():
    """Build a fresh temp directory and return a Path. Falls back to
    building the directory manually if pathlib.Path.mkdir isn't
    available. Base directory is realpath-resolved so callers that
    later `os.path.realpath` a subpath don't see the macOS-style
    `/tmp` → `/private/tmp` divergence."""
    import os
    from pathlib import Path
    try:
        import time
        stem = str(time.time_ns() if hasattr(time, "time_ns") else int(time.time() * 1_000_000))
    except ImportError:
        stem = str(os.getpid())
    base = os.getenv("TMPDIR") or "/tmp"
    try:
        import os_path
        base = os_path.realpath(base)
    except (ImportError, Exception):
        pass
    # Nest tmp_path under a per-test parent so ``tmp_path.parent`` is
    # unique per test (CPython pytest does the same). Otherwise tests
    # that create sibling files/dirs via ``tmp_path.parent / …``
    # collide between test invocations.
    parent = Path(base) / ("pytest-lite-" + stem)
    n = 0
    while parent.exists():
        n += 1
        parent = Path(base) / ("pytest-lite-" + stem + "-" + str(n))
    parent.mkdir()
    p = parent / "tmp_path"
    p.mkdir()
    return p


def _resolve_fixture(name, module, fixtures=None, chain=None, cache=None):
    """Resolve a parameter name to a fixture value. Return _UNRESOLVED
    when we can't help (caller falls back to no-arg call).

    ``module`` is the test module whose fixtures we search when the
    name isn't a builtin. ``fixtures`` is the runner-supplied {name:
    [param, …]} map covering both test functions and their fixture
    helpers. ``chain`` guards against fixture cycles.

    ``cache`` is a per-test dict; identical names resolve to the same
    instance so the test's own ``save_spy`` param and its ``ctx``'s
    inner ``save_spy`` reference the same object (real pytest does the
    same via function-scoped fixture caching)."""
    if chain is None:
        chain = set()
    if cache is None:
        cache = {}
    if name in chain:
        return _UNRESOLVED
    if name in cache:
        return cache[name]
    if name == "tmp_path":
        try:
            v = _make_tmp_path()
        except Exception:
            return _UNRESOLVED
        cache[name] = v
        return v
    if name == "monkeypatch":
        v = _Monkeypatch()
        cache[name] = v
        return v
    # Look for a user fixture in the test module: a same-named
    # function (our @pytest.fixture stub returned it unchanged).
    if module is None:
        return _UNRESOLVED
    candidate = getattr(module, name, _UNRESOLVED)
    if candidate is _UNRESOLVED or not callable(candidate):
        return _UNRESOLVED
    params = (fixtures or {}).get(name, [])
    kwargs = {}
    new_chain = chain | {name}
    for p in params:
        v = _resolve_fixture(p, module, fixtures, new_chain, cache)
        if v is _UNRESOLVED:
            return _UNRESOLVED
        kwargs[p] = v
    # Let the fixture's own exception propagate so the test's outcome
    # attributes the failure to the fixture rather than manifesting as
    # a downstream TypeError when the resolver falls back to
    # calling the test with no args.
    value = candidate(**kwargs)
    # Generator fixtures (`yield <value>` inside a @pytest.fixture)
    # produce the value after one advance; real pytest also runs the
    # tail (teardown) after the test finishes, we just leak it — good
    # enough for CPython test suites that use the pattern to scope
    # `with patch(...):` around the yield.
    # Only __next__ — nanopython's generators lack __iter__.
    if hasattr(value, "__next__"):
        try:
            result = next(value)
        except StopIteration:
            return _UNRESOLVED
        cache[name] = result
        return result
    cache[name] = value
    return value


def _module_of(fn):
    """Best-effort: extract the module a function was defined in.
    Nanopython doesn't expose ``fn.__module__`` reliably, but if the
    caller passed us a module-scoped function we can walk sys.modules."""
    modname = getattr(fn, "__module__", None)
    if modname is None:
        return None
    import sys
    return sys.modules.get(modname)


def run_module(module, verbose=True, fixtures=None, parametrize=None):
    """Run all test_* functions in ``module``. Return list of TestResult.
    When ``verbose`` is true, prints each result as it runs.

    ``fixtures`` is an optional {test_name: [param_name, …]} mapping —
    typically produced by an outer test-runner that parses the source
    (since nanopython has no ``inspect``). See ``_run_test``.

    ``parametrize`` mirrors CPython pytest's ``@pytest.mark.parametrize``
    — {test_name: [(names_tuple, [value | value_tuple, …]), …]}. Each
    entry adds one dimension of value rows; multiple entries produce the
    cartesian product. The outer runner extracts this from the test
    source (again — no runtime __code__)."""
    parametrize = parametrize or {}
    results = []
    for name, fn in _walk_module(module):
        entries = parametrize.get(name)
        if entries:
            # Fixture params that aren't in the parametrize name lists
            # still need resolving through the normal fixture map.
            param_names = set()
            for names, _rows in entries:
                for n in names:
                    param_names.add(n)
            fixture_params = [p for p in (fixtures or {}).get(name, [])
                              if p not in param_names]
            for combo in _cartesian(entries):
                label = name + "[" + _label_for(combo) + "]"
                result = _run_parametrized(label, fn, combo, fixtures,
                                           fixture_params, module)
                results.append(result)
                if verbose:
                    print("  " + result.outcome + "  " + label)
                    if result.message and result.outcome == _FAIL:
                        print("        " + result.message)
        else:
            result = _run_test(name, fn, fixtures=fixtures, module=module)
            results.append(result)
            if verbose:
                print("  " + result.outcome + "  " + name)
                if result.message and result.outcome == _FAIL:
                    print("        " + result.message)
    return results


def _cartesian(entries):
    """entries: [(names_tuple, [value | value_tuple, …]), …]. Yields
    dicts mapping every parametrize name to a resolved value."""
    if not entries:
        yield {}
        return
    names, rows = entries[0]
    for row in rows:
        head = {}
        if len(names) == 1:
            head[names[0]] = row
        else:
            for k, v in zip(names, row):
                head[k] = v
        for tail in _cartesian(entries[1:]):
            merged = dict(head)
            merged.update(tail)
            yield merged


def _label_for(combo):
    return ",".join(str(v) for v in combo.values())


def _run_parametrized(label, fn, combo, fixtures, fixture_params, module):
    kwargs = dict(combo)
    cache = {}
    for p in fixture_params:
        v = _resolve_fixture(p, module, fixtures, cache=cache)
        if v is _UNRESOLVED:
            return TestResult(label, _FAIL,
                              "could not resolve fixture " + repr(p))
        kwargs[p] = v
    return _call(label, fn, kwargs, cache)


def summarize(results):
    """Print a one-line summary. Return exit code (0 = success, 1 = any fail)."""
    n_pass = sum(1 for r in results if r.outcome == _PASS)
    n_fail = sum(1 for r in results if r.outcome == _FAIL)
    n_skip = sum(1 for r in results if r.outcome == _SKIP)
    total = len(results)
    print()
    print(
        "  "
        + str(n_pass)
        + " passed, "
        + str(n_fail)
        + " failed, "
        + str(n_skip)
        + " skipped (of "
        + str(total)
        + ")"
    )
    return 0 if n_fail == 0 else 1


# ── CLI / programmatic entry points ───────────────────────────────────────


def run_self_tests(globals_dict):
    """Run tests defined in the caller's globals and exit with the
    appropriate code. Typical usage at the bottom of a test file::

        if __name__ == "__main__":
            from pytest_lite import run_self_tests
            run_self_tests(globals())

    Why a dict and not a module name: nano's ``sys.modules`` is sparse
    (the script's __main__ isn't tracked), so we can't reach the
    current module via name lookup. ``globals()`` always works.
    """
    print("\nRunning tests:\n")
    results = []
    for name in sorted(globals_dict.keys()):
        if not name.startswith("test_"):
            continue
        obj = globals_dict[name]
        if not callable(obj):
            continue
        result = _run_test(name, obj)
        results.append(result)
        print("  " + result.outcome + "  " + name)
        if result.message and result.outcome == _FAIL:
            print("        " + result.message)
    sys.exit(summarize(results))


def main(argv=None):
    """CLI entry point. Usage: pytest_lite <file_or_module>."""
    argv = argv if argv is not None else sys.argv[1:]
    if not argv:
        print(
            "usage: pytest_lite <file.py>\n"
            "       pytest_lite <module_name>",
            file=sys.stderr,
        )
        return 2
    target = argv[0]
    module = _import_target(target)
    if module is None:
        print("could not find: " + target)
        return 2
    print("\nRunning tests from " + target + ":\n")
    results = run_module(module)
    return summarize(results)


def _import_target(target):
    """Import a module by name, or a .py file from disk (after putting
    its directory on sys.path)."""
    if target.endswith(".py"):
        idx = target.rfind("/")
        if idx >= 0:
            dir_ = target[:idx]
            name = target[idx + 1 : -3]
            if dir_ and dir_ not in sys.path:
                sys.path.insert(0, dir_)
        else:
            name = target[:-3]
        try:
            return __import__(name)
        except ImportError:
            return None
    try:
        return __import__(target)
    except ImportError:
        return None


if __name__ == "__main__":
    sys.exit(main())
