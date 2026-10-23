// petitpy as a long-lived interpreter for JavaScript, over
// petitpy-embed.wasm: the C embedding API (petitpy.h) built as a wasm
// module that is initialised once and then called.
//
//   import { loadInterpreter } from "petitpy/embed";
//   const py = await loadInterpreter();
//   py.define("host", "log", (msg) => console.log(msg));
//   py.exec("import host\ndef area(w, h):\n    return w * h");
//   py.call("area", 6, 7);           // 42
//   py.eval("[1, 'two', None]");     // [1, "two", null]
//
// None, bool, int, float, str, bytes, list, tuple and dict convert to
// JavaScript values and back (an int beyond 2**53 is a BigInt); any other
// Python object comes back as a PyObject, which keeps it alive until
// release() or until JavaScript collects the PyObject.

import {
  WASI,
  File,
  Directory,
  OpenFile,
  PreopenDirectory,
  ConsoleStdout,
} from "@bjorn3/browser_wasi_shim";
import { makeJsBridge } from "./js-bridge.js";
import { addFile } from "./wasi-fs.js";

const DEFAULT_WASM = new URL("./petitpy-embed.wasm", import.meta.url);
const OK = 0;
const EXIT = 2;
const encoder = new TextEncoder();
const decoder = new TextDecoder();

/** A Python exception, or SystemExit (type "SystemExit", with exitCode). */
export class PythonError extends Error {
  constructor(type, traceback, exception, exitCode) {
    super(traceback.trimEnd().split("\n").pop());
    this.name = "PythonError";
    this.type = type;
    this.traceback = traceback;
    this.exception = exception; // the exception object, as a PyObject
    this.exitCode = exitCode;
  }
}

/** A Python object that has no JavaScript counterpart. */
export class PyObject {
  constructor(interp, handle) {
    this.interp = interp;
    this.handle = handle;
    interp.registry.register(this, handle, this);
  }
  call(...args) {
    return this.interp.callHandle(this.handle, args);
  }
  get(name) {
    return this.interp.getattr(this.handle, name);
  }
  set(name, value) {
    this.interp.setattr(this.handle, name, value);
  }
  toString() {
    return this.interp.text(this.handle, "ppy_str");
  }
  repr() {
    return this.interp.text(this.handle, "ppy_repr");
  }
  release() {
    if (!this.handle) return;
    this.interp.registry.unregister(this);
    this.interp.e.ppy_release(this.interp.py, this.handle);
    this.handle = 0;
  }
}

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
 * Start an interpreter. `path` lists the directories of sys.path, `files`
 * fills the virtual filesystem (put modules under "lib/" and add "/lib" to
 * `path` to import them), and output goes line by line to onStdout and
 * onStderr (default: the console).
 */
export async function loadInterpreter({
  wasm = DEFAULT_WASM,
  path = [],
  argv = [],
  files = {},
  stdin = "",
  onStdout = (line) => console.log(line),
  onStderr = (line) => console.error(line),
} = {}) {
  const module = await compile(wasm);
  const root = new Map();
  for (const [name, content] of Object.entries(files)) {
    const bytes = typeof content === "string" ? encoder.encode(content) : content;
    addFile(root, name, new File(bytes, { readonly: true }), Directory);
  }
  const fds = [
    new OpenFile(new File(encoder.encode(stdin), { readonly: true })),
    ConsoleStdout.lineBuffered(onStdout),
    ConsoleStdout.lineBuffered(onStderr),
    new PreopenDirectory("/", root),
  ];
  const wasi = new WASI(["petitpy"], [], fds, { debug: false });
  const bridge = makeJsBridge();
  let interp;
  const instance = await WebAssembly.instantiate(module, {
    wasi_snapshot_preview1: wasi.wasiImport,
    env: { ...bridge.imports, ppy_js_call: (...a) => interp.hostCall(...a) },
  });
  bridge.attachMemory(instance.exports.memory);
  bridge.attachExports(instance.exports);
  wasi.initialize(instance);
  interp = new Interpreter(instance.exports, path, argv);
  return interp;
}

class Interpreter {
  constructor(e, path, argv) {
    this.e = e;
    this.hosts = [];
    this.registry = new FinalizationRegistry((h) => this.py && e.ppy_release(this.py, h));
    this.scratch = e.malloc(16); // output arguments
    const strings = [...path, ...argv].map((s) => this.cstr(s));
    const config = e.malloc(16);
    const lists = e.malloc(4 * strings.length + 4);
    strings.forEach((p, i) => this.view().setUint32(lists + 4 * i, p, true));
    const v = this.view();
    v.setUint32(config, lists, true);
    v.setUint32(config + 4, path.length, true);
    v.setUint32(config + 8, lists + 4 * path.length, true);
    v.setUint32(config + 12, argv.length, true);
    this.py = e.ppy_new(config);
    for (const p of [...strings, lists, config]) e.free(p);
    if (!this.py) throw new Error("petitpy: the interpreter could not start");
    const builtins = this.handleOf(e.ppy_import(this.py, this.cname("builtins"), this.scratch));
    this.listFn = this.attr(builtins, "list"); // kept for the life of the interpreter
    this.intFn = this.attr(builtins, "int");
    e.ppy_release(this.py, builtins);
  }

  // ── public ──────────────────────────────────────────────────────────

  /** Run source code in __main__. */
  exec(source, filename = "<string>") {
    const [p, n] = this.bytes(encoder.encode(source));
    const f = this.cstr(filename);
    const status = this.e.ppy_exec(this.py, p, n, f);
    this.e.free(p);
    this.e.free(f);
    this.check(status);
  }

  /** Evaluate an expression and return its value. */
  eval(source) {
    const [p, n] = this.bytes(encoder.encode(source));
    const status = this.e.ppy_eval(this.py, p, n, this.scratch);
    this.e.free(p);
    return this.take(this.handleOf(status));
  }

  /** Call a global of __main__ (by name) or a PyObject. */
  call(fn, ...args) {
    if (fn instanceof PyObject) return fn.call(...args);
    const f = this.handleOf(this.e.ppy_get_global(this.py, this.cname(fn), this.scratch));
    try {
      return this.callHandle(f, args);
    } finally {
      this.e.ppy_release(this.py, f);
    }
  }

  get(name) {
    return this.take(this.handleOf(this.e.ppy_get_global(this.py, this.cname(name), this.scratch)));
  }

  set(name, value) {
    this.withHandles([value], ([h]) =>
      this.check(this.e.ppy_set_global(this.py, this.cname(name), h)),
    );
  }

  import(name) {
    return new PyObject(
      this,
      this.handleOf(this.e.ppy_import(this.py, this.cname(name), this.scratch)),
    );
  }

  /** Make fn callable from Python as module.name. */
  define(module, name, fn) {
    this.hosts.push(fn);
    const m = this.cstr(module);
    const status = this.e.ppy_define_js_function(
      this.py,
      m,
      this.cname(name),
      this.hosts.length - 1,
    );
    this.e.free(m);
    this.check(status);
  }

  free() {
    this.e.ppy_free(this.py);
    this.py = 0;
  }

  // ── calls between the two sides ─────────────────────────────────────

  callHandle(f, args) {
    return this.withHandles(args, (hs) => this.take(this.invoke(f, hs)));
  }

  getattr(h, name) {
    return this.take(this.handleOf(this.e.ppy_getattr(this.py, h, this.cname(name), this.scratch)));
  }

  setattr(h, name, value) {
    this.withHandles([value], ([v]) =>
      this.check(this.e.ppy_setattr(this.py, h, this.cname(name), v)),
    );
  }

  // The env.ppy_js_call import: Python called a function from define().
  hostCall(id, py, argc, argv, result) {
    try {
      const args = [];
      for (let i = 0; i < argc; i++)
        args.push(this.borrow(this.view().getUint32(argv + 4 * i, true)));
      const value = this.hosts[id](...args);
      this.view().setUint32(result, value === undefined ? 0 : this.handleFor(value), true);
      return OK;
    } catch (err) {
      if (err instanceof PythonError && err.exception?.handle)
        return this.e.ppy_raise_exception(py, err.exception.handle);
      const type =
        err instanceof TypeError
          ? "TypeError"
          : err instanceof RangeError
            ? "ValueError"
            : "RuntimeError";
      const t = this.cstr(type);
      const m = this.cstr(String(err?.message ?? err));
      const status = this.e.ppy_raise(py, t, m);
      this.e.free(t);
      this.e.free(m);
      return status;
    }
  }

  // ── values ──────────────────────────────────────────────────────────

  /** A new handle to `value`, converted to Python; the caller releases it. */
  handleFor(value) {
    const e = this.e;
    const py = this.py;
    const out = this.scratch;
    if (value instanceof PyObject) return this.handleOf(e.ppy_dup(py, value.handle, out));
    if (value === null || value === undefined) return this.handleOf(e.ppy_new_none(py, out));
    switch (typeof value) {
      case "boolean":
        return this.handleOf(e.ppy_new_bool(py, value ? 1 : 0, out));
      case "number":
        return Number.isInteger(value) && Number.isSafeInteger(value)
          ? this.handleOf(e.ppy_new_int(py, BigInt(value), out))
          : this.handleOf(e.ppy_new_float(py, value, out));
      case "bigint":
        if (BigInt.asIntN(64, value) === value) return this.handleOf(e.ppy_new_int(py, value, out));
        return this.withHandles([String(value)], (hs) => this.invoke(this.intFn, hs));
      case "string": {
        const [p, n] = this.bytes(encoder.encode(value));
        const status = e.ppy_new_str(py, p, n, out);
        e.free(p);
        return this.handleOf(status);
      }
    }
    if (value instanceof Uint8Array) {
      const [p, n] = this.bytes(value);
      const status = e.ppy_new_bytes(py, p, n, out);
      e.free(p);
      return this.handleOf(status);
    }
    if (Array.isArray(value))
      return this.withHandles(value, (hs) => {
        const items = e.malloc(4 * hs.length + 4);
        hs.forEach((h, i) => this.view().setUint32(items + 4 * i, h, true));
        const status = e.ppy_new_list(py, hs.length, items, out);
        e.free(items);
        return this.handleOf(status);
      });
    if (value.constructor === Object || value instanceof Map) {
      const d = this.handleOf(e.ppy_new_dict(py, out));
      for (const [k, v] of value instanceof Map ? value : Object.entries(value))
        this.withHandles([k, v], ([kh, vh]) => this.check(e.ppy_setitem(py, d, kh, vh)));
      return d;
    }
    throw new TypeError(`petitpy: cannot pass ${Object.prototype.toString.call(value)} to Python`);
  }

  /** The JavaScript value of handle `h`, which this call releases. */
  take(h) {
    try {
      return this.borrow(h);
    } finally {
      this.e.ppy_release(this.py, h);
    }
  }

  /** The JavaScript value of `h`, which stays the caller's. */
  borrow(h) {
    const e = this.e;
    const py = this.py;
    const out = this.scratch;
    const type = this.cstring(e.ppy_type_name(py, h));
    switch (type) {
      case "NoneType":
        return null;
      case "bool":
        this.check(e.ppy_to_bool(py, h, out));
        return this.view().getUint8(out) !== 0;
      case "int": {
        let n;
        if (e.ppy_to_int(py, h, out) === OK) n = this.view().getBigInt64(out, true);
        else {
          this.dropError(); // wider than a machine word (32 bits here): go through its digits
          n = BigInt(this.text(h, "ppy_str"));
        }
        return n >= -Number.MAX_SAFE_INTEGER && n <= Number.MAX_SAFE_INTEGER ? Number(n) : n;
      }
      case "float":
        this.check(e.ppy_to_float(py, h, out));
        return this.view().getFloat64(out, true);
      case "str":
      case "bytes": {
        this.check(
          type === "str" ? e.ppy_to_str(py, h, out, out + 4) : e.ppy_to_bytes(py, h, out, out + 4),
        );
        const v = this.view();
        const bytes = new Uint8Array(
          e.memory.buffer,
          v.getUint32(out, true),
          v.getUint32(out + 4, true),
        );
        return type === "str" ? decoder.decode(bytes) : bytes.slice();
      }
      case "list":
      case "tuple":
        return this.items(h);
      case "dict": {
        const method = this.attr(h, "items");
        const view = this.invoke(method, []);
        this.e.ppy_release(this.py, method);
        let pairs;
        try {
          pairs = this.items(view);
        } finally {
          this.e.ppy_release(this.py, view);
        }
        return pairs.every(([k]) => typeof k === "string")
          ? Object.fromEntries(pairs)
          : new Map(pairs);
      }
    }
    return new PyObject(this, this.handleOf(e.ppy_dup(py, h, out)));
  }

  /** The items of the iterable `h`, converted. */
  items(h) {
    const e = this.e;
    const seq = this.invoke(this.listFn, [h]);
    try {
      this.check(e.ppy_len(this.py, seq, this.scratch));
      const n = this.view().getUint32(this.scratch, true);
      const result = [];
      for (let i = 0; i < n; i++) {
        const k = this.handleOf(e.ppy_new_int(this.py, BigInt(i), this.scratch));
        const status = e.ppy_getitem(this.py, seq, k, this.scratch);
        e.ppy_release(this.py, k);
        result.push(this.take(this.handleOf(status)));
      }
      return result;
    } finally {
      e.ppy_release(this.py, seq);
    }
  }

  // ── plumbing ────────────────────────────────────────────────────────

  view() {
    return new DataView(this.e.memory.buffer);
  }

  /** Throws for a failed status; otherwise nothing. */
  check(status) {
    if (status === OK) return;
    const e = this.e;
    const py = this.py;
    e.ppy_fetch_error(py, this.scratch);
    const exc = this.view().getUint32(this.scratch, true);
    const type = this.cstring(e.ppy_type_name(py, exc));
    e.ppy_format_exception(py, exc, this.scratch);
    const text = this.view().getUint32(this.scratch, true);
    const traceback = this.borrow(text);
    e.ppy_release(py, text);
    const exception = new PyObject(this, exc);
    throw new PythonError(
      type,
      traceback,
      exception,
      status === EXIT ? e.ppy_exit_code(py) : undefined,
    );
  }

  /** The handle a successful call wrote to the scratch slot. */
  handleOf(status) {
    this.check(status);
    return this.view().getUint32(this.scratch, true);
  }

  dropError() {
    this.e.ppy_fetch_error(this.py, this.scratch);
    this.e.ppy_release(this.py, this.view().getUint32(this.scratch, true));
  }

  attr(h, name) {
    return this.handleOf(this.e.ppy_getattr(this.py, h, this.cname(name), this.scratch));
  }

  /** f(*hs) for handles; returns the result's handle. */
  invoke(f, hs) {
    const argv = this.e.malloc(4 * hs.length + 4);
    hs.forEach((h, i) => this.view().setUint32(argv + 4 * i, h, true));
    const status = this.e.ppy_call(this.py, f, hs.length, argv, this.scratch);
    this.e.free(argv);
    return this.handleOf(status);
  }

  /** str(h) or repr(h), by the API function's name. */
  text(h, fn) {
    return this.take(this.handleOf(this.e[fn](this.py, h, this.scratch)));
  }

  /** Converts `values` to handles for the length of fn(handles). */
  withHandles(values, fn) {
    const hs = [];
    try {
      for (const v of values) hs.push(this.handleFor(v));
      return fn(hs);
    } finally {
      for (const h of hs) this.e.ppy_release(this.py, h);
    }
  }

  bytes(data) {
    const p = this.e.malloc(data.length + 1);
    new Uint8Array(this.e.memory.buffer, p, data.length).set(data);
    return [p, data.length];
  }

  cstr(s) {
    const data = encoder.encode(s);
    const p = this.e.malloc(data.length + 1);
    const mem = new Uint8Array(this.e.memory.buffer, p, data.length + 1);
    mem.set(data);
    mem[data.length] = 0;
    return p;
  }

  /** A NUL-terminated name, kept for the life of the interpreter (they repeat). */
  cname(s) {
    this.names ??= new Map();
    let p = this.names.get(s);
    if (p === undefined) this.names.set(s, (p = this.cstr(s)));
    return p;
  }

  cstring(p) {
    if (!p) return null;
    const mem = new Uint8Array(this.e.memory.buffer);
    let end = p;
    while (mem[end]) end++;
    return decoder.decode(mem.subarray(p, end));
  }
}
