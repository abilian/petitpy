#!/usr/bin/env python3
"""Empirical smoke: try to import hop3-rootd under petitpy, log the
first blocker at each level.

Reproducible probe for running hop3-rootd on full-native.
Instead of guessing the dependency order, this script:

  1. Builds a shim tree combining hop3-rootd's source, petitpy-lib's
     modules, and skeleton stubs for stdlib gaps (typing,
     collections.abc, importlib.metadata) — every stub is 100% no-op,
     just enough for `import X` to succeed.
  2. Runs a series of import probes with increasing scope:
       a. Each stdlib import (typing, collections.abc, …) in isolation
       b. Each hop3_rootd stdlib import individually
       c. Each hop3_rootd submodule import individually
       d. Whole-package `import hop3_rootd`
       e. Entry point `python -m hop3_rootd --help`
  3. Prints a punch-list of what worked, what failed, and the exact
     error.

Usage:
    python3 tools/hop3_rootd_smoke.py [BINARY] [HOP3_ROOTD_SRC]

Defaults:
    BINARY         zig-out/bin/petitpy
    HOP3_ROOTD_SRC ~/projects/hop3/hop3/packages/hop3-rootd/src

The shim dir goes under the scratchpad; re-runs rebuild it from
scratch (fast, ~100ms).
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# Where hop3-rootd's source lives. Override with $HOP3_SRC; the fallback is
# only a convenience for the layout this was developed against.
DEFAULT_HOP3_SRC = Path(
    os.environ.get(
        "HOP3_SRC", Path.home() / "projects/hop3/hop3/packages/hop3-rootd/src"
    )
)

# Minimal, no-op stubs. Real implementations belong in petitpy-lib/
# or as C-side modules; these are just enough to unblock `import X`.
STUBS: dict[str, str] = {
    "typing.py": '''"""No-op typing stub.

Every typing name that can appear at module scope (annotations,
Literal[...], Callable[[X], Y], etc.) resolves to something subscript-
able. Runtime type hints are erased on MicroPython anyway.
"""


class _Subscriptable:
    """Instance of this class is what Any/Literal/Final/Union/etc. bind to.

    Supports `X[...]` (annotation subscript), `isinstance(x, X)`
    (always False), and str(X). Same trick vendor micropython-lib's
    typing.py uses.
    """
    def __init__(self, name="_Subscriptable"): self._name = name
    def __getitem__(self, item): return self
    def __call__(self, *a, **kw): return None
    def __repr__(self): return "typing." + self._name
    __instancecheck__ = staticmethod(lambda self, other: False)


# Class-shaped placeholders. Instances of typing can't be inherited
# from (`class X(Protocol):` needs Protocol to be a class), so these
# are trivial classes with __class_getitem__ for subscript support.
class _Subclassable:
    def __class_getitem__(cls, item): return cls


class Protocol(_Subclassable): pass
class Generic(_Subclassable): pass


Any = _Subscriptable("Any")
Final = _Subscriptable("Final")
Literal = _Subscriptable("Literal")
Self = _Subscriptable("Self")
TextIO = _Subscriptable("TextIO")
BinaryIO = _Subscriptable("BinaryIO")
IO = _Subscriptable("IO")
ClassVar = _Subscriptable("ClassVar")
NoReturn = _Subscriptable("NoReturn")
Never = _Subscriptable("Never")
Optional = _Subscriptable("Optional")
Union = _Subscriptable("Union")
Callable = _Subscriptable("Callable")
Iterable = _Subscriptable("Iterable")
Iterator = _Subscriptable("Iterator")
Mapping = _Subscriptable("Mapping")
MutableMapping = _Subscriptable("MutableMapping")
Sequence = _Subscriptable("Sequence")
MutableSequence = _Subscriptable("MutableSequence")
Awaitable = _Subscriptable("Awaitable")
Coroutine = _Subscriptable("Coroutine")
Generator = _Subscriptable("Generator")
AsyncGenerator = _Subscriptable("AsyncGenerator")
ContextManager = _Subscriptable("ContextManager")
AsyncContextManager = _Subscriptable("AsyncContextManager")

# Builtin-collection aliases.
List = list
Dict = dict
Tuple = tuple
Set = set
FrozenSet = frozenset
Type = type
TYPE_CHECKING = False


def TypeVar(name, *args, **kw): return object
def NewType(name, tp): return tp
def cast(tp, val): return val
def overload(fn): return fn
def final(fn): return fn
def runtime_checkable(cls): return cls
def get_type_hints(obj): return {}
''',
    "collections/abc.py": '''"""No-op collections.abc stub.

Every ABC resolves to `object` — enough for `isinstance(x, Callable)`
to be False without raising, and for type-hint uses. Real ABCs live
under `collections.abc` in CPython; MicroPython doesn't ship them.
"""

Callable = object
Hashable = object
Iterable = object
Iterator = object
Reversible = object
Generator = object
Sized = object
Container = object
Collection = object
Sequence = object
MutableSequence = object
ByteString = object
Set = object
MutableSet = object
Mapping = object
MutableMapping = object
MappingView = object
ItemsView = object
KeysView = object
ValuesView = object
Awaitable = object
Coroutine = object
AsyncIterable = object
AsyncIterator = object
AsyncGenerator = object
''',
    "importlib/metadata.py": '''"""Minimal importlib.metadata stub.

CPython reads package metadata from installed .dist-info dirs. Under
petitpy there's no such directory; we hardcode a table keyed by
package name. Extend as needed.
"""


class PackageNotFoundError(ImportError):
    pass


_VERSIONS = {
    "petitpy": "0.7.1",
    # Preseed anything a probed package needs. Keeps hop3-rootd's
    # `version("hop3-rootd")` on line 15 of __init__.py from raising.
    "hop3-rootd": "0.6.2",
}


def version(pkg):
    if pkg in _VERSIONS:
        return _VERSIONS[pkg]
    raise PackageNotFoundError(pkg)
''',
    "datetime.py": '''"""Minimal datetime stub — enough to unblock import chains.

Does NOT compute real calendar arithmetic. hop3-rootd's use is
`datetime.now(timezone.utc).isoformat()` for audit-log timestamps;
this returns a fixed-but-shaped string. Ship a real Python datetime
implementation in petitpy-lib when a caller needs correctness.
"""


class timezone:
    def __init__(self, offset=None, name=None):
        self._offset = offset
        self._name = name

    def __repr__(self):
        return "timezone(?)"


timezone.utc = timezone(None, "UTC")


class timedelta:
    def __init__(self, days=0, seconds=0, microseconds=0):
        self.days = days
        self.seconds = seconds
        self.microseconds = microseconds


class datetime:
    def __init__(self, year=1970, month=1, day=1, hour=0, minute=0, second=0,
                 microsecond=0, tzinfo=None):
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
        self.microsecond = microsecond
        self.tzinfo = tzinfo

    @classmethod
    def now(cls, tz=None):
        return cls(tzinfo=tz)

    @classmethod
    def utcnow(cls):
        return cls(tzinfo=timezone.utc)

    def isoformat(self, sep="T"):
        return "1970-01-01T00:00:00+00:00"

    def __repr__(self):
        return "datetime(?)"

    def __str__(self):
        return self.isoformat()
''',
    "pathlib.py": '''"""Minimal pathlib stub — string-backed Path.

Just enough for the parts of hop3-rootd that construct paths at
import time:
    DEFAULT_SOCKET_PATH: Final[Path] = Path("/run/hop3-rootd/socket")

Runtime methods (`.is_file`, `.iterdir`, `.read_text`) raise
NotImplementedError when called — the goal is to see how far the
IMPORT graph goes, not to actually run hop3-rootd's logic.
"""


class Path:
    def __init__(self, *parts):
        # Flatten str/Path parts into a single string, POSIX-style.
        strs = []
        for p in parts:
            s = str(p) if not isinstance(p, str) else p
            if s == "":
                continue
            strs.append(s)
        if not strs:
            self._s = "."
        else:
            head = strs[0]
            tail = "/".join(x.strip("/") for x in strs[1:])
            if tail:
                if head.endswith("/"):
                    self._s = head + tail
                else:
                    self._s = head + "/" + tail
            else:
                self._s = head

    def __truediv__(self, other):
        return Path(self._s, str(other))

    def __rtruediv__(self, other):
        return Path(str(other), self._s)

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

    @property
    def name(self):
        i = self._s.rfind("/")
        return self._s[i + 1:] if i >= 0 else self._s

    @property
    def parent(self):
        i = self._s.rfind("/")
        if i < 0:
            return Path(".")
        return Path(self._s[:i] if i > 0 else "/")

    def _raise(self, method):
        raise NotImplementedError(
            "pathlib stub: " + method + " not implemented under petitpy smoke"
        )

    def exists(self): self._raise("exists")
    def is_file(self): self._raise("is_file")
    def is_dir(self): self._raise("is_dir")
    def is_symlink(self): self._raise("is_symlink")
    def read_text(self, *a, **kw): self._raise("read_text")
    def write_text(self, *a, **kw): self._raise("write_text")
    def read_bytes(self): self._raise("read_bytes")
    def write_bytes(self, *a, **kw): self._raise("write_bytes")
    def iterdir(self): self._raise("iterdir")
    def mkdir(self, *a, **kw): self._raise("mkdir")
    def unlink(self, *a, **kw): self._raise("unlink")
    def rmdir(self): self._raise("rmdir")
    def resolve(self, *a, **kw): return self
    def absolute(self): return self


class PurePath(Path): pass
class PurePosixPath(Path): pass
class PosixPath(Path): pass
''',
    "importlib/__init__.py": "",
    # Deliberately no `collections/__init__.py` + `collections/abc.py`.
    # The frozen `collections` bare module (baked from
    # petitpy-lib/collections.py) shadows any on-disk `collections/`
    # package — see finding in the smoke script output for the real fix
    # (convert petitpy-lib/collections.py into a package).
    # ── Modules that will eventually be C-side, stubbed for probe-time.
    # Each raises NotImplementedError when its functions are CALLED;
    # imports and attribute reads succeed, which is enough to walk
    # further down the import graph.
    "pwd.py": '''"""pwd stub — needs libc getpwnam(3), full-unix-profile phase 7."""

def _nope(name):
    raise NotImplementedError("pwd." + name + " requires the C-side pwd module (plan phase 7)")


class struct_passwd(tuple):
    pass


def getpwnam(name): _nope("getpwnam")
def getpwuid(uid): _nope("getpwuid")
''',
    "grp.py": '''"""grp stub — needs libc getgrnam(3), full-unix-profile phase 7."""

def _nope(name):
    raise NotImplementedError("grp." + name + " requires the C-side grp module (plan phase 7)")


class struct_group(tuple):
    pass


def getgrnam(name): _nope("getgrnam")
def getgrgid(gid): _nope("getgrgid")
''',
    "signal.py": '''"""signal stub — needs sigaction integration, full-unix-profile phase 5."""

# Common Linux signal numbers so `signal.SIGTERM` in module-scope
# constants resolves. Values match Linux; macOS differs for USR1/USR2
# but that's fine for import-time.
SIGHUP = 1
SIGINT = 2
SIGQUIT = 3
SIGKILL = 9
SIGUSR1 = 10
SIGUSR2 = 12
SIGPIPE = 13
SIGTERM = 15
SIGCHLD = 17
SIG_DFL = 0
SIG_IGN = 1


def signal(signum, handler):
    raise NotImplementedError("signal.signal requires the C-side signal module (plan phase 5)")


def getsignal(signum): return SIG_DFL
''',
    "socket.py": '''"""socket stub — needs BSD sockets, full-unix-profile phase 3."""

AF_UNIX = 1
AF_INET = 2
AF_INET6 = 10
SOCK_STREAM = 1
SOCK_DGRAM = 2
SOL_SOCKET = 1
SO_REUSEADDR = 2
SO_PEERCRED = 17  # Linux value; macOS lacks this


class error(OSError): pass


def socket(family=AF_INET, type=SOCK_STREAM, proto=0):
    raise NotImplementedError("socket.socket requires the C-side socket module (plan phase 3)")


def fromfd(fd, family, type, proto=0):
    raise NotImplementedError("socket.fromfd requires the C-side socket module (plan phase 3)")
''',
    "select.py": '''"""select stub — needs select(2)/poll(2), full-unix-profile phase 4."""


def select(rlist, wlist, xlist, timeout=None):
    raise NotImplementedError("select.select requires the C-side select module (plan phase 4)")


def poll():
    raise NotImplementedError("select.poll requires the C-side select module (plan phase 4)")
''',
    "subprocess.py": '''"""subprocess stub — needs fork+exec+wait, full-unix-profile phase 6."""


class CompletedProcess:
    def __init__(self, args, returncode, stdout=None, stderr=None):
        self.args = args
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


class CalledProcessError(Exception): pass
class TimeoutExpired(Exception): pass


PIPE = -1
STDOUT = -2
DEVNULL = -3


def run(*a, **kw):
    raise NotImplementedError("subprocess.run requires the C-side subprocess module (plan phase 6)")


def check_output(*a, **kw): return run(*a, **kw)


class Popen:
    def __init__(self, *a, **kw):
        raise NotImplementedError("subprocess.Popen not planned; use subprocess.run")
''',
    "shutil.py": '''"""shutil stub — cheap subset in Python; full impl deferred.

hop3-rootd uses only shutil.which. Ship a minimal implementation that
walks $PATH and checks os.access for executability.
"""

import os


def which(cmd, mode=None, path=None):
    if os.sep in cmd:
        # Absolute or relative path — check directly.
        if os.access(cmd, os.X_OK):
            return cmd
        return None
    search_path = path or os.getenv("PATH", "")
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
''',
    "time.py": '''"""time stub — needs time.h wrappers, full-unix-profile phase 2."""


def time():
    raise NotImplementedError("time.time requires the C-side time module (plan phase 2)")


def sleep(secs):
    raise NotImplementedError("time.sleep requires the C-side time module (plan phase 2)")


def monotonic():
    raise NotImplementedError("time.monotonic requires the C-side time module (plan phase 2)")


def perf_counter(): return monotonic()
def process_time(): return monotonic()
''',
    "uuid.py": '''"""uuid stub — pure Python, delegates to os.urandom for uuid4."""

import os


class UUID:
    def __init__(self, bytes_=None, hex=None, int=None):
        if bytes_ is not None:
            self._bytes = bytes(bytes_)
        elif int is not None:
            b = bytearray(16)
            for i in range(15, -1, -1):
                b[i] = int & 0xff
                int >>= 8
            self._bytes = bytes(b)
        else:
            raise ValueError("UUID needs bytes_ or int")

    @property
    def bytes(self): return self._bytes

    def __str__(self):
        h = self._bytes.hex()
        return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:32]

    def __repr__(self): return "UUID('" + str(self) + "')"


def uuid4():
    raw = bytearray(os.urandom(16))
    # RFC 4122 §4.4: set version 4 in bits 6-7 of byte 6, variant 10 in
    # bits 6-7 of byte 8.
    raw[6] = (raw[6] & 0x0f) | 0x40
    raw[8] = (raw[8] & 0x3f) | 0x80
    return UUID(bytes_=bytes(raw))
''',
}


def _wheel_stdlib() -> dict[Path, str]:
    """Source file -> path under share/petitpy/lib/, from the wheel's own
    build hook (loaded the way tests/wheel_layout.py loads it)."""
    import importlib.util

    spec = importlib.util.spec_from_file_location("wheel_layout", REPO / "tests" / "wheel_layout.py")
    layout = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(layout)
    return layout.load_hook().stdlib_files(REPO)


def build_shim(shim_dir: Path, hop3_src: Path) -> None:
    """Wipe + rebuild the shim directory. Idempotent, ~100ms."""
    if shim_dir.exists():
        shutil.rmtree(shim_dir)
    shim_dir.mkdir(parents=True)

    # The stdlib exactly as the wheel ships it at share/petitpy/lib/.
    for src, dest in _wheel_stdlib().items():
        (shim_dir / dest).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, shim_dir / dest)

    # No-op stubs (typing, collections.abc, importlib.metadata, …) from the
    # STUBS dict, only for modules that stdlib does not ship: a stale stub
    # would shadow the real module on a build that reads its stdlib from disk.
    for rel, content in STUBS.items():
        dst = shim_dir / rel
        if dst.exists():
            continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_text(content)

    # hop3-rootd source itself — copy the whole `hop3_rootd/` package
    # tree so it resolves as `import hop3_rootd`.
    hop3_pkg = hop3_src / "hop3_rootd"
    if not hop3_pkg.exists():
        raise SystemExit(f"hop3-rootd source not found at {hop3_pkg}")
    shutil.copytree(hop3_pkg, shim_dir / "hop3_rootd")


def run_probe(
    binary: Path, shim_dir: Path, script: str, timeout: float = 15
) -> tuple[int, str, str]:
    """Write `script` to a tempfile, run under BINARY with PETITPY_LIB=shim_dir."""
    with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False) as f:
        f.write(script + "\n")
        path = f.name
    try:
        env = os.environ.copy()
        env["PETITPY_LIB"] = str(shim_dir)
        p = subprocess.run(
            [str(binary), path],
            capture_output=True,
            text=True,
            timeout=timeout,
            env=env,
            check=False,
        )
        return p.returncode, p.stdout, p.stderr
    finally:
        os.unlink(path)


# petitpy ships frozen importlib.metadata now (Phase 8) so our shim
# is shadowed. Preseed hop3-rootd's version by patching `_VERSIONS` in
# the frozen module at the start of every probe script.
_VERSION_PRELUDE = (
    "from importlib.metadata import _VERSIONS\n_VERSIONS['hop3-rootd'] = '0.6.2'\n"
)


def probe(binary: Path, shim_dir: Path, label: str, script: str) -> bool:
    # Prepend the version prelude to every probe. Cheap; only affects
    # probes that touch hop3_rootd's __init__.py.
    script = _VERSION_PRELUDE + script
    rc, out, err = run_probe(binary, shim_dir, script)
    ok = rc == 0
    tag = "PASS" if ok else "FAIL"
    print(f"  [{tag}] {label}")
    if not ok:
        # Trim to the salient line: MicroPython prints
        #   Traceback (most recent call last):
        #     File "<stdin>", in <module>
        #   ImportError: ...
        lines = (out + err).strip().splitlines()
        if lines:
            for line in lines[-3:]:
                print(f"         {line}")
    return ok


PUNCH_LIST = """\
============================================================
PUNCH LIST — categorized findings
============================================================

A. petitpy bugs / gaps that no PETITPY_LIB shim can fix:

   1. `collections.abc` unresolvable — FIXED. petitpy-lib/
      collections/ is now a package with abc.py inside; the
      freezer registers 'collections.abc' as a dotted entry;
      import_search.tryLoadComponent tries frozen lookup by
      the full dotted name (not just the top level).

   2. `re.IGNORECASE` (etc.) — FIXED via frozen petitpy-lib/re.py
      shim (IGNORECASE=0 no-op flag; underlying case-sensitive).

   2b. re1.5 engine capacity — FIXED via port/re1.5-patched/
      overlay. Jump offsets widened int8 → int16 in compilecode.c
      + recursiveloop.c + dumpcode.c (NON_ANCHORED_PREFIX 5→7 in
      re1.5.h). Long alternation groups now compile. Corpus + wasm
      + integration all green post-patch.

   3. `from pkg import sub` submodule autoload — FIXED. Vendor
      py/runtime.c:mp_import_from has a package-fallback block
      (if getattr(pkg,sub) misses AND pkg has __path__, import
      pkg.sub). runtime.zig:mpImportFromImpl was missing it —
      ported. Also: frozen package `collections/__init__.py`
      needed `__path__ = []` so the fallback fires for it.

   3b. hop3_rootd/exec.py `env = {**os.environ, **extra_env}` —
      FIXED (2026-07-20). Grammar overlay adds a dbl_star
      alternative to dictorsetmaker (port/grammar-patched/) +
      compile.zig emits DUP_TOP; LOAD_METHOD update; ...;
      CALL_METHOD 1; POP_TOP for each `**expr`. Nested dicts,
      mixed k:v/dbl_star, single-item `{**a}`, and error paths
      (set + **, dict-comp + **) all covered. Regression pin in
      tests/test_integration_core.py::dict_unpack_pep448.

   7. `ipaddress` missing — FIXED (2026-07-20). Shipped
      petitpy-lib/ipaddress.py: ip_address, ip_network,
      IPv4/IPv6 Address/Network with str/int/eq/hash. IPv6
      stored as 8-group tuple to avoid needing 128-bit ints
      under nano's `MICROPY_LONGINT_IMPL=NONE`. Frozen at
      build-frozen/ipaddress.mpy (~3.4 KB). Unblocks
      validation.py + nft.rule + first cascade of consumers.

   8. PEP 448 `[a, *b]` list-unpack — FIXED (2026-07-20).
      Grammar already accepted star_expr in testlist_comp;
      compileAtomBracket now detects star_expr children and
      switches to BUILD_LIST 0 + dup+append/extend+call+pop.
      Regression pin in tests/test_integration_core.py
      ::list_unpack_pep448. Unblocks proxy.py, reconcile.

   9. PEP 570 positional-only `/` — FIXED (2026-07-20).
      Grammar overlay adds typedargslist_slash / varargslist_slash
      matching a lone `/` token; compile.zig walkers early-return
      on it (MicroPython doesn't enforce positional-only anyway).
      Regression pin ::positional_only_pep570. Unblocks ops._base.

   10. `class Foo(Enum):` — FIXED (2026-07-21). Added Enum,
       IntEnum, StrEnum stub base classes to petitpy-lib/
       enum.py (Enum module now frozen). Under petitpy the
       subclass form doesn't fire __init_subclass__ so members
       stay as plain class attributes — for str-valued enums
       used as opaque tokens (hop3-rootd's ErrorCode pattern)
       that's identical to CPython semantics via the str base.
       For real .name/.value/iteration semantics use @enum.

   4. `sys.argv` isn't assignable — WORKED AROUND (2026-07-21).
      Real fix would need a mutable module globals dict (same
      architectural blocker as os.path submodule assignment).
      sys.argv itself IS a mutable list, so consumers use
      `sys.argv.clear(); sys.argv.extend([...])` instead of
      `sys.argv = [...]`. Level 4 smoke uses this idiom.

   5. re1.5 engine capacity — hop3_rootd.audit's 13-alternative
      secret-scrub pattern with `[-_]?` sub-parts trips
      `ValueError: error in regex` at compile. Individual alts
      compile fine; combined they exceed the engine's limit.

   6. `TypeError: unexpected keyword argument` in hop3_rootd.state —
      FIXED. Root cause: @dataclass(frozen=True) — the shim
      only accepted init/repr/eq. Extended petitpy-lib/
      dataclasses.py to accept-and-ignore frozen/slots/
      kw_only/order/unsafe_hash/match_args (silent semantics,
      documented). state.py + any similar CPython dataclass
      usage now imports cleanly.

B. Real C-side modules the plan needs to ship (per phase order):

   - time      (phase 2, ~0.5 session)   — needed by server.py
   - socket    (phase 3, ~3 sessions)    — needed by server.py
   - select    (phase 4, ~0.5 session)   — needed by server.py
   - signal    (phase 5, ~0.5 session)   — needed by __main__.py
   - subprocess (phase 6, ~2 sessions)   — needed by exec.py
   - pwd, grp  (phase 7, ~0.5 session)   — needed by mount.py, server.py

C. Pure-Python shims to add to petitpy-lib/ (order roughly
   by scope — cheap wins first):

   - typing.py       (~50 LOC — see this script's STUBS)
   - collections/abc.py (blocked on A.1)
   - importlib/metadata.py (~10 LOC — see this script's STUBS)
   - uuid.py         (~30 LOC — pure Python, needs os.urandom)
   - shutil.py       (~20 LOC for which() — needs os.access + os.getenv)
   - datetime.py     (~200 LOC — real calendar math, not stub)
   - pathlib.py      (~250 LOC — real Path.exists/is_file/... on os.stat)
   - os.path         (~150 LOC — join/basename/dirname/exists/realpath)

Stubs live under (safe to inspect + delete):"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument(
        "binary", nargs="?", default=str(REPO / "zig-out/bin/petitpy")
    )
    parser.add_argument(
        "hop3_src",
        nargs="?",
        default=str(DEFAULT_HOP3_SRC),
    )
    parser.add_argument(
        "--shim-dir",
        default=None,
        help="Where to build the shim tree (default: under scratchpad)",
    )
    args = parser.parse_args()

    binary = Path(args.binary).resolve()
    if not binary.exists():
        print(f"error: binary not found: {binary}", file=sys.stderr)
        print("       build it first: `make build`", file=sys.stderr)
        return 2

    hop3_src = Path(args.hop3_src).resolve()
    if not (hop3_src / "hop3_rootd").exists():
        print(
            f"error: hop3-rootd source not found at {hop3_src}/hop3_rootd",
            file=sys.stderr,
        )
        return 2

    shim_dir = (
        Path(args.shim_dir)
        if args.shim_dir
        else Path(tempfile.mkdtemp(prefix="hop3-smoke-"))
    )
    print(f"binary:   {binary}")
    print(f"hop3-src: {hop3_src}")
    print(f"shim:     {shim_dir}")

    build_shim(shim_dir, hop3_src)
    print()

    # ── Level 1: stdlib imports in isolation ──────────────────────────
    print("Level 1 — stdlib imports:")
    stdlib_mods = [
        "typing",
        "collections.abc",
        "datetime",
        "pathlib",
        "signal",
        "socket",
        "importlib.metadata",
        # from petitpy-lib (should already work):
        "argparse",
        "logging",
        "json",
    ]
    for mod in stdlib_mods:
        probe(binary, shim_dir, mod, f"import {mod}")
    print()

    # ── Level 2: hop3_rootd's __main__ stdlib imports (with from-list) ─
    print("Level 2 — hop3_rootd stdlib usage:")
    main_imports = [
        ("collections.abc.Callable", "from collections.abc import Callable"),
        ("datetime.datetime,timezone", "from datetime import datetime, timezone"),
        ("pathlib.Path", "from pathlib import Path"),
        ("typing.Final,TypeVar", "from typing import Final, TypeVar"),
        ("importlib.metadata.version", "from importlib.metadata import version"),
    ]
    for label, src in main_imports:
        probe(binary, shim_dir, label, src)
    print()

    # ── Level 3: hop3_rootd package subimports one at a time ──────────
    print("Level 3 — hop3_rootd submodules (in dependency order per __main__):")
    submods = [
        "hop3_rootd",  # __init__
        "hop3_rootd.cgroup",
        "hop3_rootd.proxy",
        "hop3_rootd.audit",
        "hop3_rootd.mount",
        "hop3_rootd.nft.rule",
        "hop3_rootd.reconcile",
        "hop3_rootd.server",
        "hop3_rootd.state",
        "hop3_rootd.__main__",
    ]
    for mod in submods:
        probe(binary, shim_dir, mod, f"import {mod}")
    print()

    # ── Level 4: entry point ──────────────────────────────────────────
    # petitpy doesn't ship `-m`, so simulate by running the package's
    # __main__.py directly via a wrapper script that calls its main().
    # `sys.argv = ...` would need a mutable module globals dict (deferred
    # — same architectural blocker as os.path), so we mutate the existing
    # list in place. Same reachable state.
    print("Level 4 — entry point (simulated -m):")
    entry = """
import sys
sys.argv.clear()
sys.argv.extend(['hop3-rootd', '--help'])
from hop3_rootd.__main__ import main
sys.exit(main())
"""
    ok = probe(binary, shim_dir, "hop3-rootd --help", entry)
    print()

    print(PUNCH_LIST)
    print(f"   {shim_dir}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
