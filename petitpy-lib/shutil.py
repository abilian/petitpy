"""petitpy — shutil (subset: `which` only).

Adds when a real caller needs them: `copy`, `copytree`, `rmtree`,
`disk_usage`, `chown`, etc.
"""
import os


def which(cmd, mode=None, path=None):
    """Return the absolute path of `cmd` if executable, else None.

    Mirrors CPython's `shutil.which`. Absolute or path-containing cmd
    is checked directly; bare cmd is searched along $PATH.
    """
    if os.sep in cmd or (getattr(os, "altsep", "") and getattr(os, "altsep", "") in cmd):
        # Absolute or relative path — check directly.
        try:
            if os.access(cmd, os.X_OK):
                return cmd
        except OSError:
            pass
        return None
    search_path = path if path is not None else os.getenv("PATH", "")
    for d in search_path.split(":"):
        if not d:
            continue
        p = d + os.sep + cmd
        try:
            if os.access(p, os.X_OK):
                return p
        except OSError:
            pass
    return None


def rmtree(path, ignore_errors=False, onerror=None):
    """Recursively delete a directory tree.

    Walks bottom-up (post-order): remove file entries first, then the
    directory itself. `ignore_errors` swallows OSError silently;
    `onerror` (function or None) is called with (func, path, exc)
    per CPython — signature accepted, exception is the actual OSError.
    """
    def _fail(func, p, exc):
        if ignore_errors:
            return
        if onerror is not None:
            onerror(func, p, exc)
            return
        raise exc

    if isinstance(path, str):
        p = path
    else:
        p = str(path)
    try:
        st = os.lstat(p)
    except OSError as e:
        _fail(os.lstat, p, e)
        return
    mode = st.st_mode
    if (mode & 0o170000) != 0o040000:
        # Not a directory: unlink like CPython does (or fail).
        try:
            os.unlink(p)
        except OSError as e:
            _fail(os.unlink, p, e)
        return
    try:
        entries = os.listdir(p)
    except OSError as e:
        _fail(os.listdir, p, e)
        return
    for name in entries:
        child = p + "/" + name if not p.endswith("/") else p + name
        try:
            child_st = os.lstat(child)
        except OSError as e:
            _fail(os.lstat, child, e)
            continue
        cmode = child_st.st_mode & 0o170000
        if cmode == 0o040000:
            rmtree(child, ignore_errors=ignore_errors, onerror=onerror)
        else:
            try:
                os.unlink(child)
            except OSError as e:
                _fail(os.unlink, child, e)
    try:
        os.rmdir(p)
    except OSError as e:
        _fail(os.rmdir, p, e)


def copyfile(src, dst):
    """Copy the file at ``src`` to ``dst`` — bytes-for-bytes. Overwrites
    an existing dst; no metadata is preserved."""
    if not isinstance(src, str):
        src = str(src)
    if not isinstance(dst, str):
        dst = str(dst)
    src_fd = os.open(src, os.O_RDONLY)
    try:
        dst_fd = os.open(dst, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o666)
        try:
            while True:
                chunk = os.read(src_fd, 65536)
                if not chunk:
                    break
                offset = 0
                while offset < len(chunk):
                    n = os.write(dst_fd, chunk[offset:])
                    if n <= 0:
                        break
                    offset += n
        finally:
            os.close(dst_fd)
    finally:
        os.close(src_fd)
    return dst


def copy(src, dst):
    """Copy `src` to `dst`. If `dst` is a directory, copy into it under
    the same basename. Returns the destination path."""
    if not isinstance(src, str):
        src = str(src)
    if not isinstance(dst, str):
        dst = str(dst)
    try:
        st = os.lstat(dst)
        if (st.st_mode & 0o170000) == 0o040000:
            base = src.rsplit("/", 1)[-1]
            dst = dst.rstrip("/") + "/" + base
    except OSError:
        pass
    return copyfile(src, dst)
