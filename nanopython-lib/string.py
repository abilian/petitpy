"""Minimal nanopython `string` module — constants + a list-based translate().

Ships as part of the frozen-tiny set. Adapted from upstream
micropython-lib/python-stdlib/string/string/__init__.py, replacing the
`io.StringIO`-based translate with a list-join version so the module
works under nano (where `io` is full-only).

ADR 010 §A3a slice 2.
"""

# ── ctype-style character classification ──────────────────────────────
whitespace = " \t\n\r\v\f"
ascii_lowercase = "abcdefghijklmnopqrstuvwxyz"
ascii_uppercase = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
ascii_letters = ascii_lowercase + ascii_uppercase
digits = "0123456789"
hexdigits = digits + "abcdef" + "ABCDEF"
octdigits = "01234567"
punctuation = """!"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"""
printable = digits + ascii_letters + punctuation + whitespace


def translate(s, table):
    """Apply a {codepoint: replacement} table to each char in `s`.

    table values may be: an int codepoint (chr-encoded), a str
    replacement, or None (drop the character).
    """
    out = []
    for c in s:
        v = ord(c)
        if v in table:
            r = table[v]
            if isinstance(r, int):
                out.append(chr(r))
            elif r is not None:
                out.append(r)
        else:
            out.append(c)
    return "".join(out)


def capwords(s, sep=None):
    """Split `s` on `sep` (default: whitespace), title-case each word,
    rejoin with `sep` (or a single space when sep is None).
    """
    if sep is None:
        return " ".join(w.capitalize() for w in s.split())
    return sep.join(w.capitalize() for w in s.split(sep))
