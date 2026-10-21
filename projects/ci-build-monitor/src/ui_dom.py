# DOM Utilities
# Common DOM manipulation functions

import js


def get_element(element_id):
    """Get DOM element by ID."""
    return js.document.getElementById(element_id)


def get_prop(obj, key, default_val):
    """Safely get property from JS object with default value."""
    if not obj:
        return default_val
    val = getattr(obj, key)
    if val is None:
        return default_val
    return val


def set_display(element, visible):
    """Set element display style."""
    element.style.set("display", "block" if visible else "none")


def js_str_attr(obj, key, default=""):
    """Read a string attr off a JsProxy and materialize it to a Python str.

    ``JsProxy.__getattr__`` always returns a JsProxy (never None), so the
    only case needing a default is the null/undefined handle.
    """
    val = getattr(obj, key)
    if val._h == 0:
        return default
    return val.to_str()
