# Makefile — projects/ci-build-monitor
#
# Session 1: only `sync-wasm` is wired. `build` is a placeholder for session 4
# (bundles wasm + Python sources + HTML into a loadable extension dir).

WEB := ../../web

.PHONY: sync-wasm build help serve smoke

help:
	@echo "Targets:"
	@echo "  sync-wasm   Re-copy petitpy.wasm + js-bridge.js from $(WEB)/"
	@echo "  serve       Serve this directory at http://localhost:8000/"
	@echo "  smoke       Headless-Chromium console-capture smoke for popup.html"
	@echo "  build       (session 4) Bundle the extension"

smoke:
	python3 ../../tools/browser-smoke.py --serve . --page popup.html --wait 5000

sync-wasm:
	cp $(WEB)/petitpy.wasm wasm/petitpy.wasm
	cp $(WEB)/lib/js-bridge.js wasm/js-bridge.js
	@echo "wasm pair refreshed from $(WEB)/"

serve:
	python3 serve.py 8000

build:
	@echo "build target is a session-4 placeholder; not implemented yet."
	@exit 1
