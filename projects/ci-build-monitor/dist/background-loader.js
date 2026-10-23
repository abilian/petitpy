// background-loader.js — Chrome MV3 service worker entry-point.
//
// This is the wasm-aware service worker that boots petitpy and runs
// pages_background.py to register the chrome.alarms / chrome.notifications
// / chrome.runtime.onMessage event handlers that drive the extension.
//
// Service-worker constraints (Chrome MV3):
//   1. No DOM / no `window` / no `document` — pages_background.py only
//      uses `js.console`, `js.get("Date")`, `js.get("Promise")`, and the
//      `chrome.*` API, all of which exist on `globalThis` in a SW. Good.
//   2. ES module imports work when manifest declares `"type": "module"`
//      under `background.service_worker`. We rely on that to import the
//      bjorn3 wasi shim from jsdelivr (same as bootstrap.js).
//   3. `WebAssembly.compileStreaming` works in SWs. `fetch` resolves
//      relative URLs against the extension root (`chrome.runtime.getURL`).
//   4. The chrome-shim.js is NOT loaded here — in a SW, `chrome.*` IS the
//      real API. The shim is only for the standalone-web (`make serve`)
//      mode loaded by popup.html / options.html / status.html.
//
// Differences vs bootstrap.js:
//   - No cache-buster — chrome reloads the SW from disk on extension
//     reload, and HTTP-style caching does not apply to chrome-extension://
//     URLs.
//   - Paths are resolved via `chrome.runtime.getURL("...")` so they work
//     no matter where the SW is registered from inside the extension.
//   - Only pages_background.py needs to run, but we mount the full /src
//     tree so future cross-imports keep working.
//   - The wasi shim is imported from a VENDORED local copy under
//     `dist/vendor/wasi-shim/`, not from jsdelivr. Chrome MV3 service
//     workers cannot import remote ES modules — only same-origin
//     (chrome-extension://) modules are allowed. The popup/options/status
//     pages still import from jsdelivr because page CSP is more
//     permissive than SW CSP.

import {
  WASI,
  File,
  OpenFile,
  PreopenDirectory,
  ConsoleStdout,
} from "./vendor/wasi-shim/index.js";
import { makeJsBridge } from "../wasm/js-bridge.js";

const SRC_PATHS = [
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

function rawConsoleFd(tag, sink) {
  const dec = new TextDecoder("utf-8", { fatal: false });
  return new ConsoleStdout((buffer) => {
    sink(tag, JSON.stringify(dec.decode(buffer, { stream: true })));
  });
}

// `chrome.runtime.getURL` is the canonical way to resolve a path inside
// the extension package — works regardless of where the SW was registered.
function extUrl(path) {
  return chrome.runtime.getURL(path);
}

async function bootBackground() {
  const wasmResp = await fetch(extUrl("wasm/petitpy.wasm"));
  const pyResps = await Promise.all(
    SRC_PATHS.map((p) =>
      fetch(extUrl(`src/${p}`)).then(async (r) => [p, await r.text()]),
    ),
  );

  const wasmModule = await WebAssembly.compileStreaming(wasmResp);
  const enc = new TextEncoder();

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
    ["petitpy", "/src/pages_background.py"],
    ["PETITPY_LIB=/src"],
    [stdinFd, stdoutFd, stderrFd, srcDir],
  );

  const inst = await WebAssembly.instantiate(wasmModule, {
    wasi_snapshot_preview1: wasi.wasiImport,
    env: bridge.imports,
  });
  bridge.attachMemory(inst.exports.memory);
  bridge.attachExports(inst.exports);

  // wasi.start() runs the Python entry-point and returns. pages_background.py
  // registers chrome.alarms.onAlarm / chrome.notifications.onClicked /
  // chrome.storage.onChanged / chrome.runtime.onMessage listeners during
  // its module-level `init()` call. Those listeners hold references back
  // into the wasm instance via the J5 callback bridge; as long as the SW
  // stays alive (chrome wakes it on each event), the bridge can dispatch
  // the registered Python callbacks.
  wasi.start(inst);
  console.log("[background-loader] pages_background.py initialized");
}

// Chrome MV3 service workers fire `install` once when first registered
// and `activate` when they take control. We boot on the top-level module
// load — that's the SW startup phase, equivalent to the old persistent
// background page's top-of-file. Errors here are unrecoverable: the SW
// will simply log and remain inert until the next event wakes it.
bootBackground().catch((err) => {
  console.error("[background-loader] boot failed:", err);
});
