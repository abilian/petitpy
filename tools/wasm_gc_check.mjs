// wasm GC check (ADR 019 §5): drive the web build the way a browser page
// does — run main.py, then fire JS callbacks into Python — and check that
// collection at safe points (src/memory/gc.zig) keeps memory flat and
// leaves live state intact. Nothing else exercises wasm collection: the
// corpus and integration gates run single scripts, which never reach a
// safe point before they end.
//
// Usage: node tools/wasm_gc_check.mjs [web/petitpy.wasm]   (make wasm-gc-check)

import { closeSync, mkdtempSync, openSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { WASI } from "node:wasi";
import { makeJsBridge } from "../web/lib/js-bridge.js";

const wasmPath = process.argv[2] ?? new URL("../web/petitpy.wasm", import.meta.url).pathname;
const module = await WebAssembly.compile(readFileSync(wasmPath));

// Runs `source` as /main.py, fires `n` callbacks with id 1 and one with
// id 2; returns the program's stdout and the final wasm memory size.
async function run(source, n) {
  const dir = mkdtempSync(join(tmpdir(), "wasm-gc-check-"));
  const outPath = join(dir, "out.txt");
  writeFileSync(join(dir, "main.py"), source);
  writeFileSync(outPath, "");
  try {
    const out = openSync(outPath, "w");
    const wasi = new WASI({
      version: "preview1",
      args: ["petitpy", "/main.py"],
      preopens: { "/": dir },
      stdout: out,
      returnOnExit: true,
    });
    const bridge = makeJsBridge();
    const inst = await WebAssembly.instantiate(module, {
      wasi_snapshot_preview1: wasi.wasiImport,
      env: bridge.imports,
    });
    bridge.attachMemory(inst.exports.memory);
    bridge.attachExports(inst.exports);
    wasi.start(inst);
    for (let i = 0; i < n; i++) inst.exports.npy_dispatch_callback(1, 0, 0);
    inst.exports.npy_dispatch_callback(2, 0, 0);
    closeSync(out);
    return {
      stdout: readFileSync(outPath, "utf8"),
      memoryMB: inst.exports.memory.buffer.byteLength / 2 ** 20,
    };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

// Each callback drops ~400 KB. Without collection 2000 of them took
// 1362 MB; with it the heap stays at its first 1 MB area.
const GARBAGE = `
from _petitpy_js import _set_dispatcher
import gc

def d(cid, args):
    junk = [[i, str(i)] for i in range(3000)]
    if cid == 2:
        print("heap", gc.mem_alloc() + gc.mem_free())

_set_dispatcher(d)
`;

// State that must survive collections: a linked list of instances, a
// closure, a suspended generator, a list of strings, a bytearray; and
// gc.collect() called from inside callbacks (deferred to the safe point).
const STATE = `
from _petitpy_js import _set_dispatcher
import gc

class Node:
    def __init__(self, v, nxt):
        self.v = v
        self.nxt = nxt
    def total(self):
        t, n = 0, self
        while n is not None:
            t += n.v
            n = n.nxt
        return t

def counter():
    c = [0]
    def inc():
        c[0] += 1
        return c[0]
    return inc

state = {"head": None, "words": [], "inc": counter(), "gen": (i * i for i in range(10**9)), "calls": 0}
expect = {"total": 0, "square": 0}
big = bytearray(200000)

def d(cid, args):
    state["calls"] += 1
    k = state["calls"]
    if k % 3:
        state["head"] = Node(k, state["head"])
        expect["total"] += k
    state["words"].append(str(k) * (k % 7))
    if len(state["words"]) > 50:
        state["words"].pop(0)
    state["inc"]()
    expect["square"] = next(state["gen"])
    junk = [{"a": [i], "b": str(i)} for i in range(500)]
    big[k % len(big)] = k & 0xFF
    if k % 97 == 0:
        gc.collect()
    if cid == 2:
        print(state["head"].total() == expect["total"],
              state["inc"]() == k + 1,
              expect["square"] == (k - 1) ** 2,
              state["words"] == [str(j) * (j % 7) for j in range(k - 49, k + 1)],
              big[k % len(big)] == k & 0xFF)

_set_dispatcher(d)
`;

let failed = false;
function check(name, ok, detail) {
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}  ${detail}`);
  failed ||= !ok;
}

const garbage = await run(GARBAGE, 2000);
const heap = Number(/heap (\d+)/.exec(garbage.stdout)?.[1]);
check(
  "garbage is collected",
  heap > 0 && heap <= 4 * 2 ** 20 && garbage.memoryMB < 64,
  `heap ${(heap / 2 ** 20).toFixed(1)} MB, wasm memory ${garbage.memoryMB.toFixed(1)} MB after 2000 callbacks`,
);

const live = await run(STATE, 5000);
check(
  "live state survives",
  live.stdout.trim() === "True True True True True",
  `checks: ${live.stdout.trim() || "(no output)"}, wasm memory ${live.memoryMB.toFixed(1)} MB after 5000 callbacks`,
);

process.exit(failed ? 1 : 0);
