"""petitpy — minimal importlib.metadata.

CPython reads package metadata from installed .dist-info dirs on
sys.path. Under petitpy there's no dist-info; we ship a hardcoded
table keyed by package name and a `version()` function that reads it.

Callers extend the table at runtime:

    from importlib.metadata import _VERSIONS
    _VERSIONS["hop3-rootd"] = "0.6.2"

`PackageNotFoundError` is raised for unknown packages (subclasses
`ImportError` to match CPython).
"""


class PackageNotFoundError(ImportError):
    pass


_VERSIONS = {
    "petitpy": "0.7.1",
}


def version(pkg):
    if pkg in _VERSIONS:
        return _VERSIONS[pkg]
    raise PackageNotFoundError(pkg)
