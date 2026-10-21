"""nanopython re shim — augment the C-side `ure` with CPython-shape
flag constants.

MicroPython's re1.5 engine (in vendor `extmod/modre.c` + `lib/re1.5/`)
is a compact ASCII NFA. It does not natively support the CPython flag
options — no IGNORECASE, MULTILINE, DOTALL, or VERBOSE. But CPython
code commonly writes them at module scope, e.g.

    _SECRET_RE = re.compile(r"password|token", re.IGNORECASE)

which trips `AttributeError: no attribute 'IGNORECASE'` on `import`
against a bare C-only re. This shim adds the constants so the import
succeeds. The compiled pattern accepts the flag argument (compile()
ignores it) but the underlying match is CASE-SENSITIVE.

Truthful behavior summary for callers:
  * re.compile(pat) — full re1.5 support (character classes, groups,
    quantifiers, alternation, anchors).
  * re.compile(pat, flags) — flags argument accepted but IGNORED. Any
    code relying on IGNORECASE/DOTALL semantic gets case-sensitive /
    dot-doesn't-match-newline behavior. Real fix is engine work
    (re1.5 doesn't have hooks for it) — deferred until a caller needs
    it strongly enough.

Filesystem order: MicroPython searches non-extensible built-ins →
frozen modules → filesystem → extensible built-ins. Since `re` is
registered as EXTENSIBLE (vendor MP_REGISTER_EXTENSIBLE_MODULE), this
frozen shim wins over the C module on `import re`. The C surface is
still reachable directly via `import ure`.
"""
import ure as _ure


def _expand_ignorecase(pat):
    """Rewrite ASCII letters in the pattern so both cases match. re1.5
    has no IGNORECASE hook, so we widen each `a` to `[aA]` at pattern-
    prep time. Character classes like `[a-z]` also grow their range;
    `\\<escape>` and existing bracket contents are preserved."""
    out = []
    i = 0
    n = len(pat)
    while i < n:
        c = pat[i]
        if c == "\\" and i + 1 < n:
            out.append(pat[i:i + 2])
            i += 2
            continue
        if c == "[":
            end = i + 1
            depth = 1
            while end < n and depth > 0:
                if pat[end] == "\\" and end + 1 < n:
                    end += 2
                    continue
                if pat[end] == "]":
                    depth -= 1
                    if depth == 0:
                        break
                end += 1
            out.append(_widen_class(pat[i:end + 1]))
            i = end + 1
            continue
        if "A" <= c <= "Z":
            out.append("[" + c + c.lower() + "]")
        elif "a" <= c <= "z":
            out.append("[" + c + c.upper() + "]")
        else:
            out.append(c)
        i += 1
    return "".join(out)


def _widen_class(cls):
    """Widen `[a-z]` → `[a-zA-Z]` and single letters similarly. Called
    on a whole `[...]` chunk. Preserves ranges and escapes."""
    if not cls.startswith("[") or not cls.endswith("]"):
        return cls
    inner = cls[1:-1]
    negate = ""
    if inner.startswith("^"):
        negate = "^"
        inner = inner[1:]
    added = []
    i = 0
    n = len(inner)
    while i < n:
        c = inner[i]
        if c == "\\" and i + 1 < n:
            i += 2
            continue
        if i + 2 < n and inner[i + 1] == "-":
            lo, hi = c, inner[i + 2]
            if "A" <= lo <= "Z" and "A" <= hi <= "Z":
                added.append(lo.lower() + "-" + hi.lower())
            elif "a" <= lo <= "z" and "a" <= hi <= "z":
                added.append(lo.upper() + "-" + hi.upper())
            i += 3
            continue
        if "A" <= c <= "Z":
            added.append(c.lower())
        elif "a" <= c <= "z":
            added.append(c.upper())
        i += 1
    if not added:
        return cls
    return "[" + negate + inner + "".join(added) + "]"


def _expand_braces(pat):
    """Rewrite CPython-style ``{n}`` / ``{n,m}`` / ``{n,}`` quantifiers
    into explicit repetition + optional groups. re1.5 has no brace
    handling — it treats ``{`` as a literal — so ``[a-z]{2,5}`` never
    matches. We expand at the pattern-source level before handing off
    to ure. The quantified atom is either a character class ``[…]``,
    a group ``(…)`` (possibly nested), an escape ``\\.``, or a single
    non-metacharacter.

    Approximation notes:
    - ``{n,}`` becomes ``atom * n`` followed by ``atom*``.
    - ``{n,m}`` becomes ``atom * n`` followed by ``atom?`` repeated
      ``m-n`` times, each wrapped so the trailing optionals nest — this
      keeps the "up to m" semantics without needing brace support.
    - Backslash escapes are re-emitted verbatim.
    """
    out = []
    i = 0
    n = len(pat)
    while i < n:
        c = pat[i]
        if c == "\\" and i + 1 < n:
            out.append(pat[i:i + 2])
            i += 2
            continue
        if c == "{":
            spec, end = _parse_brace_spec(pat, i)
            if spec is None:
                out.append(c)
                i += 1
                continue
            atom_start = _find_atom_start(out)
            atom = "".join(out[atom_start:])
            del out[atom_start:]
            out.append(_expand_atom(atom, spec))
            i = end
            continue
        if c == "[":
            j = _skip_class(pat, i)
            out.append(pat[i:j])
            i = j
            continue
        if c == "(":
            j = _skip_group(pat, i)
            # Recurse into the group body so `{n,m}` inside groups
            # (very common — e.g. hostname alternations) gets
            # expanded too. Slice past the outer `(` and `)`.
            inner_expanded = _expand_braces(pat[i + 1:j - 1])
            out.append("(" + inner_expanded + ")")
            i = j
            continue
        out.append(c)
        i += 1
    return "".join(out)


def _parse_brace_spec(pat, i):
    """Parse ``{n}``, ``{n,}``, or ``{n,m}`` starting at pat[i].
    Return ((lo, hi_or_None), end_index) or (None, i) on non-quantifier
    braces (which stay as literals)."""
    j = i + 1
    lo_str = ""
    while j < len(pat) and pat[j].isdigit():
        lo_str += pat[j]
        j += 1
    if not lo_str:
        return None, i
    lo = int(lo_str)
    if j < len(pat) and pat[j] == "}":
        return (lo, lo), j + 1
    if j < len(pat) and pat[j] == ",":
        j += 1
        hi_str = ""
        while j < len(pat) and pat[j].isdigit():
            hi_str += pat[j]
            j += 1
        if j < len(pat) and pat[j] == "}":
            hi = int(hi_str) if hi_str else None
            return (lo, hi), j + 1
    return None, i


def _find_atom_start(out):
    """Find the start index (in the flat char list ``out``) of the
    quantified atom just before a `{...}`. Handles brackets, groups,
    escapes, single chars."""
    if not out:
        return 0
    last = out[-1]
    if len(last) > 1:
        # Already a complete atom (a bracketed class, group, or escape
        # emitted as one chunk above).
        return len(out) - 1
    # Single character. Walk back if it's the close of a bracket/paren.
    if last == "]":
        depth = 1
        j = len(out) - 2
        while j >= 0 and depth > 0:
            if out[j] == "[":
                depth -= 1
            elif out[j] == "]":
                depth += 1
            j -= 1
        return max(0, j + 1)
    if last == ")":
        depth = 1
        j = len(out) - 2
        while j >= 0 and depth > 0:
            if out[j] == "(":
                depth -= 1
            elif out[j] == ")":
                depth += 1
            j -= 1
        return max(0, j + 1)
    return len(out) - 1


_MAX_NESTED_OPTIONAL = 63


def _expand_atom(atom, spec):
    lo, hi = spec
    if hi is None:
        return atom * lo + atom + "*"
    if hi == lo:
        return atom * lo
    # {lo, hi}: `atom * lo` followed by nested optionals so we accept
    # 0..(hi-lo) additional repetitions. Above _MAX_NESTED_OPTIONAL the
    # nested `(atom(atom(…)?)?)?` explodes to 3-4 KB per level and hits
    # re1.5's compile-time byte-code cap (see `port/re1.5-patched/`);
    # we lose the "≤ hi" bound and over-match with `atom*`. Callers
    # relying on {n,254}-style hostname upper bounds get a value-based
    # length check elsewhere anyway.
    extra = hi - lo
    if extra > _MAX_NESTED_OPTIONAL:
        return atom * lo + atom + "*"
    tail = ""
    for _ in range(extra):
        tail = "(" + atom + tail + ")?"
    return atom * lo + tail


def _skip_class(pat, i):
    j = i + 1
    if j < len(pat) and pat[j] == "^":
        j += 1
    if j < len(pat) and pat[j] == "]":
        j += 1  # `[]` isn't legal but survive it
    while j < len(pat) and pat[j] != "]":
        if pat[j] == "\\" and j + 1 < len(pat):
            j += 2
        else:
            j += 1
    return j + 1 if j < len(pat) else j


def _skip_group(pat, i):
    depth = 1
    j = i + 1
    while j < len(pat) and depth > 0:
        c = pat[j]
        if c == "\\" and j + 1 < len(pat):
            j += 2
            continue
        if c == "[":
            j = _skip_class(pat, j)
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        j += 1
    return j


class _CompiledPattern:
    """Thin wrapper adding CPython-compat attributes on top of a ure
    compiled pattern. hop3-rootd-style code reads ``.pattern`` for error
    messages (``must match {APP_NAME_RE.pattern!r}``); ure alone has
    no such attribute."""

    __slots__ = ("_p", "_full", "pattern", "flags")

    def __init__(self, source, ure_p, flags):
        self._p = ure_p
        self._full = None
        self.pattern = source
        self.flags = flags

    def match(self, string, pos=0, endpos=None):
        # ure.match doesn't take pos/endpos; approximate by slicing.
        if endpos is None and pos == 0:
            return self._p.match(string)
        return self._p.match(string[pos:endpos])

    def fullmatch(self, string, pos=0, endpos=None):
        if self._full is None:
            self._full = _ure.compile(_anchor(_prep(self.pattern, self.flags)))
        return self._full.match(string[pos:endpos])

    def search(self, string, pos=0, endpos=None):
        if endpos is None and pos == 0:
            return self._p.search(string)
        return self._p.search(string[pos:endpos])

    def sub(self, repl, string, count=0):
        return self._p.sub(repl, string, count)

    def split(self, string, maxsplit=0):
        return self._p.split(string, maxsplit)

    def findall(self, string):
        # ure doesn't ship findall. Mirror CPython's contract: if the
        # pattern has one capturing group, return the group strings;
        # multiple groups → list of tuples; no groups → whole matches.
        results = []
        pos = 0
        while pos <= len(string):
            m = self._p.search(string[pos:])
            if m is None:
                break
            start = m.start()
            end = m.end()
            # Try progressively higher group indices; if group(1) is
            # available it's a captured group; if not, use the whole
            # match. Bounded to a small cap since ure gives no
            # explicit groups count.
            grp1 = None
            try:
                grp1 = m.group(1)
            except (IndexError, ValueError):
                grp1 = None
            if grp1 is not None:
                # Peek at a second group to decide single vs tuple.
                grp2 = None
                try:
                    grp2 = m.group(2)
                except (IndexError, ValueError):
                    grp2 = None
                if grp2 is not None:
                    tup = [grp1, grp2]
                    for gi in range(3, 32):
                        try:
                            gv = m.group(gi)
                        except (IndexError, ValueError):
                            break
                        tup.append(gv)
                    results.append(tuple(tup))
                else:
                    results.append(grp1)
            else:
                results.append(m.group(0))
            if end == start:
                pos += start + 1
            else:
                pos += end
        return results


def _prep(pattern, flags):
    p = _expand_braces(pattern)
    if flags & IGNORECASE:
        p = _expand_ignorecase(p)
    return p


def _anchor(p):
    # The whole pattern must match, so alternatives cannot stop early.
    return "(?:" + p + ")$"


def compile(pattern, flags=0):
    """Compile a regex. Brace quantifiers (`{n}`, `{n,m}`, `{n,}`) get
    rewritten to explicit repetition; IGNORECASE widens each ASCII
    letter (both bare and inside `[…]` classes) to match both cases.
    Other flags — MULTILINE, DOTALL, VERBOSE — stay honest no-ops."""
    return _CompiledPattern(pattern, _ure.compile(_prep(pattern, flags)), flags)


def match(pattern, string, flags=0):
    return _ure.compile(_prep(pattern, flags)).match(string)


def fullmatch(pattern, string, flags=0):
    return _ure.compile(_anchor(_prep(pattern, flags))).match(string)


def search(pattern, string, flags=0):
    return _ure.compile(_prep(pattern, flags)).search(string)


def sub(pattern, repl, string, count=0, flags=0):
    return _ure.compile(_prep(pattern, flags)).sub(repl, string, count)

# Flag constants. Zero-valued because the re1.5 engine has no flag hooks
# — the value is a placeholder for API-shape compatibility. Any bit
# pattern would work; CPython's actual values are re.IGNORECASE=2,
# MULTILINE=8, DOTALL=16, VERBOSE=64 — using them here would be
# actively misleading (implying real support). Zero is the honest
# no-op signal, and `re.compile(pat, 0)` is the CPython-legal way to
# say "no flags".
IGNORECASE = 2
MULTILINE = 0
DOTALL = 0
VERBOSE = 0
DEBUG = 0

# CPython short aliases.
I = IGNORECASE
M = MULTILINE
S = DOTALL
X = VERBOSE
