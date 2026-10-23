// Loader for the js-bridge conformance page. Minimal by design: it boots the
// same web/petitpy.wasm the demos load, runs main.py, and gets out of the
// way. main.py writes its verdict into #out so `--assert-text` can gate it.
import {
  WASI,
  File,
  OpenFile,
  PreopenDirectory,
  ConsoleStdout,
} from "https://cdn.jsdelivr.net/npm/@bjorn3/browser_wasi_shim@0.4.2/dist/index.js";
import { makeJsBridge } from "../../lib/js-bridge.js";

const $out = document.getElementById("out");

function rawConsoleFd(tag, sink) {
  const dec = new TextDecoder("utf-8", { fatal: false });
  return new ConsoleStdout((buf) => sink(tag, dec.decode(buf, { stream: true })));
}

const _v = Date.now();
const [wasmResp, mainResp] = await Promise.all([
  fetch(`../../petitpy.wasm?v=${_v}`, { cache: "no-store" }),
  fetch(`./main.py?v=${_v}`, { cache: "no-store" }),
]);
const wasmModule = await WebAssembly.compileStreaming(wasmResp);
const enc = new TextEncoder();

const fsMap = new Map();
fsMap.set("main.py", new File(enc.encode(await mainResp.text()), { readonly: true }));
const fs = new PreopenDirectory("/", fsMap);

const bridge = makeJsBridge();
const wasi = new WASI(
  ["petitpy", "/main.py"],
  [],
  [
    new OpenFile(new File(enc.encode(""), { readonly: true })),
    rawConsoleFd("[py]", (t, s) => console.log(t, s)),
    rawConsoleFd("[stderr]", (t, s) => console.error(t, s)),
    fs,
  ],
);

try {
  const inst = await WebAssembly.instantiate(wasmModule, {
    wasi_snapshot_preview1: wasi.wasiImport,
    env: bridge.imports,
  });
  bridge.attachMemory(inst.exports.memory);
  bridge.attachExports(inst.exports);
  wasi.start(inst);
} catch (e) {
  // A host trap here means the instance died — main.py never wrote its
  // verdict, so the assert fails, which is the correct outcome.
  $out.textContent += `\nBRIDGE-CONFORMANCE: FAIL host error: ${e?.message ?? e}`;
}
