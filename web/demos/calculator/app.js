// Calculator demo — persistent wasm + bridge callbacks.
//
// Same J5b shape as the other demos: one wasm instance per page load.
// main.py owns the calculator state machine and registers a zero-arg
// dispatcher per key (digits, ops, =, C, CE, +/-, DEL). The JS side
// only boots the wasm and routes button clicks + keydown events into
// the matching Python callback. The bridge currently drops callback
// args (no malloc/free exports), so we cannot read `event.key` from a
// Python keydown handler — hence the per-key dispatch table below.
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

setStatus("Loading nanopython.wasm + main.py…");
// Cache-buster — stale wasm or main.py masquerades as a runtime bug.
const _v = Date.now();
const [wasmResp, mainResp] = await Promise.all([
  fetch(`../../nanopython.wasm?v=${_v}`, { cache: "no-store" }),
  fetch(`./main.py?v=${_v}`, { cache: "no-store" }),
]);
const wasmModule = await WebAssembly.compileStreaming(wasmResp);
const enc = new TextEncoder();
const mainBytes = enc.encode(await mainResp.text());

const fsMap = new Map();
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

  // Map a logical key name (matching data-key on the buttons) to the
  // window-level Python callback name installed by main.py.
  function press(key) {
    const cb = window["__calc_" + key];
    if (cb) cb();
  }

  // Click handlers — delegated via the .pad container.
  const pad = document.getElementById("pad");
  pad.addEventListener("click", (e) => {
    const btn = e.target.closest("button[data-key]");
    if (!btn) return;
    press(btn.dataset.key);
  });

  // Keyboard handlers.
  window.addEventListener("keydown", (e) => {
    const k = e.key;
    let key = null;
    if (k >= "0" && k <= "9") key = k;
    else if (k === "+" || k === "-" || k === "*" || k === "/") key = k;
    else if (k === "=" || k === "Enter") key = "=";
    else if (k === "Escape") key = "C";
    else if (k === "Backspace") key = "DEL";
    if (key !== null) {
      press(key);
      e.preventDefault();
    }
  });
} catch (e) {
  setStatus(`host error: ${e?.message ?? e}`, "err");
}
