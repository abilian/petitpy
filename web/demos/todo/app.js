// TodoMVC demo — persistent wasm + js bridge.
//
// JS boots the wasm instance once, exposes the bridge, then attaches a
// single delegated click handler on the <ul> that surfaces the clicked
// li's data-id + action ("toggle" / "delete") into Python via the
// globals-stash workaround (notes/03). Python owns the todo list, the
// filter state, the localStorage round-trip, and the DOM rendering.
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

  // Delegated click handler — single listener on the <ul>. Walks up from
  // e.target with .closest("li") so clicks on either the checkbox or the
  // delete button resolve to the same row. Stashes the row's data-id and
  // a small action tag on window before invoking the 0-arg
  // window._py_action; Python reads both globals and acts on them.
  const list = document.getElementById("list");
  list.addEventListener("click", (e) => {
    const li = e.target.closest("li");
    if (!li || !li.dataset.id) return;
    let action = null;
    if (e.target.matches("input[type=checkbox]")) action = "toggle";
    else if (e.target.matches(".delete")) action = "delete";
    if (!action) return;
    window._todoId = li.dataset.id;
    window._todoAction = action;
    if (window._py_action) window._py_action();
  });
} catch (e) {
  setStatus(`host error: ${e?.message ?? e}`, "err");
}
