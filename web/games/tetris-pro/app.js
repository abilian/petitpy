// Generic loader — fetches nanopy.py + main.py, mounts both, installs
// one keydown shim. Identical to web/2048-lite/app.js; will move to
// web/lib/demo-loader.js once we have more than two consumers.

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

  // Generic key dispatch — calls window["__np_key_<key>"] for whichever
  // key was pressed. nanopy registers wrappers there (either via the
  // @on_key decorator or the on_press loop helper).
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
