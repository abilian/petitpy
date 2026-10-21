// Snake demo — persistent wasm + bridge callbacks.
//
// Same J5b shape as the other demos: one wasm instance per page load.
// main.py owns the snake state, draws every frame to <canvas id="board">
// through the js bridge, and runs the game tick via setInterval.
//
// Keyboard: the JS bridge currently drops callback args when the wasm has
// no malloc/free exports (see web/lib/js-bridge.js). So we can't read
// `event.key` from a Python keydown handler. Workaround: Python publishes
// 5 zero-arg callbacks on `window` (one per direction + restart), and the
// keydown listener below dispatches by key name. The mapping stays in JS;
// all game logic stays in Python.
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

  // After main.py has run, the 5 dispatch callbacks are installed on
  // window. Map keyboard input to them and prevent the page from
  // scrolling on arrow keys.
  window.addEventListener("keydown", (e) => {
    const k = e.key;
    let handled = true;
    if (k === "ArrowUp" || k === "w" || k === "W") window.__snakeUp?.();
    else if (k === "ArrowDown" || k === "s" || k === "S") window.__snakeDown?.();
    else if (k === "ArrowLeft" || k === "a" || k === "A") window.__snakeLeft?.();
    else if (k === "ArrowRight" || k === "d" || k === "D") window.__snakeRight?.();
    else if (k === "r" || k === "R") window.__snakeRestart?.();
    else handled = false;
    if (handled) e.preventDefault();
  });
} catch (e) {
  setStatus(`host error: ${e?.message ?? e}`, "err");
}
