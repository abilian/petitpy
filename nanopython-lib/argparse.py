"""argparse — minimal command-line argument parser for nanopython.

Covers the daily-CPython idioms::

    p = argparse.ArgumentParser(description="my tool")
    p.add_argument("input")
    p.add_argument("--verbose", "-v", action="store_true")
    p.add_argument("--count", type=int, default=1)
    p.add_argument("--mode", choices=["fast", "safe"])
    args = p.parse_args()

    if args.verbose: ...
    for i in range(args.count): process(args.input)

Supported:
    - Positional arguments (``p.add_argument("input")``)
    - Long flags (``--verbose``), short flags (``-v``), or both
    - ``--flag value`` and ``--flag=value`` forms
    - ``action="store"`` (default), ``"store_true"``, ``"store_false"``, ``"count"``
    - ``type=`` callable for type conversion (e.g., ``type=int``)
    - ``default=`` for default values
    - ``choices=`` for value validation
    - ``required=`` for non-positional options
    - ``-h`` / ``--help`` automatically handled
    - Exit-on-error with a useful message (matches CPython behavior)

Not supported (vs CPython argparse):
    - Subparsers / ``add_subparsers()``
    - ``nargs=`` (no N / '?' / '*' / '+')
    - ``action="append"`` / ``"extend"`` / ``"version"``
    - Mutually exclusive groups
    - ``parents=``, ``allow_abbrev=``, custom Action subclasses
    - Custom usage / formatter classes

See ADR 011 for the design rationale.
"""

import sys


class Namespace:
    """Object returned by ``parse_args()``. Each declared argument
    becomes an attribute."""

    def __repr__(self):
        items = []
        for k in dir(self):
            if k.startswith("_"):
                continue
            v = getattr(self, k)
            items.append(k + "=" + repr(v))
        return "Namespace(" + ", ".join(items) + ")"


class _ArgumentError(Exception):
    """Internal: raised on parse failure. The parser converts to
    a user-friendly error+exit via _error()."""


class _Spec:
    """One argument's specification, built by add_argument()."""

    def __init__(self, dest, flags, type, default, action, choices, required, help):
        self.dest = dest
        self.flags = flags  # all flag strings, or [name] for positional
        self.type = type
        self.default = default
        self.action = action
        self.choices = choices
        self.required = required
        self.help = help
        self.is_positional = not (flags and flags[0].startswith("-"))
        self.seen = False  # tracked during parse for required-check


class ArgumentParser:
    """The argument-parser entry point."""

    def __init__(self, prog=None, description=""):
        self.prog = prog or "program"
        self.description = description
        self._positionals = []  # list of _Spec
        self._optionals = {}  # flag → _Spec (alternates point to same spec)
        self._all_specs = []  # all specs in declaration order

    def add_argument(
        self,
        *name_or_flags,
        type=str,
        default=None,
        action="store",
        choices=None,
        required=False,
        help="",
    ):
        if not name_or_flags:
            raise TypeError("add_argument() requires at least one name or flag")

        flags = list(name_or_flags)
        first = flags[0]

        if first.startswith("-"):
            # Optional. Derive dest from the longest --flag if any.
            long_flags = [f for f in flags if f.startswith("--")]
            if long_flags:
                dest = long_flags[0].lstrip("-").replace("-", "_")
            else:
                dest = flags[0].lstrip("-").replace("-", "_")
        else:
            # Positional.
            dest = first.replace("-", "_")
            required = True

        if action not in ("store", "store_true", "store_false", "count"):
            raise ValueError("unsupported action: " + action)

        # Implicit defaults for flag-style actions.
        if action == "store_true" and default is None:
            default = False
        elif action == "store_false" and default is None:
            default = True
        elif action == "count" and default is None:
            default = 0

        spec = _Spec(
            dest=dest,
            flags=flags,
            type=type,
            default=default,
            action=action,
            choices=choices,
            required=required,
            help=help,
        )

        if spec.is_positional:
            self._positionals.append(spec)
        else:
            for flag in flags:
                self._optionals[flag] = spec
        self._all_specs.append(spec)
        return spec

    def parse_args(self, argv=None):
        """Parse argv (default ``sys.argv[1:]``) and return a Namespace.
        On parse failure, prints an error message and exits with status 2."""
        if argv is None:
            argv = sys.argv[1:]
        try:
            return self._parse(list(argv))
        except _ArgumentError as e:
            self._error(str(e))

    def _parse(self, argv):
        ns = Namespace()
        # Seed defaults.
        for spec in self._all_specs:
            setattr(ns, spec.dest, spec.default)

        positional_idx = 0
        i = 0
        while i < len(argv):
            arg = argv[i]

            # Help is handled specially.
            if arg in ("-h", "--help"):
                self.print_help()
                sys.exit(0)

            # --flag=value form
            if arg.startswith("--") and "=" in arg:
                flag, _, value = arg.partition("=")
                spec = self._optionals.get(flag)
                if spec is None:
                    raise _ArgumentError("unrecognized argument: " + arg)
                self._apply(ns, spec, value)
                i += 1
                continue

            # --flag or -f form
            if arg.startswith("-") and arg in self._optionals:
                spec = self._optionals[arg]
                if spec.action in ("store_true", "store_false", "count"):
                    self._apply(ns, spec, None)
                    i += 1
                else:
                    if i + 1 >= len(argv):
                        raise _ArgumentError(arg + " requires a value")
                    self._apply(ns, spec, argv[i + 1])
                    i += 2
                continue

            # Unknown flag (starts with - but isn't registered)
            if arg.startswith("-"):
                raise _ArgumentError("unrecognized argument: " + arg)

            # Positional
            if positional_idx >= len(self._positionals):
                raise _ArgumentError("unexpected positional argument: " + arg)
            spec = self._positionals[positional_idx]
            positional_idx += 1
            self._apply(ns, spec, arg)
            i += 1

        # Missing positional?
        if positional_idx < len(self._positionals):
            missing = self._positionals[positional_idx].dest
            raise _ArgumentError("missing required argument: " + missing)

        # Required option missing?
        for spec in self._all_specs:
            if spec.required and not spec.is_positional and not spec.seen:
                raise _ArgumentError(
                    "missing required option: " + spec.flags[0]
                )

        return ns

    def _apply(self, ns, spec, raw_value):
        """Convert ``raw_value`` per spec and store on ``ns``."""
        spec.seen = True
        if spec.action == "store_true":
            value = True
        elif spec.action == "store_false":
            value = False
        elif spec.action == "count":
            current = getattr(ns, spec.dest, 0)
            if current is None:
                current = 0
            value = current + 1
        else:  # action == "store"
            try:
                value = spec.type(raw_value)
            except (ValueError, TypeError):
                raise _ArgumentError(
                    "invalid value for "
                    + spec.flags[0]
                    + ": "
                    + repr(raw_value)
                )
            if spec.choices is not None and value not in spec.choices:
                raise _ArgumentError(
                    "invalid choice for "
                    + spec.flags[0]
                    + ": "
                    + repr(value)
                    + " (choose from "
                    + ", ".join(repr(c) for c in spec.choices)
                    + ")"
                )
        setattr(ns, spec.dest, value)

    def print_help(self):
        """Print a usage + arguments overview."""
        pos_str = " " + " ".join(s.dest for s in self._positionals) if self._positionals else ""
        print("usage: " + self.prog + " [options]" + pos_str)
        if self.description:
            print()
            print(self.description)
        if self._positionals:
            print()
            print("positional arguments:")
            for s in self._positionals:
                line = "  " + s.dest
                if s.help:
                    line += "  " + s.help
                print(line)
        print()
        print("options:")
        print("  -h, --help  show this help message and exit")
        seen = set()
        for s in self._all_specs:
            if s.is_positional:
                continue
            key = tuple(s.flags)
            if key in seen:
                continue
            seen.add(key)
            line = "  " + ", ".join(s.flags)
            if s.help:
                line += "  " + s.help
            print(line)

    def print_usage(self):
        pos_str = " " + " ".join(s.dest for s in self._positionals) if self._positionals else ""
        print("usage: " + self.prog + " [options]" + pos_str)

    def _error(self, message):
        """Print error and exit with status 2 — matches CPython argparse."""
        print(self.prog + ": error: " + message)
        sys.exit(2)
