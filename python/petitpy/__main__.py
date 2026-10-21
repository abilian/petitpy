"""`python -m petitpy ARGS`: run the installed petitpy binary."""
from __future__ import annotations

import os
import subprocess
import sys

from . import find_bin


def main() -> None:
    argv = [str(find_bin()), *sys.argv[1:]]
    if os.name == "posix":
        os.execv(argv[0], argv)
    sys.exit(subprocess.call(argv))


if __name__ == "__main__":
    main()
