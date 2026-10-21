// petitpy for the browser and Node: run Python source on the wasm build.
//
//   import { loadPetitpy } from "petitpy";
//   const py = await loadPetitpy();
//   const { stdout, stderr, exitCode } = await py.run('print("hello")');
//
// Each run gets a fresh instance of the compiled module, over a virtual
// filesystem holding the program at /main.py and any `files` you pass
// (put modules under "lib/" to import them). The instance stays alive
// after run() returns, so a program that registers JS callbacks (DOM
// events, timers through the `js` module) keeps running; their output
// goes to onStdout / onStderr.

import { WASI, File, Directory, OpenFile, PreopenDirectory, ConsoleStdout } from "@bjorn3/browser_wasi_shim";
import { makeJsBridge } from "./js-bridge.js";
import { addFile } from "./wasi-fs.js";

const DEFAULT_WASM = new URL("./petitpy.wasm", import.meta.url);


async function compile(wasm) {
  if (wasm instanceof WebAssembly.Module) return wasm;
  if (wasm instanceof ArrayBuffer || ArrayBuffer.isView(wasm)) return WebAssembly.compile(wasm);
  const resp = wasm instanceof Response ? wasm : await fetch(wasm);
  if (!resp.ok) throw new Error(`petitpy: fetching the wasm failed (${resp.status})`);
  return WebAssembly.compileStreaming
    ? WebAssembly.compileStreaming(resp)
    : WebAssembly.compile(await resp.arrayBuffer());
}

/**
 * Compile petitpy.wasm once; `wasm` is a URL, a Response, bytes or a
 * WebAssembly.Module (default: the file next to this module).
 */
export async function loadPetitpy({ wasm = DEFAULT_WASM } = {}) {
  const module = await compile(wasm);
  const encoder = new TextEncoder();

  async function run(source, { stdin = "", files = {}, argv = [], onStdout, onStderr } = {}) {
    let stdout = "";
    let stderr = "";
    const fsMap = new Map([["main.py", new File(encoder.encode(source), { readonly: true })]]);
    for (const [path, content] of Object.entries(files)) {
      const bytes = typeof content === "string" ? encoder.encode(content) : content;
      addFile(fsMap, path, new File(bytes, { readonly: true }), Directory);
    }
    const fds = [
      new OpenFile(new File(encoder.encode(stdin), { readonly: true })),
      ConsoleStdout.lineBuffered((line) => {
        stdout += line + "\n";
        onStdout?.(line);
      }),
      ConsoleStdout.lineBuffered((line) => {
        stderr += line + "\n";
        onStderr?.(line);
      }),
      new PreopenDirectory("/", fsMap),
    ];
    const wasi = new WASI(["petitpy", "/main.py", ...argv], ["PETITPY_LIB=/lib"], fds, { debug: false });
    const bridge = makeJsBridge();
    const instance = await WebAssembly.instantiate(module, {
      wasi_snapshot_preview1: wasi.wasiImport,
      env: bridge.imports,
    });
    bridge.attachMemory(instance.exports.memory);
    bridge.attachExports(instance.exports);
    const exitCode = wasi.start(instance);
    return { stdout, stderr, exitCode, instance };
  }

  return { module, run };
}
