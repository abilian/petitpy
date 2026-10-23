#!/usr/bin/env python3
"""Run hop3-rootd's own unit test suite (tests/a_unit/*.py) under
petitpy, module-by-module, and report a punch list.

Reuses the smoke tool's shim-tree approach: build a temp dir combining
hop3-rootd source + petitpy-lib + stubs, then also drop the a_unit
test files (test_*.py + _fakes.py) into it. For each test file, launch
petitpy on a small driver that runs the file's `test_*` functions
via pytest_lite.

The output is per-file:
  a_unit/test_audit.py            17 passed, 0 failed, 0 skipped (of 17)
  a_unit/test_state.py            3 passed, 8 failed, 0 skipped (of 11)
    - test_state_load_missing → assert 3 == 4
    - ...
"""

from __future__ import annotations

import argparse
import ast
import os
import subprocess
import sys
import tempfile
from pathlib import Path

# Sibling tool in tools/ (sys.path[0] when either runs as a script).
# Reused for build_shim + STUBS + _VERSION_PRELUDE.
import hop3_rootd_smoke as smoke


def parse_test_fixtures(test_file):
    """Return {name: [param_name, …]} for every ``def`` in the source
    file — both test_* functions AND fixture helpers. petitpy has no
    ``inspect`` so pytest_lite can't read the parameter list at run
    time; the runner extracts it here (real CPython, via ``ast``) and
    hands the map into the driver so the resolver can recurse into
    fixture-of-fixture dependencies (`@pytest.fixture def
    cgroup_root(tmp_path, monkeypatch): ...`)."""
    tree = ast.parse(test_file.read_text())
    out = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef):
            params = [a.arg for a in node.args.args if a.arg != "self"]
            if params:
                out[node.name] = params
    return out


def parse_test_parametrize(test_file):
    """Return {test_name: [(param_names_tuple, [value, …]), …]} for
    every ``def test_…`` carrying an ``@pytest.mark.parametrize(...)``.
    petitpy's pytest_lite treats @pytest.mark as a no-op decorator
    so we hoist the value list into the driver script — pytest_lite
    then runs the test once per row.

    ``param_names_tuple`` is a tuple of str: single-name form
    ``parametrize("x", …)`` becomes ``("x",)``; multi-name form
    ``parametrize("x,y", [(1, 2), …])`` (or a tuple of names) becomes
    ``("x", "y")``. Rows correspondingly are single values for single-
    param or tuples for multi. Only literals and module-level names are
    extracted; a row with other args (a call, an attribute) drops the
    whole parametrize entry (real parametrize logic falls back to
    resolving fixtures for those args, out of scope here)."""
    tree = ast.parse(test_file.read_text())
    out = {}
    for node in ast.walk(tree):
        if not isinstance(node, ast.FunctionDef):
            continue
        for dec in node.decorator_list:
            if not isinstance(dec, ast.Call):
                continue
            fn = dec.func
            attr = None
            if isinstance(fn, ast.Attribute):
                attr = fn.attr
            if attr != "parametrize" or len(dec.args) < 2:
                continue
            names_node, rows_node = dec.args[0], dec.args[1]
            names = _literal_names(names_node)
            if names is None:
                continue
            rows = _literal_rows(rows_node, len(names))
            if rows is None:
                continue
            out.setdefault(node.name, []).append((names, rows))
    return out


def _literal_names(node):
    """Accept either `"x"`, `"x,y"`, or `("x", "y")` and normalise
    to a tuple of str."""
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        # "x" or "x, y"
        parts = [p.strip() for p in node.value.split(",")]
        return tuple(p for p in parts if p)
    if isinstance(node, (ast.Tuple, ast.List)):
        vals = []
        for e in node.elts:
            if isinstance(e, ast.Constant) and isinstance(e.value, str):
                vals.append(e.value)
            else:
                return None
        return tuple(vals)
    return None


def _literal_rows(node, expected_arity):
    """Return a list of Python literal values. If ``expected_arity`` >
    1, each row must be a tuple/list of the right length. Return None
    if any value isn't a literal — the runner then skips this
    parametrize entry (safer than leaking None into tests)."""
    if not isinstance(node, (ast.List, ast.Tuple)):
        return None
    rows = []
    for entry in node.elts:
        if expected_arity == 1:
            v = _literal_value(entry)
            if v is _NOT_LITERAL:
                return None
            rows.append(v)
        else:
            if not isinstance(entry, (ast.Tuple, ast.List)):
                return None
            if len(entry.elts) != expected_arity:
                return None
            row = []
            for e in entry.elts:
                v = _literal_value(e)
                if v is _NOT_LITERAL:
                    return None
                row.append(v)
            rows.append(tuple(row))
    return rows


class _NotLiteral:
    pass


class _Ref(str):
    """A module-level name in a parametrize row (a validator function,
    say); the driver resolves it on the imported test module."""

    def __repr__(self):
        return "_M." + self


_NOT_LITERAL = _NotLiteral()


def _literal_value(node):
    """Return the Python value of an ast node when it's a literal
    (Constant, Tuple/List of literals, dict of literals), or a ``_Ref``
    for a bare name. ``_NOT_LITERAL`` otherwise (Call, Attribute). Small
    BinOps (`"x" * 33`, `3 + 4`) get evaluated so test-suite tricks
    like `parametrize("value", ["", "x" * 33, …])` don't drop the
    whole parametrize entry."""
    if isinstance(node, ast.Constant):
        return node.value
    if isinstance(node, ast.Name):
        return _Ref(node.id)
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.USub):
        v = _literal_value(node.operand)
        return -v if isinstance(v, (int, float)) else _NOT_LITERAL
    if isinstance(node, ast.BinOp):
        left = _literal_value(node.left)
        right = _literal_value(node.right)
        if left is _NOT_LITERAL or right is _NOT_LITERAL:
            return _NOT_LITERAL
        try:
            if isinstance(node.op, ast.Add):
                return left + right
            if isinstance(node.op, ast.Sub):
                return left - right
            if isinstance(node.op, ast.Mult):
                return left * right
        except (TypeError, ValueError, OverflowError):
            return _NOT_LITERAL
        return _NOT_LITERAL
    if isinstance(node, (ast.Tuple, ast.List)):
        out = []
        for e in node.elts:
            v = _literal_value(e)
            if v is _NOT_LITERAL:
                return _NOT_LITERAL
            out.append(v)
        return tuple(out) if isinstance(node, ast.Tuple) else out
    if isinstance(node, ast.Dict):
        d = {}
        for k, val in zip(node.keys, node.values):
            kv = _literal_value(k) if k is not None else _NOT_LITERAL
            vv = _literal_value(val)
            if kv is _NOT_LITERAL or vv is _NOT_LITERAL:
                return _NOT_LITERAL
            d[kv] = vv
        return d
    return _NOT_LITERAL


REPO = Path(__file__).resolve().parent.parent


def build_test_shim(shim_dir: Path, hop3_src: Path) -> None:
    """Build the smoke shim, then drop the a_unit test files on top."""
    smoke.build_shim(shim_dir, hop3_src)
    a_unit = hop3_src.parent / "tests" / "a_unit"
    if not a_unit.exists():
        raise SystemExit(f"a_unit tests not found at {a_unit}")
    for py in a_unit.glob("*.py"):
        # test files + _fakes.py land at shim root so `import test_audit`
        # works and `import _fakes` resolves. Skip __init__.py — it would
        # make the shim dir itself look like a package, breaking every
        # top-level import from within.
        if py.name == "__init__.py":
            continue
        (shim_dir / py.name).write_text(py.read_text())
    # Some test files spell the shared helper as
    # `from tests.a_unit._fakes import FakeExec`; replicate that dotted
    # path so those imports resolve without editing the test source.
    aliased = shim_dir / "tests" / "a_unit"
    aliased.mkdir(parents=True, exist_ok=True)
    (aliased.parent / "__init__.py").write_text("")
    (aliased / "__init__.py").write_text("")
    fakes = a_unit / "_fakes.py"
    if fakes.exists():
        (aliased / "_fakes.py").write_bytes(fakes.read_bytes())


def run_test_file(
    binary: Path, shim_dir: Path, test_name: str, timeout: float = 30
) -> tuple[int, str, str]:
    """Run a single test_*.py under petitpy + pytest_lite. Returns
    (returncode, stdout, stderr)."""
    # Parse the file source with Python's ast to build the fixture-param
    # map — pytest_lite consumes it to resolve tmp_path / monkeypatch /
    # user fixtures for each test function. petitpy lacks
    # `__code__.co_varnames` so run-time introspection is off the table.
    test_path = shim_dir / (test_name + ".py")
    fixtures_map = parse_test_fixtures(test_path)
    parametrize_map = parse_test_parametrize(test_path)
    # Wrap the module import in try/except so an ImportError raised mid-
    # load doesn't cascade into a downstream NameError (which is what
    # `import test_x` produces when the target module's own imports
    # fail — the name never binds locally).
    driver = smoke._VERSION_PRELUDE + (
        "import sys\n"
        "import pytest_lite\n"
        "try:\n"
        f"    import {test_name}\n"
        "except BaseException as e:\n"
        f"    print('IMPORT-CRASH ' + type(e).__name__ + ': ' + str(e))\n"
        "    sys.exit(2)\n"
        f"_M = {test_name}\n"
        f"_FIXTURES = {fixtures_map!r}\n"
        f"_PARAMETRIZE = {parametrize_map!r}\n"
        f"results = pytest_lite.run_module({test_name}, verbose=True, "
        "fixtures=_FIXTURES, parametrize=_PARAMETRIZE)\n"
        "sys.exit(pytest_lite.summarize(results))\n"
    )
    with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False) as f:
        f.write(driver)
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


def parse_summary(stdout: str) -> tuple[int, int, int, int]:
    """Extract (passed, failed, skipped, total) from pytest_lite's
    summary line. Returns (-1, -1, -1, -1) if not found — an early
    import error or crash."""
    for line in stdout.splitlines():
        s = line.strip()
        if " passed, " in s and " failed, " in s and " skipped " in s:
            parts = s.replace(",", " ").split()
            try:
                passed = int(parts[0])
                failed = int(parts[2])
                skipped = int(parts[4])
                total = int(parts[-1].rstrip(")"))
                return passed, failed, skipped, total
            except (ValueError, IndexError):
                continue
    return -1, -1, -1, -1


def collect_failures(stdout: str) -> list[str]:
    """Extract failing test names + messages from run_module output.
    pytest_lite prints one line per test as 'PASS/FAIL/SKIP  name'
    optionally followed by an indented message line for FAIL."""
    out = []
    lines = stdout.splitlines()
    for i, line in enumerate(lines):
        s = line.strip()
        if s.startswith("FAIL "):
            name = s[5:].strip()
            msg = ""
            if i + 1 < len(lines) and lines[i + 1].startswith(" " * 6):
                msg = lines[i + 1].strip()
            out.append(f"{name}: {msg}" if msg else name)
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument(
        "binary", nargs="?", default=str(REPO / "zig-out/bin/petitpy")
    )
    parser.add_argument(
        "hop3_src",
        nargs="?",
        default=str(smoke.DEFAULT_HOP3_SRC),
    )
    parser.add_argument(
        "--shim-dir",
        default=None,
        help="Where to build the shim tree (default: scratchpad)",
    )
    parser.add_argument(
        "--only",
        default=None,
        help="Regex-substring of test file basename to filter (e.g. 'audit')",
    )
    parser.add_argument(
        "--verbose", action="store_true", help="Show full per-test PASS/FAIL/SKIP lines"
    )
    args = parser.parse_args()

    binary = Path(args.binary).resolve()
    if not binary.exists():
        print(f"error: binary not found: {binary}", file=sys.stderr)
        return 2

    hop3_src = Path(args.hop3_src).resolve()
    if not (hop3_src / "hop3_rootd").exists():
        print(f"error: hop3_rootd package not found under {hop3_src}", file=sys.stderr)
        return 2

    shim_dir = (
        Path(args.shim_dir)
        if args.shim_dir
        else Path(tempfile.mkdtemp(prefix="hop3-tests-"))
    )
    print(f"binary:   {binary}")
    print(f"hop3_src: {hop3_src}")
    print(f"shim:     {shim_dir}\n")
    build_test_shim(shim_dir, hop3_src)

    a_unit = hop3_src.parent / "tests" / "a_unit"
    test_files = sorted(p for p in a_unit.glob("test_*.py"))
    if args.only:
        test_files = [p for p in test_files if args.only in p.stem]
    if not test_files:
        print("no test_*.py files matched")
        return 2

    grand = {
        "passed": 0,
        "failed": 0,
        "skipped": 0,
        "total": 0,
        "crashed": 0,
        "no_summary": 0,
    }
    per_file_lines = []
    for tf in test_files:
        print(f">>> {tf.name}", flush=True)
        _rc, out, err = run_test_file(binary, shim_dir, tf.stem)
        p, f, s, t = parse_summary(out)
        if p < 0:
            grand["crashed"] += 1
            crash_line = ""
            for line in out.splitlines():
                sline = line.strip()
                if sline.startswith("IMPORT-CRASH "):
                    crash_line = sline[len("IMPORT-CRASH ") :]
                    break
            if not crash_line:
                for line in (out + err).splitlines():
                    sline = line.strip()
                    if sline.startswith(("File ", "Traceback")) or "Error" in sline:
                        crash_line = sline
            # If the driver caught a NameError with the "isn't defined"
            # signature, that's petitpy's silent SyntaxError-inside-
            # imported-module conversion. Re-run the file as a script
            # to surface the real cause.
            if crash_line.startswith("NameError:") and "isn't defined" in crash_line:
                env2 = os.environ.copy()
                env2["PETITPY_LIB"] = str(shim_dir)
                p2 = subprocess.run(
                    [str(binary), str(shim_dir / tf.name)],
                    capture_output=True,
                    text=True,
                    timeout=30,
                    env=env2,
                    check=False,
                )
                real = ""
                for line in (p2.stdout + p2.stderr).splitlines():
                    sline = line.strip()
                    if "Error" in sline and ":" in sline:
                        real = sline
                        break
                if real:
                    crash_line = f"{crash_line} [real cause: {real}]"
            per_file_lines.append(f"  {tf.name:38s} CRASH  {crash_line[:120]}")
            if args.verbose:
                print(out[-800:])
                if err:
                    print("STDERR:", err[-400:])
            print()
            continue
        grand["passed"] += p
        grand["failed"] += f
        grand["skipped"] += s
        grand["total"] += t
        per_file_lines.append(
            f"  {tf.name:38s} {p:3d} passed, {f:3d} failed, {s:3d} skipped (of {t})"
        )
        if args.verbose:
            print(out)
        if f > 0 and not args.verbose:
            for fail in collect_failures(out)[:5]:
                print(f"    - {fail}")
        print()

    print("=" * 60)
    print("PER-FILE SUMMARY")
    print("=" * 60)
    for line in per_file_lines:
        print(line)
    print()
    print(
        f"GRAND TOTAL: {grand['passed']} passed, "
        f"{grand['failed']} failed, {grand['skipped']} skipped "
        f"(of {grand['total']}), {grand['crashed']} file(s) crashed"
    )
    return 0 if grand["failed"] == 0 and grand["crashed"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
