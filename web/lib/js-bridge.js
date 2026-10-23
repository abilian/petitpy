// ADR-006 J3 — JS-side bridge.
//
// Maintains a handle table mapping wasm-side u32 IDs to JS object references.
// Provides the imports object that petitpy.wasm expects under the
// `petitpy_js` namespace alongside the WASI `wasi_snapshot_preview1`
// imports. The Zig side declares the externs in js_bridge.zig with the
// default `env` module-name convention; the playground loader merges them
// into both `env` and `petitpy_js` namespaces so either resolution
// path works depending on how the compiler emitted the wasm import.
//
// Handle 0 is reserved for null / undefined; allocation starts at 1.
//
// J4 — `this` binding for method calls. When `js_get_attr` resolves to a
// function value, we store a {receiver, fn} bound-method record in the
// handle table rather than the bare function. `js_call` then invokes via
// `fn.apply(receiver, ...)` so `document.getElementById("x")` (and any
// other method that depends on `this`) sees the correct receiver. Bare
// functions (e.g. `js.parseInt`) are still called without a `this`.

export function makeJsBridge() {
  const handles = new Map();
  let nextHandle = 1;

  // Pre-populate handle 0 with null/undefined so a fresh `js_get_global`
  // of a missing property returns 0 -> null (consistent with the Python
  // proxy's __str__ → "undefined" path).
  handles.set(0, null);

  function newHandle(value) {
    // Reuse handle 0 for null/undefined so cleanup doesn't have to
    // double-track them.
    if (value === null || value === undefined) return 0;
    const h = nextHandle++;
    handles.set(h, value);
    return h;
  }

  function newBoundMethod(receiver, fn) {
    const h = nextHandle++;
    handles.set(h, { __bound: true, receiver, fn });
    return h;
  }

  // Resolve a handle to the underlying JS value. Bound-method records
  // unwrap to their `fn` — callers that need to invoke with the receiver
  // (i.e. js_call) inspect the record directly; everywhere else (passing
  // as argument, set_attr, to_string) the JS-visible value is the fn.
  function valueOf(handle) {
    const v = handles.get(handle);
    if (v && typeof v === "object" && v.__bound === true) return v.fn;
    return v;
  }

  function readMemString(memory, ptr, len) {
    const bytes = new Uint8Array(memory.buffer, ptr, len);
    return new TextDecoder().decode(bytes);
  }

  let memory; // bound after WebAssembly.instantiate.
  let wasmExports; // bound after WebAssembly.instantiate (for export callbacks).

  const imports = {
    js_get_global(namePtr, nameLen) {
      const name = readMemString(memory, namePtr, nameLen);
      return newHandle(globalThis[name]);
    },
    js_get_attr(handle, namePtr, nameLen) {
      const obj = valueOf(handle);
      if (obj == null) return 0;
      const name = readMemString(memory, namePtr, nameLen);
      const v = obj[name];
      // Functions get remembered with their receiver so `this` is bound
      // correctly when called. Non-function values use a plain handle.
      if (typeof v === "function") return newBoundMethod(obj, v);
      return newHandle(v);
    },
    js_set_attr(handle, namePtr, nameLen, valueHandle) {
      const obj = valueOf(handle);
      if (obj == null) return;
      const name = readMemString(memory, namePtr, nameLen);
      obj[name] = valueOf(valueHandle);
    },
    js_call(handle, argsPtr, argsCount) {
      const entry = handles.get(handle);
      const argsView = new Uint32Array(memory.buffer, argsPtr, argsCount);
      const args = Array.from(argsView).map((h) => valueOf(h));
      if (entry && typeof entry === "object" && entry.__bound === true) {
        return newHandle(entry.fn.apply(entry.receiver, args));
      }
      if (typeof entry !== "function") {
        throw new Error(`js_call: handle ${handle} is not a function`);
      }
      return newHandle(entry(...args));
    },
    js_release(handle) {
      if (handle === 0) return;
      handles.delete(handle);
    },
    js_create_string(ptr, len) {
      return newHandle(readMemString(memory, ptr, len));
    },
    js_create_int(value) {
      return newHandle(value);
    },
    js_to_string_len(handle) {
      const s = String(valueOf(handle));
      return new TextEncoder().encode(s).length;
    },
    js_to_string(handle, outPtr, outMax) {
      const s = String(valueOf(handle));
      const bytes = new TextEncoder().encode(s);
      const len = Math.min(bytes.length, outMax);
      new Uint8Array(memory.buffer, outPtr, len).set(bytes.subarray(0, len));
      return len;
    },
    js_to_int(handle) {
      const v = valueOf(handle);
      return v | 0;
    },
    js_bridge_present() {
      return 1;
    },
    // J5a — Python registered a callable; mint a JS function that, when
    // called, fires npy_dispatch_callback(id, args_ptr, args_count) back
    // into wasm. The JS function's argument values are first allocated
    // as bridge handles, then their handles are spilled into wasm memory
    // as a u32 array on the wasm stack (via `__npy_alloc_arg_buf` if
    // available; otherwise we accept a hard limit and use a scratch
    // region from `npy_dispatch_alloc`/free pair). For the first cut
    // we use a static scratch slab in wasm memory exposed by the runtime
    // — but to keep the bridge JS self-contained we instead allocate a
    // small Uint32Array attached to the wasm linear memory via a fresh
    // `WebAssembly.Memory.grow`-free strategy: copy into a fixed offset
    // in the existing memory's data segment that's set aside by the
    // runtime. For now we cap at 8 args and use a JS-side TypedArray
    // backed by wasm memory at a runtime-provided scratch ptr. To avoid
    // the scratch-ptr lookup complexity for the J5a slice we use a
    // simpler shape: we allocate args by writing into the existing
    // bridge `handles` map and pass a synthetic ptr=0 with the args
    // count = 0 when there are no args. With args > 0 we write to a
    // freshly grown region. To stay simple, J5a supports zero-arg
    // callbacks (the common `addEventListener("click", py_fn)`
    // shape) — multi-arg event handlers will land with a Python-side
    // event marshaler in a follow-up.
    js_create_callback(callbackId) {
      const fn = function (...args) {
        if (!wasmExports || !wasmExports.npy_dispatch_callback) return undefined;
        // Marshal JS args to bridge handles first.
        const argHandles = args.map((a) => newHandle(a));
        let resultHandle;
        if (argHandles.length === 0) {
          resultHandle = wasmExports.npy_dispatch_callback(callbackId, 0, 0);
        } else {
          // Stage the handle array into wasm linear memory using the
          // MicroPython GC allocator (`m_malloc` is exported from the
          // runtime). We don't free — the allocation is a tiny u32[] per
          // dispatch and the runtime's GC reclaims it; trading a
          // negligible leak for not having to export m_free here.
          //
          // Until this landed, the bridge probed for `malloc`/`free` (not
          // exported by petitpy) and fell through to dropping args,
          // which made Promise.then(cb) callbacks appear to never fire —
          // the dispatch ran but Python's `cb` raised TypeError "missing
          // 1 required argument" (the resolved value) and the dispatcher's
          // broad `except Exception` swallowed it.
          if (wasmExports.m_malloc) {
            const ptr = wasmExports.m_malloc(argHandles.length * 4);
            new Uint32Array(memory.buffer, ptr, argHandles.length).set(argHandles);
            resultHandle = wasmExports.npy_dispatch_callback(callbackId, ptr, argHandles.length);
          } else if (wasmExports.malloc && wasmExports.free) {
            const ptr = wasmExports.malloc(argHandles.length * 4);
            new Uint32Array(memory.buffer, ptr, argHandles.length).set(argHandles);
            resultHandle = wasmExports.npy_dispatch_callback(callbackId, ptr, argHandles.length);
            wasmExports.free(ptr);
          } else {
            // No allocator available — drop args. The Python callback
            // receives zero proxies. addEventListener("click", fn) works
            // (no args needed); event-object access requires an allocator.
            resultHandle = wasmExports.npy_dispatch_callback(callbackId, 0, 0);
          }
        }
        return valueOf(resultHandle);
      };
      return newHandle(fn);
    },
  };

  function attachMemory(wasmMemory) {
    memory = wasmMemory;
  }

  function attachExports(exports) {
    wasmExports = exports;
  }

  return { imports, attachMemory, attachExports, handles };
}
