#!/bin/sh
# Project status — progress + shape snapshot. Read-only.
#
# Usage:
#   tools/status.sh           # quick: current binary's preset only
#   ALL=1 tools/status.sh     # rebuild + test BOTH presets (~1-2 min)
#
# Run from any cwd; chdirs to repo root.

set -u
cd "$(dirname "$0")/.."

bar() { printf -- '─%.0s' $(seq 1 64); echo; }
sec() { echo; bar; echo "  $1"; bar; }
loc() { find "$@" 2>/dev/null | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1+0}'; }

# ── Git ─────────────────────────────────────────────────────────────
sec "Git"
echo "  branch: $(git rev-parse --abbrev-ref HEAD)"
echo "  HEAD:   $(git log -1 --format='%h %s (%cr)')"
dirty=$(git status -s | wc -l | tr -d ' ')
if [ "$dirty" -eq 0 ]; then
    echo "  tree:   clean"
else
    echo "  tree:   $dirty modified path(s)"
    git status -s | head -10 | sed 's/^/    /'
fi

# ── Code shape ──────────────────────────────────────────────────────
sec "Code shape (LOC)"
zig_src=$(find src -name '*.zig' | xargs wc -l | tail -1 | awk '{print $1+0}')
c_src=$(find src -name '*.c'    | xargs wc -l | tail -1 | awk '{print $1+0}')
h_src=$(find src -name '*.h'    | xargs wc -l | tail -1 | awk '{print $1+0}')
shims=$(find src -name '*_shim.c' | wc -l | tr -d ' ')
vendor_c=$(find vendor -name '*.c' 2>/dev/null | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1+0}')
vendor_h=$(find vendor -name '*.h' 2>/dev/null | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1+0}')
ported=$((zig_src + c_src + h_src))
printf "  Zig (src):       %6d\n" "$zig_src"
printf "  C   (src):       %6d  (%d *_shim.c files)\n" "$c_src" "$shims"
printf "  H   (src):       %6d\n" "$h_src"
printf "  Vendor C:        %6d\n" "$vendor_c"
printf "  Vendor H:        %6d\n" "$vendor_h"
if [ "$ported" -gt 0 ] && [ "$vendor_c" -gt 0 ]; then
    ratio=$(awk "BEGIN { printf \"%.2f\", $vendor_c / $ported }")
    echo "  Vendor C / ported (Zig+C+H): ${ratio}x"
fi

# ── Per-subsystem Zig LOC ───────────────────────────────────────────
sec "Zig LOC by subsystem"
for d in src/*/; do
    n=$(find "$d" -name '*.zig' | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1+0}')
    [ "$n" -gt 0 ] && printf "  %-20s %6d\n" "${d}" "$n"
done

# ── Notes ───────────────────────────────────────────────────────────
sec "Notes (5 most recent)"
ls -t notes/*.md 2>/dev/null | head -5 | sed 's|^|  |'

# ── Corpus ──────────────────────────────────────────────────────────
run_corpus() {
    cfg=$1
    echo "  building CONFIG=$cfg..."
    if make -s build CONFIG="$cfg" >/tmp/nanopython-build.log 2>&1; then
        python3 tools/progress.py --config "$cfg" ./zig-out/bin/nanopython | sed 's/^/  /'
    else
        echo "  BUILD FAILED for CONFIG=$cfg (see /tmp/nanopython-build.log)"
    fi
}

sec "Corpus — nano (invariant; must be 100%)"
run_corpus nano

if [ "${ALL:-0}" = "1" ]; then
    sec "Corpus — full"
    run_corpus full
    sec "Restoring nano build (the invariant)"
    if make -s build CONFIG=nano >/dev/null 2>&1; then
        echo "  ok"
    else
        echo "  FAILED — binary may be in CONFIG=full state"
    fi
else
    sec "Corpus — full"
    echo "  (skipped; re-run with ALL=1 to rebuild + test the full preset)"
fi

# ── Unit ────────────────────────────────────────────────────────────
sec "Unit tests"
make -s unit 2>&1 | tail -8 | sed 's/^/  /'

# ── Lint ────────────────────────────────────────────────────────────
sec "Lint"
if make -s lint >/tmp/nanopython-lint.log 2>&1; then
    echo "  clean"
else
    echo "  FAILED:"
    tail -10 /tmp/nanopython-lint.log | sed 's/^/    /'
fi

bar
echo "Done."
