#!/usr/bin/env python3
"""nanopython integration smoke tests — top-level runner.

Small, readable, fast suite complementing the byte-exact corpus
(tools/corpus.py). Runs against a built interpreter, asserting exact
stdout for each case. Cases are split by topic across
`tests/test_integration_*.py`; each of those modules exports a CASES
list and can also be run individually (see their `__main__` footer).

Runner-pluggable:
    python3 tests/integration.py                          # local zig-out
    python3 tests/integration.py path/to/nanopython
    python3 tests/integration.py --runner "tools/run_wasm.sh wasm/path"

The runner argv is split via shell rules and the script path is
appended as the last argument.

Why this exists alongside `make wasm-check` (the corpus gate): the
corpus is a byte-exact strangler-discipline tool against frozen
reference output, and many of its float-touching tests are legitimately
in `wasm-known-fails.txt`. That gate doesn't catch "basic float-printing
crashes on wasm" — those are already known-failing for unrelated
reasons. This suite is the independent "this binary actually works"
gate.
"""

from __future__ import annotations

import sys
from pathlib import Path

# tests/*.py aren't a package; make sibling modules importable.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from _integration_runner import run
from test_integration_core import CASES as CORE_CASES
from test_integration_os import CASES as OS_CASES


def main() -> int:
    return run(CORE_CASES + OS_CASES)


if __name__ == "__main__":
    sys.exit(main())
