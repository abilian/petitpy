"""nanopython — the parts of `os` written in Python.

Nanopython's `os` module is native, with a ROM globals dict that cannot
take new entries at run time. Its module `__getattr__` looks up any
name it lacks here, so `os.environ`, `os.makedirs`, `os.walk` and the
rest of this module are reached as ordinary `os` attributes."""

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


devnull = "/dev/null"
pathsep = ":"


class _Environ(dict):
    """`os.environ`: the environment at startup, as a dict whose writes
    reach the process environment, so child processes inherit them."""

    def __setitem__(self, key, value):
        os.putenv(key, value)
        super().__setitem__(key, value)

    def __delitem__(self, key):
        os.unsetenv(key)
        super().__delitem__(key)

    def pop(self, key, *default):
        if key in self:
            os.unsetenv(key)
        return super().pop(key, *default)

    def popitem(self):
        key, value = super().popitem()
        os.unsetenv(key)
        return key, value

    def setdefault(self, key, value=None):
        if key not in self:
            self[key] = value
        return self[key]

    def update(self, *args, **kwargs):
        for key, value in dict(*args, **kwargs).items():
            self[key] = value

    def clear(self):
        for key in list(self):
            del self[key]

    def copy(self):
        return dict(self)


environ = _Environ(os._environ())


def fspath(p):
    if isinstance(p, (str, bytes)):
        return p
    if hasattr(p, "__fspath__"):
        return p.__fspath__()
    raise TypeError("expected str, bytes or os.PathLike object")


def replace(src, dst):
    # rename(2) replaces an existing destination on POSIX.
    os.rename(src, dst)


def makedirs(name, mode=0o777, exist_ok=False):
    from os import path

    head, tail = path.split(name)
    if not tail:
        head, tail = path.split(head)
    if head and tail and not path.exists(head):
        makedirs(head, mode, exist_ok=True)
    try:
        os.mkdir(name, mode)
    except OSError:
        if not exist_ok or not path.isdir(name):
            raise


def walk(top, topdown=True, onerror=None, followlinks=False):
    from os import path

    try:
        names = os.listdir(top)
    except OSError as e:
        if onerror is not None:
            onerror(e)
        return
    dirs = []
    files = []
    for name in names:
        (dirs if path.isdir(path.join(top, name)) else files).append(name)
    if topdown:
        yield top, dirs, files
    for name in dirs:
        sub = path.join(top, name)
        if followlinks or not path.islink(sub):
            yield from walk(sub, topdown, onerror, followlinks)
    if not topdown:
        yield top, dirs, files
