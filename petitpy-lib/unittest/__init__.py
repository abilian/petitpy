"""unittest — package marker. Only the ``mock`` submodule ships under
petitpy; the actual test runner isn't ported (use pytest_lite).

Filesystem-loaded packages get ``__path__`` from the import loader
automatically — do NOT override here (``__path__ = []`` shadows a
disk-loaded package and the loader panics on a null parentPath)."""
