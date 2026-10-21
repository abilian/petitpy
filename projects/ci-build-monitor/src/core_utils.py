# Core Utilities
# Common utility functions used across the codebase

import js


def create_obj():
    """Create JS-compatible object using Python dict (compiles to {})."""
    return js.JSON.parse("{}")


_ID_COUNTER = 0


def generate_id():
    """Generate a unique ID.

    The nano build has no float type and the smallint window stops at
    ~5.4e8 — `Date.now()` (~1.7e12) and `Math.random()` (a float) both
    blow up. Use a masked Date seed plus a monotonic counter instead.
    See notes/03-nano-python-cheatsheet.md §1 and §2.
    """
    global _ID_COUNTER
    _ID_COUNTER = _ID_COUNTER + 1
    seed = js.get("Date").now().to_str()
    return seed + "-" + str(_ID_COUNTER)


def count_dict_keys(d):
    """Count keys in a dict/JS object (Prescrypt-compatible).

    Uses js.Object.keys() instead of 'for k in d' to work with
    JavaScript objects returned from promises.
    """
    if not d:
        return 0
    keys = js.get("Object").keys(d)
    return keys.length


def proxy_url(real_url):
    """Route fetches through serve.py's /proxy/ when the page is on localhost.

    In a real extension, manifest host_permissions bypass CORS so we hit
    upstream URLs directly. In standalone web-app mode (served by
    serve.py on http://localhost:PORT/), the upstreams don't send
    Access-Control-Allow-Origin so we tunnel through the local CORS
    proxy instead.
    """
    origin = js.window.location.origin.to_str()
    if origin.startswith(("http://localhost", "http://127.0.0.1")):
        return origin + "/proxy/" + real_url
    return real_url
