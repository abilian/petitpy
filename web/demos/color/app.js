// Color picker — one wasm instance per page load. main.py wires the
// HSL/RGB slider input handlers via the ADR-006 js bridge and exits;
// the instance stays alive for the lifetime of the page.
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
// Cache-buster on both fetches — stale wasm with old frozen bytecode
// has masqueraded as a Python-side bug before.
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
  setStatus("Drag any slider: HSL and RGB stay linked.", "ok");
} catch (e) {
  setStatus(`host error: ${e?.message ?? e}`, "err");
}
