"""petitpy — pathlib subset (Path only, POSIX semantics).

Ships enough of pathlib for the CPython idioms hop3-rootd-shape code
uses at import + runtime:

    p = Path("/var/log/app")
    p / "audit.log"                 → Path("/var/log/app/audit.log")
    p.name, p.parent, p.suffix      → string properties
    p.exists(), p.is_file(),        → bool (via os.stat)
        p.is_dir(), p.is_symlink()
    p.read_text(), p.write_text(s)  → str I/O
    p.read_bytes(), p.write_bytes(b)→ bytes I/O
    p.iterdir()                     → generator of Path (via os.listdir)
    p.mkdir(mode=0o777, parents=False, exist_ok=False)
    p.unlink(missing_ok=False)
    p.rmdir()
    str(p), p.as_posix(), p.absolute(), p.resolve()

Not shipped (add if a caller needs it): PurePath / PureWindowsPath /
non-POSIX variants, `p.glob()`, `p.match()`, `p.stat()` (use os.stat
directly), `p.rename()` (use os.rename), `p.owner()`, `p.group()`.
"""
import os


class Path:
    """POSIX-style path object. String-backed; equality is string-eq."""

    def __init__(self, *parts):
        # Accept str or Path parts. Flatten into one POSIX string,
        # matching pathlib's join semantics: an absolute part resets
        # the accumulated path.
        if not parts:
            self._s = "."
            return
        s = _join_parts(parts)
        # Normalize double-slash → single (except at the very start,
        # per POSIX). Drop trailing slash unless root.
        s = _normalize_slashes(s)
        self._s = s

    # ── construction / composition ────────────────────────────────────

    def __truediv__(self, other):
        return Path(self._s, str(other) if not isinstance(other, Path) else other._s)

    def __rtruediv__(self, other):
        left = str(other) if not isinstance(other, Path) else other._s
        return Path(left, self._s)

    def joinpath(self, *others):
        return Path(self._s, *others)

    # ── properties ────────────────────────────────────────────────────

    def __str__(self):
        return self._s

    def __repr__(self):
        return "PosixPath('" + self._s + "')"

    def __fspath__(self):
        return self._s

    def __eq__(self, other):
        if isinstance(other, Path):
            return self._s == other._s
        return NotImplemented

    def __hash__(self):
        return hash(self._s)

    def as_posix(self):
        return self._s

    @property
    def name(self):
        i = self._s.rfind("/")
        return self._s[i + 1 :] if i >= 0 else self._s

    @property
    def parent(self):
        i = self._s.rfind("/")
        if i < 0:
            return Path(".")
        if i == 0:
            return Path("/")
        return Path(self._s[:i])

    @property
    def parents(self):
        # Sequence of parents from immediate up to the root.
        result = []
        cur = self.parent
        while str(cur) not in (".", "/") and cur != cur.parent:
            result.append(cur)
            cur = cur.parent
        result.append(cur)
        return result

    @property
    def parts(self):
        if self._s == "/":
            return ("/",)
        pieces = self._s.split("/")
        if self._s.startswith("/"):
            return ("/",) + tuple(p for p in pieces if p)
        return tuple(p for p in pieces if p)

    @property
    def suffix(self):
        n = self.name
        i = n.rfind(".")
        if i <= 0:  # includes "no dot" and leading-dot (dotfiles)
            return ""
        return n[i:]

    @property
    def stem(self):
        n = self.name
        i = n.rfind(".")
        if i <= 0:
            return n
        return n[:i]

    def with_name(self, name):
        return self.parent / name

    def with_suffix(self, suffix):
        return self.parent / (self.stem + suffix)

    def is_absolute(self):
        return self._s.startswith("/")

    def absolute(self):
        if self.is_absolute():
            return self
        return Path(os.getcwd(), self._s)

    def resolve(self, strict=False):
        # Simple resolve: absolute + normalize. No symlink following
        # (would need os.readlink loop; add when a caller needs it).
        return self.absolute()

    def relative_to(self, other):
        other_s = str(other)
        if self._s.startswith(other_s.rstrip("/") + "/"):
            return Path(self._s[len(other_s.rstrip("/")) + 1 :])
        if self._s == other_s:
            return Path(".")
        raise ValueError(repr(self._s) + " is not in the subpath of " + repr(other_s))

    # ── filesystem queries ────────────────────────────────────────────

    def exists(self):
        try:
            os.stat(self._s)
            return True
        except OSError:
            return False

    def is_file(self):
        try:
            return (os.stat(self._s).st_mode & 0o170000) == 0o100000
        except OSError:
            return False

    def is_dir(self):
        try:
            return (os.stat(self._s).st_mode & 0o170000) == 0o040000
        except OSError:
            return False

    def is_symlink(self):
        try:
            return (os.lstat(self._s).st_mode & 0o170000) == 0o120000
        except OSError:
            return False

    # ── I/O ───────────────────────────────────────────────────────────

    def open(self, mode="r", encoding=None, errors=None, newline=None,
             buffering=-1):
        """Open the file and return a file-like object.

        petitpy's builtin ``open()`` returns a stream that doesn't
        expose ``.fileno()``; hop3-rootd (and similar CPython code)
        pairs writes with ``os.fsync(f.fileno())``, so we wrap the
        raw file descriptor in a small object that keeps the fd
        alongside the stream. Modes: 'r', 'w', 'a', with optional
        'b'/'t'/'+' suffixes."""
        return _PathFile(self._s, mode, encoding=encoding)

    def read_bytes(self):
        fd = os.open(self._s, os.O_RDONLY)
        try:
            chunks = []
            while True:
                chunk = os.read(fd, 4096)
                if not chunk:
                    break
                chunks.append(chunk)
            return b"".join(chunks)
        finally:
            os.close(fd)

    def read_text(self, encoding="utf-8"):
        return self.read_bytes().decode(encoding)

    def write_bytes(self, data):
        fd = os.open(self._s, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o666)
        try:
            offset = 0
            while offset < len(data):
                # os.write returns bytes-written; may be short.
                n = os.write(fd, data[offset:])
                if n <= 0:
                    break
                offset += n
            return offset
        finally:
            os.close(fd)

    def write_text(self, data, encoding="utf-8"):
        return self.write_bytes(data.encode(encoding))

    # ── directory operations ──────────────────────────────────────────

    def iterdir(self):
        for name in os.listdir(self._s):
            yield self / name

    def glob(self, pattern):
        """POSIX glob against this directory. Supports ``*``, ``?``,
        ``[seq]`` — no ``**`` recursion, no brace expansion. Enough for
        `Path("/etc").glob("*.conf")` idioms."""
        # Split pattern into path segments so `foo/*.txt` walks the
        # foo/ subdir. `**` is treated as a literal `*` (single-level
        # match); real recursion would need a stack.
        parts = pattern.split("/")
        yield from _glob_walk(self, parts)

    def mkdir(self, mode=0o777, parents=False, exist_ok=False):
        try:
            os.mkdir(self._s, mode)
        except OSError as e:
            code = e.args[0]
            if code == 17:  # EEXIST
                if not exist_ok:
                    raise
                return
            if code == 2 and parents:  # ENOENT — create ancestors first
                parent = self.parent
                if str(parent) not in (".", "/"):
                    parent.mkdir(mode, parents=True, exist_ok=True)
                    os.mkdir(self._s, mode)
                    return
            raise

    def rmdir(self):
        os.rmdir(self._s)

    def unlink(self, missing_ok=False):
        try:
            os.unlink(self._s)
        except OSError as e:
            if missing_ok and e.args[0] == 2:  # ENOENT
                return
            raise

    def rename(self, target):
        target_s = str(target) if not isinstance(target, Path) else target._s
        os.rename(self._s, target_s)
        return Path(target_s)

    def replace(self, target):
        """Rename this path to `target`, overwriting an existing target
        atomically on POSIX. CPython distinguishes replace() (silent
        overwrite) from rename() (which may fail if target exists on
        Windows); under POSIX rename(2) is already replace semantics,
        so both funnel through os.rename."""
        target_s = str(target) if not isinstance(target, Path) else target._s
        os.rename(self._s, target_s)
        return Path(target_s)

    def symlink_to(self, target, target_is_directory=False):
        """Create a symlink at ``self`` pointing to ``target``. Mirrors
        CPython's ``Path.symlink_to`` — ``target_is_directory`` is a
        Windows-only hint we accept and ignore."""
        target_s = str(target) if not isinstance(target, Path) else target._s
        os.symlink(target_s, self._s)

    def stat(self):
        """Return the raw os.stat result for this path. Follows symlinks;
        use ``lstat()`` (via ``os.lstat`` directly) to inspect the link
        itself."""
        return os.stat(self._s)

    def lstat(self):
        return os.lstat(self._s)

    def chmod(self, mode):
        os.chmod(self._s, mode)

    def touch(self, mode=0o666, exist_ok=True):
        """Create the file with the given mode. If it already exists,
        succeed silently when ``exist_ok`` (the default), else raise."""
        try:
            fd = os.open(self._s, os.O_CREAT | os.O_WRONLY | os.O_EXCL, mode)
        except OSError as e:
            if e.args[0] == 17 and exist_ok:  # EEXIST
                return
            raise
        os.close(fd)


# CPython aliases.
PosixPath = Path
PurePath = Path
PurePosixPath = Path


# ── helpers ───────────────────────────────────────────────────────────

def _join_parts(parts):
    """POSIX path join: an absolute part resets the accumulated path."""
    result = ""
    for p in parts:
        s = str(p) if not isinstance(p, Path) else p._s
        if s == "":
            continue
        if s.startswith("/"):
            result = s
        elif result == "":
            result = s
        elif result.endswith("/"):
            result = result + s
        else:
            result = result + "/" + s
    return result if result else "."


def _normalize_slashes(s):
    """Collapse `//` → `/` (except leading `//` per POSIX rule 1) and
    strip trailing slash except for root."""
    if not s:
        return "."
    # Preserve a leading double-slash (POSIX permits it) but collapse
    # any triple-or-more.
    if s.startswith("//") and not s.startswith("///"):
        head, rest = s[:2], s[2:]
    else:
        head, rest = "", s
    # Collapse //+ → /
    while "//" in rest:
        rest = rest.replace("//", "/")
    result = head + rest
    # Strip trailing / (except for the root itself)
    if len(result) > 1 and result.endswith("/"):
        result = result[:-1]
    return result


# ── file wrapper used by Path.open ────────────────────────────────────────

def _glob_walk(base, parts):
    if not parts:
        yield base
        return
    head, tail = parts[0], parts[1:]
    if not head:
        yield from _glob_walk(base, tail)
        return
    if not _has_glob_meta(head):
        # Literal segment — descend if the child exists.
        child = base / head
        if child.exists():
            yield from _glob_walk(child, tail)
        return
    try:
        entries = os.listdir(base._s)
    except OSError:
        return
    for name in entries:
        if _fnmatch(name, head):
            yield from _glob_walk(base / name, tail)


def _has_glob_meta(seg):
    for c in seg:
        if c in "*?[":
            return True
    return False


def _fnmatch(name, pattern):
    """POSIX shell-style glob match. Anchored — no partial matches."""
    return _fnmatch_at(name, 0, pattern, 0)


def _fnmatch_at(name, i, pat, j):
    n, m = len(name), len(pat)
    while j < m:
        c = pat[j]
        if c == "*":
            # Skip consecutive stars, then try each split.
            while j < m and pat[j] == "*":
                j += 1
            if j == m:
                return True
            for k in range(i, n + 1):
                if _fnmatch_at(name, k, pat, j):
                    return True
            return False
        if c == "?":
            if i >= n:
                return False
            i += 1
            j += 1
            continue
        if c == "[":
            end = pat.find("]", j + 1)
            if end < 0:
                # Not a class — treat `[` as literal.
                if i >= n or name[i] != "[":
                    return False
                i += 1
                j += 1
                continue
            klass = pat[j + 1:end]
            negate = klass.startswith("!") or klass.startswith("^")
            if negate:
                klass = klass[1:]
            if i >= n:
                return False
            matched = False
            k = 0
            while k < len(klass):
                if k + 2 < len(klass) and klass[k + 1] == "-":
                    if klass[k] <= name[i] <= klass[k + 2]:
                        matched = True
                    k += 3
                else:
                    if klass[k] == name[i]:
                        matched = True
                    k += 1
            if matched == negate:
                return False
            i += 1
            j = end + 1
            continue
        if i >= n or name[i] != c:
            return False
        i += 1
        j += 1
    return i == n


class _PathFile:
    """Minimal file object with fileno() support so
    `os.fsync(f.fileno())` works. Mode parsing follows CPython's
    ``open()`` grammar (``'r' | 'w' | 'a' | 'x'`` plus optional
    ``'+' | 'b' | 't'``)."""

    def __init__(self, path_str, mode, encoding=None):
        self._path = path_str
        self._mode = mode
        self._encoding = encoding or "utf-8"
        self._closed = False
        wants_binary = "b" in mode
        wants_append = "a" in mode
        wants_write = "w" in mode or "a" in mode or "x" in mode
        wants_read = "r" in mode
        wants_plus = "+" in mode

        flags = 0
        if wants_write and (wants_read or wants_plus):
            flags = os.O_RDWR
        elif wants_write:
            flags = os.O_WRONLY
        else:
            flags = os.O_RDONLY
        if wants_write:
            flags |= os.O_CREAT
            if wants_append:
                flags |= os.O_APPEND
            elif "w" in mode:
                flags |= os.O_TRUNC
            if "x" in mode:
                flags |= os.O_EXCL
        self._fd = os.open(path_str, flags, 0o666)
        self._binary = wants_binary
        self._buffer = b""

    def fileno(self):
        return self._fd

    def seek(self, offset, whence=0):
        return os.lseek(self._fd, offset, whence)

    def tell(self):
        return os.lseek(self._fd, 0, 1)

    @property
    def closed(self):
        return self._closed

    def write(self, data):
        if self._binary:
            if isinstance(data, str):
                data = data.encode(self._encoding)
        else:
            if isinstance(data, str):
                data = data.encode(self._encoding)
        offset = 0
        while offset < len(data):
            n = os.write(self._fd, data[offset:])
            if n <= 0:
                break
            offset += n
        return offset

    def read(self, size=-1):
        chunks = []
        while size < 0 or sum(len(c) for c in chunks) < size:
            want = 4096 if size < 0 else min(4096, size - sum(len(c) for c in chunks))
            chunk = os.read(self._fd, want)
            if not chunk:
                break
            chunks.append(chunk)
        data = b"".join(chunks)
        if self._binary:
            return data
        return data.decode(self._encoding)

    def readline(self):
        line_bytes = []
        while True:
            byte = os.read(self._fd, 1)
            if not byte:
                break
            line_bytes.append(byte)
            if byte == b"\n":
                break
        data = b"".join(line_bytes)
        if self._binary:
            return data
        return data.decode(self._encoding)

    def readlines(self):
        out = []
        while True:
            line = self.readline()
            if not line:
                break
            out.append(line)
        return out

    def flush(self):
        # os.write is unbuffered — nothing to flush at this layer.
        # os.fsync(self._fd) would guarantee kernel-side durability
        # but that's the caller's decision.
        pass

    def close(self):
        if not self._closed:
            os.close(self._fd)
            self._closed = True

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        self.close()
        return False

    def __iter__(self):
        return self

    def __next__(self):
        line = self.readline()
        if not line:
            raise StopIteration
        return line
