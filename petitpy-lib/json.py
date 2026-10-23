"""petitpy json — CPython's dumps/loads/dump/load and JSONEncoder.

Plain data goes through the native `_json` module. Anything it leaves
(a subclass, a non-str key, NaN, `indent`, `sort_keys`, a hook, an
invalid document) runs the code below, which follows CPython's output
and error messages. Not shipped: JSONDecoder and loads(cls=).
"""

import _json

_INF = float("inf")


class JSONDecodeError(ValueError):
    """Raised when input isn't valid JSON."""

    def __init__(self, msg, doc, pos):
        lineno = doc.count("\n", 0, pos) + 1
        colno = pos - doc.rfind("\n", 0, pos)
        super().__init__("%s: line %d column %d (char %d)" % (msg, lineno, colno, pos))
        self.msg = msg
        self.doc = doc
        self.pos = pos
        self.lineno = lineno
        self.colno = colno


# ── encode ────────────────────────────────────────────────────────────────


class JSONEncoder:
    item_separator = ", "
    key_separator = ": "

    def __init__(self, *, skipkeys=False, ensure_ascii=True, check_circular=True,
                 allow_nan=True, sort_keys=False, indent=None, separators=None,
                 default=None):
        self.skipkeys = skipkeys
        self.ensure_ascii = bool(ensure_ascii)
        self.check_circular = check_circular
        self.allow_nan = allow_nan
        self.sort_keys = sort_keys
        self.indent = " " * indent if isinstance(indent, int) else indent
        if separators is not None:
            self.item_separator, self.key_separator = separators
        elif indent is not None:
            self.item_separator = ","
        if default is not None:
            self.default = default

    def default(self, o):
        raise TypeError("Object of type %s is not JSON serializable" % type(o).__name__)

    def encode(self, o):
        if self.indent is None and not self.sort_keys:
            try:
                return _json.encode(o, self.item_separator, self.key_separator, self.ensure_ascii)
            except TypeError:
                pass  # a value the native encoder leaves to the code below
        out = []
        self._markers = set() if self.check_circular else None
        self._value(o, out, 0)
        return "".join(out)

    def _float(self, f):
        if f != f:
            s = "NaN"
        elif f == _INF:
            s = "Infinity"
        elif f == -_INF:
            s = "-Infinity"
        else:
            return repr(float(f))
        if not self.allow_nan:
            raise ValueError("Out of range float values are not JSON compliant: " + repr(f))
        return s

    def _enter(self, o):
        if self._markers is not None:
            if id(o) in self._markers:
                raise ValueError("Circular reference detected")
            self._markers.add(id(o))

    def _leave(self, o):
        if self._markers is not None:
            self._markers.discard(id(o))

    def _newline(self, level):
        return None if self.indent is None else "\n" + self.indent * level

    def _value(self, o, out, level):
        if isinstance(o, str):
            out.append(_json.string(o, self.ensure_ascii))
        elif o is None:
            out.append("null")
        elif o is True:
            out.append("true")
        elif o is False:
            out.append("false")
        elif isinstance(o, int):
            out.append(str(int(o)))
        elif isinstance(o, float):
            out.append(self._float(o))
        elif isinstance(o, (list, tuple)):
            self._array(o, out, level)
        elif isinstance(o, dict):
            self._object(o, out, level)
        else:
            self._enter(o)
            self._value(self.default(o), out, level)
            self._leave(o)

    def _array(self, o, out, level):
        if not o:
            out.append("[]")
            return
        self._enter(o)
        nl = self._newline(level + 1)
        out.append("[")
        for i, item in enumerate(o):
            if i:
                out.append(self.item_separator)
            if nl:
                out.append(nl)
            self._value(item, out, level + 1)
        if nl:
            out.append(self._newline(level))
        out.append("]")
        self._leave(o)

    def _object(self, o, out, level):
        if not o:
            out.append("{}")
            return
        self._enter(o)
        items = list(o.items())
        if self.sort_keys:
            items.sort(key=lambda kv: kv[0])
        nl = self._newline(level + 1)
        out.append("{")
        first = True
        for k, v in items:
            if isinstance(k, str):
                pass
            elif isinstance(k, float):
                k = self._float(k)
            elif k is True:
                k = "true"
            elif k is False:
                k = "false"
            elif k is None:
                k = "null"
            elif isinstance(k, int):
                k = str(int(k))
            elif self.skipkeys:
                continue
            else:
                raise TypeError("keys must be str, int, float, bool or None, not " + type(k).__name__)
            if not first:
                out.append(self.item_separator)
            first = False
            if nl:
                out.append(nl)
            out.append(_json.string(k, self.ensure_ascii))
            out.append(self.key_separator)
            self._value(v, out, level + 1)
        if nl:
            out.append(self._newline(level))
        out.append("}")
        self._leave(o)


def dumps(obj, *, cls=None, **kw):
    """Serialize ``obj`` to a JSON string, as CPython does."""
    if cls is None and not kw:
        try:
            return _json.encode(obj, ", ", ": ", True)
        except TypeError:
            pass  # JSONEncoder below tries the native encoder again first
    return (cls or JSONEncoder)(**kw).encode(obj)


def dump(obj, fp, **kw):
    fp.write(dumps(obj, **kw))


# ── decode ────────────────────────────────────────────────────────────────

_UNESC = {'"': '"', "\\": "\\", "/": "/", "b": "\b", "f": "\f", "n": "\n", "r": "\r", "t": "\t"}
_HEX = "0123456789abcdefABCDEF"


class _Decoder:
    def __init__(self, s, *, object_hook=None, object_pairs_hook=None, parse_float=None,
                 parse_int=None, parse_constant=None, strict=True):
        self.s = s
        self.n = len(s)
        self.object_hook = object_hook
        self.object_pairs_hook = object_pairs_hook
        self.parse_float = parse_float or float
        self.parse_int = parse_int or int
        self.parse_constant = parse_constant or float
        self.strict = strict

    def error(self, msg, i):
        raise JSONDecodeError(msg, self.s, i)

    def ws(self, i):
        s = self.s
        while i < self.n and s[i] in " \t\n\r":
            i += 1
        return i

    def document(self):
        v, i = self.value(self.ws(0))
        i = self.ws(i)
        if i != self.n:
            self.error("Extra data", i)
        return v

    # `i` is past any whitespace.
    def value(self, i):
        s = self.s
        if i >= self.n:
            self.error("Expecting value", i)
        c = s[i]
        if c == '"':
            return self.string(i)
        if c == "{":
            return self.object(i + 1)
        if c == "[":
            return self.array(i + 1)
        if c == "n" and s.startswith("null", i):
            return None, i + 4
        if c == "t" and s.startswith("true", i):
            return True, i + 4
        if c == "f" and s.startswith("false", i):
            return False, i + 5
        for name in ("NaN", "Infinity", "-Infinity"):
            if c == name[0] and s.startswith(name, i):
                return self.parse_constant(name), i + len(name)
        return self.number(i)

    def digits(self, i):
        s = self.s
        while i < self.n and "0" <= s[i] <= "9":
            i += 1
        return i

    def number(self, start):
        s = self.s
        n = self.n
        i = start + 1 if s[start] == "-" else start
        if i < n and s[i] == "0":
            i += 1
        elif i < n and "1" <= s[i] <= "9":
            i = self.digits(i + 1)
        else:
            self.error("Expecting value", start)
        is_float = False
        if i + 1 < n and s[i] == "." and "0" <= s[i + 1] <= "9":
            i = self.digits(i + 2)
            is_float = True
        if i < n and s[i] in "eE":
            j = i + 1
            if j < n and s[j] in "+-":
                j += 1
            if j < n and "0" <= s[j] <= "9":
                i = self.digits(j + 1)
                is_float = True
        tok = s[start:i]
        return (self.parse_float(tok) if is_float else self.parse_int(tok)), i

    def hex4(self, i):
        h = self.s[i + 1:i + 5]
        if len(h) != 4 or any(c not in _HEX for c in h):
            self.error("Invalid \\uXXXX escape", i)
        return int(h, 16)

    def string(self, start):
        s = self.s
        n = self.n
        out = []
        i = run = start + 1
        while True:
            if i >= n:
                self.error("Unterminated string starting at", start)
            c = s[i]
            if c == '"':
                out.append(s[run:i])
                return "".join(out), i + 1
            if c == "\\":
                out.append(s[run:i])
                if i + 1 >= n:
                    self.error("Unterminated string starting at", start)
                e = s[i + 1]
                if e == "u":
                    cp = self.hex4(i + 1)
                    i += 6
                    if 0xD800 <= cp <= 0xDBFF and s.startswith("\\u", i):
                        lo = self.hex4(i + 1)
                        if 0xDC00 <= lo <= 0xDFFF:
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                            i += 6
                    out.append(chr(cp))
                else:
                    ch = _UNESC.get(e)
                    if ch is None:
                        self.error("Invalid \\escape", i)
                    out.append(ch)
                    i += 2
                run = i
            elif c < " " and self.strict:
                self.error("Invalid control character at", i)
            else:
                i += 1

    def object(self, i):
        s = self.s
        pairs = []
        i = self.ws(i)
        if i < self.n and s[i] == "}":
            return self.make_object(pairs), i + 1
        while True:
            if i >= self.n or s[i] != '"':
                self.error("Expecting property name enclosed in double quotes", i)
            k, i = self.string(i)
            i = self.ws(i)
            if i >= self.n or s[i] != ":":
                self.error("Expecting ':' delimiter", i)
            v, i = self.value(self.ws(i + 1))
            pairs.append((k, v))
            i = self.ws(i)
            if i < self.n and s[i] == "}":
                return self.make_object(pairs), i + 1
            if i >= self.n or s[i] != ",":
                self.error("Expecting ',' delimiter", i)
            comma = i
            i = self.ws(i + 1)
            if i < self.n and s[i] == "}":
                self.error("Illegal trailing comma before end of object", comma)

    def make_object(self, pairs):
        if self.object_pairs_hook is not None:
            return self.object_pairs_hook(pairs)
        d = dict(pairs)
        return d if self.object_hook is None else self.object_hook(d)

    def array(self, i):
        s = self.s
        values = []
        i = self.ws(i)
        if i < self.n and s[i] == "]":
            return values, i + 1
        while True:
            v, i = self.value(i)
            values.append(v)
            i = self.ws(i)
            if i < self.n and s[i] == "]":
                return values, i + 1
            if i >= self.n or s[i] != ",":
                self.error("Expecting ',' delimiter", i)
            comma = i
            i = self.ws(i + 1)
            if i < self.n and s[i] == "]":
                self.error("Illegal trailing comma before end of array", comma)


def loads(s, **kw):
    """Parse a JSON document into a Python value, as CPython does.

    Takes CPython's object_hook, object_pairs_hook, parse_float,
    parse_int, parse_constant and strict."""
    if not isinstance(s, str):
        if not isinstance(s, (bytes, bytearray)):
            raise TypeError("the JSON object must be str, bytes or bytearray, not " + type(s).__name__)
        s = s.decode("utf-8")
    if not kw:
        try:
            return _json.decode(s)
        except ValueError:
            pass  # invalid JSON, or a case left to the code below
    return _Decoder(s, **kw).document()


def load(fp, **kw):
    return loads(fp.read(), **kw)
