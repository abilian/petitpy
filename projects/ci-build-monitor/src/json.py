"""Minimal petitpy json module — just enough for the ADR-003 L1+L2
smoke test (`json.dumps({"a": 1, "b": [1, 2, 3]})`).

This is NOT a CPython-compatible json implementation. It's a placeholder
that ships as part of the frozen-tiny set so `import json` works out of
the box. A real json module will land via micropython-lib once package
imports are supported.
"""


def _encode(o, out):
    if o is None:
        out.append("null")
    elif o is True:
        out.append("true")
    elif o is False:
        out.append("false")
    elif isinstance(o, str):
        out.append('"')
        for ch in o:
            c = ord(ch)
            if c == 0x22:  # "
                out.append('\\"')
            elif c == 0x5C:  # backslash
                out.append("\\\\")
            elif c == 0x08:
                out.append("\\b")
            elif c == 0x09:
                out.append("\\t")
            elif c == 0x0A:
                out.append("\\n")
            elif c == 0x0C:
                out.append("\\f")
            elif c == 0x0D:
                out.append("\\r")
            elif c < 0x20:
                out.append("\\u%04x" % c)
            else:
                out.append(ch)
        out.append('"')
    elif isinstance(o, (int, float)):
        out.append(str(o))
    elif isinstance(o, (list, tuple)):
        out.append("[")
        first = True
        for item in o:
            if first:
                first = False
            else:
                out.append(", ")
            _encode(item, out)
        out.append("]")
    elif isinstance(o, dict):
        out.append("{")
        first = True
        for k in o:
            if not isinstance(k, str):
                raise TypeError("keys must be str")
            if first:
                first = False
            else:
                out.append(", ")
            _encode(k, out)
            out.append(": ")
            _encode(o[k], out)
        out.append("}")
    else:
        raise TypeError("not JSON serialisable")


def dumps(obj):
    out = []
    _encode(obj, out)
    return "".join(out)


def loads(s):
    raise NotImplementedError("petitpy json: loads not implemented yet")
