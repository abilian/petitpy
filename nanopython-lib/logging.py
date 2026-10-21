"""logging — minimal logging for nanopython scripts.

The daily-CPython surface — ``getLogger`` / ``basicConfig`` / per-level
methods — works the same way. The handler / filter / propagation
hierarchy that bigger applications use is not implemented.

Usage::

    import logging

    logging.basicConfig(level=logging.INFO)
    log = logging.getLogger("myapp")
    log.debug("won't show — below INFO")
    log.info("hello %s", "world")
    log.warning("uh oh: count=%d", 42)

Format string variables supported (via plain ``%`` substitution):
    ``%(name)s``      — logger name
    ``%(levelname)s`` — level name ("INFO", "WARNING", …)
    ``%(level)d``     — level number
    ``%(message)s``   — the formatted message

Not supported (vs CPython logging):

  - ``Handler`` / ``Formatter`` / ``Filter`` classes
  - Logger hierarchy and propagation (every logger writes to one sink)
  - ``%(asctime)s``, ``%(threadName)s``, ``%(process)s`` (no datetime
    / threading)
  - ``dictConfig`` / ``fileConfig``
  - ``exc_info=`` traceback formatting
  - Lazy formatting via ``log()`` with non-str msg

Nano-specific extension: ``basicConfig(sink=callable)`` redirects
output to ``callable(line)`` instead of ``print``. Useful for tests
and for sending logs to a JS-side console under the wasm bridge.

See ADR 011 for the design rationale.
"""

# ── level constants ────────────────────────────────────────────────────

DEBUG = 10
INFO = 20
WARNING = 30
WARN = WARNING  # legacy alias
ERROR = 40
CRITICAL = 50
FATAL = CRITICAL  # legacy alias
NOTSET = 0

_LEVEL_NAMES = {
    DEBUG: "DEBUG",
    INFO: "INFO",
    WARNING: "WARNING",
    ERROR: "ERROR",
    CRITICAL: "CRITICAL",
    NOTSET: "NOTSET",
}


def getLevelName(level):
    """Return the textual name of a level number."""
    name = _LEVEL_NAMES.get(level)
    if name is not None:
        return name
    return "Level " + str(level)


# ── module-level (root) config ─────────────────────────────────────────

_root_level = WARNING
_root_format = "%(levelname)s:%(name)s:%(message)s"
_sink = None  # None means use print
_loggers = {}


def _emit(line):
    """Write a line to the active sink."""
    if _sink is None:
        print(line)
    else:
        _sink(line)


def _render(fmt, level, name, message):
    """Substitute %()s tokens in `fmt`."""
    out = fmt
    out = out.replace("%(levelname)s", getLevelName(level))
    out = out.replace("%(name)s", name)
    out = out.replace("%(level)d", str(level))
    out = out.replace("%(message)s", message)
    return out


# ── Logger ─────────────────────────────────────────────────────────────


class Logger:
    """Per-name logger. Created by getLogger() and cached there."""

    def __init__(self, name):
        self.name = name
        self.level = NOTSET  # NOTSET = inherit from root
        self.handlers = []
        self.propagate = True

    def setLevel(self, level):
        """Override the root level for this logger only. Accepts a
        numeric level or a string name (CPython convention)."""
        self.level = _coerce_level(level)

    def addHandler(self, handler):
        """No-op handler management — output goes through the
        module-level print sink; recorded so `logger.handlers` is a
        real list callers can inspect."""
        self.handlers.append(handler)

    def removeHandler(self, handler):
        try:
            self.handlers.remove(handler)
        except ValueError:
            pass

    def addFilter(self, f):
        pass

    def removeFilter(self, f):
        pass

    def getEffectiveLevel(self):
        return self.level if self.level != NOTSET else _root_level

    def hasHandlers(self):
        return bool(self.handlers)

    def isEnabledFor(self, level):
        """True if a log at `level` would be emitted by this logger."""
        effective = self.level if self.level != NOTSET else _root_level
        return level >= effective

    def log(self, level, msg, *args):
        """Generic log; only emitted if isEnabledFor(level)."""
        if not self.isEnabledFor(level):
            return
        if args:
            try:
                msg = msg % args
            except (TypeError, ValueError):
                pass  # leave msg unformatted if substitution fails
        _emit(_render(_root_format, level, self.name, msg))

    def debug(self, msg, *args):
        self.log(DEBUG, msg, *args)

    def info(self, msg, *args):
        self.log(INFO, msg, *args)

    def warning(self, msg, *args):
        self.log(WARNING, msg, *args)

    def warn(self, msg, *args):
        # Legacy alias retained for portability.
        self.log(WARNING, msg, *args)

    def error(self, msg, *args):
        self.log(ERROR, msg, *args)

    def critical(self, msg, *args):
        self.log(CRITICAL, msg, *args)

    def exception(self, msg, *args, exc_info=True):
        """Log at ERROR level. CPython attaches the current traceback;
        we drop that (no exc_info formatting under the print sink) but
        keep the method so callers written for CPython don't crash."""
        self.log(ERROR, msg, *args)

    def fatal(self, msg, *args):
        # Legacy alias retained for portability.
        self.log(CRITICAL, msg, *args)


# ── public API ─────────────────────────────────────────────────────────


def getLogger(name=None):
    """Return (and cache) a Logger by name. ``None`` and ``"root"``
    both refer to the root logger."""
    if name is None or name == "root":
        name = "root"
    if name not in _loggers:
        _loggers[name] = Logger(name)
    return _loggers[name]


def basicConfig(level=None, format=None, sink=None):
    """Configure the root logger.

    Parameters
    ----------
    level
        Set the root level. Loggers with `level == NOTSET` inherit.
    format
        Set the root format string. See module docstring for the
        supported tokens.
    sink
        Callable that takes one string per log line. Defaults to
        ``print``. Nano-specific; not in CPython logging. Useful for
        tests and for non-stdout outputs.
    """
    global _root_level, _root_format, _sink
    if level is not None:
        _root_level = level
    if format is not None:
        _root_format = format
    if sink is not None:
        _sink = sink


def disable(level=CRITICAL):
    """Disable logging at or below ``level``. (Nano subset: this just
    raises the root level; CPython's version inserts an implicit
    filter, which has the same observable effect for our subset.)"""
    global _root_level
    _root_level = max(_root_level, level + 1)


# ── module-level shortcuts (operate on root logger) ────────────────────


def debug(msg, *args):
    getLogger().debug(msg, *args)


def info(msg, *args):
    getLogger().info(msg, *args)


def warning(msg, *args):
    getLogger().warning(msg, *args)


def warn(msg, *args):
    getLogger().warning(msg, *args)


def error(msg, *args):
    getLogger().error(msg, *args)


def critical(msg, *args):
    getLogger().critical(msg, *args)


def fatal(msg, *args):
    getLogger().critical(msg, *args)


def log(level, msg, *args):
    getLogger().log(level, msg, *args)


# ── test/dev helpers ───────────────────────────────────────────────────


def _reset_for_tests():
    """Reset all module state. Test fixture; not part of the public
    API."""
    global _root_level, _root_format, _sink, _loggers
    _root_level = WARNING
    _root_format = "%(levelname)s:%(name)s:%(message)s"
    _sink = None
    _loggers = {}


# ── Handler / Formatter stubs ─────────────────────────────────────────────
#
# CPython application boilerplate (`logging.basicConfig(handlers=[...])`,
# `Handler().setFormatter(Formatter(...))`) crashes without these classes
# even when the runtime effect isn't exercised. Ship no-op stubs so the
# module-scope construction goes through — logging output still flows
# via the simple print sink above.


_NAME_TO_LEVEL = {
    "CRITICAL": CRITICAL,
    "FATAL": CRITICAL,
    "ERROR": ERROR,
    "WARN": WARNING,
    "WARNING": WARNING,
    "INFO": INFO,
    "DEBUG": DEBUG,
    "NOTSET": NOTSET,
}


def _coerce_level(level):
    if isinstance(level, str):
        return _NAME_TO_LEVEL.get(level.upper(), NOTSET)
    return level


class Handler:
    """No-op handler stub. Setting level/formatter/filter succeeds but
    doesn't affect output (single print-sink model)."""

    def __init__(self, level=NOTSET):
        self.level = _coerce_level(level)
        self.formatter = None

    def setLevel(self, level):
        self.level = _coerce_level(level)

    def setFormatter(self, formatter):
        self.formatter = formatter

    def addFilter(self, f):
        pass

    def removeFilter(self, f):
        pass

    def emit(self, record):
        pass

    def flush(self):
        pass

    def close(self):
        pass


class StreamHandler(Handler):
    def __init__(self, stream=None):
        Handler.__init__(self)
        self.stream = stream


class FileHandler(Handler):
    def __init__(self, filename, mode="a", encoding=None):
        Handler.__init__(self)
        self.baseFilename = filename
        self.mode = mode
        self.encoding = encoding


class NullHandler(Handler):
    pass


class Formatter:
    """Stub formatter — records the format string but doesn't rewrite
    output. Handler.setFormatter uses this; our sink formats via the
    module-level basicConfig format anyway."""

    def __init__(self, fmt=None, datefmt=None, style="%"):
        self._fmt = fmt
        self._datefmt = datefmt
        self._style = style

    def format(self, record):
        return str(record)


class Filter:
    def __init__(self, name=""):
        self.name = name

    def filter(self, record):
        return True
