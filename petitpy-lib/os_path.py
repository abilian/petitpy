"""petitpy — os.path subset (POSIX semantics only).

Frozen as `os.path` (dotted-name entry in tools/freeze_modules.py).
Reachable via `from os import path` (which triggers mp_import_from's
package fallback since C-side `os` has `__path__` set to an empty
tuple) OR `import os.path` (top-level dotted).

Ships the CPython idioms hop3-rootd-shape code reaches for:
  * join(a, *rest)                — POSIX path concat
  * basename(p), dirname(p)       — split at last '/'
  * split(p)                      → (dirname, basename)
  * splitext(p)                   → (root, ext)
  * exists(p), isfile(p), isdir(p), islink(p)
  * abspath(p)                    → prepend cwd if relative
  * realpath(p)                   → walk symlinks (best-effort)
  * normpath(p)                   → collapse ./ ../ //
  * expanduser(p)                 → resolve leading ~
  * sep, altsep, extsep, pardir, curdir

Not shipped: getmtime/getctime/getsize (use os.stat).
"""
import os

sep = "/"
altsep = ""
extsep = "."
pardir = ".."
curdir = "."
pathsep = ":"


def join(a, *rest):
    """POSIX join. Absolute later parts reset the accumulator."""
    result = a
    for p in rest:
        if p.startswith("/"):
            result = p
        elif result == "" or result.endswith("/"):
            result = result + p
        else:
            result = result + "/" + p
    return result


def split(p):
    """(dirname, basename)."""
    i = p.rfind("/")
    if i < 0:
        return "", p
    if i == 0:
        return "/", p[1:]
    return p[:i], p[i + 1:]


def basename(p):
    return split(p)[1]


def dirname(p):
    return split(p)[0]


def splitext(p):
    """(root, ext) — ext includes the dot."""
    base = basename(p)
    i = base.rfind(".")
    if i <= 0:  # no dot or dot at position 0 (dotfile)
        return p, ""
    dot_in_full = len(dirname(p)) + (1 if dirname(p) else 0) + i
    return p[:dot_in_full], p[dot_in_full:]


def exists(p):
    try:
        os.stat(p)
        return True
    except OSError:
        return False


def isfile(p):
    try:
        return (os.stat(p).st_mode & 0o170000) == 0o100000
    except OSError:
        return False


def isdir(p):
    try:
        return (os.stat(p).st_mode & 0o170000) == 0o040000
    except OSError:
        return False


def islink(p):
    try:
        return (os.lstat(p).st_mode & 0o170000) == 0o120000
    except OSError:
        return False


def abspath(p):
    if p.startswith("/"):
        return normpath(p)
    return normpath(join(os.getcwd(), p))


def normpath(p):
    """Collapse . and .. components. Preserves leading //."""
    if not p:
        return "."
    is_abs = p.startswith("/")
    # Preserve exactly one leading // per POSIX (drop 3+).
    leading = ""
    if p.startswith("//") and not p.startswith("///"):
        leading = "//"
        p = p[2:]
    elif is_abs:
        leading = "/"
        p = p[1:]
    parts = []
    for chunk in p.split("/"):
        if chunk == "" or chunk == ".":
            continue
        if chunk == "..":
            if parts and parts[-1] != "..":
                parts.pop()
            elif not is_abs:
                parts.append("..")
            # else: drop (can't go above /)
        else:
            parts.append(chunk)
    result = leading + "/".join(parts)
    return result if result else ("/" if is_abs else ".")


def realpath(p):
    """Resolve symlinks. Best-effort — walks each component."""
    if not isinstance(p, str):
        p = str(p)
    if not p.startswith("/"):
        p = join(os.getcwd(), p)
    parts = normpath(p).split("/")
    resolved = ""
    for comp in parts:
        if not comp:
            continue
        # Use join() so we never build "//" from a "/"-rooted resolved
        # prefix plus a bare component (dirname("/tmp") = "/", plain
        # concat gave "//private/tmp" and normpath preserved the
        # POSIX-rule-1 double slash).
        candidate = join(resolved or "/", comp)
        # Follow symlink if present, bounded to a small depth to
        # avoid loops.
        for _ in range(32):
            try:
                if (os.lstat(candidate).st_mode & 0o170000) != 0o120000:
                    break
                target = os.readlink(candidate)
                if target.startswith("/"):
                    candidate = target
                else:
                    candidate = join(dirname(candidate), target)
                candidate = normpath(candidate)
            except OSError:
                break
        resolved = candidate
    return resolved if resolved else "/"


def expanduser(p):
    """Replace leading ~ or ~user with the home directory."""
    if not p.startswith("~"):
        return p
    if p == "~" or p.startswith("~/"):
        home = os.getenv("HOME")
        if home is None:
            return p  # match CPython: silently leave alone if $HOME unset
        return home + p[1:]
    # ~user: look up via pwd if available.
    try:
        import pwd
        i = p.find("/", 1)
        user = p[1:i] if i > 0 else p[1:]
        home = pwd.getpwnam(user).pw_dir
        return home + (p[i:] if i > 0 else "")
    except (ImportError, KeyError):
        return p
