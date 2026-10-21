"""nanopython json — CPython-shape dumps/loads without dependencies.

Ships enough of the CPython interface for real programs to
round-trip: nested dicts/lists, strings with escapes, ints, bools,
None. Adds `separators`, `indent`, `sort_keys` on `dumps` and a real
recursive-descent `loads` (RFC 8259 subset — no comments, no
trailing commas, no NaN/Inf).

Not shipped:
    - float encoding beyond `str(f)` (CPython uses repr with rounding)
    - json.dump / json.load (file streaming — use dumps/loads plus
      Path.write_text / Path.read_text)
    - object_hook / parse_float / cls / default hooks
"""

import _json


# ── encode (dumps) ────────────────────────────────────────────────────────

_ESC = {
    0x22: '\\"',
    0x5C: "\\\\",
    0x08: "\\b",
    0x09: "\\t",
    0x0A: "\\n",
    0x0C: "\\f",
    0x0D: "\\r",
}


def _encode_str(s, out):
    # Most strings need no escaping: test that with C-level scans instead
    # of looping over every character in Python.
    if '"' not in s and "\\" not in s and (not s or min(s) >= " "):
        out.append('"' + s + '"')
        return
    out.append('"')
    for ch in s:
        c = ord(ch)
        esc = _ESC.get(c)
        if esc is not None:
            out.append(esc)
        elif c < 0x20:
            out.append("\\u%04x" % c)
        else:
            out.append(ch)
    out.append('"')


def _encode(o, out, item_sep, kv_sep, indent, level, sort_keys):
    if o is None:
        out.append("null")
        return
    if o is True:
        out.append("true")
        return
    if o is False:
        out.append("false")
        return
    if isinstance(o, str):
        _encode_str(o, out)
        return
    if isinstance(o, bool):
        # bool is a subclass of int — cover before the int branch
        # (already handled above via `is True` / `is False`).
        out.append("true" if o else "false")
        return
    if isinstance(o, (int, float)):
        out.append(str(o))
        return
    if isinstance(o, (list, tuple)):
        if not o:
            out.append("[]")
            return
        out.append("[")
        for i, item in enumerate(o):
            if i:
                out.append(item_sep)
            if indent is not None:
                out.append("\n" + indent * (level + 1))
            _encode(item, out, item_sep, kv_sep, indent, level + 1, sort_keys)
        if indent is not None:
            out.append("\n" + indent * level)
        out.append("]")
        return
    if isinstance(o, dict):
        if not o:
            out.append("{}")
            return
        keys = list(o)
        if sort_keys:
            keys.sort()
        out.append("{")
        for i, k in enumerate(keys):
            if not isinstance(k, str):
                raise TypeError("dict key must be a string, not " + type(k).__name__)
            if i:
                out.append(item_sep)
            if indent is not None:
                out.append("\n" + indent * (level + 1))
            _encode_str(k, out)
            out.append(kv_sep)
            _encode(o[k], out, item_sep, kv_sep, indent, level + 1, sort_keys)
        if indent is not None:
            out.append("\n" + indent * level)
        out.append("}")
        return
    raise TypeError(type(o).__name__ + " is not JSON serialisable")


def dumps(obj, separators=None, indent=None, sort_keys=False,
          ensure_ascii=True, skipkeys=False, allow_nan=True, cls=None,
          default=None, **_ignored):
    """Serialise ``obj`` to a JSON string.

    - separators=(item_sep, kv_sep) overrides ", " / ": ".
    - indent=<int|str> pretty-prints. Int → that many spaces per level.
    - sort_keys sorts dict keys deterministically.

    Extra CPython kwargs (skipkeys, ensure_ascii, allow_nan, cls,
    default) are accepted for signature compat but ignored — enough for
    common use, not a full implementation.
    """
    if separators is None:
        if indent is not None:
            item_sep = ","
            kv_sep = ": "
        else:
            item_sep = ", "
            kv_sep = ": "
    else:
        item_sep, kv_sep = separators
    if isinstance(indent, int):
        indent_str = " " * indent
    elif isinstance(indent, str):
        indent_str = indent
    else:
        indent_str = None
    if indent_str is None and not sort_keys:
        try:
            return _json.encode(obj, item_sep, kv_sep)
        except TypeError:
            pass  # a value the native encoder leaves to the code below
    out = []
    _encode(obj, out, item_sep, kv_sep, indent_str, 0, sort_keys)
    return "".join(out)


# ── decode (loads) ────────────────────────────────────────────────────────


class JSONDecodeError(ValueError):
    """Raised when input isn't valid JSON."""

    def __init__(self, msg, doc="", pos=0):
        super().__init__(msg + ": line 1 column " + str(pos + 1) + " (char " + str(pos) + ")")
        self.msg = msg
        self.doc = doc
        self.pos = pos


def _decode_error(msg, s, i):
    raise JSONDecodeError(msg, s, i)


def _skip_ws(s, i, n):
    while i < n:
        c = s[i]
        if c == " " or c == "\t" or c == "\n" or c == "\r":
            i += 1
        else:
            break
    return i


def _decode_string(s, i, n):
    # Assumes s[i] == '"'
    i += 1
    out = []
    while i < n:
        c = s[i]
        if c == '"':
            return "".join(out), i + 1
        if c == "\\":
            i += 1
            if i >= n:
                _decode_error("unterminated string escape", s, i)
            e = s[i]
            if e == '"' or e == "\\" or e == "/":
                out.append(e)
                i += 1
            elif e == "b":
                out.append("\b"); i += 1
            elif e == "f":
                out.append("\f"); i += 1
            elif e == "n":
                out.append("\n"); i += 1
            elif e == "r":
                out.append("\r"); i += 1
            elif e == "t":
                out.append("\t"); i += 1
            elif e == "u":
                if i + 5 > n:
                    _decode_error("short \\u escape", s, i)
                hexstr = s[i + 1:i + 5]
                try:
                    code = int(hexstr, 16)
                except ValueError:
                    _decode_error("bad \\u escape", s, i)
                out.append(chr(code))
                i += 5
            else:
                _decode_error("bad escape \\" + e, s, i)
        else:
            out.append(c)
            i += 1
    _decode_error("unterminated string", s, i)


def _decode_number(s, i, n):
    start = i
    if s[i] == "-":
        i += 1
    while i < n and "0" <= s[i] <= "9":
        i += 1
    is_float = False
    if i < n and s[i] == ".":
        is_float = True
        i += 1
        while i < n and "0" <= s[i] <= "9":
            i += 1
    if i < n and (s[i] == "e" or s[i] == "E"):
        is_float = True
        i += 1
        if i < n and (s[i] == "+" or s[i] == "-"):
            i += 1
        while i < n and "0" <= s[i] <= "9":
            i += 1
    token = s[start:i]
    if is_float:
        return float(token), i
    return int(token), i


def _decode_value(s, i, n):
    i = _skip_ws(s, i, n)
    if i >= n:
        _decode_error("expected JSON value", s, i)
    c = s[i]
    if c == '"':
        return _decode_string(s, i, n)
    if c == "{":
        return _decode_object(s, i, n)
    if c == "[":
        return _decode_array(s, i, n)
    if c == "t":
        if s[i:i + 4] == "true":
            return True, i + 4
        _decode_error("expected true", s, i)
    if c == "f":
        if s[i:i + 5] == "false":
            return False, i + 5
        _decode_error("expected false", s, i)
    if c == "n":
        if s[i:i + 4] == "null":
            return None, i + 4
        _decode_error("expected null", s, i)
    if c == "-" or "0" <= c <= "9":
        return _decode_number(s, i, n)
    _decode_error("unexpected character " + repr(c), s, i)


def _decode_object(s, i, n):
    # Assumes s[i] == '{'
    i += 1
    result = {}
    i = _skip_ws(s, i, n)
    if i < n and s[i] == "}":
        return result, i + 1
    while True:
        i = _skip_ws(s, i, n)
        if i >= n or s[i] != '"':
            _decode_error("expected string key", s, i)
        key, i = _decode_string(s, i, n)
        i = _skip_ws(s, i, n)
        if i >= n or s[i] != ":":
            _decode_error("expected ':'", s, i)
        i += 1
        value, i = _decode_value(s, i, n)
        result[key] = value
        i = _skip_ws(s, i, n)
        if i >= n:
            _decode_error("unterminated object", s, i)
        if s[i] == ",":
            i += 1
            continue
        if s[i] == "}":
            return result, i + 1
        _decode_error("expected ',' or '}'", s, i)


def _decode_array(s, i, n):
    # Assumes s[i] == '['
    i += 1
    result = []
    i = _skip_ws(s, i, n)
    if i < n and s[i] == "]":
        return result, i + 1
    while True:
        value, i = _decode_value(s, i, n)
        result.append(value)
        i = _skip_ws(s, i, n)
        if i >= n:
            _decode_error("unterminated array", s, i)
        if s[i] == ",":
            i += 1
            continue
        if s[i] == "]":
            return result, i + 1
        _decode_error("expected ',' or ']'", s, i)


def loads(s, cls=None, object_hook=None, parse_float=None, parse_int=None,
          parse_constant=None, object_pairs_hook=None, **_ignored):
    """Parse a JSON string into a Python value.

    Hook kwargs (object_hook, parse_float, …) are accepted for signature
    compat but ignored — plain dicts/floats/ints only."""
    if isinstance(s, (bytes, bytearray)):
        s = s.decode("utf-8")
    if not isinstance(s, str):
        raise TypeError("json.loads argument must be str/bytes, got " + type(s).__name__)
    try:
        return _json.decode(s)
    except ValueError:
        pass  # invalid JSON, or a case left to the code below
    value, i = _decode_value(s, 0, len(s))
    i = _skip_ws(s, i, len(s))
    if i != len(s):
        _decode_error("trailing data", s, i)
    return value
