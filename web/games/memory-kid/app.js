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
import { installKeydown, installClick, installAudio } from "../../lib/nanopy-host.js";

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

setStatus("Loading petitpy.wasm + nanopy.py + main.py…");
const _v = Date.now();
const [wasmResp, helperResp, mainResp] = await Promise.all([
  fetch(`../../petitpy.wasm?v=${_v}`, { cache: "no-store" }),
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
const wasi = new WASI(["petitpy", "/main.py"], [], [stdinFd, stdoutFd, stderrFd, fs]);
try {
  const inst = await WebAssembly.instantiate(wasmModule, {
    wasi_snapshot_preview1: wasi.wasiImport,
    env: bridge.imports,
  });
  bridge.attachMemory(inst.exports.memory);
  bridge.attachExports(inst.exports);
  wasi.start(inst);

  // Hosted helpers — keydown / click / audio dispatch live in
  // web/lib/nanopy-host.js so we don't repeat them per demo.
  installKeydown();
  installClick("board");
  installAudio();
} catch (e) {
  setStatus(`host error: ${e?.message ?? e}`, "err");
}
