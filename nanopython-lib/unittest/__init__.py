"""unittest — package marker. Only the ``mock`` submodule ships under
nanopython; the actual test runner isn't ported (use pytest_lite).

Filesystem-loaded packages get ``__path__`` from the import loader
automatically — do NOT override here (see notes/plans/full-unix-profile.md
finding on parentPath null-panic when ``__path__ = []`` shadows a
disk-loaded package)."""
