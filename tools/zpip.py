#!/usr/bin/env python3
"""zpip — mip-compatible package installer for petitpy.

ADR-003 L3. Talks to the upstream MicroPython registry
(`micropython.org/pi/v2`) using the same `package.json` + `/file/<hh>/<hash>`
protocol that `mip` uses, but written in Python 3 stdlib only (no
`requests`, no `micropython` shims). The on-disk shape it produces is
flat — `<target>/<file>.py` — exactly what petitpy's L1 filesystem
import hook expects.

Usage:
    zpip install <pkg>              # install to ~/.petitpy/lib
    zpip install <pkg> -t <dir>     # install to <dir>
    zpip install <pkg> --mpy        # prefer .mpy files (v6)
    zpip list                       # list installed packages

Default install location: $PETITPY_LIB or ~/.petitpy/lib (matches
the env var that main.zig's wireEnvSysPath reads, so installed packages
become importable without extra sys.path setup).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

_REGISTRY = "https://micropython.org/pi/v2"
# petitpy speaks .mpy v6 (sys.implementation._mpy == 6).
_MPY_VERSION = 6


def _default_lib_dir() -> Path:
    env = os.environ.get("PETITPY_LIB")
    if env:
        return Path(env)
    return Path.home() / ".petitpy" / "lib"


def _http_get(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "zpip/0.1"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        if resp.status != 200:
            raise RuntimeError(f"HTTP {resp.status} for {url}")
        return resp.read()


def _file_matches_hash(path: Path, short_hash: str) -> bool:
    """The registry hashes are sha256 hexdigest prefixes (8-64 hex chars)."""
    if not path.exists():
        return False
    try:
        h = hashlib.sha256(path.read_bytes()).hexdigest()
        return h.startswith(short_hash)
    except OSError:
        return False


def _download_file(url: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    data = _http_get(url)
    dest.write_bytes(data)


def _install_package_json(
    pkg_json_url: str,
    target: Path,
    visited: set[str],
) -> bool:
    """Fetch package.json, download files + recurse into deps."""
    if pkg_json_url in visited:
        return True
    visited.add(pkg_json_url)

    try:
        raw = _http_get(pkg_json_url)
    except (urllib.error.URLError, RuntimeError) as e:
        print(f"  error fetching {pkg_json_url}: {e}", file=sys.stderr)
        return False
    meta: dict[str, Any] = json.loads(raw)

    # hashes: list of [target_path, short_hash] pairs, served from /file/<hh>/<hash>.
    for target_path, short_hash in meta.get("hashes", []):
        dst = target / target_path
        if _file_matches_hash(dst, short_hash):
            print(f"  exists  {target_path}")
            continue
        file_url = f"{_REGISTRY}/file/{short_hash[:2]}/{short_hash}"
        print(f"  fetch   {target_path}  <- {short_hash[:8]}")
        try:
            _download_file(file_url, dst)
        except (urllib.error.URLError, RuntimeError) as e:
            print(f"  error fetching file {short_hash}: {e}", file=sys.stderr)
            return False

    # urls: list of [target_path, url] pairs (direct external URLs; rare).
    for target_path, url in meta.get("urls", []):
        dst = target / target_path
        print(f"  fetch   {target_path}  <- {url}")
        try:
            _download_file(url, dst)
        except (urllib.error.URLError, RuntimeError) as e:
            print(f"  error fetching {url}: {e}", file=sys.stderr)
            return False

    # deps: list of [pkg_name, version] pairs. Recurse.
    for dep_name, dep_version in meta.get("deps", []):
        if not _install_named(dep_name, dep_version or "latest", target, visited):
            return False

    return True


def _install_named(name: str, version: str, target: Path, visited: set[str]) -> bool:
    # Try mpy v6 first if requested, else plain Python source.
    pkg_json_url = f"{_REGISTRY}/package/{_MPY_VERSION}/{name}/{version}.json"
    return _install_package_json(pkg_json_url, target, visited)


def _install_named_py(name: str, version: str, target: Path, visited: set[str]) -> bool:
    pkg_json_url = f"{_REGISTRY}/package/py/{name}/{version}.json"
    return _install_package_json(pkg_json_url, target, visited)


def _manifest_path(target: Path) -> Path:
    return target / ".zpip-manifest.json"


def _load_manifest(target: Path) -> dict[str, Any]:
    p = _manifest_path(target)
    if not p.exists():
        return {"packages": {}}
    try:
        return json.loads(p.read_text())
    except (OSError, json.JSONDecodeError):
        return {"packages": {}}


def _save_manifest(target: Path, manifest: dict[str, Any]) -> None:
    target.mkdir(parents=True, exist_ok=True)
    _manifest_path(target).write_text(json.dumps(manifest, indent=2))


def _record_install(target: Path, name: str, version: str) -> None:
    manifest = _load_manifest(target)
    manifest["packages"][name] = {"version": version}
    _save_manifest(target, manifest)


def cmd_install(args: argparse.Namespace) -> int:
    target: Path = Path(args.target).expanduser() if args.target else _default_lib_dir()
    target.mkdir(parents=True, exist_ok=True)
    version = args.version or "latest"
    print(f"Installing {args.package} ({version}) -> {target}")

    visited: set[str] = set()
    if args.mpy:
        ok = _install_named(args.package, version, target, visited)
    else:
        ok = _install_named_py(args.package, version, target, visited)

    if not ok:
        print("Install failed (may be partial)", file=sys.stderr)
        return 1
    _record_install(target, args.package, version)
    print(f"Done. {args.package} installed to {target}")
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    target: Path = Path(args.target).expanduser() if args.target else _default_lib_dir()
    manifest = _load_manifest(target)
    pkgs = manifest.get("packages", {})
    if not pkgs:
        print(f"No packages installed in {target}")
        return 0
    print(f"Installed in {target}:")
    for name, info in sorted(pkgs.items()):
        print(f"  {name:30s} {info.get('version', '?')}")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="zpip",
        description="mip-compatible package installer for petitpy (ADR-003 L3)",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_install = sub.add_parser("install", help="install a package")
    p_install.add_argument("package")
    p_install.add_argument(
        "-t",
        "--target",
        help="install directory (default: $PETITPY_LIB or ~/.petitpy/lib)",
    )
    p_install.add_argument("--version", help="version (default: latest)")
    p_install.add_argument("--mpy", action="store_true", help="prefer .mpy v6 files")
    p_install.set_defaults(func=cmd_install)

    p_list = sub.add_parser("list", help="list installed packages")
    p_list.add_argument(
        "-t",
        "--target",
        help="lib directory (default: $PETITPY_LIB or ~/.petitpy/lib)",
    )
    p_list.set_defaults(func=cmd_list)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
