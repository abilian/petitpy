// Playground demo — run preset Python snippets in nanopython.wasm.
//
// This is a leaner cousin of the top-level web/app.js: no Packages pane, no
// localStorage, no share URLs. The point is to showcase the example library
// ported from Prescrypt's python-playground demo. The original needed a
// server-side compile (it transpiled Python to JavaScript); ours runs the
// nanopython interpreter directly in WebAssembly, so there's no server at all.

import {
  WASI,
  File,
  OpenFile,
  PreopenDirectory,
  ConsoleStdout,
} from "https://cdn.jsdelivr.net/npm/@bjorn3/browser_wasi_shim@0.4.2/dist/index.js";

import { EXAMPLES } from "./examples.js";
import { makeJsBridge } from "../../lib/js-bridge.js";

const $editor = document.getElementById("code-editor");
const $output = document.getElementById("output");
const $run = document.getElementById("run-btn");
const $status = document.getElementById("status");
const $list = document.getElementById("examples");

let wasmModule = null;

function setStatus(text, kind = "") {
  $status.textContent = text;
  $status.classList.remove("err", "ok");
  if (kind) $status.classList.add(kind);
}

async function loadWasm() {
  setStatus("Loading nanopython.wasm…");
  // Cache-buster on wasm so dev iteration always picks up a fresh build.
  const _v = Date.now();
  const resp = await fetch(`../../nanopython.wasm?v=${_v}`, { cache: "no-store" });
  if (!resp.ok) throw new Error(`fetch failed: ${resp.status}`);
  wasmModule = await WebAssembly.compileStreaming(resp);
  setStatus("Ready.", "ok");
  $run.disabled = false;
  $run.textContent = "Run";
}

async function runPython(source) {
  const enc = new TextEncoder();
  let buffer = "";
  const stdoutFd = ConsoleStdout.lineBuffered((line) => {
    buffer += line + "\n";
  });
  const stderrFd = ConsoleStdout.lineBuffered((line) => {
    buffer += line + "\n";
  });
  const stdinFd = new OpenFile(new File(enc.encode(""), { readonly: true }));

  const fsMap = new Map();
  fsMap.set("source.py", new File(enc.encode(source), { readonly: true }));
  const fs = new PreopenDirectory("/", fsMap);

  const wasi = new WASI(["nanopython", "/source.py"], [], [stdinFd, stdoutFd, stderrFd, fs]);

  // ADR-006 J3 — JS interop bridge. The wasm has env::js_* extern imports
  // (feature-js defaults to on for wasm builds), so the imports object must
  // include `env: bridge.imports` or instantiate fails. Bridge handles live
  // for the duration of one Run; recreated each click since each snippet
  // runs in a fresh wasm instance.
  const jsBridge = makeJsBridge();

  let exitCode = 0;
  try {
    const inst = await WebAssembly.instantiate(wasmModule, {
      wasi_snapshot_preview1: wasi.wasiImport,
      env: jsBridge.imports,
    });
    jsBridge.attachMemory(inst.exports.memory);
    jsBridge.attachExports(inst.exports);
    exitCode = wasi.start(inst);
  } catch (e) {
    buffer += `\n[host error] ${e?.message ?? e}\n`;
    exitCode = -1;
  }
  return { output: buffer, exitCode };
}

function selectExample(example) {
  $editor.value = example.code;
  for (const b of document.querySelectorAll(".example-btn")) {
    b.classList.toggle("active", b.dataset.example === example.name);
  }
  $output.textContent = '(Click "Run" to execute)';
  $output.className = "output empty";
}

async function onRun() {
  if (!wasmModule) return;
  $run.disabled = true;
  $output.textContent = "Running…";
  $output.className = "output empty";
  setStatus("Running…");

  const { output, exitCode } = await runPython($editor.value);
  if (output) {
    $output.textContent = output;
    $output.className = exitCode === 0 ? "output" : "output error";
  } else {
    $output.textContent = "(no output)";
    $output.className = "output empty";
  }
  setStatus(
    exitCode === 0 ? "Finished (exit 0)." : `Finished (exit ${exitCode}).`,
    exitCode === 0 ? "ok" : "err",
  );
  $run.disabled = false;
}

function populateExamples() {
  for (const example of EXAMPLES) {
    const li = document.createElement("li");
    const btn = document.createElement("button");
    btn.textContent = example.title;
    btn.className = "example-btn";
    btn.dataset.example = example.name;
    btn.addEventListener("click", () => selectExample(example));
    li.appendChild(btn);
    $list.appendChild(li);
  }
}

$run.addEventListener("click", onRun);

$editor.addEventListener("keydown", (e) => {
  if ((e.ctrlKey || e.metaKey) && e.key === "Enter") {
    e.preventDefault();
    onRun();
  }
});

populateExamples();
selectExample(EXAMPLES[0]);
loadWasm().catch((e) => setStatus(`Load failed: ${e.message}`, "err"));
