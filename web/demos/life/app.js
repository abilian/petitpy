// Game of Life demo — persistent wasm + js bridge.
//
// JS boots the wasm instance, exposes the bridge, and (see below) handles
// the canvas mousedown/mousemove/mouseup wrapping for cell painting.
// main.py owns the grid, the rule engine, the canvas rendering, and the
// setInterval loop. After main.py returns the wasm stays alive because
// the bridge JS retains `wasmExports`, so the Python event handlers keep
// firing for the lifetime of the page.
//
// Mouse paint: the JS bridge currently drops callback args when wasm has
// no malloc/free exports (see web/lib/js-bridge.js). A Python
// mousedown handler attached via addEventListener therefore receives no
// event object. Workaround: Python publishes a 0-arg `window._py_paint`,
// and the listeners below stash the canvas-relative coords on
// `window._paintX`/`_paintY` before invoking it.
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

setStatus("Loading petitpy.wasm + main.py…");
// Cache-buster — stale wasm or main.py masquerades as a runtime bug.
const _v = Date.now();
const [wasmResp, mainResp] = await Promise.all([
  fetch(`../../petitpy.wasm?v=${_v}`, { cache: "no-store" }),
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
const wasi = new WASI(["petitpy", "/main.py"], [], [stdinFd, stdoutFd, stderrFd, fs]);
try {
  const inst = await WebAssembly.instantiate(wasmModule, {
    wasi_snapshot_preview1: wasi.wasiImport,
    env: bridge.imports,
  });
  bridge.attachMemory(inst.exports.memory);
  bridge.attachExports(inst.exports);
  wasi.start(inst);
  // main.py overwrites #status when it is ready; if we got here without a
  // trap the page is interactive.

  // Mouse paint dispatch — see header comment. main.py has installed
  // window._py_paint by the time wasi.start() returns.
  const canvas = document.getElementById("life-canvas");
  let painting = false;
  function setCoords(e) {
    const rect = canvas.getBoundingClientRect();
    window._paintX = Math.floor(e.clientX - rect.left);
    window._paintY = Math.floor(e.clientY - rect.top);
  }
  canvas.addEventListener("mousedown", (e) => {
    painting = true;
    setCoords(e);
    if (window._py_paint) window._py_paint();
  });
  canvas.addEventListener("mousemove", (e) => {
    if (!painting) return;
    setCoords(e);
    if (window._py_paint) window._py_paint();
  });
  canvas.addEventListener("mouseup", () => {
    painting = false;
  });
  canvas.addEventListener("mouseleave", () => {
    painting = false;
  });
} catch (e) {
  setStatus(`host error: ${e?.message ?? e}`, "err");
}
