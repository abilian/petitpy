"""Check the stdlib layout that `pip install petitpy` ships.

The wheel installs the binary, built without frozen modules, as
`bin/petitpy` (and `bin/ppy`), and the stdlib that scripts/hatch_build.py collects
from nanopython-lib/ at `share/petitpy/lib/`,
where the binary finds it next to itself. This lays out the same tree
from the hook's own `stdlib_files()`, then imports every module with the
copied binary and no PETITPY_LIB. The frozen-tiny integration suite
cannot see this layout: frozen modules win over files on disk.

Usage: python3 tests/wheel_layout.py <nanopython binary built without -Dfrozen-tiny>
"""

from __future__ import annotations

import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import types
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def load_hook() -> types.ModuleType:
    # The hook imports hatchling and packaging at top level; only
    # stdlib_files() is needed here, so stand-ins do when they are absent.
    for name in ("hatchling", "hatchling.builders", "hatchling.builders.hooks", "hatchling.builders.hooks.plugin"):
        sys.modules.setdefault(name, types.ModuleType(name))
    stub = types.ModuleType("hatchling.builders.hooks.plugin.interface")
    stub.BuildHookInterface = object
    sys.modules.setdefault(stub.__name__, stub)
    if importlib.util.find_spec("packaging") is None:
        sys.modules["packaging"] = types.SimpleNamespace(tags=None)
    spec = importlib.util.spec_from_file_location("hatch_build", ROOT / "scripts" / "hatch_build.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


OS_EXT_CHECK = """\
import os, subprocess
from os import environ, makedirs
os.environ['NPY_WL'] = 'v'
assert os.getenv('NPY_WL') == 'v' and environ is os.environ
assert subprocess.run(['/bin/sh', '-c', 'echo $NPY_WL'], capture_output=True).stdout == b'v\\n'
assert subprocess.run(['/bin/sh', '-c', 'echo $NPY_WL'], capture_output=True, env={**os.environ, 'NPY_WL': 'w'}).stdout == b'w\\n'
del os.environ['NPY_WL']
assert os.getenv('NPY_WL') is None and 'NPY_WL' not in os.environ
makedirs('d/a/b')
makedirs('d/a', exist_ok=True)
open('d/a/f', 'w').close()
assert [(p, sorted(f)) for p, d, f in os.walk('d')] == [('d', []), ('d/a', ['f']), ('d/a/b', [])]
assert hasattr(os, 'fdopen') and not hasattr(os, 'nope')
"""


def module_name(dest: str) -> str:
    """`collections/__init__.py` -> `collections`, `unittest/mock.py` -> `unittest.mock`."""
    parts = dest.removesuffix(".py").split("/")
    if parts[-1] == "__init__":
        parts.pop()
    return ".".join(parts)


def main() -> int:
    binary = Path(sys.argv[1]).resolve()
    files = load_hook().stdlib_files(ROOT)
    failed = []
    with tempfile.TemporaryDirectory() as tmp:
        lib = Path(tmp) / "share" / "petitpy" / "lib"
        for src, dest in files.items():
            (lib / dest).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(src, lib / dest)
        (Path(tmp) / "bin").mkdir()
        installed = Path(tmp) / "bin" / binary.name
        shutil.copy2(binary, installed)
        env = {k: v for k, v in os.environ.items() if k not in ("PETITPY_LIB", "PYTHONPATH")}
        env["HOME"] = tmp  # no ~/.petitpy/lib either
        # Every module, the two ways a package's submodule is reached, and
        # the three spellings of os.path (os_path.py, through os.__getattr__).
        sources = [f"import {module_name(d)}" for d in sorted(files.values())]
        sources += ["from collections import Counter, abc", "from importlib import metadata"]
        sources += ["import os\nassert os.path.join('a', 'b') == 'a/b'", "from os import path", "import os.path"]
        # The parts of os written in Python (os_ext.py, also through os.__getattr__).
        sources += [OS_EXT_CHECK]
        script = Path(tmp) / "case.py"
        for source in sources:
            script.write_text(source + "\n")
            r = subprocess.run([installed, script], cwd=tmp, env=env, capture_output=True, text=True, timeout=30)
            if r.returncode:
                last = (r.stdout + r.stderr).strip().splitlines()[-1:]
                failed.append(f"{source}: {' '.join(last)}")
    for line in failed:
        print(f"FAIL  {line}")
    print(f"wheel layout: {len(sources) - len(failed)}/{len(sources)} imports")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
