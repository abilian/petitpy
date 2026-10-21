# nanopython — browser demos

A self-contained in-browser gallery of thirteen demos for [nanopython](../) (a Zig/C strangler of MicroPython). The interpreter is compiled to `wasm32-wasi` and run via [`@bjorn3/browser_wasi_shim`](https://github.com/bjorn3/browser_wasi_shim) loaded from a CDN.

The demos live as siblings under `web/`: `playground/` (the rich Python REPL with examples, package fetcher, stdin pane, and Save/Share), `snippets/`, `validation/`, `dashboard/`, `simulation/`, `life/`, `markdown/`, `snake/`, `reaction-diffusion/`, `todo/`, `pomodoro/`, `calculator/`, `color/`. The single shared `web/nanopython.wasm` is fetched relatively (`../nanopython.wasm`) from each demo.

## How to run locally

Browsers refuse to load `.wasm` over `file://`, so any local HTTP server works. From the repo root:

```sh
python3 -m http.server -d web 8000
```

Then open <http://localhost:8000/> in your browser for the demo gallery; <http://localhost:8000/playground/> opens the rich playground directly.

There is also a `make web` shortcut at the repo root that rebuilds the wasm and prints the same command.

## What's in the UI

- **Examples dropdown** — pick a canned sample (fibonacci, fizzbuzz, quicksort, closures, generators, walrus, and an `input()` echo demo that uses stdin).
- **Saved scripts** — name your code in the text field, click **Save**, and it lives in `localStorage` under the key `nanopython:scripts:v1`. Pick from the dropdown to reload. **Delete** removes the selected script.
- **Share** — encodes the source into the URL fragment (`#code=<base64url>`) and copies the URL to the clipboard. Open the URL elsewhere and the textarea populates from the fragment on page load.
- **Packages pane** — space- or newline-separated list of micropython-lib package names that aren't in the frozen-tiny core (`json`, `types`, `__future__`, `_thread`). On Run, each is fetched from `micropython.org/pi/v2` and mounted at `/lib/...` inside the wasm. The cache indicator under the pane shows what's persisted in IndexedDB. **Clear cache** wipes the IndexedDB store.
- **stdin pane** — anything you type here is piped to fd 0. `input()` reads it line by line; `sys.stdin.read()` would read all of it (when supported by the runtime).
- **Run** — instantiates the wasm fresh on each click. The exit code shows in the status line.

### Lazy-fetching packages (ADR-003 L4)

Type a non-frozen package name (e.g. `abc`) into the Packages pane, then in the Python textarea write `import abc; print(abc.ABC)` and click Run.

- First Run: the JS shim fetches `index.json` + the package's `package.json` + every referenced file from `micropython.org/pi/v2`, stores them in IndexedDB (object store `packages`, db `nanopython-cache`), and mounts them at `/lib/<file-path>` inside the WASI preopen. A short preamble injects `sys.path.insert(0, "/lib")` so nanopython's L1 filesystem importer finds them.
- Subsequent runs (same page session or after a reload): the package is in IndexedDB → instant cache hit, no network.
- Cache key format: `nanopython:<runtime>:<package>@<version>`. LRU eviction kicks in at a 10 MB total cap.
- Open DevTools → Application → IndexedDB → `nanopython-cache` → `packages` to inspect what's stored.

## How it works

- `web/nanopython.wasm` is a ReleaseSmall build (`zig build -Dtarget=wasm32-wasi -Dconfig=nano -Doptimize=ReleaseSmall`), ~290 KB.
- `web/app.js` fetches the wasm, sets up a virtual filesystem with a single preopened root containing `source.py` (filled from the textarea), wires stdin as an `OpenFile` over the stdin-textarea bytes, passes `argv = ["nanopython", "/source.py"]`, and instantiates the module.
- `web/examples.js` ships the example library inline so the static drop has no dependency on the `examples/` directory.
- WASI calls (`fd_read`, `fd_write`, `args_get`, `path_open`, …) are answered by the browser_wasi_shim. stdout/stderr writes land in a JavaScript buffer rendered into the `<pre>` element; `fd_read` on fd 0 pulls from the stdin textarea.

## Rebuilding the wasm

```sh
# from the repo root
zig build -Dtarget=wasm32-wasi -Dconfig=nano -Doptimize=ReleaseSmall
cp zig-out/bin/nanopython.wasm web/nanopython.wasm
```

Or just `make web`.

## Deploying as static files

The whole site is the contents of `web/`: a gallery (`index.html`, `shared.css`, `nanopython.wasm`) plus the sibling demo directories (`playground/`, `snippets/`, `validation/`, `dashboard/`, `simulation/`, `life/`, `markdown/`, `snake/`, `reaction-diffusion/`, `todo/`, `pomodoro/`, `calculator/`, `color/`). Any static host that serves `.wasm` with `Content-Type: application/wasm` works.

### SourceHut (pages.sr.ht)

```sh
# one-shot upload from the repo root:
tar -C web -czf nanopython-web.tar.gz .
hut pages publish -d nanopython.pages.sr.ht nanopython-web.tar.gz
```

### Codeberg Pages / GitHub Pages

Both publish a branch's contents. Mirror `web/` into a `pages` (Codeberg) or `gh-pages` (GitHub) orphan branch — or, for GitHub, point Settings → Pages → Source at `main` / folder `/web`.

## Limits

This is a demo, not a sandbox. It runs with the full nano corpus capability (no `import time` / `import os` beyond what nano ships).

Long-running scripts lock the main thread — refresh the page to abort. Moving wasm execution to a Web Worker is on the v0.5 roadmap.

## Files

- `index.html` — gallery (cards for the thirteen demos)
- `shared.css` — palette + components shared across demos
- `nanopython.wasm` — the interpreter (build product; rebuild with `make web`)
- `playground/` — the main demo: textarea + examples dropdown + package fetcher + stdin + Save/Share. `index.html`, `app.js`, `examples.js`, `zpip-browser.js`.
- `snippets/` — a simpler tour: eight pre-baked Python snippets. `index.html`, `app.js`.
- `validation/` — form fields run `validators.py` on blur. `index.html`, `app.js`, `runner.py`, `validators.py`.
- `dashboard/` — Python aggregates sales rows and draws every Canvas chart through the ADR-006 `js` bridge; JS only boots wasm. `index.html`, `app.js`, `main.py`.
- `simulation/` — Lotka-Volterra trajectory, animated. `index.html`, `app.js`, `simulation.py`.
- `life/` — Conway's Game of Life on a 60&times;40 torus, painted from Python through the `js` bridge. `index.html`, `app.js`, `main.py`.
- `markdown/` — live Markdown preview: each keystroke runs `main.py`, which parses and writes HTML straight to the DOM. `index.html`, `app.js`, `main.py`.
- `snake/` — classic Snake on a 20&times;20 grid; Python owns state, draws each frame, and reads keys via the `js` bridge. `index.html`, `app.js`, `main.py`.
- `reaction-diffusion/` — Gray-Scott solver on an 80&times;80 grid, Q-scaled integer math (no floats in nano). `index.html`, `app.js`, `main.py`.
- `todo/` — TodoMVC-style list with `localStorage` persistence; Python owns the model and renders rows through the `js` bridge with event delegation. `index.html`, `app.js`, `main.py`.
- `pomodoro/` — 25/5/15 work-break timer; Python runs the state machine, JS ticks `setInterval` back into `main.py` once a second. `index.html`, `app.js`, `main.py`.
- `calculator/` — integer four-function calculator; Python drives the state machine, button clicks and keystrokes feed the same handler. `index.html`, `app.js`, `main.py`.
- `color/` — linked HSL/RGB sliders with hex output; Python converts HSL&harr;RGB on every slider event and paints the swatch. `index.html`, `app.js`, `main.py`.
