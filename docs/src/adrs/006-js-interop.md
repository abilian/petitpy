# ADR 006. JS interop: direct DOM bridge via sync host calls (A2), forward-compatible with asyncify

- **Status**: Accepted. J1-J5 arc implemented; powers every demo under `web/` and `projects/ci-build-monitor/`.
- **Decider**: project maintainers
- **Supersedes**: nothing
- **Consequences**: opens the path for Python-dominant browser demos by giving Python code direct DOM access; commits to a synchronous host-call ABI with documented marshaling rules; introduces a project-extension module (`js`) that has no MicroPython equivalent and leaves the language, bytecode and extension protocol covered by ADR-003's compatibility commitment untouched; defers asyncify-based `await` support to a later ADR while preserving forward-compatibility with it

## 1. Context

ADR-001 made WASM the primary target. ADR-002 made the feature surface composable. ADR-003 wired the stdlib in. None of them touched the part of the browser story the demos themselves are now exposing: the boundary between Python and the DOM.

The five demos under `web/` (playground, snippets, validation, dashboard, simulation) share a bulk asymmetry. Per-demo JavaScript runs about 150-300 LOC. Per-demo Python runs about 50-150 LOC. The diagnosis on record:

> There are often more JavaScript code than Python code. The code is to replace JavaScript, with just a bit of JavaScript as glue code — keeping the UI logic in Python rather than JavaScript. Is it possible to do better?

The shape of every demo is the same: JavaScript catches a DOM event, encodes the inputs as stdin or argv, spawns the wasm module, reads stdout, and renders the result. Python contributes only the computation step in the middle. The UI is entirely JS by construction. That construction is forced by the WASI sandbox, which exposes stdin, stdout and argv, and lacks the DOM, `fetch`, an event loop and `requestAnimationFrame`.

This ADR closes that gap: it gives Python code a way to read and write the DOM directly, so the JS half of a demo shrinks to a thin loader and the UI moves to Python.

### 1.1 Relationship to ADR-003's compatibility commitment

ADR-003 commits petitpy to MicroPython compatibility on three axes: bytecode (.mpy v6), language semantics, and the extension/registry protocol. Compatibility constrains the shared surfaces; it does not enumerate the set of modules petitpy is allowed to ship. Project extensions (new Zig modules, new Python builtins, new build features) are explicitly permitted.

The `js` module described here is such an extension. It does not alter syntax, bytecode, language semantics, or the extension/registry protocol. ADR-003's compatibility constraints are therefore unaffected by adding it.

MicroPython has no standard `js` module. The JavaScript port of MicroPython uses Emscripten and exposes a different surface (mostly around embedding MicroPython in Node.js) with no analog to Pyodide's DOM-access story. Petitpy skips that surface here. If a future MicroPython release introduces a `js` module whose API shape differs from the one defined below, that is a future forward-compat question to revisit at that point.

Concretely: Python code that uses `import js` will not run under MicroPython (no such module exists upstream); Python code that does not use `import js` is unaffected. The extension is bounded: it adds a module; it does not change the language, the bytecode format, the existing builtin modules, or the extension mechanism.

### 1.2 The Pyodide reference point

Pyodide is the obvious comparison. It is CPython compiled to WASM via Emscripten, with a `pyodide.ffi` module that gives Python code a `js` proxy reaching into the browser's `globalThis`. Pyodide is the de facto standard for "Python in the browser."

The design adopted here differs from Pyodide as follows:

| Pyodide | This ADR |
|---|---|
| Emscripten + CPython | Zig + WASI + MicroPython bytecode |
| Asyncify-based `await js.fetch(...)` | Sync calls only (asyncify deferred) |
| Full DOM + WebGL + workers | DOM read/write (sync) for now |
| ~10 MB compressed download | ~286 KB ReleaseSmall, must stay tiny |
| PyProxy / JsProxy with explicit `destroy()` and elaborate lifecycle | Smaller proxy surface; explicit cleanup TBD |

We borrow the **API shape**. `js.document.getElementById("foo").textContent = "hi"` reads the same way for a developer familiar with Pyodide's docs. The borrowing is asymmetric: Pyodide is the more complete implementation; petitpy adopts its visible surface where it is consistent and small, documents where it differs, and stays tiny.

Petitpy does *not* adopt tracking Pyodide upstream as a moving target. Pyodide's release cadence and feature set evolve with CPython and with the maintainers' priorities. Petitpy adopts the *current* visible surface, writes its docs against its own behavior, and treats "differences from Pyodide" as a docs appendix. If Pyodide changes its proxy semantics in a future release, petitpy's docs do not change.

### 1.3 What the demos need

The motivating demos do not need `await fetch(...)`. They need:

- Read an input element's value when the Run button is clicked.
- Write a result back to an output element.
- Wire a button's `click` event to a Python callable, so iteration can be driven from Python.
- Update a `<canvas>` or a list of `<div>`s in response.

That is a sync read/write surface plus an event registration mechanism. Asynchronous APIs (`fetch`, `requestAnimationFrame`, async iterators) are real but not on the critical path for any current demo. They are why A3 (asyncify) is in the survey. They are also why the ABI is designed to grow into asyncify without breaking.

### 1.4 What "Python-dominant" means concretely

Today, a `validation` demo's HTML loads `app.js`. `app.js` (200+ LOC) attaches click handlers, reads form inputs, serializes them to a string the wasm module can ingest via stdin, spawns the wasm, parses the stdout, and rewrites the page. The Python script (~60 LOC) parses the input string, runs the validator, and prints a result line.

Python-dominant inverts that. The HTML loads a thin bootstrap (~30 LOC of JS: instantiate wasm, hand off control). The Python script (~150 LOC) imports `js`, grabs the form elements, attaches its own click handler that reads `.value`, runs the validator, and writes the result back to the page. There is no stdout protocol, no string-encoded payload, no JS-side render logic. The JavaScript that remains is exactly the loader, plus the bridge; both are shared across demos, neither belongs to the demo's own code.

The success criterion in §7 (Python:JS LOC ratio inverted) is the operational definition of "Python-dominant" used by this ADR.

## 2. Approaches surveyed

This section surveys five approaches. The first is the status quo. The next three are increasingly capable and increasingly expensive. The fifth is a hybrid that tries to sidestep the asyncify cost.

### A1. Status quo (stdout-marker protocol)

Python prints structured output (JSON, line-prefixed markers, whatever). JavaScript parses stdout and renders. No new wasm imports; the WASI sandbox is unchanged.

- **Pros**: zero new infrastructure; ABI stable (it is the WASI ABI); works in any environment that runs wasm.
- **Cons**: per-demo JS is roughly 3× the Python; the "Python in your browser" pitch is undercut by the fact that the visible UI is JavaScript; every demo re-invents its own stdout protocol; event handlers require either re-running the wasm or never running it again.

This is the status quo. The note quoted in §1 is a complaint about exactly this shape. A1 is in the survey only as the baseline cost being paid: every line of A1's JS that a later approach removes is a line that no longer has to be taught to demo authors.

### A2. Sync host calls only

Extend the wasm imports with a small set of host functions: `js_get`, `js_set`, `js_call`, `js_release`, plus a callback-registration pair. When Python writes `js.document.body.textContent = "hi"`, the proxy's `__setattr__` invokes the import. The JS side does the DOM write and returns. Each call is synchronous from wasm's view: the wasm frame blocks while JS runs.

- **Pros**: small implementation (~500-800 LOC across Zig, Python, JS); no new toolchain dependency; matches the "Python with side effects" mental model most users start with; the proxy surface is small enough to fit on one page.
- **Cons**: cannot `await` async APIs (`fetch`, `requestAnimationFrame`) without blocking the main thread, which would freeze the browser; event handlers require keeping the wasm instance alive between events plus a JS-to-Python callback dispatch path.

This is the path most existing "small Python in browser" projects converge on before they consider asyncify. The "sync from wasm's view" property makes A2 cheap: there is no stack-spilling, no continuation passing, no coroutine wrapping. The wasm call into JS returns when JS returns, exactly the same way `extern fn` calls work today. That structural simplicity also bounds A2's reach: anything that requires waiting on a Promise has to be reshaped (callback-style) or deferred to A3.

### A3. Asyncify (the Pyodide model)

Run Binaryen's asyncify pass on the wasm. Asyncify rewrites the wasm to spill its stack on every async-marked call and resume from the spilled stack when JS resolves the call. With asyncify in place, Python can `await js.fetch("/x").then(...)` and the wasm yields cleanly back to the JS event loop while waiting.

- **Pros**: full async DOM access; `await` works for fetch, requestAnimationFrame, and any Promise-returning JS API; the event-handler model becomes ordinary `async def` code with no registered callbacks; matches the prevailing browser-Python pattern.
- **Cons**: asyncify adds about 30-50% to the wasm binary size, sometimes more (the precise number depends on call-graph reachability; every function on a path that might await is wrapped); requires Binaryen in the build (`wasm-opt --asyncify`); complicates `ReleaseSmall` (which is already tightly budgeted per ADR-001 Theme F); the rewrite changes execution semantics in ways that are hard to debug when something goes wrong.

For petitpy specifically, the size cost is the sharp edge: the 286 KB ReleaseSmall binary is a headline number for the WASM-primary positioning. Asyncify could push the build to 400-450 KB, which is still small but no longer the "smaller than MicroPython" headline.

### A4. Web Worker + SharedArrayBuffer + Atomics.wait

Run wasm in a Web Worker; keep DOM access on the main thread. The Worker calls JS imports that post a message to main and then block on `Atomics.wait` against a SharedArrayBuffer cell. The main thread does the DOM work, writes the result into the SharedArrayBuffer, and notifies the Worker.

- **Pros**: no asyncify; sync semantics from Python's view; full access to async DOM APIs via the bridge (main thread runs Promise-returning APIs and resolves them before notifying); cleaner separation between Python execution and UI.
- **Cons**: requires cross-origin isolation (COOP + COEP headers) for SharedArrayBuffer, which constrains how the demos can be hosted (static-site hosts may need configuration); Workers add deployment complexity; mobile browsers historically have had quirks with SharedArrayBuffer; debugging across the Worker boundary is harder than a single-thread bridge.

This is a clean architecture in the abstract. The hosting constraint is the primary pain: a static GitHub Pages demo cannot serve the required headers without proxying.

### A5. Hybrid (sync host calls + Python coroutine/generator event loop)

This approach uses A2 for the common case (DOM read/write) and adds a Python-side cooperative event loop that JS pumps. Wasm exposes a `tick()` export; JS calls `tick()` from event handlers, requestAnimationFrame, or a setTimeout chain. Python generators or a hand-rolled callback queue handle multi-step interactions without ever blocking the main thread.

- **Pros**: avoids asyncify; the event model becomes "Python registers callbacks, JS pumps the loop on event"; structurally similar to MicroPython's own `uasyncio` patterns.
- **Cons**: hand-rolled event loop in Python is awkward to write and to teach; many simple use cases (`await fetch`) become harder; the model is unique to petitpy, so no documentation transfers from Pyodide; "what is the right shape of the loop" becomes a project-defining question that does not need to be answered now.

A5 would work. It does not pay for itself at the current scope.

### 2.1 Summary

| Approach | Capability | Cost | Forward-compat |
|---|---|---|---|
| A1 status quo | None new | None | N/A; leaves the problem unsolved |
| **A2 sync host calls** | DOM read/write + event callbacks | ~500-800 LOC, small ABI | Same ABI grows into A3 cleanly |
| A3 asyncify | Sync + async via await | +30-50% binary, Binaryen dep | This is the destination |
| A4 Worker + SAB | Sync + async via SAB | Hosting constraint, Worker complexity | Orthogonal to A2/A3 |
| A5 hybrid loop | Sync + cooperative async | Project-defining event-loop shape | Diverges from Pyodide |

A2 is the only option in the table whose cost is bounded by existing build practice and whose ABI does not have to be redesigned later. A1 is the do-nothing. A3 is the destination but expensive. A4 has a hosting cost incompatible with the static-site demo story. A5 invents a model that would have to be taught to every demo author from scratch. The pragmatic order is A2 first, A3 second (and separately), A4 and A5 only if forced.

## 3. Decision

Adopt **A2 (sync host calls)** as the first cut. Define the wasm-import ABI so that A3 (asyncify) can be layered on later without breaking the existing demos or the existing Python `js` module. A4 and A5 are deferred: A4 remains available if main-thread blocking becomes a real issue; A5 is rejected for the project's current shape.

Rationale:

- The demos that motivated this ADR (validation, dashboard, simulation) do not need `await`. They need DOM read/write inside a single Run. A2 is sufficient for the cases on the table.
- A2 ships in a tractable session count (~3-5). A3 ships in roughly twice that, with the additional Binaryen toolchain dependency. The order of operations is: prove the model with A2, then evaluate whether A3 is actually needed.
- The ABI between Python and JS (`js_get(handle, prop)`, `js_set(handle, prop, value)`, `js_call(handle, args)`, `js_release(handle)`, `js_create_callback(py_id)`, `js_invoke_callback(py_id, args)`) is forward-compatible with asyncify. Asyncify wraps the *same* imports; it does not require new ones. Shipping A2's ABI first does not foreclose A3.
- A2 ships first; usage informs whether A3 is needed; A3 lands (or does not) under a separate ADR once the demand is concrete.

### D1. Project extension (compatible with ADR-003)

The `js` module is a petitpy project extension. MicroPython has no equivalent. The compatibility surfaces named in ADR-003, namely syntax, bytecode (.mpy v6), language semantics, and the extension/registry protocol, are not touched by adding it. Project extensions on top of those surfaces are permitted by ADR-003 and expected as petitpy evolves.

Concretely: a Python script that uses `import js` will fail under MicroPython (no such module exists upstream). A Python script that omits `import js` runs unaffected. The extension is bounded: it adds a module; the language, the bytecode format, the existing builtin modules, and the extension mechanism stay untouched. Future MicroPython could introduce a `js` module of its own; if its API shape differs from this one, the resulting forward-compat question is revisited at that point.

The `js` module name itself follows Pyodide's convention. Alternatives considered: `nanopython.dom`, `_nanojs`, `web`. `js` wins on three grounds: (a) Pyodide users will recognize it; (b) it reads cleanly (`from js import document`); (c) MicroPython does not use the name (no collision risk if round-tripping in the other direction is ever desired).

### D2. API surface: Pyodide-like

`js.X` accesses property `X` of `globalThis`. `js.document.getElementById("foo")` returns a Python proxy wrapping the JS Element. The proxy supports:

| Python expression | JS effect |
|---|---|
| `proxy.attr` | read property `attr` |
| `proxy.attr = value` | write property `attr` |
| `proxy.method(args)` | call method `method` with args |
| `proxy(args)` | call the JS object as a function (if callable) |
| `proxy[key]` | indexed access (arrays and objects) |
| `proxy[key] = value` | indexed assignment |
| `len(proxy)` | `.length` on arrays, `.size` on Maps/Sets |
| `iter(proxy)` | best-effort iteration via `[Symbol.iterator]` or array index |

Pyodide's surface is followed where it is consistent and small. Pyodide's more elaborate features (`JsProxy.to_py()` deep conversion, `JsProxy.then()`/`finally_()` chaining, the `Proxy` async iterator protocol) are not adopted in the first cut. Those are A3-territory.

### D3. Type marshaling

Inbound (Python → JS) and outbound (JS → Python) follow a small set of rules. By value where it is cheap and unambiguous; by reference (proxy / handle) where the JS side has interesting identity or methods.

| Python | JS | Direction | Notes |
|---|---|---|---|
| `str` | `string` | both, by value | UTF-8 over the boundary |
| `int` (smallint) | `Number` | both, by value | range checked |
| `int` (bignum) | `BigInt` or TypeError | Python → JS | BigInt round-trips; smallint fits in Number, larger → BigInt |
| `float` | `Number` | both, by value | |
| `bool` | `Boolean` | both, by value | |
| `None` | `null` | both, by value | `undefined` from JS also surfaces as `None` |
| `bytes` / `bytearray` | `Uint8Array` | both, by value | copy on each direction in the first cut |
| `dict` | plain object | both, by value | deep copy; nested proxies are flattened with a warning |
| `list` / `tuple` | array | both, by value | tuple becomes a frozen array hint (advisory) |
| any other Python object | not supported in v1 | Python → JS | raises `TypeError` |
| JS object (DOM, etc.) | Python proxy | JS → Python | by reference via handle table |
| JS function | callable proxy | JS → Python | proxy is callable; arguments marshal in |
| Python callable | JS function | Python → JS | registered in the callback table (D4) |

The marshaling table is small by design. Edge cases (Map, Set, Date, ArrayBuffer-other-than-Uint8Array, typed-array variants) are documented as "passes as a proxy; access via properties." Pyodide-completeness is not a goal. Pyodide's deep marshaling story is a substantial chunk of its codebase, which most demos do not need.

Two choices in the table are non-obvious:

- **dict ↔ object is by value, deep copy.** Pyodide makes the opposite choice (proxy by reference, with `to_py()` to deep-copy on demand). By-value is picked here because the motivating demos do structural marshaling for small payloads (form values, validation results), where proxy overhead would dominate. The cost is correctness in edge cases: round-tripping a dict-of-dict and modifying the inner dict on the JS side does not propagate back to Python. This is documented.
- **Python callable → JS function via callback table.** The alternative is a one-shot closure: every Python callable handed to JS becomes a fresh JS function that, when called, host-calls back into wasm. The callback-table approach de-duplicates (the same Python callable produces the same JS function), gives the JS side a stable identity for `removeEventListener`, and centralizes lifetime management. The cost is the table itself, ~50 LOC.

### D4. Event handlers

Python registers a callable. The bridge enters it in a callback table keyed by an integer id. JS receives the id along with the registration call (e.g., `button.addEventListener("click", py_handler)`); when the event fires, the JS side host-calls into wasm with `js_invoke_callback(id, event_proxy)`, which dispatches back to the Python callable.

The wasm instance stays alive across events. This is a change from the current shape: today's demos tear down the wasm after each Run. With event handlers, the instance has to persist so that callback state (Python closures, registered handlers, the handle table) is kept. JS controls lifetime by holding a reference to the instance; "Stop" or "Reset" in the demo UI calls a teardown that flushes the handle and callback tables before dropping the instance.

Garbage collection across the boundary is the open hairy question. The first cut uses explicit lifetimes: a Python `js.unregister(handler)` removes a callback; the Python proxy holds a Zig-side reference that drops the JS handle when the proxy is garbage-collected by Python; JS-side handles only release when Python releases them. Cycles between Python proxies and JS handles will leak in the first cut. The leak is documented; it is not solved. (Pyodide has explicit `destroy()` calls for exactly this reason. If leak pressure becomes real, that pattern is adopted.)

### D5. Browser-only

Under native, wasmtime and any non-browser host, `import js` raises `ImportError`. The module is browser-only and gated by a build option (provisionally `-Dfeature-js`, to be wired through the ADR-002 mechanism) and a build target (the wasm host imports must be present).

Native demos that want DOM-like capabilities use the stdout protocol as today. A future "import-portable" story (`import js` works under native with no-op stubs) is a small additional ask, left out of scope here. (Open question; see §6.)

### D6. JS-side runtime infra

A small JS module at `web/lib/js-bridge.js` (estimated ~300 LOC) holds the JS half of the bridge. It maintains:

- **Handle table.** Maps wasm-side integer handles to JS object references. `js_get` and `js_call` produce new handles; `js_release` drops them. The table is per-wasm-instance; teardown clears it.
- **Callback table.** Maps Python-side integer callback ids to a small dispatch closure that calls back into wasm. Python registers; JS invokes.
- **Marshaling helpers.** Implements the D3 rules in both directions. Lives in one place so that adding a new type (e.g., `Map` someday) is a single-file change.
- **Cleanup hook.** Wired into the demo loader so that wasm-instance teardown drops everything.

The JS bridge is a single file (not split per concern) because it is small and tightly coupled. Splitting it would invite the same per-demo duplication the demos suffer from today.

### D7. ABI stability

The wasm import names and signatures are committed once this ADR is accepted. After that, only additive changes are allowed. Concretely, the initial import set is:

| Import | Signature | Meaning |
|---|---|---|
| `js_get` | `(handle: i32, name_ptr: i32, name_len: i32) -> i32` | get property; returns a handle |
| `js_set` | `(handle: i32, name_ptr: i32, name_len: i32, value_handle: i32) -> i32` | set property; returns status |
| `js_call` | `(handle: i32, args_ptr: i32, args_len: i32) -> i32` | call method or function; returns a handle |
| `js_release` | `(handle: i32) -> void` | drop a handle from the table |
| `js_create_callback` | `(py_id: i32) -> i32` | register a Python callable as a JS function handle |
| `js_invoke_callback` | `(py_id: i32, args_ptr: i32, args_len: i32) -> i32` | wasm-side entry that JS calls when the event fires; a paired export, unlike the rows above |
| `js_to_int` / `js_to_float` / `js_to_str` / `js_to_bytes` | `(handle: i32, ...) -> ...` | marshal a JS-side value into Python-side primitive |
| `js_from_*` | `(value: ...) -> i32` | create a handle wrapping a Python primitive |

Signatures stay stable. New imports can be added (asyncify will need a `js_call_async` paired with the wasm-side resume export). Existing imports are not changed.

## 4. Shape

Five work items landed A2 end-to-end:

1. **J1.** Wasm imports and host-call dispatch on the Zig side, including the callback-dispatch export (JS invokes a Python callable by id from an event handler, needing reentrant frame discipline).
2. **J2.** Python-side `js` module: a thin `Proxy` class holding an integer handle and forwarding every Python operation to a wasm import. It neither caches nor keeps a shadow shape. Frozen into the binary per ADR 003.
3. **J3.** JS-side bridge (`web/lib/js-bridge.js`): handle table, callback table, marshaling, teardown.
4. **J4.** Refactor existing demos to use `import js` directly. Per-demo JS shrinks; per-demo Python grows and absorbs the UI logic. The Python:JS LOC ratio inverts to Python-dominant.
5. **J5.** Documentation and one new pure-Python demo with a ~30 LOC JS loader.

J1 and J3 are independent and were pursued in parallel. J2 required J1. J4 required all three. J6 (asyncify) is a follow-up decision.

## 5. Out of scope (deferred by choice)

| Direction | Why deferred |
|---|---|
| **Asyncify (A3) for `await js.fetch(...)`** | Its own ADR after A2 ships and evidence exists for whether the sync surface is sufficient |
| **Web Worker + SharedArrayBuffer model (A4)** | Orthogonal; revisit if main-thread blocking becomes user-visible pain |
| **The exact subset of the DOM API "supported"** | Python may call anything; the JS side either succeeds or raises. No opinionated subset is defined; the layer is a bridge, with no DOM wrapper |
| **Server-side rendering, SSR, hydration** | Out of scope; petitpy is not a framework |
| **Native + wasmtime versions of `import js`** | Browser-only in v1; portability stubs are an open question (§6) |
| **Pyodide-style deep proxy lifecycle (`destroy()`, `PyProxy.unwrap()`, etc.)** | First cut uses explicit lifetimes + accepted leak on cycles; revisit if leak pressure is real |
| **`pyodide` shim for source compatibility with Pyodide code** | Out of scope; we adopt the API shape and stop short of the package surface |
| **Multi-instance or multi-thread Python in one page** | Single-threaded Python; if two wasm instances coexist, their handle tables are independent and disjoint |

## 6. Risks

**Source incompatibility with MicroPython's browser story.** Per D1, the `js` module is a petitpy extension; MicroPython has no equivalent. The risk is that a developer who expects to port code from the MicroPython Emscripten port's API hits a wall. *Mitigation*: docs state up front that `js` is petitpy-specific; the ADR-003 compatibility surfaces (syntax, bytecode, language semantics, extension/registry protocol) are unaffected, so the incompatibility is bounded to this one new module.

**Sync-only is a forward-compat trap if `await` is needed sooner than expected.** Risk: a popular demo wants `await fetch(...)`, A2 cannot deliver it, and the workaround (synchronous `XMLHttpRequest`-style blocking) is worse than no demo. *Mitigation*: the ABI is designed so that A3 layers on without changing the existing imports; if pressure rises, J6 is a 2-3 session arc with no redesign. As a probe, if a demo's first proposal is "I need to fetch in Python," J6 moves up the queue.

**Handle table leaks.** If a Python proxy is not garbage-collected (cycles, long-lived globals, etc.), the JS handle it wraps is not released. *Mitigation*: explicit `js.release(proxy)` is documented; wasm-instance teardown drops everything; handle-table size is surfaced in the demo console so growth over time is flagged as a regression.

**Wasm instance lifetime becomes complicated.** Today's demos run wasm to completion and drop it. With event handlers, the instance has to persist across events, which means initialization happens once, and state accumulates. *Mitigation*: a Reset button in each refactored demo calls a clean teardown; the instance is owned by the JS loader, distinct from the demo logic.

**Cross-instance handle confusion.** If a page has two wasm instances (rare but possible), handles from one are not valid in the other. *Mitigation*: the handle table is per-instance; the bridge tags handles with the instance id and refuses cross-instance use with a clear error.

**Asyncify size cost arrives via user demand.** Even with A2 shipped, users may push for asyncify for the `await` ergonomics, threatening the 30-50% size cost on the default build. *Mitigation*: per ADR-002, asyncify is opt-in (`-Dfeature-asyncify` or similar); the default wasm-tiny stays sync-only and small; size-sensitive users pick size, await-sensitive users pick await.

**Pyodide is the reference and Pyodide is bigger.** Users will compare features and find missing pieces (deep `to_py`, async iteration, Web Worker integration, full numpy-array marshaling). *Mitigation*: docs are explicit that this is a smaller bridge by design (a Pyodide drop-in stays out of scope). We adopt the API shape, stopping short of the API surface.

**The bridge JS becomes a maintenance burden.** Today's per-demo JS is ad-hoc, but also self-contained: a broken demo does not break another demo. After J4, all demos share `js-bridge.js`; a regression there breaks everything. *Mitigation*: the bridge gets a test page (`web/test-js-bridge/`) that exercises every code path, run as part of any demo-touching change.

**Documentation drift.** "Pyodide-like, except…" is a docs trap: every version of the docs has to track Pyodide's surface to stay accurate. *Mitigation*: docs describe petitpy's own behavior, with a short "differences from Pyodide" appendix; upstream tracking is not promised.

## 7. Success criteria

The work ships when:

| Criterion | Verified by |
|---|---|
| A demo refactored under J4 has Python:JS LOC ratio inverted (Python ≥ 2× JS) | LOC count in the PR |
| `js.document.body.textContent = "hi"` works from Python in the browser demo | manual smoke on the public URL |
| A button-click handler registered in Python updates the DOM in response to a real click | `web/test-js-bridge/index.html` |
| `import js` raises `ImportError` under native and under wasmtime | `tests/unit/test_js_native.py` |
| The wasm-tiny binary does not grow by more than ~10 KB from adding the `js` module + imports | size measurement in CI artifacts |
| The byte-exact regression detector stays at 537/541 | `make check` on every commit; the `js` module is wasm-only and does not touch the native interpreter |
| The ABI document (`docs/js-bridge-abi.md`) is published and version-stamped | docs site review |
| At least one new demo (J5) is pure-Python (≤30 LOC of JS that is just loader) | demo source review |

## 8. Open questions (deferred to future work)

- **Should `import js` work under native with no-op stubs for code portability?** Pro: write-once-run-anywhere demo code. Con: silent no-op DOM writes are a debugging trap. Likely resolution: `ImportError` (current decision) plus a `js.is_browser()` predicate for guarded code.


- **How much of Pyodide's lifecycle to mirror?** Pyodide has `PyProxy.destroy()`, `PyProxy.copy()`, `PyProxy.toJs()`, `JsProxy.to_py()`, plus a complex GC interaction. First cut: explicit lifetimes + leak-on-cycles. Revisit if real leak pressure surfaces.


- **Is `js` a feature flag under ADR-002?** Likely yes: `-Dfeature-js` gates the wasm import declarations + the frozen Python module. The cost when off is zero; the cost when on is the size of the bridge module + imports.


- **Threading and shared state when multiple Python "tasks" exist.** Probably out of scope (single-threaded Python), but a future async story (J6) will need to address reentrancy.


- **Should the proxy support Python special methods beyond the ones in D2?** `__eq__` cross-language is the obvious next one. Defer until a demo asks for it.


- **Does `js` get a frozen `.mpy` slot in wasm-tiny, or is it a builtin module?** Mechanical choice; matches whatever the bridge between Python-frozen and Zig-side reaches for in ADR-003's resolver.


- **Source-compatibility shim for Pyodide code.** If users start porting Pyodide demos, should a `pyodide` module that aliases `js` ship? Defer until a real port-attempt happens.


## 9. References

- `001-roadmap-v04.md`: WASM-primary positioning that this ADR builds the browser side of.
- `002-feature-selection.md`: the `-Dfeature-*` mechanism that gates `js` and (later) asyncify.
- `003-library-and-module-loading.md`: the compatibility-with-MicroPython commitment whose surfaces (syntax, bytecode, language semantics, extension/registry protocol) this ADR leaves untouched. The `js` module is a project extension built on top of those surfaces.
- `004-benchmarking.md`: relevant once A3 lands; binary-size and startup-time deltas from asyncify will go in the matrix.
- `web/README.md`: current demo inventory; the LOC ratios cited in §1 come from inspecting these demos.
- Pyodide design docs at `pyodide.org/en/stable/usage/api/python-api.html`: the API-shape reference adopted here (without a commitment to track upstream).
- `@bjorn3/browser_wasi_shim` documentation: the shim layer the bridge extends for JS-side hosting.

---

*This ADR is Proposed. Acceptance is recorded by editing the Status field.*
