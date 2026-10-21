# nanopython — js module (ADR-006 J2).
#
# Browser bridge: synchronous host calls to the JavaScript globalThis.
# See docs/src/adrs/006-js-interop.md for design + ABI stability.
#
# The wasm host registers js_* imports (web/lib/js-bridge.js); this Python
# module fronts them via the `_nanopython_js` builtin module (gated by
# -Dfeature-js at build time).
#
# Under native + wasmtime CLI, `_nanopython_js` does not exist (the C
# module table doesn't include it), so `from _nanopython_js import ...`
# raises ImportError. We translate that to a single ImportError with a
# message pointing at ADR-006 D5.

try:
    from _nanopython_js import _bridge_present
    _AVAILABLE = bool(_bridge_present())
except (ImportError, OSError):
    _AVAILABLE = False


def is_browser():
    """Return True if the JS host bridge is live; False under native / wasmtime CLI."""
    return _AVAILABLE


if not _AVAILABLE:
    raise ImportError(
        "js: no host bridge available. nanopython must be built with "
        "-Dfeature-js=true and run inside a browser/host that registers "
        "the js_* wasm imports. See docs/src/adrs/006-js-interop.md."
    )


from _nanopython_js import (
    _get_global,
    _get_attr,
    _set_attr,
    _call,
    _release,
    _create_string,
    _create_int,
    _to_string,
    _to_int,
    _create_callback,
    _set_dispatcher,
)


# J5a — Python callback marshaling.
#
# JS-side event handlers (addEventListener, setTimeout callbacks, Promise
# .then chains in the future J6 asyncify arc) require handing JS a function
# that, when called, runs Python. We register callables in this dict (the
# GC anchor — without it the wasm-side dispatcher would hold dangling Obj
# refs after the local var goes out of scope) and ask the bridge to mint a
# JS function that, when called, fires back into wasm via the export
# `npy_dispatch_callback(id, args_ptr, args_count)`.
_CALLBACKS = {}
_NEXT_CALLBACK_ID = 1


def _dispatch_callback(callback_id, args):
    """Run the registered Python callable. Called from Zig (npy_dispatch_callback).

    ``args`` is a list of int JS handles (the JS-side raw arg handles for
    the event). We wrap each one in a JsProxy so user code receives a
    familiar handle-like object (proxy.target, proxy.type, etc.).

    Returns a JS handle for the callback's return value (0 if the callback
    returns None, the proxy's underlying handle if it returns a JsProxy).
    """
    fn = _CALLBACKS.get(callback_id)
    if fn is None:
        return 0
    proxies = [JsProxy(h) for h in args]
    try:
        result = fn(*proxies)
    except Exception:
        # Swallow — JS has no exception channel here. A future arc can add
        # console.error reporting via the bridge.
        return 0
    if result is None:
        return 0
    if isinstance(result, JsProxy):
        return result._h
    return _marshal(result)


def _marshal(value):
    """Convert a Python value to a JS-side handle."""
    if isinstance(value, JsProxy):
        return value._h
    if isinstance(value, str):
        return _create_string(value)
    if isinstance(value, bool):
        # Bool subclasses int in Python; check before int to avoid losing the
        # boolean distinction. First cut maps True/False to 1/0 ints.
        return _create_int(1 if value else 0)
    if isinstance(value, int):
        return _create_int(value)
    if callable(value):
        # J5a — callables get a stable id, are pinned in _CALLBACKS for GC,
        # and the JS side gets back a function handle that fires into
        # npy_dispatch_callback when invoked.
        global _NEXT_CALLBACK_ID
        cb_id = _NEXT_CALLBACK_ID
        _NEXT_CALLBACK_ID += 1
        _CALLBACKS[cb_id] = value
        return _create_callback(cb_id)
    # Static message: type(x).__name__ is unavailable under nano (raises
    # AttributeError "no such attribute"), so we'd trap before reaching
    # the TypeError. Same family of gotchas as the __setattr__ and
    # sys.stdout notes elsewhere in this file.
    raise TypeError("unsupported value type for js bridge (must be str, int, bool, callable, or JsProxy)")


class JsProxy:
    """Handle to a JS object. Proxies attribute access + calls.

    Notes on nano build:
      - ``__slots__`` is silently ignored by MicroPython, so we don't use it.
      - ``MICROPY_PY_DELATTR_SETATTR`` was OFF in v0.6 and earlier; flipped
        to ON in v0.7. ``__setattr__`` now fires on user classes, so
        ``proxy.name = value`` pushes to JS directly. The legacy
        :meth:`set` method is kept for backwards compatibility.
      - Internal attributes (names starting with ``_``) are routed through
        ``object.__setattr__`` so they stay on the Python side instead of
        being pushed to the JS object.
    """

    def __init__(self, handle):
        # Bypass our own __setattr__ for the internal handle storage.
        object.__setattr__(self, "_h", handle)

    def __getattr__(self, name):
        # __getattr__ only fires for names not already on the instance, so
        # this never recurses through ``self._h`` lookup.
        return JsProxy(_get_attr(self._h, name))

    def __setattr__(self, name, value):
        # Internal attributes (prefixed _) stay Python-side; public ones
        # push to the JS object via the bridge. The check happens here,
        # not via descriptor protocol, so subclassing works.
        if name.startswith("_"):
            object.__setattr__(self, name, value)
        else:
            _set_attr(self._h, name, _marshal(value))

    def set(self, name, value):
        """Push ``obj.<name> = value`` to the JS side.

        Legacy method, kept for backwards compatibility. New code can use
        ``proxy.name = value`` directly now that nano supports
        ``__setattr__`` dispatch (v0.7).
        """
        _set_attr(self._h, name, _marshal(value))

    def __call__(self, *args):
        handles = [_marshal(a) for a in args]
        return JsProxy(_call(self._h, handles))

    def to_str(self):
        """Return the JS-side string conversion of this proxy.

        Prefer this over ``str(proxy)`` in nano + wasm code: it goes
        straight to the bridge's ``_to_string`` shim without depending on
        the interpreter's ``__str__`` dispatch path. ``__str__`` IS wired
        on user classes under nano (verified on native via a standalone
        test), but the wasm/browser path was observed to silently return
        the default object repr instead of calling ``__str__`` — the
        symptom that surfaced the validation demo's "always Validated"
        bug. Using :meth:`to_str` removes that variable entirely.
        """
        return _to_string(self._h)

    def to_int(self):
        """Return the JS-side int conversion of this proxy. See :meth:`to_str`."""
        return _to_int(self._h)

    def __str__(self):
        # Kept for the full-config / native code paths where dispatch
        # works. Browser code should call :meth:`to_str` explicitly.
        return _to_string(self._h)

    def __int__(self):
        return _to_int(self._h)

    def __del__(self):
        # Minimal lifecycle per ADR-006 D4 / Q2: release on garbage-collect;
        # cycle leaks accepted.
        try:
            _release(self._h)
        except Exception:
            # Interpreter teardown may already have torn down the bridge;
            # swallow to avoid noisy errors during __del__.
            pass


def get(name):
    """Look up `globalThis[name]` and return a JsProxy.

    Use this for any global not pre-instantiated below — e.g.
    ``js.get("fetch")``, ``js.get("crypto")``. The pre-instantiated
    attributes (``document`` / ``window`` / ``console`` / ``Math`` /
    ``JSON``) are normal module attributes and cheaper than `get()`.
    """
    return JsProxy(_get_global(name))


# Pre-instantiated common globals.
#
# We can't use the PEP 562 module ``__getattr__`` trick here: nanopython's
# port config sets MICROPY_CONFIG_ROM_LEVEL_MINIMUM, which disables
# MICROPY_MODULE_GETATTR. Storing ``__getattr__`` on ``sys.modules["js"]``
# succeeds (the module dict isn't fixed) but the attribute is never
# consulted on lookup — ``js.document`` raises ``AttributeError`` and the
# unhandled exception trips a wasm trap (``unreachable executed``) inside
# the host. So we instead bind the handful of globals demo code reaches
# for at module-load time. For anything not in this list, use ``get()``.
document = JsProxy(_get_global("document"))
window = JsProxy(_get_global("window"))
console = JsProxy(_get_global("console"))
Math = JsProxy(_get_global("Math"))
JSON = JsProxy(_get_global("JSON"))

# J5a — Hand the Zig side a reference to our dispatcher. From here on the
# wasm-side `npy_dispatch_callback` export forwards JS-triggered events
# into `_dispatch_callback(id, args)` above. Registered once at import.
_set_dispatcher(_dispatch_callback)
