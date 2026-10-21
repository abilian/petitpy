# Nano Build Monitor (nanopython port of ci-build-monitor)

A Chrome/Firefox extension that monitors CI builds across Sourcehut, GitHub, and GitLab. Originally written in Python and compiled to JavaScript with Prescrypt under the name "CI Build Monitor"; this directory is the in-progress port to nanopython, renamed "Nano Build Monitor" so both extensions can be loaded side-by-side. The same Python sources run unmodified (well, almost — see `notes/PORTING.md`) on top of the nanopython wasm runtime via the J5 js bridge.

Upstream Prescrypt-targeted source lives at `sandbox/ci-build-monitor/` (symlink into the user's working tree of the original extension). The nanopython port lives here.

## Status — HTML pages live; per-page wasm loaders boot Python sources

Sessions 1 and 2 of the Python port landed `core/` + `ui/` + `providers/` + `services/` + `pages/options.py` + `pages/status.py` (since flattened — see below). The current session lands the HTML entry-points + per-page wasm loaders: a shared `dist/bootstrap.js` helper fetches `wasm/nanopython.wasm` + every `src/*.py`, mounts them flat under a `PreopenDirectory` at `/src`, wires the ADR-006 js bridge, and runs the entry-point under WASI. Each HTML page bootstraps a different entry (`/src/pages_popup.py`, `pages_options.py`, `pages_status.py`) via a one-line per-page loader.

Layout note: nanopython's import machinery is flat-only (no packages, no dotted module names — see `src/runtime/import_search.zig` in the parent repo). Each former `src/<pkg>/<mod>.py` is now `src/<pkg>_<mod>.py`, and `from <pkg>.<mod> import …` was rewritten to `from <pkg>_<mod> import …`.

### Works

- Directory skeleton (`src/`, `wasm/`, `dist/`, `styles/`, `icons/`, `notes/`).
- `wasm/nanopython.wasm` and `wasm/js-bridge.js` mirror the canonical pair from `web/`.
- `make sync-wasm` re-copies the wasm pair from `../../web/`.
- `make serve` runs `python3 -m http.server -d . 8000` so the pages can be loaded in a browser.
- HTML pages (`popup.html`, `options.html`, `status.html`) are copied verbatim from sandbox, with Prescrypt `<script src="dist/helpers.js">` + `<script src="dist/X.js">` replaced by a single `<script type="module" src="dist/X-loader.js">`.
- `dist/bootstrap.js` shared loader + three per-page loaders (`popup-loader.js`, `options-loader.js`, `status-loader.js`).
- `manifest.json`, `styles/common.css`, and `icons/icon{16,48,128}.png` copied from sandbox.
- Smoke test: served via `make serve`, all 16 URLs (3 HTML pages, manifest, 3 loaders, bootstrap.js, wasm pair, css, one icon, 4 .py samples) return 200.
- The full Prescrypt → nanopython transformation catalog is documented in `notes/PORTING.md`.
- `STATUS.md` lists every source file (19 .py + 3 HTML + manifest + 4 loader JS + assets) with a porting checkbox.

### In progress / next

- Session 3: port `pages/popup.py` and `pages/background.py`; wire `manifest.json`'s `background.scripts` field to a wasm-aware service worker loader.

### Deferred

- Promise chains via `.then(fn).catch(fn)` — work via the J5 callback bridge, but the bridge does not yet expose a Promise polyfill, so async paths may need re-shaping.
- `chrome.storage`, `chrome.notifications`, `chrome.alarms` — these are JS-side globals reached via `js.chrome` / `js.get("chrome")` and only resolve when the page is loaded as an actual browser extension; the `make serve` path runs the pages without those globals (so `services/storage.py` will surface `undefined` reads at runtime — that's expected and only verified end-to-end once the extension is loaded for real).
- Type hints (`list[Build]`, `-> Build`, `from __future__ import annotations`) — drop on port. nano has limited typing support.
- `manifest.json` `background.scripts` rewrite for the wasm service worker — session 3.
- Build pipeline (`make build` that bundles wasm + Python + HTML into a loadable `.zip`) — placeholder in `Makefile`.

## Layout

```
projects/ci-build-monitor/
├── README.md             ← you are here
├── STATUS.md             ← per-file porting tracker
├── Makefile              ← sync-wasm + serve + build skeleton
├── manifest.json         ← extension manifest
├── popup.html            ← loads dist/popup-loader.js
├── options.html          ← loads dist/options-loader.js
├── status.html           ← loads dist/status-loader.js
├── icons/                ← icon{16,48,128}.png
├── styles/common.css
├── notes/
│   └── PORTING.md        ← canonical Prescrypt → nanopython transformation table
├── src/                  ← Python port (15 flat .py files; pages_*, providers_*, services_*, ui_*, core_*)
├── dist/
│   ├── bootstrap.js      ← shared wasm + Python + bridge loader
│   ├── popup-loader.js   ← bootstrap("/src/pages_popup.py")
│   ├── options-loader.js ← bootstrap("/src/pages_options.py")
│   └── status-loader.js  ← bootstrap("/src/pages_status.py")
└── wasm/
    ├── nanopython.wasm   ← copy from ../../web/nanopython.wasm
    └── js-bridge.js      ← copy from ../../web/lib/js-bridge.js
```

## Quickstart

### Standalone web mode (`make serve`)

```sh
make sync-wasm   # re-copy wasm pair from ../../web/
make serve       # python3 -m http.server -d . 8000
```

Open `http://localhost:8000/popup.html` (or `options.html` / `status.html`) in a browser to load the page. Open devtools console to see `[py]` and `[stderr]` output from the wasm runtime. `chrome.*` is stubbed by `dist/chrome-shim.js` (localStorage-backed storage, console-logged notifications, setInterval-backed alarms). `pages_background.py` is not exercised in this mode — there is no service worker.

### Load as an unpacked extension

To exercise the full extension surface (real `chrome.storage`, `chrome.notifications`, `chrome.alarms` + the `pages_background.py` service worker), load the directory as an unpacked extension:

**Chrome / Chromium / Edge** — visit `chrome://extensions`, enable **Developer mode** (toggle, top-right), click **Load unpacked**, then select the `projects/ci-build-monitor/` directory. The extension icon appears in the toolbar; click it for the popup, right-click → "Options" for the options page, click "Open Dashboard" inside the popup for the status page. The service worker (`dist/background-loader.js`) shows up under "Inspect views: service worker" — click it to open a devtools console scoped to the SW for `[py]` and `[stderr]` traces from `pages_background.py`.

**Firefox** — see the dedicated [Loading in Firefox](#loading-in-firefox) section below for step-by-step instructions and FF-specific gotchas.

#### MV3 service-worker constraints

Chrome MV3 service workers are stricter than extension pages:

1. **No remote ES module imports.** SWs can only `import` from same-origin (`chrome-extension://`) URLs — not from CDNs. `dist/background-loader.js` therefore imports `@bjorn3/browser_wasi_shim` from the vendored `dist/vendor/wasi-shim/` copy, not from jsdelivr (which is what `dist/bootstrap.js` does for the page loaders). Re-vendoring is a manual step: `curl` the seven `.js` files from `https://cdn.jsdelivr.net/npm/@bjorn3/browser_wasi_shim@0.4.2/dist/` into `dist/vendor/wasi-shim/`.
2. **`WebAssembly.compile` requires `'wasm-unsafe-eval'` in CSP.** Added under `content_security_policy.extension_pages` in `manifest.json`. Without it, `WebAssembly.compileStreaming` throws `CompileError: Wasm code generation disallowed by embedder`.
3. **No DOM / `window` / `document`.** Pages_background.py is careful to only touch `js.console`, `js.get("Date")`, `js.get("Promise")`, and `chrome.*` — all of which are on `globalThis` inside a service worker. It does not use `window.localStorage` or any DOM API.
4. **SW lifecycle: woken on events.** A MV3 SW is not persistent; chrome wakes it when a registered event fires (`chrome.alarms.onAlarm`, `chrome.notifications.onClicked`, `chrome.runtime.onMessage`, …). `pages_background.py`'s `init()` runs on each wake-up, re-registers all listeners (idempotent), then `check_all_sources()` runs once. Subsequent events dispatch through the J5 callback bridge.

#### Smoke-test the loaded extension

1. Open the popup (toolbar icon). The popup should boot wasm, show the spinner, and either render "No repositories configured" (fresh install) or the cached repo list.
2. Open the options page (right-click toolbar icon → "Options"). Add a repository (e.g. `github` provider, owner `octocat`, repo `hello-world`).
3. Open the service-worker devtools console (chrome://extensions → "Inspect views: service worker"). Confirm `[py] "CI Build Monitor initializing..."` appears, followed by `chrome.alarms.create` taking effect (visible via `chrome.alarms.getAll(console.log)` in the SW console).
4. Trigger a check manually: in the SW console, run `chrome.alarms.create("checkBuilds", {when: Date.now() + 1000})`. After a second, `[py] "Checking all monitored sources..."` should print, followed by per-source result lines.
5. To force a notification, configure a repo with a known failing build; the SW will call `chrome.notifications.create` and a system notification should appear.

### Loading in Firefox

The manifest declares `browser_specific_settings.gecko.id = "nano-build-monitor@fermigier.com"` (distinct from the upstream Prescrypt `ci-build-monitor@fermigier.com`) so both extensions can be loaded in the same Firefox profile at the same time without ID collision.

1. Visit `about:debugging` in the URL bar.
2. Click **This Firefox** in the left sidebar.
3. Click **Load Temporary Add-on...**.
4. Navigate to `projects/ci-build-monitor/` and select `manifest.json`.
5. The extension appears in the list with name "Nano Build Monitor". Click **Inspect** next to the background entry to open a devtools console scoped to it; the popup/options/status pages open from the toolbar icon (popup), right-click → "Manage Extension" → "Preferences" (options), or the "Open Dashboard" button inside the popup (status).

Temporary add-ons are removed when Firefox restarts; for a persistent install you must sign the extension via AMO (or use Firefox Developer Edition / ESR with `xpinstall.signatures.required = false` in `about:config`).

#### Firefox MV3 gotchas

1. **`chrome.*` vs `browser.*`.** Firefox aliases the `chrome` global to `browser` automatically in MV3, so `pages_background.py`'s `js.get("chrome").alarms.create(...)` works unmodified. The reverse alias (Chrome accepting `browser.*`) does NOT hold — keep code on `chrome.*`.
2. **Service worker support is partial.** Firefox added MV3 `background.service_worker` in 121, but its SW lifecycle differs from Chrome (e.g., event-dispatch timing, idle-shutdown thresholds) and several edge cases still fall back to the persistent-script model. The manifest declares both `background.service_worker` and `background.scripts` pointing at the same `dist/background-loader.js`; FF picks `scripts` when its SW path misbehaves, Chrome ignores `scripts` when `service_worker` is set.
3. **CSP `'wasm-unsafe-eval'`.** Firefox MV3 enforces the same `extension_pages` CSP shape as Chrome; the `'wasm-unsafe-eval'` token is required for `WebAssembly.compileStreaming` and is already declared in `manifest.json`. Without it, FF throws `CompileError: WebAssembly.compile(): Wasm code generation disallowed`.
4. **No remote ES module imports in SWs.** Same restriction as Chrome — `dist/background-loader.js` imports the wasi shim from the vendored `dist/vendor/wasi-shim/` copy, not jsdelivr.
5. **Strict `gecko.id` matching.** Firefox keys storage and signing on the `gecko.id`, so changing it (e.g., during development) invalidates `chrome.storage.local` data scoped to the previous ID. Pin the ID and don't churn it.
6. **`strict_min_version`** is set to `121.0`; loading on older Firefoxes will fail the manifest validation step at install time.
