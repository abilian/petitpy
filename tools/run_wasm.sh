#!/bin/sh
# run_wasm.sh — wasmtime wrapper for the corpus runner.
#
# Why this exists: tools/corpus.py's run_cmd sets cwd to the test's
# parent directory before invoking wasmtime. Combined with the sandbox/
# symlink (which resolves to an out-of-tree clone), --dir=/ gives
# PermissionDenied because the resolved test path is outside the mounted
# host root. The fix: use --dir=. + pass the test as a relative basename.
#
# Usage: run_wasm.sh <abs-path-to-wasm> [binary-flags...] <abs-path-to-script>
#
# The script path is always LAST; anything between it and the wasm path
# is a flag for the binary itself (`--emit-mpy`), which the integration
# runner passes per-case.
#
# Wired into the corpus runner via:
#   python3 tools/progress.py tools/run_wasm.sh zig-out/bin/nanopython.wasm

WASM="$1"
shift

# Rotate every argument but the last to the end, leaving the script path
# in $1 and the flags behind it.
nflags=$(($# - 1))
i=0
while [ "$i" -lt "$nflags" ]; do
    flag="$1"
    shift
    set -- "$@" "$flag"
    i=$((i + 1))
done

SCRIPT="$1"
shift
SCRIPT_DIR=$(dirname "$SCRIPT")
SCRIPT_NAME=$(basename "$SCRIPT")
cd "$SCRIPT_DIR" || exit 1
exec wasmtime --dir=. "$WASM" "$@" "$SCRIPT_NAME"
