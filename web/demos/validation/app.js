// Validation demo — J5b: persistent wasm + bridge callbacks.
//
// The wasm instance is started ONCE on page load. main.py registers
// per-field blur handlers and the "Validate" click handler via the
// ADR-006 js bridge; from then on the page lifetime owns the instance
// and JS-side events fire straight into Python. There is no per-click
// wasm boot, no JS click handler — the button itself is wired by
// Python.
import {
  WASI,
  File,
  OpenFile,
  PreopenDirectory,
  ConsoleStdout,
} from "https://cdn.jsdelivr.net/npm/@bjorn3/browser_wasi_shim@0.4.2/dist/index.js";
import { makeJsBridge } from "../../lib/js-bridge.js";

// Raw-byte console fd: flush on every fd_write so a partial Python traceback
// (e.g. "Traceback (most recen…" buffered before a trap) surfaces immediately,
// instead of disappearing in a line-buffered ConsoleStdout. The buffer arg is
// the raw bytes written by the wasm guest; we JSON.stringify so partial lines
// and embedded escapes are visible in devtools.
function rawConsoleFd(tag, sink) {
  const dec = new TextDecoder("utf-8", { fatal: false });
  return new ConsoleStdout((buffer) => {
    sink(tag, JSON.stringify(dec.decode(buffer, { stream: true })));
  });
}

const $status = document.getElementById("status");
const $btn = document.getElementById("validate-btn");

function setStatus(text, kind = "") {
  $status.textContent = text;
  $status.classList.remove("err", "ok");
  if (kind) $status.classList.add(kind);
}

setStatus("Loading nanopython.wasm + main.py…");
// Cache-buster on both the wasm and main.py — browsers cache aggressively and
// a stale wasm with old js.py bytecode masquerades as a Python-side bug.
const _v = Date.now();
const [wasmResp, mainResp] = await Promise.all([
  fetch(`../../nanopython.wasm?v=${_v}`, { cache: "no-store" }),
  fetch(`./main.py?v=${_v}`, { cache: "no-store" }),
]);
const wasmModule = await WebAssembly.compileStreaming(wasmResp);
const enc = new TextEncoder();
const mainBytes = enc.encode(await mainResp.text());

// J5b — boot the wasm instance ONCE on page load. main.py wires the DOM
// event handlers (blur + click) and returns; the instance stays alive
// because the bridge JS retains `wasmExports`, so the callbacks remain
// callable for the rest of the page lifetime.
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
  setStatus("Fill in the form — fields validate on blur, or click Validate.", "ok");
  $btn.disabled = false;
} catch (e) {
  setStatus(`host error: ${e?.message ?? e}`, "err");
}
