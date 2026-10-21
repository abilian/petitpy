// Shared loader for the ci-build-monitor pages.
//
// Each page loader (popup-loader.js, options-loader.js, status-loader.js)
// imports `bootstrap(entryPath)` from this module and calls it once with
// its own entry-point path under /src/. This module:
//
//   1. Fetches nanopython.wasm + every Python source under src/ (the list
//      is hard-coded — porting the directory walk into the browser would
//      add nothing for a fixed source tree).
//   2. Mounts every file flat under a PreopenDirectory at /src, so
//      `import providers_base` etc. resolve against /src on the wasi fs.
//   3. Wires the ADR-006 js bridge so Python code can reach DOM / chrome
//      globals via the `js` module.
//
// Layout note: nanopython's import machinery is flat-only (no packages,
// no dotted module names — see src/runtime/import_search.zig). The source
// tree is therefore flattened: what was `providers/base.py` is now
// `providers_base.py`, imported as `from providers_base import ...`.
//
// Cache-busting: every fetch uses `?v=<Date.now()>` + cache:"no-store"
// to defeat aggressive browser caching during dev (a stale .py masquerades
// as a runtime bug; see web/validation/app.js for the precedent).

import {
  WASI,
  File,
  OpenFile,
  PreopenDirectory,
  ConsoleStdout,
} from "https://cdn.jsdelivr.net/npm/@bjorn3/browser_wasi_shim@0.4.2/dist/index.js";
import { makeJsBridge } from "../wasm/js-bridge.js";

// Hard-coded source manifest. Order does not matter — the wasi fs just
// needs every file present before main runs.
const SRC_PATHS = [
  "json.py",
  "core_utils.py",
  "ui_dom.py",
  "ui_formatters.py",
  "ui_badges.py",
  "ui_repo_helpers.py",
  "services_storage.py",
  "services_notifications.py",
  "providers_base.py",
  "providers_github.py",
  "providers_gitlab.py",
  "providers_sourcehut.py",
  "pages_popup.py",
  "pages_options.py",
  "pages_status.py",
  "pages_background.py",
];

// Raw-byte console fd: flush on every fd_write so a partial Python
// traceback surfaces immediately, instead of disappearing in a
// line-buffered ConsoleStdout. (Borrowed from web/validation/app.js.)
function rawConsoleFd(tag, sink) {
  const dec = new TextDecoder("utf-8", { fatal: false });
  return new ConsoleStdout((buffer) => {
    sink(tag, JSON.stringify(dec.decode(buffer, { stream: true })));
  });
}

export async function bootstrap(entryPath) {
  const v = Date.now();

  // Fetch the wasm + every .py in parallel.
  const wasmResp = await fetch(`../wasm/nanopython.wasm?v=${v}`, { cache: "no-store" });
  const pyResps = await Promise.all(
    SRC_PATHS.map((p) =>
      fetch(`../src/${p}?v=${v}`, { cache: "no-store" }).then(async (r) => [p, await r.text()]),
    ),
  );

  const wasmModule = await WebAssembly.compileStreaming(wasmResp);
  const enc = new TextEncoder();

  // Wrap every Python source as a wasi File mounted flat under /src.
  // The layout is intentionally flat (see header) — every path is just
  // "<name>.py" with no nested directories.
  const srcEntries = new Map();
  for (const [path, text] of pyResps) {
    srcEntries.set(path, new File(enc.encode(text), { readonly: true }));
  }
  const srcDir = new PreopenDirectory("/src", srcEntries);

  const stdinFd = new OpenFile(new File(enc.encode(""), { readonly: true }));
  const stdoutFd = rawConsoleFd("[py]", (tag, t) => console.log(tag, t));
  const stderrFd = rawConsoleFd("[stderr]", (tag, t) => console.error(tag, t));

  const bridge = makeJsBridge();
  const wasi = new WASI(
    ["nanopython", entryPath],
    ["PETITPY_LIB=/src"],
    [stdinFd, stdoutFd, stderrFd, srcDir],
  );

  const inst = await WebAssembly.instantiate(wasmModule, {
    wasi_snapshot_preview1: wasi.wasiImport,
    env: bridge.imports,
  });
  bridge.attachMemory(inst.exports.memory);
  bridge.attachExports(inst.exports);
  wasi.start(inst);
}
