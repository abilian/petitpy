"""stat — POSIX file-mode constants + predicates for petitpy.

Ships the constant and predicate surface CPython test suites reach for
(S_ISDIR, S_ISREG, S_IRUSR, …) so `import stat` succeeds. Values match
POSIX / <sys/stat.h>. No syscalls here — pair with `os.stat` /
`os.lstat` to actually query the filesystem.
"""

# ── file-type bit fields ──────────────────────────────────────────────────

S_IFMT = 0o170000       # bit mask for the file type bit field
S_IFDIR = 0o040000      # directory
S_IFCHR = 0o020000      # character device
S_IFBLK = 0o060000      # block device
S_IFREG = 0o100000      # regular file
S_IFIFO = 0o010000      # named pipe (FIFO)
S_IFLNK = 0o120000      # symbolic link
S_IFSOCK = 0o140000     # socket

# ── permission bits ───────────────────────────────────────────────────────

S_ISUID = 0o4000        # set-user-ID
S_ISGID = 0o2000        # set-group-ID
S_ISVTX = 0o1000        # sticky bit

S_IRWXU = 0o0700        # owner mask
S_IRUSR = 0o0400        # owner read
S_IWUSR = 0o0200        # owner write
S_IXUSR = 0o0100        # owner execute

S_IRWXG = 0o0070        # group mask
S_IRGRP = 0o0040        # group read
S_IWGRP = 0o0020        # group write
S_IXGRP = 0o0010        # group execute

S_IRWXO = 0o0007        # other mask
S_IROTH = 0o0004        # other read
S_IWOTH = 0o0002        # other write
S_IXOTH = 0o0001        # other execute

S_IREAD = S_IRUSR       # BSD-legacy alias
S_IWRITE = S_IWUSR
S_IEXEC = S_IXUSR


# ── extract-just-permissions helper ───────────────────────────────────────

def S_IMODE(mode):
    """Return the portion of `mode` corresponding to permissions bits
    plus the sticky/setuid/setgid bits."""
    return mode & 0o7777


def S_IFMT_of(mode):
    """Return the file-type portion of `mode`."""
    return mode & S_IFMT


# ── file-type predicates ──────────────────────────────────────────────────

def S_ISDIR(mode):
    return (mode & S_IFMT) == S_IFDIR


def S_ISCHR(mode):
    return (mode & S_IFMT) == S_IFCHR


def S_ISBLK(mode):
    return (mode & S_IFMT) == S_IFBLK


def S_ISREG(mode):
    return (mode & S_IFMT) == S_IFREG


def S_ISFIFO(mode):
    return (mode & S_IFMT) == S_IFIFO


def S_ISLNK(mode):
    return (mode & S_IFMT) == S_IFLNK


def S_ISSOCK(mode):
    return (mode & S_IFMT) == S_IFSOCK
