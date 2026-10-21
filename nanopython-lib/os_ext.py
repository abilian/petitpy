"""nanopython — os module extensions.

Nanopython's C-side `os` module is registered from a ROM globals dict
so we can't monkey-patch new functions onto it at runtime. This module
provides the missing helpers under a separate name; runner-level source
rewrites redirect `os.fdopen(fd, …)` → `_os_ext.fdopen(fd, …)` in
hop3-rootd-style code that reaches for the CPython idiom."""

import os


class _FdFile:
    """File-like object wrapping a raw fd. Mirrors the surface of
    `pathlib._PathFile` (write / read / readline / flush / close /
    fileno / context-manager iteration) so `os.fdopen(fd, "w") as f:
    f.write(...); os.fsync(f.fileno())` works the same as
    `path.open("w")`."""

    def __init__(self, fd, mode="r", encoding=None):
        self._fd = fd
        self._mode = mode
        self._encoding = encoding or "utf-8"
        self._closed = False
        self._binary = "b" in mode

    def fileno(self):
        return self._fd

    @property
    def closed(self):
        return self._closed

    def write(self, data):
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
        buf = []
        while True:
            b = os.read(self._fd, 1)
            if not b:
                break
            buf.append(b)
            if b == b"\n":
                break
        data = b"".join(buf)
        if self._binary:
            return data
        return data.decode(self._encoding)

    def flush(self):
        # os.write is unbuffered; nothing to flush at this layer.
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


def fdopen(fd, mode="r", buffering=-1, encoding=None, errors=None,
           newline=None, closefd=True):
    """Wrap an existing file descriptor in a file-like object. Signature
    tracks CPython's; only ``mode`` + ``encoding`` are actually honoured.
    ``buffering`` / ``errors`` / ``newline`` / ``closefd`` are accepted
    for CPython-compat but have no effect (os.write is unbuffered)."""
    return _FdFile(fd, mode, encoding=encoding)


_COMMON_ENV_VARS = (
    "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TERM", "LANG",
    "LC_ALL", "LC_CTYPE", "PWD", "OLDPWD", "TMPDIR", "TMP", "TEMP",
    "MAIL", "HOSTNAME", "DISPLAY", "XDG_RUNTIME_DIR", "XDG_CONFIG_HOME",
    "XDG_CACHE_HOME", "XDG_DATA_HOME", "PYTHONPATH", "PYTHONHOME",
    "PETITPY_LIB", "SSH_AUTH_SOCK", "SSH_AGENT_PID", "SSH_CONNECTION",
    "EDITOR", "VISUAL", "PAGER", "MANPATH", "COLORTERM",
)


def _build_environ():
    """Build the process env snapshot. A plain dict so ``{**environ}``
    and ``dict.update(environ)`` work with vendor MicroPython's
    pair-iterating update semantics (there's no keys()-protocol seam).

    Nanopython's C-side ``os`` doesn't expose the environ table for
    iteration, so we probe a curated list of well-known names via
    ``os.getenv`` and stash the ones that were set. Callers can add
    entries by assigning; those don't automatically propagate to
    ``os.putenv`` — pair the two calls when the child processes need
    to inherit the value."""
    out = {}
    if hasattr(os, "getenv"):
        for name in _COMMON_ENV_VARS:
            v = os.getenv(name)
            if v is not None:
                out[name] = v
    return out


environ = _build_environ()
