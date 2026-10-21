# STATUS — ci-build-monitor port

Per-file porting state. Update as each file lands.

Legend: **no** = not started · **partial** = in progress · **yes** = ported and verified loadable under nanopython wasm.

## Python sources

Flat layout: nanopython's import machinery is flat-only (no packages, no dotted module names — see `src/runtime/import_search.zig`). Each former `src/<pkg>/<mod>.py` is now `src/<pkg>_<mod>.py`, and `from <pkg>.<mod> import …` was rewritten to `from <pkg>_<mod> import …`. The empty `__init__.py` package markers were dropped — they had no content.

| File                                | Ported  | LOC  | Notes                                                                                          |
| ----------------------------------- | ------- | ---: | ---------------------------------------------------------------------------------------------- |
| `src/core_utils.py`                 | partial |   27 | Ported (session 2). `create_obj()` returns `js.JSON.parse("{}")`. `generate_id` uses `Date.now().to_str()`. |
| `src/ui_dom.py`                     | partial |   25 | Ported (session 2). `get_prop` uses `getattr`. `set_display` writes via `style.set(...)`.       |
| `src/ui_formatters.py`              | partial |   51 | Ported (session 2). `js.newDate(...)` → `js.get("Date")(...)`.                                  |
| `src/ui_badges.py`                  | partial |   56 | Ported (session 2). DOM writes via `.set(...)`.                                                |
| `src/ui_repo_helpers.py`            | partial |   62 | Ported (session 2).                                                                            |
| `src/services_storage.py`           | partial |  246 | Ported (session 3a). `chrome = js.get("chrome")` cached. Open: dynamic-key reads on JsProxy.   |
| `src/services_notifications.py`     | partial |  162 | Ported (session 3a). `options.set(...)` writes; `setTimeout` callback via J5.                  |
| `src/providers_base.py`             | partial |   22 | Ported. Depends on `core_utils.create_obj` (now landed).                                        |
| `src/providers_github.py`           | partial |  167 | Ported. `js.Date.parse` / `js.Promise.resolve` / `js.fetch` rerouted through `js.get(...)`.    |
| `src/providers_gitlab.py`           | partial |  171 | Same shape as `github.py`. `js.encodeURIComponent(...)` routed through `js.get(...)`.            |
| `src/providers_sourcehut.py`        | partial |  395 | Ported. RSS DOMParser constructed via `js.get("eval")("new DOMParser()")` (bridge can't `new`). |
| `src/pages_popup.py`                | no      |  305 | DOM-heavy. Each `el.style.display = ...` becomes `el.style.set("display", ...)`.               |
| `src/pages_options.py`              | partial |  ~580 | Ported (session 3b). `chrome = js.get("chrome")` cached. `data = create_obj()` + `.set(...)` for storage payloads. `js.confirm` → `js.get("confirm")(...)`. `js.newDate()` → `js.get("Date")()`. `Blob` and `FileReader` constructed via `js.get("eval")("...")` because the bridge can't `new`. `int(el.value)` → `el.value.to_int()`. `el.value` reads coerced with `.to_str()` for Python string ops. `repos.append(repo)` becomes `repos.push(repo)` when `repos` is a JsProxy array; `new_repos` rebuilt as `js.get("Array")()`. |
| `src/pages_status.py`               | partial | ~810 | Ported (session 3b). All `js.Object.keys(...)` routed through `js.get("Object").keys(...)`. `keys.length` reads need `.to_int()`. `getattr(repositories, source_id)` for dynamic-key reads on a JsProxy. `coerce_str()` helper added for `get_prop`-returned values that may be JsProxy strings (needed for slicing/comparison). `sleeping_repos` array round-tripped as a fresh `js.get("Array")()` on write back. `data["key"] = ...` storage payloads → `create_obj()` + `.set(...)`. Tabs: `tab.dataset.tab.to_str()`. `get_provider_badge_text` import dropped (was unused upstream too). |
| `src/pages_background.py`           | no      |  283 | Service worker — `chrome.alarms.onAlarm` callback. Check Promise chain interaction.             |

Subtotal: 15 .py files, ~3710 LOC.

## HTML + manifest + loaders

| File                                | Ported  | Notes                                                                                          |
| ----------------------------------- | ------- | ---------------------------------------------------------------------------------------------- |
| `manifest.json`                     | yes     | Copied from sandbox (session 2). `background.scripts` still points at `dist/helpers.js` + `dist/background.js`; that wiring lands in session 3 alongside the Python service worker port. |
| `popup.html`                        | yes     | Copied from sandbox. Prescrypt `dist/helpers.js` + `dist/popup.js` removed; replaced by `<script type="module" src="dist/popup-loader.js">`. |
| `options.html`                      | yes     | Same pattern — boots via `dist/options-loader.js`.                                              |
| `status.html`                       | yes     | Same pattern — boots via `dist/status-loader.js`.                                               |
| `dist/bootstrap.js`                 | yes     | Shared loader: fetch wasm + every `src/*.py`, mount them flat under a `PreopenDirectory` at `/src`, wire the J5 bridge, `wasi.start(inst)`. Cache-buster on every fetch. |
| `dist/popup-loader.js`              | yes     | `bootstrap("/src/pages_popup.py")`.                                                            |
| `dist/options-loader.js`            | yes     | `bootstrap("/src/pages_options.py")`.                                                          |
| `dist/status-loader.js`             | yes     | `bootstrap("/src/pages_status.py")`.                                                           |
| `styles/common.css`                 | yes     | Verbatim copy from sandbox.                                                                    |
| `icons/icon16.png`, `48`, `128`     | yes     | Verbatim copy from sandbox.                                                                    |

## Sessions

- **Session 1**: scaffold + PORTING.md + STATUS.md. No `.py` ported.
- **Session 2 (port)**: `core/` + `ui/` + `providers/` + `services/` (split across 207-2..207-4 worktrees).
- **Session 3a**: `services/storage.py` + `services/notifications.py`.
- **Session 3b**: `pages/options.py` + `pages/status.py`. Largest two files — `popup.py` and `background.py` still to do.
- **Session 2 (HTML)** (this one): HTML pages + manifest + styles + icons copied from sandbox, `<script>` tags rewired to per-page loaders, shared `dist/bootstrap.js` boots wasm + Python sources via `PreopenDirectory` tree at `/src`. `make serve` target added. All 16 smoke-test URLs (3 HTML, manifest, 3 loaders, bootstrap, 2 wasm, css, icon, 4 .py samples) return 200.
- **Session 3 (next)**: background service worker (`pages/popup.py` + `pages/background.py` python port if still pending) and `manifest.json` background.scripts wiring.
