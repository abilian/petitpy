// 2048-lite — spike loader for the cognitive-simplicity refactor.
//
// Differences from web/2048/app.js:
//   1. Fetches nanopy.py + main.py and mounts BOTH in the WASI preopen
//      so `from nanopy import ...` resolves.
//   2. After main.py runs, reads `window.__np_key_map` (an object whose
//      keys are JS event.key values and whose values are names of
//      window-level callbacks the `@on_key` decorator registered).
//      The keydown handler is the same length as before — but it's
//      generic, not per-game.
//
// The eventual home for this shim is `web/lib/demo-loader.js`
// (Tier 1 #1 in notes/07-js-vs-nanopython-games.md).

import {
  WASI,
  File,
  OpenFile,
  PreopenDirectory,
  ConsoleStdout,
} from "https://cdn.jsdelivr.net/npm/@bjorn3/browser_wasi_shim@0.4.2/dist/index.js";
import { makeJsBridge } from "../../lib/js-bridge.js";

function rawConsoleFd(tag, sink) {
  const dec = new TextDecoder("utf-8", { fatal: false });
  return new ConsoleStdout((buffer) => {
    sink(tag, JSON.stringify(dec.decode(buffer, { stream: true })));
  });
}

const $status = document.getElementById("status");
function setStatus(text, kind = "") {
  $status.textContent = text;
  $status.classList.remove("err", "ok");
  if (kind) $status.classList.add(kind);
}

setStatus("Loading nanopython.wasm + nanopy.py + main.py…");
const _v = Date.now();
const [wasmResp, helperResp, mainResp] = await Promise.all([
  fetch(`../../nanopython.wasm?v=${_v}`, { cache: "no-store" }),
  fetch(`./nanopy.py?v=${_v}`, { cache: "no-store" }),
  fetch(`./main.py?v=${_v}`, { cache: "no-store" }),
]);
const wasmModule = await WebAssembly.compileStreaming(wasmResp);
const enc = new TextEncoder();
const helperBytes = enc.encode(await helperResp.text());
const mainBytes = enc.encode(await mainResp.text());

const fsMap = new Map();
fsMap.set("nanopy.py", new File(helperBytes, { readonly: true }));
fsMap.set("main.py", new File(mainBytes, { readonly: true }));
const fs = new PreopenDirectory("/", fsMap);

const stdinFd = new OpenFile(new File(enc.encode(""), { readonly: true }));
const stdoutFd = rawConsoleFd("[py]", (tag, t) => console.log(tag, t));
const stderrFd = rawConsoleFd("[stderr]", (tag, t) => console.error(tag, t));

const bridge = makeJsBridge();
const wasi = new WASI(["nanopython", "/main.py"], [], [stdinFd, stdoutFd, stderrFd, fs]);
try {
  const inst = await WebAssembly.instantiate(wasmModule, {
    wasi_snapshot_preview1: wasi.wasiImport,
    env: bridge.imports,
  });
  bridge.attachMemory(inst.exports.memory);
  bridge.attachExports(inst.exports);
  wasi.start(inst);

  // Generic key dispatch — the `@on_key("ArrowLeft")` decorator registers
  // its handler as `window.__np_key_ArrowLeft`. Same handler works for
  // every demo that uses the helper; no per-game key map in JS.
  window.addEventListener("keydown", (e) => {
    const cb = window["__np_key_" + e.key];
    if (typeof cb === "function") {
      cb();
      e.preventDefault();
    }
  });
} catch (e) {
  setStatus(`host error: ${e?.message ?? e}`, "err");
}
