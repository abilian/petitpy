"""The split between the two halves of pyfront, enforced.

`pyfront.emit` is the `.mpy` side: opcodes, the container format, the buffers
that build them. `pyfront.compile` is the `ast` side. The dependency runs one
way, and nothing states that except this file — a stray `import ast` in
`emit/` would fuse the two halves and nothing else would notice.

Why it matters here more than usual: pyfront exists to be a *second*,
independent front-end for the same bytecode boundary. If the format half stops
being separable from the compiler half, it can no longer be tested on its own,
reused by a disassembler, or pointed at a different source language.
"""

from __future__ import annotations

import ast
import pathlib

PKG = pathlib.Path(__file__).resolve().parents[2] / "src" / "pyfront"


def _imports(path: pathlib.Path) -> set[str]:
    """Every module named by an import in `path`, absolute or relative.

    A relative import is reported as `.` times its level plus the module, so
    `from ..emit.code import Code` in compile/ reads as `..emit.code`.
    """
    names: set[str] = set()
    for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
        match node:
            case ast.Import(names=aliases):
                names.update(a.name for a in aliases)
            case ast.ImportFrom(module=mod, level=level):
                names.add("." * level + (mod or ""))
    return names


def _modules(pkg: str) -> list[pathlib.Path]:
    found = sorted((PKG / pkg).glob("*.py"))
    assert found, f"no modules found in {pkg}/ — did the layout move?"
    return found


def test_emit_never_imports_ast() -> None:
    """The format half must not learn what produced the bytecode."""
    for path in _modules("emit"):
        assert "ast" not in _imports(path), (
            f"{path.name} imports ast: the .mpy format half has fused with the "
            f"compiler half"
        )


def test_emit_never_imports_the_compiler() -> None:
    """...nor reach up into it. The dependency runs one way only."""
    for path in _modules("emit"):
        for name in _imports(path):
            assert "compile" not in name, f"{path.name} imports {name}"


def test_compile_writes_no_bytes_directly() -> None:
    """The compiler half goes through `emit`, so opcode numbers and the
    container layout stay in one place."""
    for path in _modules("compile"):
        names = _imports(path)
        assert "struct" not in names, f"{path.name} packs bytes itself"


def test_the_two_halves_are_actually_populated() -> None:
    """Guards the tests above: they all pass vacuously against an empty
    directory, so a rename that empties one would look green."""
    assert len(_modules("emit")) >= 4
    assert len(_modules("compile")) >= 5
