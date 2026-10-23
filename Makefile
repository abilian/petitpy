# petitpy — common tasks. (Generation of vendor/ lives in port/Makefile;
# this root Makefile drives the strangler build/test/lint loop.)
#
# Invariant (CLAUDE.md): `make check` must end at 100.0% N/N byte-identical
# to the nano-C reference. Never commit a red tree.

MAKE     := make
BIN      := ./zig-out/bin/petitpy
ZIGSRC   := build.zig $(wildcard src/*.zig)
# Host-side (CPython) Python that `make lint` checks. Deliberately NOT the
# whole tree: petitpy-lib/, web/ and projects/*/src/ target the nano
# runtime, where host lint rules give the wrong answer.
# tests/qstr_fixture.py is lexer input,
# not code — same reason corpus/*.out is excluded.
PYSRC    := $(wildcard tools/*.py) \
            tests/integration.py tests/_integration_runner.py \
            tests/test_integration_core.py tests/test_integration_os.py \
            scripts/hatch_build.py port/gate_moduledefs.py \
            projects/ci-build-monitor/serve.py

# Config preset: "nano" (default, the frozen reference) or "full"
# (everything available). Drives
# the -Dconfig flag on `zig build` which in turn selects which arm of
# port/mpconfigport.h applies AND which comptime branches activate in
# src/*.zig (via @import("build_options")).
CONFIG   ?= full

.DEFAULT_GOAL := all

## all: all common targets. Covers both the native and the wasm arm.
##      `make test` alone is native-only (fast); `make all` adds the
##      wasm gates (corpus + integration) so silent wasm regressions
##      land here instead of in user reports.
all:
	$(MAKE) build
	$(MAKE) test
	$(MAKE) check-all
	$(MAKE) wasm-check
	$(MAKE) test-integration-wasm
	$(MAKE) lint

## help: the dozen targets you actually need. `make help ALL=1` lists all of
##       them with their one-line descriptions; the full prose for a target is
##       its `##` block in this file.
##
##       There are ~58 targets because the project has three independent axes
##       (native/wasm, nano/full, compiler/vm) and each needs its own gate.
##       They are not redundant, but nobody needs all of them in one screen.
EVERYDAY := build test check check-all wasm-check test-integration lint smoke run clean all format

help:
ifdef ALL
	@echo "petitpy make targets (all):"
	@grep -E '^## [a-zA-Z0-9_-]+:' $(MAKEFILE_LIST) | sed 's/^## /  /'
else
	@echo "petitpy — everyday targets:"
	@for t in $(EVERYDAY); do \
	  grep -E "^## $$t:" $(MAKEFILE_LIST) | sed 's/^## /  /'; \
	done
	@echo ""
	@echo "  ... and $$(( $$(grep -cE '^## [a-zA-Z0-9_-]+:' $(MAKEFILE_LIST)) - $(words $(EVERYDAY)) )) more: make help ALL=1"
endif

## bootstrap: clone MicroPython into vendor/micropython if the symlink/dir
##            is missing. Idempotent — no-op when vendor/micropython
##            already resolves (symlink to an external clone, or a
##            direct checkout from this target).
##
## MICROPY_REV pins the upstream MicroPython SHA the qstr counts
## (src/compiler/qstr.zig N_MAIN etc.) and corpus goldens were calibrated
## against. Bumping this SHA generally requires re-running the corpus
## gate and (if qstr counts shifted upstream) bumping N_MAIN.
MICROPY_REV := b14d129a1

vendor/micropython:
	@echo "vendor/micropython missing — cloning MicroPython@$(MICROPY_REV) (fresh-checkout bootstrap)"
	git clone https://github.com/micropython/micropython.git $@
	git -C $@ checkout $(MICROPY_REV)

bootstrap: vendor/micropython

## verify-linux: cross-compile petitpy for the container's native
##               arch on the host, then run the integration suite
##               against the resulting ELF inside a Debian container.
##               Requires Docker.
##
##               Uses the docker/OrbStack default platform (arm64 on
##               Apple Silicon, amd64 on Intel/AMD). No emulation
##               involved either way.
VERIFY_IMAGE ?= petitpy-verify-linux:latest

# Match the host CPU: arm64/aarch64 hosts get an aarch64 Zig +
# aarch64-linux-gnu cross-compile; anything else defaults to x86_64.
# Determined from `uname -m` so `make verify-linux` doesn't need a
# flag.
HOST_ARCH := $(shell uname -m)
ifeq ($(filter $(HOST_ARCH),arm64 aarch64),)
  ZIG_ARCH         := x86_64
  ZIG_LINUX_TARGET := x86_64-linux-gnu
  ELF_ARCH_MATCH   := x86-64
else
  ZIG_ARCH         := aarch64
  ZIG_LINUX_TARGET := aarch64-linux-gnu
  ELF_ARCH_MATCH   := aarch64
endif

verify-linux-image:
	docker build -f tools/Dockerfile.verify-linux \
	  --build-arg ZIG_ARCH=$(ZIG_ARCH) \
	  -t $(VERIFY_IMAGE) .

verify-linux: verify-linux-image freeze-modules
	@echo "→ cross-compiling for $(ZIG_LINUX_TARGET) on the host..."
	@zig build -Dtarget=$(ZIG_LINUX_TARGET) -Doptimize=ReleaseSmall -Dconfig=full -Dfrozen-tiny=true || true
	@test -x zig-out/bin/petitpy \
	  || (echo "cross-compile failed to produce zig-out/bin/petitpy"; exit 1)
	@file zig-out/bin/petitpy | grep -q $(ELF_ARCH_MATCH) \
	  || (echo "zig-out/bin/petitpy is not $(ELF_ARCH_MATCH) — did the cross-compile pick up the host target?"; exit 1)
	@echo "→ running tests/integration.py inside the container..."
	@docker run --rm \
	  -v $(PWD):/src:ro \
	  $(VERIFY_IMAGE) \
	  bash -c 'cd /src && python3 tests/integration.py zig-out/bin/petitpy'

## port: (re)generate vendor/micropython_embed from the symlinked tree
port: | vendor/micropython
	$(MAKE) -C port

## build: regenerate vendor/ then build zig-out/bin/petitpy (Debug).
##        Default CONFIG=full per ADR 012 Phase 4b. Use CONFIG=nano for
##        the shipping arm.
build: port
	zig build -Dconfig=$(CONFIG)

## freeze-modules: ADR-003 L2 — compile the frozen-tiny .py set to .mpy
##                  under build-frozen/. Requires zigpy-compile (built by
##                  `make build` first; this rule runs `zig build` to
##                  ensure it's present). After this, `make build-frozen`
##                  or `zig build -Dfrozen-tiny=true` bakes the bytes
##                  into the petitpy binary via @embedFile.
freeze-modules: port
	zig build -Dconfig=$(CONFIG)
	python3 tools/freeze_modules.py

## build-frozen: build petitpy with the frozen-tiny set baked in.
##               Runs `make freeze-modules` first, then re-invokes
##               `zig build` with -Dfrozen-tiny=true so
##               frozen_modules.zig's @embedFile calls find their inputs.
build-frozen: freeze-modules
	zig build -Dconfig=$(CONFIG) -Dfrozen-tiny=true

## build-release: ReleaseFast build (~960 KB on arm64, ~3× smaller than Debug).
build-release: port
	zig build -Dconfig=$(CONFIG) -Doptimize=ReleaseFast

## build-release-frozen: ReleaseFast + frozen-tiny baked in. Used by
##                       `make metrics-record` so the native binary
##                       it measures + benchmarks against has the same
##                       module surface (json, _thread, heapq,
##                       bisect, …) as the shipping wasm.
build-release-frozen: freeze-modules
	zig build -Dconfig=$(CONFIG) -Doptimize=ReleaseFast -Dfrozen-tiny=true

## build-small: ReleaseSmall build (~447 KB on arm64, the shipping size).
##              Comparable to upstream MicroPython's unix-standard (~652 KB).
build-small: port
	zig build -Dconfig=$(CONFIG) -Doptimize=ReleaseSmall

## wasm: build the WASI WASM binary at zig-out/bin/petitpy.wasm.
##       Run with: wasmtime --dir=/tmp zig-out/bin/petitpy.wasm script.py
##       Defaults to Debug (~4 MB, with debug-info-style symbols intact —
##       useful for inspection / fault localization); for the
##       production-size ~340 KB build use `wasm-small`.
##       -Dfeature-js=false because wasmtime has no JS host to satisfy
##       the bridge's env imports (the demos under web/ load via JS so
##       use a different build target there).
wasm: port
	@# ADR 012 Phase 4a: wasm arm always built with the nano profile.
	@# wasm32 has no MPZ and corpus/wasm-known-fails.txt is calibrated
	@# against nano; full on wasm would hit ~70 extra fails on the
	@# bignum/longlong wall. CONFIG= override deliberately ignored.
	zig build -Dtarget=wasm32-wasi -Dconfig=nano -Dfeature-js=false

## wasm-small: build a ReleaseSmall wasm binary with frozen-tiny baked
##             in (so `import json` etc. work without lazy-fetch).
##             Used by `make wasm-check`.
##             -Dfeature-js=false because wasmtime has no JS host to
##             satisfy the bridge's env imports.
wasm-small: freeze-modules
	@# ADR 012 Phase 4a: wasm arm pinned to nano (see `wasm` target).
	zig build -Dtarget=wasm32-wasi -Dconfig=nano -Doptimize=ReleaseSmall \
	  -Dfrozen-tiny=true -Dfeature-js=false

## wasm-check: STRICT corpus gate under wasmtime. Fails on regression
##             (any test fails that's NOT in corpus/wasm-known-fails.txt)
##             OR on golden-out-of-date (any test in known-fails passes).
##             Closing wasm bugs MUST remove the test from known-fails in
##             the same commit. The known-fails list is the path toward
##             100% — it only ever shrinks, never grows.
wasm-check: wasm-small
	python3 tools/wasm_gate.py

## check-full: STRICT corpus gate for -Dconfig=full. Same bidirectional
##             discipline as wasm-check: regressions fail, unexpected
##             passes fail. corpus/full-known-fails.txt only ever
##             shrinks. Per ADR 012 the eventual default profile becomes
##             full; this gate is the path to making that flip safe.
## v0.7.1: -Dfrozen-tiny=true so `import random` (needed by
## class_setname_hazard_rand) works from build-frozen/random.mpy.
## Depends on freeze-modules to populate build-frozen/.
check-full: freeze-modules
	zig build -Dconfig=full -Dfrozen-tiny=true
	python3 tools/full_gate.py

## check-nano: nano-arm strict gate. Equivalent to `make check
##             CONFIG=nano` but always nano regardless of CONFIG override.
##             Paired with check-full per ADR 012 dual-arm discipline.
##             NOT frozen-tiny: nano has ucollections.deque compiled in
##             (strict MP semantics), while frozen-tiny would shadow it
##             with petitpy-lib/collections.py (CPython-compat deque).
##             Two deque tests would flip from PASS to FAIL and break
##             the 541/541 invariant.
check-nano:
	zig build -Dconfig=nano
	python3 tools/progress.py --config nano --strict ./zig-out/bin/petitpy

## check-release: the corpus and integration gates on ReleaseFast builds,
##        what benchmarks and build-release ship. Every other gate builds
##        Debug, where `undefined` is a fixed fill; reading it after a raise
##        segfaulted ReleaseFast for months unseen (enumerate(), f1ec72a).
##        Leaves ReleaseFast binaries in zig-out. Not in the aggregate.
check-release: freeze-modules
	zig build -Dconfig=nano -Doptimize=ReleaseFast
	python3 tools/progress.py --config nano --strict ./zig-out/bin/petitpy
	zig build -Dconfig=full -Dfrozen-tiny=true -Doptimize=ReleaseFast
	python3 tools/full_gate.py
	zig build -Dconfig=nano -Dfrozen-tiny=true -Doptimize=ReleaseFast
	python3 tests/integration.py --config nano

## check-all: aggregate native gate — both arms strict. After ADR 012
##            Phase 4b lands, this becomes the canonical pre-commit
##            check; until then it's the dual-arm safety net.
check-all:
	$(MAKE) check-nano
	$(MAKE) check-full
	$(MAKE) check-split

## check-split: strict gate for the split (compiler/VM) configuration —
##              quadrants 1 and 3 of the compiler x VM matrix.
##              Q1 is zigpy-compile -> petitpy-vm; Q3 is vendor mpy-cross
##              -> petitpy-vm, the only check that validates the VM against
##              a front-end we didn't write. In a combined binary a compiler
##              bug and a VM bug can cancel out invisibly; this is what stops
##              that. Run by check-all — you don't need to invoke it directly.
check-split: freeze-modules
	zig build -Dconfig=full -Dfrozen-tiny=true
	python3 tools/quadrant_gate.py

## check-capability: the capability matrix as a gate. Compiles a
##                    construct set with BOTH front-ends and runs each result on
##                    BOTH back-ends, then fails on a back-end gap, a back-end
##                    split, or a front-end split, against
##                    corpus/capability-known.txt. A FRONT-END GAP is not gated:
##                    it is the measurement, not a defect.
##
##                    NOT in check-all. It needs vendor MicroPython built and a
##                    uv environment for projects/pyfront, and takes minutes; the
##                    corpus gates stay the fast path. Run it when either
##                    front-end or either back-end changes.
check-capability: build
	python3 tools/capability_matrix.py --gate

## metrics-record: append a row to metrics/history.ndjson with current
##                  wasm/native sizes, native + wasm corpus pass counts,
##                  and golden-programs distribution. Fast (~10s); add
##                  --with-perf to also run the p2w benchmark set
##                  (minutes). See tools/metrics.py for the record schema.
##                  Builds the actual shipping artifacts first so the
##                  recorded sizes are what users would see — `web` for
##                  the wasm ReleaseSmall + frozen-tiny binary,
##                  `build-release-frozen` for the native ReleaseFast
##                  binary with the same frozen-tiny modules baked in
##                  (so the native benchmark target has the same module
##                  surface as the shipping wasm — needed for programs
##                  that `import json` etc.).
metrics-record: web build-release-frozen wasm-small
	python3 tools/metrics.py record $(METRICS_FLAGS)

## metrics-report: print recent rows from metrics/history.ndjson as
##                 a trend table (commit + size + coverage + delta).
metrics-report:
	python3 tools/metrics.py report

## metrics-latest: print the most recent recorded row in
##                 human-readable form.
metrics-latest:
	python3 tools/metrics.py latest

## cold-load: time wasmtime startup of `print("ok")` (ADR 010 §D2).
##            Prints median ms over 5 runs. Comparable across commits
##            on the same machine.
cold-load: wasm-small
	@python3 tools/timing.py

## metrics-record-perf: like metrics-record but ALSO runs the p2w
##                      benchmark set through nano native, nano wasm,
##                      MicroPython unix-standard, and CPython —
##                      records per-benchmark median times + geomean
##                      ratios. Takes ~3 minutes (vs ~10s for the
##                      size-only metrics-record).
metrics-record-perf: web build-release-frozen wasm-small
	python3 tools/metrics.py record --with-perf $(METRICS_FLAGS)

## golden: re-bootstrap golden-programs/ from source corpora. Walks the
##         four collections under sandbox/, dedupes by content hash,
##         filters out-of-scope third-party libs, runs each program
##         through vendor MicroPython (oracle) + petitpy native +
##         wasm, re-categorises into the bucket dirs. See ADR 008
##         (docs/src/adrs/008-golden-programs.md). Takes ~30s.
##         Native uses build-frozen so json/_thread/types work —
##         matches the wasm-small frozen-tiny configuration,
##         so the two arms have the same module surface.
golden: build-frozen wasm-small
	python3 tools/golden_bootstrap.py --rebuild

## compatibility: regenerate docs/src/COMPATIBILITY.md from golden-programs/.
##                Walks the bucket directories, parses each program's
##                `# golden:` header, and writes a user-facing markdown
##                doc that answers "does my program work in petitpy
##                today?". Ship under docs/ so Zensical picks it up.
##                ADR 009 Lane A A4 + ADR 008 §Phase 2.
compatibility:
	python3 tools/gen_compatibility.py

## doc-setup: install Zensical (one-time per environment). The static-site
##            generator that renders docs/ to a browseable site. Configured
##            via docs/zensical.toml.
doc-setup:
	pip install zensical

## doc-build: render docs/ to a static site via Zensical. Output lands in
##            docs/site/ (gitignored). Prerequisite: `make doc-setup` once.
##            Includes the auto-generated docs/src/COMPATIBILITY.md (rerun
##            `make compatibility` first if the golden buckets changed).
##            The web pages (playground, demos, games) are copied to
##            docs/site/play/, so the docs site serves them too.
WEB_SITE_PARTS := index.html shared.css petitpy.wasm lib demos games gallery extensions
doc-build: web
	@command -v zensical >/dev/null 2>&1 || \
		{ echo "zensical missing — run 'make doc-setup'"; exit 2; }
	cd docs && zensical build
	rm -rf docs/site/play && mkdir -p docs/site/play
	cd web && cp -RL $(WEB_SITE_PARTS) ../docs/site/play/

## doc-serve: serve docs/ with live reload at http://localhost:8000 (default
##            port). Edits to docs/src/*.md or docs/zensical.toml refresh in-place.
##            Prerequisite: `make doc-setup` once.
doc-serve:
	@command -v zensical >/dev/null 2>&1 || \
		{ echo "zensical missing — run 'make doc-setup'"; exit 2; }
	cd docs && zensical serve

## wasm-opt: post-link size optimization via binaryen's `wasm-opt -Oz`.
##           Reads zig-out/bin/petitpy.wasm and writes
##           zig-out/bin/petitpy.opt.wasm. Typical reduction:
##           14% raw / 5% gzipped on top of Zig's ReleaseSmall. Requires
##           binaryen (`brew install binaryen` / `apt install binaryen`).
##           --all-features is required because Zig emits bulk-memory +
##           nontrapping-float-to-int ops that wasm-opt's default
##           feature set rejects. ADR 007 §4 P1.
wasm-opt:
	@command -v wasm-opt >/dev/null 2>&1 || \
		{ echo "wasm-opt missing (install binaryen: brew install binaryen)"; exit 2; }
	@test -f zig-out/bin/petitpy.wasm || \
		{ echo "no zig-out/bin/petitpy.wasm — run 'make wasm-small' first"; exit 2; }
	wasm-opt -Oz --all-features -ocimfs 1000 --strip-debug --strip-producers --converge \
		zig-out/bin/petitpy.wasm -o zig-out/bin/petitpy.opt.wasm
	@before=$$(wc -c < zig-out/bin/petitpy.wasm); \
	 after=$$(wc -c < zig-out/bin/petitpy.opt.wasm); \
	 saved=$$((before - after)); \
	 pct=$$(awk "BEGIN { printf \"%.1f\", $$saved * 100 / $$before }"); \
	 echo ""; \
	 echo "  Before: $$before bytes"; \
	 echo "  After:  $$after bytes  (saved $$saved = $$pct%)"

## wasm-tiny: maximally-stripped wasm32-wasi build for browser delivery.
##            Disables math + collections + struct + array + errno + micropython
##            + gc-module per F3 (ADR-001 Theme F). Hello-world / list / dict /
##            comprehension / exceptions all still work. Use for embed-in-page
##            Python where stdlib breadth isn't needed.
wasm-tiny: port
	zig build -Dtarget=wasm32-wasi -Dconfig=nano -Doptimize=ReleaseSmall \
	  -Dfeature-math=false \
	  -Dfeature-collections=false \
	  -Dfeature-struct=false \
	  -Dfeature-array=false \
	  -Dfeature-errno=false \
	  -Dfeature-micropython=false \
	  -Dfeature-gc-module=false
	@ls -lh zig-out/bin/petitpy.wasm

## gen-gallery: rebuild the playground gallery from golden-programs/works/.
##              Writes the index to web/demos/playground/gallery.js and copies
##              the sources to web/gallery/ (gitignored — they are copies).
##              Membership is measured: only programs whose `works-on=` header
##              says petitpy-wasm, which `make golden` wrote after running
##              them there.
gen-gallery:
	python3 tools/gen_gallery.py
	@command -v prettier >/dev/null 2>&1 && \
	  prettier --write 'web/demos/playground/gallery.js' >/dev/null || true

## gen-opcodes: regenerate the playground's opcode + static-qstr tables from
##              vendor headers (py/bc0.h, genhdr/qstrdefs.generated.h). The
##              disassembler in web/demos/playground/mpy.js reads them. Both
##              outputs carry a SHA-256 of their source so drift shows in the
##              diff. Run after `make port`.
gen-opcodes:
	python3 tools/gen_opcodes_js.py
	@command -v prettier >/dev/null 2>&1 && \
	  prettier --write 'web/demos/playground/opcodes.js' 'web/demos/playground/qstrs.js' >/dev/null || \
	  echo "(prettier absent — generated files may fail 'make lint')"

## web: build a ReleaseSmall wasm with frozen-tiny enabled (~300 KB), drop it
##      under web/, and print the command to serve the browser demo locally.
##      The -Dfrozen-tiny=true flag bakes the json + types + _thread
##      modules into the binary so `import json` works in the browser
##      without lazy-fetch (ADR-003).
web: freeze-modules gen-gallery
	@# ADR 012 Phase 4a: web ships the wasm artifact; wasm arm pinned
	@# to nano regardless of top-level CONFIG (see `wasm` target).
	zig build -Dtarget=wasm32-wasi -Dconfig=nano -Doptimize=ReleaseSmall -Dfrozen-tiny=true
	@# ADR 007 §4 P6 — post-link `wasm-opt -Oz` shrinks the shipping
	@# artifact by ~14% (see also: tools/metrics.py for the longitudinal
	@# trend). Gracefully degrades when binaryen isn't installed so
	@# contributors without it still get a working demo.
	@# Feature flags: enable exactly what the binary uses — bulk-memory,
	@# nontrapping-float-to-int, and exception-handling for ADR 013's
	@# trampoline (with reference-types, which its exnref form needs). Not
	@# `--all-features`, which would let wasm-opt emit features the
	@# runtimes may lack. A wasm-opt failure fails the target, so a stale
	@# web/petitpy.wasm is never shipped.
	@# -ocimfs 1000: by default -Oz inlines every function that has one
	@# caller, including dispatchBody (about 3950 in binaryen's measure)
	@# into mp_execute_bytecode. The loop then never re-enters a function
	@# and V8 keeps it on Liftoff: bubble retired 1.8x the instructions
	@# (ADR 020 C2). Smaller functions still inline.
	@if command -v wasm-opt >/dev/null 2>&1; then \
	  wasm-opt -Oz --enable-bulk-memory --enable-nontrapping-float-to-int \
	    --enable-exception-handling --enable-reference-types \
	    -ocimfs 1000 --strip-debug --strip-producers --converge \
	    zig-out/bin/petitpy.wasm -o web/petitpy.wasm || exit 1; \
	  before=$$(wc -c < zig-out/bin/petitpy.wasm); \
	  after=$$(wc -c < web/petitpy.wasm); \
	  saved=$$((before - after)); \
	  pct=$$(awk "BEGIN { printf \"%.1f\", $$saved * 100 / $$before }"); \
	  echo "  wasm-opt:  $$before → $$after bytes (saved $$saved = $$pct%)"; \
	else \
	  echo "  wasm-opt missing (install binaryen for ~14% smaller demo); shipping raw"; \
	  cp zig-out/bin/petitpy.wasm web/petitpy.wasm; \
	fi
	@echo ""
	@echo "Serve from the web/ directory (the demos use relative paths):"
	@echo "  python3 -m http.server -d web 8000"
	@echo ""
	@echo "  http://localhost:8000/                     index"
	@echo "  http://localhost:8000/demos/playground/    editor + bytecode + gallery"

## web-embed: web/petitpy-embed.wasm, the embedding API (petitpy.h) as a
##            wasm module that is initialised once and then called, for
##            web/lib/petitpy-embed.js. Same profile as web/petitpy.wasm.
web-embed: freeze-modules
	zig build lib -Dtarget=wasm32-wasi -Dconfig=nano -Doptimize=ReleaseSmall -Dfrozen-tiny=true -p zig-out/embed-wasm
	@if command -v wasm-opt >/dev/null 2>&1; then \
	  wasm-opt -Oz --enable-bulk-memory --enable-nontrapping-float-to-int \
	    --enable-exception-handling --enable-reference-types \
	    -ocimfs 1000 --strip-debug --strip-producers --converge \
	    zig-out/embed-wasm/bin/petitpy-embed.wasm -o web/petitpy-embed.wasm || exit 1; \
	else \
	  cp zig-out/embed-wasm/bin/petitpy-embed.wasm web/petitpy-embed.wasm; \
	fi
	@echo "  web/petitpy-embed.wasm: $$(wc -c < web/petitpy-embed.wasm) bytes"

## rebuild: clean caches + full rebuild (the strangle clean-rebuild)
rebuild: clean build

## test: every test tier, fast first (unit → integration → e2e). Use
##       `test-unit` / `test-integration` / `test-e2e` to run one tier.
test: test-unit test-integration test-e2e test-stdlib test-wheel-layout test-embed

## test-wheel-layout: import every stdlib module from the directory layout
##                    `pip install` ships (scripts/hatch_build.py), with a
##                    full binary built without frozen modules, as the
##                    wheel's is. The frozen-tiny suites cannot see it.
test-wheel-layout: port
	zig build -Dconfig=full -p zig-out/wheel-layout
	python3 tests/wheel_layout.py zig-out/wheel-layout/bin/petitpy

## test-embed: build libpetitpy.a and petitpy.h (`zig build lib`, the
##             embedding API of ADR 022), link tests/embed/api_test.c
##             against them with the system C compiler, and run it, then
##             again with a collection every 10 allocations so that a value
##             held only through a handle would be lost if it were not a
##             root; and build and run examples/embed/host.c.
EMBED_CFLAGS := $(if $(filter Darwin,$(shell uname -s)),-mmacosx-version-min=$(shell sw_vers -productVersion))
test-embed: freeze-modules
	zig build lib -Dconfig=full -Dfrozen-tiny=true -p zig-out/embed
	$(CC) -std=c99 -Wall -Wextra -Werror $(EMBED_CFLAGS) -Izig-out/embed/include \
	  tests/embed/api_test.c zig-out/embed/lib/libpetitpy.a -lpthread -lm -o zig-out/embed/api_test
	zig-out/embed/api_test
	NPY_GC_STRESS=10 zig-out/embed/api_test > zig-out/embed/stress.log || { cat zig-out/embed/stress.log; exit 1; }
	$(CC) -std=c99 -Wall -Wextra -Werror $(EMBED_CFLAGS) -Izig-out/embed/include \
	  examples/embed/host.c zig-out/embed/lib/libpetitpy.a -lpthread -lm -o zig-out/embed/host
	test "$$(zig-out/embed/host)" = 41

## test-stdlib: run petitpy-lib/*'s test suite under
##              tests/stdlib/test_*.py via pytest_lite (ADR 011).
##              The first test file (test_pytest_lite.py) is the
##              bootstrap self-test; the rest are stdlib unit tests
##              run through the pytest_lite runner.
test-stdlib: build
	@for f in tests/stdlib/test_*.py; do \
	  echo ">>> $$f"; \
	  $(BIN) $$f || exit $$?; \
	done

## test-unit: every Zig unit test (~105 across compiler + VM).
##            Wraps `zig build unit`. Use `test-unit-compiler` /
##            `test-unit-vm` to run one side at a time.
test-unit: build
	zig build unit --summary all

## test-unit-compiler: just the compiler-track unit tests (qstr / lexer /
##                    bigint / parser / scope / emit / driver — ~93 tests).
test-unit-compiler: build
	zig build unit-compiler --summary all

## test-unit-vm: just the VM-track unit tests (the shimless runtime
##               utilities — smallint, unicode, parsenumbase, persistentcode).
test-unit-vm: build
	zig build unit-vm --summary all

## test-integration: curated end-to-end smoke suite (small, readable,
##                   fast) in tests/integration.py — complements the
##                   corpus. Runs against the native binary WITH
##                   frozen-tiny, matching what `make web` ships to
##                   the browser (so a test of `from collections import
##                   deque` etc. behaves the same on both arms).
test-integration: build-frozen
	python3 tests/integration.py --config $(CONFIG) $(BIN)

## test-integration-wasm: the same suite against the wasm binary,
##                        invoked via wasmtime. The independent gate
##                        for "the wasm binary actually works" — the
##                        corpus + known-fails coupling doesn't catch
##                        wasm-only regressions in paths the corpus
##                        has already flagged.
test-integration-wasm: wasm-small
	python3 tests/integration.py --config wasm --runner "tools/run_wasm.sh zig-out/bin/petitpy.wasm"

## test-e2e: corpus (byte-identical vs frozen .out files) + compile-exec
##           (Zig frontend → vendor VM → diff stdout). The corpus is the
##           strangler's invariant; compile-exec is informational (2 known
##           harness-artifact failures).
test-e2e: build
	python3 tools/progress.py --config $(CONFIG) $(BIN)
	@if [ "$(CONFIG)" = "nano" ]; then \
		python3 tools/compile-exec-test.py || \
		echo "(compile-exec informational — 2 known harness fails)"; \
	else \
		echo "(compile-exec-test runs against the full oracle only)"; \
	fi

## test-coverage: line-coverage report over `make test-unit`. Requires
##                kcov (install with `brew install kcov` on macOS).
##                Writes HTML to coverage/unit/index.html.
test-coverage: test-coverage-compiler test-coverage-vm
	@# Merge into one cross-side report; per-side reports stay where they are.
	@kcov --merge coverage/unit/merged \
		coverage/unit/compiler/per-binary/*/ \
		coverage/unit/vm/per-binary/*/
	@echo "Coverage reports:"
	@echo "  coverage/unit/compiler/merged/index.html  (compiler track)"
	@echo "  coverage/unit/vm/merged/index.html        (VM track)"
	@echo "  coverage/unit/merged/index.html           (both, merged)"

## test-coverage-compiler: line coverage for just the compiler-track tests.
test-coverage-compiler:
	@command -v kcov >/dev/null 2>&1 || { \
		echo "kcov not installed (brew install kcov / apt-get install kcov)"; \
		exit 1; \
	}
	@if [ -d coverage/unit/compiler ]; then xattr -cr coverage/unit/compiler 2>/dev/null || true; fi
	@rm -rf coverage/unit/compiler && mkdir -p coverage/unit/compiler/per-binary
	$(MAKE) -s test-unit-compiler
	@for bin in $$(find .zig-cache -type f -name 'compiler-*' -perm +111 2>/dev/null); do \
		name=$$(basename "$$bin"); \
		kcov --include-pattern=/src/compiler/ \
			"coverage/unit/compiler/per-binary/$$name" "$$bin" >/dev/null 2>&1 || true; \
	done
	@kcov --merge coverage/unit/compiler/merged coverage/unit/compiler/per-binary/*/
	@echo "Compiler coverage: coverage/unit/compiler/merged/index.html"

## test-coverage-vm: line coverage for just the VM-track tests.
test-coverage-vm:
	@command -v kcov >/dev/null 2>&1 || { \
		echo "kcov not installed (brew install kcov / apt-get install kcov)"; \
		exit 1; \
	}
	@if [ -d coverage/unit/vm ]; then xattr -cr coverage/unit/vm 2>/dev/null || true; fi
	@rm -rf coverage/unit/vm && mkdir -p coverage/unit/vm/per-binary
	$(MAKE) -s test-unit-vm
	@# Exclude src/compiler/ so the VM coverage % isn't diluted by compiler
	@# files the VM test binary happens to pull in transitively.
	@for bin in $$(find .zig-cache -type f -name 'vm-*' -perm +111 2>/dev/null); do \
		name=$$(basename "$$bin"); \
		kcov --include-pattern=/src/ --exclude-pattern=/src/compiler/ \
			"coverage/unit/vm/per-binary/$$name" "$$bin" >/dev/null 2>&1 || true; \
	done
	@kcov --merge coverage/unit/vm/merged coverage/unit/vm/per-binary/*/
	@echo "VM coverage: coverage/unit/vm/merged/index.html"

## test-coverage-e2e: line-coverage report over the corpus (`make check`).
##                    Measures what % of strangled Zig is exercised by the
##                    541 byte-identical golden tests — the more meaningful
##                    number for a strangler than unit-test coverage alone.
##                    Requires kcov; expect ~541 wrapped invocations (slow).
##                    Writes HTML to coverage/e2e/merged/index.html.
test-coverage-e2e:
	@command -v kcov >/dev/null 2>&1 || { \
		echo "kcov not installed."; \
		echo "  macOS:   brew install kcov"; \
		echo "  Linux:   apt-get install kcov  (or build from source)"; \
		exit 1; \
	}
	$(MAKE) build
	@# macOS Sequoia marks kcov-written files with com.apple.provenance;
	@# clear it before rm so a fresh run isn't blocked by stale coverage.
	@if [ -d coverage/e2e ]; then xattr -cr coverage/e2e 2>/dev/null || true; fi
	@rm -rf coverage/e2e && mkdir -p coverage/e2e/per-test
	@echo "Wrapping $$(ls corpus/$(CONFIG)/basics/*.out | wc -l) corpus runs with kcov (slow — minutes)…"
	@for out in corpus/$(CONFIG)/basics/*.out; do \
		base=$$(basename "$$out" .out); \
		script="corpus/basics/$$base.py"; \
		[ -f "$$script" ] || continue; \
		kcov --include-pattern=/src/ "coverage/e2e/per-test/$$base" \
			$(BIN) "$$script" >/dev/null 2>&1 || true; \
	done
	@echo "Merging per-test coverage…"
	@kcov --merge coverage/e2e/merged coverage/e2e/per-test/*/
	@echo "Coverage report: coverage/e2e/merged/index.html"

## check: the invariant gate. Default (CONFIG=full) routes to the strict
##        bidirectional gate against corpus/full-known-fails.txt.
##        CONFIG=nano routes to progress.py --strict for the byte-exact
##        nano invariant (fails unless 541/541). Per ADR 012 Phase 4b
##        (2026-06-13) full is the default profile.
## v0.7.1: CONFIG=full routes through build-frozen (frozen-tiny binary,
## random/etc. reachable); CONFIG=nano stays on the non-frozen build
## because nano's ucollections.deque golden semantics don't survive
## the frozen collections.py shadow (see check-nano rationale).
check:
	@if [ "$(CONFIG)" = "full" ]; then \
	  $(MAKE) build-frozen && python3 tools/full_gate.py; \
	else \
	  $(MAKE) build && python3 tools/progress.py --config $(CONFIG) --strict $(BIN); \
	fi

## verify: detailed per-test PASS/FAIL list. For full, uses full_gate;
##         for nano, uses corpus.py verify against the frozen goldens.
verify:
	@if [ "$(CONFIG)" = "full" ]; then \
	  $(MAKE) build-frozen && python3 tools/full_gate.py; \
	else \
	  $(MAKE) build && python3 tools/corpus.py --config $(CONFIG) verify $(BIN); \
	fi

## run: build then run a script — `make run SCRIPT=path/to.py`
run: build
	@test -n "$(SCRIPT)" || { echo "usage: make run SCRIPT=file.py"; exit 2; }
	$(BIN) $(SCRIPT)

## format: apply zig fmt (Zig) + prettier (JS, web/* + projects/*) to our
##         sources (never touches vendor/ or corpus/).
format:
	zig fmt $(ZIGSRC)
	@command -v prettier >/dev/null 2>&1 && prettier --write 'web/**/*.js' 'projects/**/*.js' || echo "(prettier absent — skipped JS format)"

## lint: zig fmt --check on our Zig + byte-compile + ruff over $(PYSRC)
##       + prettier --check on JS sources.
##       Deliberately excludes corpus/*.out (byte-exact fixtures) and the
##       nano-runtime Python noted above $(PYSRC).
lint:
	zig fmt --check $(ZIGSRC)
	python3 -m py_compile $(PYSRC)
	@if command -v ruff >/dev/null 2>&1; then ruff check $(PYSRC); else echo "(ruff absent — skipped python lint)"; fi
	@if command -v prettier >/dev/null 2>&1; then prettier --check 'web/**/*.js' 'projects/**/*.js'; else echo "(prettier absent — skipped JS lint)"; fi

## clean: remove everything this repo generates. `make clean ALL=1` also drops
##        the expensive-to-rebuild artifacts: vendor/micropython_embed (needs
##        `make port`), web/petitpy.wasm (needs `make web`, and `make smoke`
##        won't run without it). vendor/micropython and sandbox/ are never
##        touched — they are external clones.
GENERATED := .zig-cache zig-out coverage build-frozen port/build-embed \
             dist docs/site .ruff_cache .pytest_cache .workflow-tmp \
             notes/tech-reports/TR-001.pdf
EXPENSIVE := vendor/micropython_embed web/petitpy.wasm

clean:
	rm -rf $(GENERATED)
	@find . -name __pycache__ -type d \
	  -not -path './sandbox/*' -not -path './.venv/*' -not -path './vendor/*' \
	  -prune -exec rm -rf {} + 2>/dev/null || true
	@# Every sandbox/* entry is a symlink into a SEPARATE checkout, so find needs
	@# -L to see inside at all. __pycache__ is regenerable, but this reaches
	@# outside the repo, so the count is printed rather than removed silently.
	@# .git/.venv/node_modules are pruned: most hits under an unpruned walk are
	@# third-party venv packages, which are not ours to clear.
	@if [ -d sandbox ]; then \
	  n=$$(find -L sandbox \( -name .git -o -name .venv -o -name node_modules \) -prune \
	       -o -name __pycache__ -type d -prune -print 2>/dev/null | wc -l | tr -d ' '); \
	  if [ "$$n" -gt 0 ]; then \
	    find -L sandbox \( -name .git -o -name .venv -o -name node_modules \) -prune \
	      -o -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true; \
	    echo "  removed $$n __pycache__ dirs from the linked sandbox/ trees (outside this repo)"; \
	  fi; \
	fi
ifdef ALL
	rm -rf $(EXPENSIVE)
	@echo "removed vendor/ and web/petitpy.wasm — next build needs \`make port\`"
endif

## freeze: DANGER — re-freeze corpus goldens for the active config from
##         the current binary. Only after a deliberate config change.
##         `make freeze CONFIG=full` re-freezes the full corpus from the
##         upstream standard oracle (omits $(BIN) so the oracle is the
##         default reference).
freeze: build
	python3 tools/corpus.py --config $(CONFIG) gen $(if $(filter full,$(CONFIG)),,$(BIN))

## smoke: headless-Chromium console-capture smoke for EVERY page under
##        web/demos/ + web/games/, plus the ci-build-monitor extension page.
##        Requires `make smoke-setup` once per environment. Exits non-zero on
##        any [error] / [pageerror].
##
##        The page list is enumerated, not hardcoded: `make` never touches
##        web/, so this is the only gate those pages have, and a hardcoded
##        list silently stops covering anything added later. It was 6 of 32.
## wasm-gc-check: wasm garbage collection (ADR 019 §5). Drives the web build
##        the way a page does (main.py, then JS callbacks) under Node, and
##        checks memory stays flat and live state survives collection at safe
##        points. The corpus and integration gates can't: a single script never
##        reaches a safe point. Needs node; not in the aggregate.
wasm-gc-check: web
	node --no-warnings tools/wasm_gc_check.mjs web/petitpy.wasm

## npm-package: assemble the npm package in npm/dist/ (the web wasm, the
##              JS bridge and npm/'s API module), versioned from build.zig.
##              Publishing (`npm publish ./npm/dist`) is the maintainer's step.
npm-package: web web-embed
	rm -rf npm/dist && mkdir -p npm/dist
	cp npm/index.js npm/index.d.ts npm/embed.d.ts npm/README.md LICENSE web/lib/js-bridge.js web/lib/wasi-fs.js npm/dist/
	cp web/lib/petitpy-embed.js npm/dist/embed.js
	cp web/petitpy.wasm web/petitpy-embed.wasm npm/dist/
	version=$$(sed -n 's/^pub const version = "\(.*\)";/\1/p' build.zig); \
	  sed "s/\"version\": \"0.0.0\"/\"version\": \"$$version\"/" npm/package.json > npm/dist/package.json

## release-dist: build everything a release publishes (ADR 016): the
##               PyPI files (pypi-dist) and the npm package in npm/dist/.
release-dist: pypi-dist npm-package

## pypi-dist: build the sdist and the four wheels in dist/, cross-compiled
##            here by Zig. Smoke-tests the wheel for this machine in a
##            fresh venv.
RELEASE_TARGETS := aarch64-macos.11.0:macosx_11_0_arm64 \
                   x86_64-macos.11.0:macosx_11_0_x86_64 \
                   x86_64-linux-gnu.2.17:manylinux_2_17_x86_64 \
                   aarch64-linux-gnu.2.17:manylinux_2_17_aarch64
pypi-dist: port
	rm -rf dist && mkdir dist
	uv build --sdist --out-dir dist
	for t in $(RELEASE_TARGETS); do PETITPY_TARGET=$$t uv build --wheel --out-dir dist || exit 1; done
	uv venv -q dist/.smoke
	uv pip install -q --python dist/.smoke/bin/python --no-index --find-links dist petitpy
	dist/.smoke/bin/petitpy -c 'import os, datetime, json; print("smoke:", os.path.join("a", "b"), datetime.date(2026, 1, 2), json.dumps([1.5]))'
	dist/.smoke/bin/ppy --version
	ls -l dist

## release-publish: upload dist/ to PyPI and npm/dist/ to npm. The
##                  maintainer's step: needs PyPI and npm credentials, and
##                  refuses unless HEAD is tagged v<build.zig version>.
release-publish:
	@version=$$(sed -n 's/^pub const version = "\(.*\)";/\1/p' build.zig); \
	  tag=$$(git describe --exact-match --tags HEAD 2>/dev/null); \
	  [ "$$tag" = "v$$version" ] || { echo "HEAD is tagged '$$tag', not v$$version; tag the release first"; exit 1; }
	uv publish dist/*.tar.gz dist/*.whl
	npm publish ./npm/dist

## publish: clean, rebuild dist/ and upload it to PyPI (not npm). Needs
##          PyPI credentials for twine.
publish: clean
	$(MAKE) pypi-dist
	uv run twine upload --skip-existing dist/*

## npm-check: run the assembled package under Node and in headless
##            Chromium (needs `make smoke-setup`). Installs its one
##            dependency into npm/dist (network); not in the aggregate.
npm-check: npm-check-node
	python3 tools/browser-smoke.py --serve npm --page test-browser.html \
	  --wait-for-text "passed" --assert-text "4 of 4 passed"

## npm-check-node: the Node half of npm-check, run in CI: run() and the
##                 long-lived interpreter of petitpy/embed.
npm-check-node: npm-package
	cd npm/dist && npm install --no-save --ignore-scripts --no-audit --no-fund >/dev/null
	node --no-warnings npm/test.mjs $(CURDIR)/npm/dist
	node --no-warnings npm/test-embed.mjs $(CURDIR)/npm/dist

SMOKE_PAGES := $(patsubst web/%index.html,%,\
                 $(wildcard web/demos/*/index.html) \
                 $(wildcard web/games/*/index.html))

smoke:
	@for page in $(SMOKE_PAGES); do \
	  echo "--- $$page"; \
	  python3 tools/browser-smoke.py --serve web --page "$$page" || exit 1; \
	done
	python3 tools/browser-smoke.py --serve projects/ci-build-monitor --page popup.html --wait 5000
	$(MAKE) smoke-flows

## smoke-flows: interaction + assertion flows for the pages that carry state.
##              The page sweep in `smoke` proves pages BOOT; these prove the
##              paths that only run on user input still WORK — the storage
##              round-trips behind the snake/todo handler fixes, and the
##              js-bridge failure semantics that cannot be gated under
##              wasmtime (the demo artifact needs a JS host).
##              Each flow asserts, so it fails the build rather than warning.
smoke-flows:
	@echo "--- js-bridge conformance"
	python3 tools/browser-smoke.py --serve web --page tests/bridge-conformance/ --wait 5000 \
	  --assert-text "BRIDGE-CONFORMANCE: OK" --assert-no-text "FAIL"
	@echo "--- todo: add an item (save path)"
	python3 tools/browser-smoke.py --serve web --page demos/todo/ --wait 3000 \
	  --eval "localStorage.clear(); 'cleared'" \
	  --type "#new-todo=smoke-item" --click "#add-btn" --sleep 800 \
	  --assert-text "smoke-item"
	@echo "--- todo: restore valid stored data (load path)"
	python3 tools/browser-smoke.py --serve web --page demos/todo/ --wait 3000 \
	  --eval "localStorage.setItem('petitpy-todos','[{\"id\":7,\"text\":\"restored-item\",\"done\":false}]'); location.reload(); 'seeded'" \
	  --sleep 3500 --assert-text "restored-item"
	@echo "--- todo: corrupt stored data must not kill the page"
	python3 tools/browser-smoke.py --serve web --page demos/todo/ --wait 2500 \
	  --eval "localStorage.setItem('petitpy-todos','[{\"id\":'); location.reload(); 'seeded'" \
	  --sleep 3500 --assert-text "No todos yet"
	@echo "--- snake: valid high score loads"
	python3 tools/browser-smoke.py --serve web --page games/snake/ --wait 2500 \
	  --eval "localStorage.setItem('petitpy:snake:high','42'); location.reload(); 'seeded'" \
	  --sleep 3000 --assert-text "HIGH42"
	@echo "--- snake: corrupt high score falls back to 0"
	python3 tools/browser-smoke.py --serve web --page games/snake/ --wait 2500 \
	  --eval "localStorage.setItem('petitpy:snake:high','not-a-number'); location.reload(); 'seeded'" \
	  --sleep 3000 --assert-text "HIGH0"

## smoke-setup: install the playwright pip package + the chromium browser
##              binary (~150 MB download). Run once per environment.
smoke-setup:
	pip install playwright
	python3 -m playwright install chromium

# --- Firefox extension packaging --------------------------------------------
# The ci-build-monitor demo is a WebExtension. These targets wrap the official
# Mozilla `web-ext` tool (Node/npx). If web-ext is unavailable, use
# `ext-package-zip` for the plain-zip fallback (Firefox accepts a zip with
# the .xpi extension).
EXT_DIR      := projects/ci-build-monitor
EXT_ARTIFACT := $(EXT_DIR)/dist-ext
# Files present in source but excluded from the .xpi — kept in sync with
# $(EXT_DIR)/.web-extignore. `web-ext lint` reads the source dir directly
# (not the build output), so it needs --ignore-files to skip these.
EXT_IGNORE   := serve.py test-smoke.sh Makefile README.md STATUS.md \
                notes notes/** dist-ext dist-ext/** build build/** \
                .gitignore .web-extignore \
                src/__pycache__ src/__pycache__/** *.pyc

## ext-lint: run `web-ext lint` against the extension source directory.
ext-lint:
	npx --yes web-ext lint --source-dir $(EXT_DIR) --ignore-files $(EXT_IGNORE)

## ext-package: build the extension archive via `web-ext build` into
##              $(EXT_ARTIFACT)/. web-ext writes a .zip; we also copy it
##              to .xpi so Firefox's drag-into-about:debugging / signing
##              workflow accepts the file by extension.
ext-package:
	npx --yes web-ext build --source-dir $(EXT_DIR) --artifacts-dir $(EXT_ARTIFACT) --overwrite-dest --ignore-files $(EXT_IGNORE)
	@for z in $(EXT_ARTIFACT)/*.zip; do cp -f "$$z" "$${z%.zip}.xpi"; done
	@echo ""
	@echo "Artifact(s):"
	@ls -lh $(EXT_ARTIFACT)/*.zip $(EXT_ARTIFACT)/*.xpi 2>/dev/null || true

## ext-run: launch Firefox Desktop with the extension temporarily loaded.
ext-run:
	npx --yes web-ext run --source-dir $(EXT_DIR) --target firefox-desktop

## ext-package-zip: fallback when web-ext is unavailable — produce a plain
##                  zip with a .xpi extension. Excludes dev-only files.
ext-package-zip:
	@mkdir -p $(EXT_ARTIFACT)
	@rm -f $(EXT_ARTIFACT)/ci-build-monitor.xpi
	cd $(EXT_DIR) && zip -r dist-ext/ci-build-monitor.xpi . \
	  -x 'dist-ext/*' \
	  -x 'node_modules/*' \
	  -x '.web-extignore' \
	  -x '.gitignore' \
	  -x 'Makefile' \
	  -x 'README.md' \
	  -x 'STATUS.md' \
	  -x 'notes/*' \
	  -x 'serve.py' \
	  -x 'test-smoke.sh' \
	  -x '*.DS_Store' \
	  -x '*.swp' -x '*.swo'
	@ls -lh $(EXT_ARTIFACT)/ci-build-monitor.xpi

.PHONY: all help port build build-release build-small wasm wasm-small wasm-check wasm-opt wasm-tiny web web-embed rebuild \
        test test-unit test-unit-compiler test-unit-vm \
        test-integration test-integration-wasm test-e2e \
        test-coverage test-coverage-compiler test-coverage-vm test-coverage-e2e \
        check verify check-full check-nano check-all check-release run format lint clean freeze \
        metrics-record metrics-record-perf metrics-report metrics-latest \
        golden compatibility \
        doc-setup doc-build doc-serve \
        smoke smoke-setup wasm-gc-check test-wheel-layout test-embed npm-package npm-check npm-check-node pypi-dist release-dist release-publish publish \
        ext-lint ext-package ext-run ext-package-zip
