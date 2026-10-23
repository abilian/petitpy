# PORTING.md — Prescrypt to petitpy transformation reference

This is the canonical reference future sessions follow when porting `sandbox/ci-build-monitor/src/*.py` into `projects/ci-build-monitor/src/*.py`. Every rule below was derived from the actual source patterns in the upstream codebase + the nano runtime's constraints and the bridge documented in `petitpy-lib/js.py`.

Read this file BEFORE editing any ported `.py` file. If you discover a new transformation that isn't documented here, add a row and reference the source-file:line that surfaced it.

## Why a transformation pass at all

The upstream extension was authored for Prescrypt (Python-to-JavaScript transpiler). It uses JS-style attribute syntax on JS objects (`obj.attr = val`, `obj["key"] = val`) which Prescrypt compiles transparently. petitpy runs the Python sources unmodified on the wasm runtime via the J5 js bridge, but the bridge is a thin Python wrapper (`JsProxy`) around handle ints — it does not implement `__setattr__` or `__setitem__`. So writes to JS objects must go through the explicit `proxy.set(name, value)` method.

The transformations below convert Prescrypt-flavored Python into petitpy-friendly Python while preserving semantics.

## Transformation table

### Attribute write on a JS proxy

| Prescrypt source            | petitpy port              | Why                                                                                                                                  |
| --------------------------- | ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `obj.attr = val`            | `obj.set("attr", val)`       | nano's port config disables `__setattr__` dispatch on user classes (`MICROPY_PY_DELATTR_SETATTR=0`); `JsProxy.set` is the explicit replacement. See `petitpy-lib/js.py` `JsProxy` docstring. |
| `obj["key"] = val`          | `obj.set("key", val)`        | `JsProxy` does not implement `__setitem__`. Same `.set()` call works for both attribute and key writes — JS doesn't distinguish.     |

### Attribute / key read on a JS proxy

| Prescrypt source            | petitpy port              | Why                                                                                                                  |
| --------------------------- | ---------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `obj.attr` (read)           | `obj.attr` (unchanged)       | `JsProxy.__getattr__` is implemented and works.                                                                      |
| `obj["key"]` (read)         | `obj.key`                    | `JsProxy` does not implement `__getitem__`; route through `__getattr__` instead. (For dynamic-name reads, use `js.get(name)` on the global, or accept that dynamic-key reads need bracket-style helpers — see open question below.) |

### Conversions

| Prescrypt source            | petitpy port              | Why                                                                                                                  |
| --------------------------- | ---------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `str(jsproxy)`              | `jsproxy.to_str()`           | `__str__` dispatch is unreliable on the wasm path — bridge's `_to_string` shim is direct. See `JsProxy.to_str` docstring. |
| `int(jsproxy)`              | `jsproxy.to_int()`           | Same reasoning as `to_str`.                                                                                          |
| `len(jsproxy)`              | `jsproxy.length` then `.to_int()` if needed | `JsProxy` has no `__len__`; JS arrays expose `.length` as an attribute.                                              |

### `js.undefined`

Prescrypt's runtime exposes `js.undefined` as a sentinel. petitpy's `js` module does not. Replace with one of:

| Prescrypt source            | petitpy port              | Notes                                                                                                                |
| --------------------------- | ---------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `val is js.undefined`       | `val is None`                | Most JS `undefined` returns come through the bridge as `None`. Verify per call site.                                 |
| `val == js.undefined`       | wrap the read in `try / except AttributeError` | If the bridge raises rather than returning `None`, catch and treat as missing.                                       |
| `val is js.undefined`       | `val.to_str() == "undefined"` | Fallback when neither of the above is true — round-trips through the bridge's string conversion.                     |

Pick whichever lands cleanly per call site; don't introduce a project-wide `is_undefined()` helper before session 3 (we don't yet know which form dominates).

### `create_obj()`

The upstream code already abstracts this via `core.utils.create_obj()` which returns a plain Python `{}`. Prescrypt compiles `{}` to a JS object; petitpy does not. Use the bridge to materialise a real JS object:

```python
import js

def create_obj():
    return js.JSON.parse("{}")
```

The returned value is a `JsProxy` over a fresh JS object; subsequent writes use `.set("key", value)`. Update both the `create_obj` definition in `src/core_utils.py` AND the re-export in `src/providers_base.py`.

### Promise chains

`.then(fn)` and `.then(fn).catch(fn)` patterns work via the J5 callback bridge: a Python callable handed to `.then` is marshalled to a JS function (see `_marshal` and `_create_callback` in `petitpy-lib/js.py`). No source-level change is needed. **Caveat:** if a Promise chain stores callbacks across yields (which it does — `.then` runs on a future tick), the GC anchor in `_CALLBACKS` keeps them alive. Watch for memory growth on tight polling loops (`background.py`'s `chrome.alarms.onAlarm`).

### `js.chrome.X`

`chrome` is not pre-instantiated in `petitpy-lib/js.py` (the only pre-instantiated globals are `document`, `window`, `console`, `Math`, `JSON`). Two options:

1. Use `js.get("chrome").storage.local.get(...)` — explicit and matches what `js.py` advertises.
2. Add `chrome = JsProxy(_get_global("chrome"))` to `petitpy-lib/js.py` — requires a separate trivial commit, NOT in scope for this port's session 2.

**Default during port:** route through `js.get("chrome")`, factor the call into a module-level local if it's used heavily (e.g. `chrome = js.get("chrome")` at the top of `services/storage.py`). Revisit the pre-instantiation question in session 4.

### Module-level boilerplate to drop

| Prescrypt source                       | petitpy port              | Why                                                                                                                  |
| -------------------------------------- | ---------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `from __future__ import annotations`   | drop the line                | nano does not implement `__future__`; the import is silently ignored at best and may error.                          |
| `def foo() -> Build:`                  | `def foo():`                 | nano's parser tolerates simple return annotations but they cost ROM and add nothing.                                 |
| `list[Build]`, `dict[str, int]`        | drop the subscript           | nano does not implement PEP 585 generic builtins; `list[Build]` raises at parse / runtime.                            |
| `from typing import ...`               | drop the import unless used at runtime | The `typing` module is absent; runtime imports raise `ImportError`.                                                  |

### Sentinel comparisons in upstream code

Audit each `is`/`==`/`!=` comparison against:

- `None` — fine, unchanged.
- `js.undefined` — see "js.undefined" row above.
- `""` (empty string) — fine, unchanged.
- `0` / `False` — fine, unchanged, but `bool(jsproxy)` may not dispatch reliably; prefer `proxy.to_int() == 0` for JS values.

### dict / list-of-JsProxy iteration

Prescrypt makes a Python `dict` look like a JS object; petitpy does not. Code like `for repo_name in repos_dict: ...` works when `repos_dict` is a native Python dict but NOT when it's a `JsProxy` over a JS object. In the latter case use:

```python
keys = js.Object.keys(proxy)         # JsProxy over a JS Array
i = 0
while i < keys.length.to_int():
    name = keys[i]                    # JsProxy, use .to_str() if needed
    ...
    i = i + 1
```

The upstream code already has a `count_dict_keys(d)` helper in `core/utils.py` that uses `js.Object.keys()`. Generalise the pattern when you hit a `for k in d:` loop where `d` is a JS object.

## Open questions (resolve in later sessions)

- Does the petitpy bridge's `_create_callback` survive a `.then(fn).catch(fn)` chain across the wasm/JS boundary cleanly? Spike in session 3 with the storage layer.
- Do we need `js.chrome` pre-instantiated, or is `js.get("chrome")` plus a module-level local good enough? Defer to session 4.
- What's the manifest.json shape for petitpy entry-points (the wasm needs to be loaded by each HTML page; does the background script use a different loader)? Session 4.
- Promise polyfill / asyncify: the bridge today handles `setTimeout` callbacks but Promise resolution is implicit. If a `.then` callback's return value needs to feed the next `.then`, the bridge marshals it via `_marshal` — verify the type round-trips correctly for `JsProxy` returns (the code in `_dispatch_callback` returns `result._h` directly, which should be fine).

## Source-file mapping

The upstream tree under `sandbox/ci-build-monitor/src/` is flattened in `projects/ci-build-monitor/src/`: each former `<pkg>/<mod>.py` becomes `<pkg>_<mod>.py`, and `from <pkg>.<mod> import …` is rewritten to `from <pkg>_<mod> import …`. Empty `__init__.py` package markers are dropped. petitpy's import machinery is flat-only (no packages / no dotted module names — see `src/runtime/import_search.zig` in the parent repo). Per-file porting status is tracked in `STATUS.md`.
