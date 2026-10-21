"""`pyfront SOURCE -o OUT.mpy`."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .compile import compile_source
from .errors import Unsupported


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="pyfront", description=__doc__)
    ap.add_argument("source", type=Path)
    ap.add_argument("-o", "--output", type=Path, help="default: SOURCE with .mpy")
    args = ap.parse_args(argv)

    out = args.output or args.source.with_suffix(".mpy")
    try:
        data = compile_source(args.source.read_text(), str(args.source))
    except Unsupported as exc:
        print(f"pyfront: unsupported: {exc}", file=sys.stderr)
        return 2
    except SyntaxError as exc:
        print(f"pyfront: {exc}", file=sys.stderr)
        return 2
    out.write_bytes(data)
    return 0


if __name__ == "__main__":
    sys.exit(main())
