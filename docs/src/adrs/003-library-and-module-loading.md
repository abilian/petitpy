# ADR 003. library and module loading: micropython-lib direct + frozen-tiny core + lazy-fetch

- **Status**: Accepted. Frozen-tiny stdlib lives in `nanopython-lib/`; lazy-fetch via `tools/zpip.py` ships in the playground demo.
- **Decider**: project maintainers
- **Supersedes**: nothing
- **Consequences**: commits the project to micropython-lib as the stdlib source and to a hybrid frozen-tiny + lazy-fetch delivery model under WASM, with the same library reaching native via filesystem and a `mip`-compatible installer

## 1. Context

ADR-001 repositions the project around the WASM build; ADR-002 decomposes the build into per-feature `-Dfeature-*` flags. Both are about the *interpreter*. This ADR is about the *environment* it runs in.

Today, in the WASM demo, `import json` fails. So does `import re`, `import base64`, `import urllib.parse`, and essentially every CPython stdlib name. Only the eight builtin modules baked into the binary (`sys`, `math`, `errno`, `struct`, `collections`, `micropython`, `array`, `gc`) resolve. The strangler arc finished the interpreter; it never built the environment.

### 1.1 Compatibility with MicroPython

Compatibility with MicroPython is a contract about a specific surface. Extending petitpy beyond MicroPython is explicitly allowed; changing what MicroPython already defines requires an explicit divergence decision on record.

> **Scope note (2026-07):** the scope stated in this section has narrowed in practice. The single explicit adherence point today is the bytecode format. The extension-ecosystem clause is aspirational and not tested; the syntax clause is no longer a strict subset (grammar overlays under `port/grammar-patched/` accept PEP 448 dict/list unpack in more positions and PEP 570 positional-only markers that upstream rejects); the runtime-semantics clause holds byte-exact under `nano` (541/541) while `full` ships documented divergences (CPython-shape `collections.deque`, permissive `re.IGNORECASE`, extended `@dataclass` flags). C-level ABI compatibility is not, and has never been, provided. The current statement is in [comparison-micropython.md](../comparison-micropython.md); per-profile divergences are enumerated in the corresponding `corpus/*-known-fails.txt` files.

**Compatibility commits petitpy to not breaking these surfaces:**

- **Bytecode format.** `.mpy` v6, byte-for-byte compatible. The output of `zigpy-compile` runs on the upstream MicroPython VM, and `.mpy` files produced by MicroPython's `mpy-cross` run on petitpy. This is the explicit adherence point today. A future ADR could break it, and if that happens it will be by explicit decision.
- **Syntax (nano profile).** Python source petitpy's `nano` config accepts matches what upstream MicroPython accepts. Under `full`, the grammar overlays accept a superset (see scope note).
- **Runtime semantics that the corpus measures.** Same exception types, same string-formatting rules, same dict ordering guarantees, same numeric coercions, for the byte-exact `nano` frozen profile. Under `full`, corpus-tracked divergences are documented in `corpus/full-known-fails.txt` with per-entry rationale.
- **Extension ecosystem and registry protocol (aspirational).** Original intent: packages from `micropython.org/pi/v2` install and run; the client behaves as a `mip`-compatible peer. Not tested in current practice; `nanopython-lib/` is hand-written for petitpy's shape. Deferred until it appears as a user request.

**Compatibility allows any of the following:**

- **Additional Python modules.** Petitpy can ship modules MicroPython does not have (e.g., a `js` browser-bridge module). This counts as an extension. Programs that rely on MicroPython's module surface continue to work, and programs that import petitpy-specific modules are petitpy-specific.
- **Additional Zig-side runtime features.** Internal architecture decisions (the strangler port, the polled-sentinel `PyError` convention, the NX-3 NLR replacement, the ADR-002 per-feature flags) are implementation details.
- **Additional build features.** Per-feature gating, the frozen-tiny core, IndexedDB lazy-fetch, the JS bridge: all extension surface.
- **Project-specific tools, conventions, and ADRs.** Documentation, ADR structure, the package manager name (`zpip`), test infrastructure: none of this overlaps with the compatibility contract.
- **C-level ABI.** It is unstable and undocumented for external use. The `mp_mirrors.zig` field-for-field mirrors and the `full` config's link contracts against vendor C are internal invariants used during the port; do not link against them.

**The rule:** if a feature *adds* something MicroPython does not have, it is an extension. If a feature *changes* something MicroPython already defines, it is a divergence: it needs a rationale in the corresponding known-fails file.

### 1.2 Audiences this ADR designs for

This ADR ranks three audiences by design weight:

- **Browser-demo visitor (primary).** Lands on a URL, types Python into a textarea, has no toolchain, will spend at most a few minutes deciding whether the project is interesting. Cares about: imports working out of the box, low first-import latency, small binary download. WASM-primary positioning (ADR-001) gives this audience the most weight.
- **Native CLI user (first-class).** Has cloned the repo or installed a binary on macOS/Linux. Wants to write a Python script that does something useful (read a JSON file, parse a URL, hash a string). Cares about: a `mip`-compatible install workflow that mirrors `pip install`, modules resolving via the filesystem `sys.path`, legible failure modes. Native is a real audience with its own UX, distinct from the WASM work.
- **Embedded user (future, aware).** This audience is out of scope here. The decisions below should still leave room for an eventual embedded story (a board without network or IndexedDB, with a frozen-only library). The per-feature flags from ADR-002 give us the lever to disable the registry client for that audience when it arrives.

### 1.3 What MicroPython provides, what we are missing

Upstream MicroPython solves stdlib delivery via **micropython-lib** (a separate repository, `github.com/micropython/micropython-lib`) containing pure-Python implementations of much of the CPython stdlib plus microcontroller drivers. Modules are distributed as `.mpy` files via the **mip** tool, which fetches from `micropython.org/pi/v2`.

| Piece | Upstream | petitpy today |
|---|---|---|
| `sys.path` wired to the import machinery | Yes | No (list exists in `sys`, never read) |
| Import hook for filesystem modules | Yes | No (`module_get_builtin` only) |
| `.mpy` loader from disk | Yes | Unreachable code path |
| Package installer | Yes (`mip`) | No equivalent |
| Frozen-module bundling | Yes (manifest files) | No (only feature toggles) |
| Public registry | `micropython.org/pi/v2` | None needed; reuse upstream |
| Browser-side delivery for WASM | N/A (no WASM port) | Open question |

Most pieces are reusable. The browser-side delivery model is the piece this ADR has to design from scratch.

### 1.4 Why "freeze everything" is wrong

The simplest fix (baking all of micropython-lib into the binary as frozen modules) would inflate the WASM binary from 286 KB to 2-3 MB, undoing the wasm-tiny story from ADR-001 §Theme F. It also conflates "the interpreter" with "the library," collapsing the per-feature granularity ADR-002 established. The right shape is the one the rest of the web learned twenty years ago: ship a tiny default, fetch the rest on demand, cache aggressively.

## 2. Decision space

### 2.1 Where does the stdlib come from?

| Source | Verdict |
|---|---|
| **micropython-lib direct (chosen)** | Exists, tested, wire-compatible, active upstream, free. Cost: periodic sync, occasional CPython-API divergence. |
| CPython stdlib porting | 10-100× the work, never converges. Out of scope. |
| PyPI gateway | Different format, C extensions, wheels, filesystem assumptions; collides with WASM. |
| nanopython-lib only | Re-invents what already exists; users get 5% of expected stdlib. |

### 2.2 How is it delivered to the WASM binary?

| Delivery | Binary delta | First-import latency | Offline |
|---|---|---|---|
| Fully frozen | +2-3 MB | 0 ms | total |
| Fully lazy | 0 KB | 100-200 ms | broken on cold cache |
| **Hybrid frozen-tiny + lazy (chosen)** | +30-50 KB | 0 ms for tiny, 100-200 ms for rest | usable: tiny core gives a working REPL |
| Build-time user manifest | varies | 0 ms picked, fails otherwise | broken for unpicked |

### 2.3 How does the import hook reach the stdlib?

| Mechanism | Verdict |
|---|---|
| **Zig-side resolver (chosen)** | Simple, fast, matches codebase shape; less extensible. |
| Python-side `sys.meta_path` / `sys.path_hooks` | Mirrors CPython, slower, larger surface. Defer. |
| Hybrid | Two paths to maintain. Defer. |

### 2.4 Where do fetched modules live in the browser?

| Storage | Verdict |
|---|---|
| **IndexedDB (chosen)** | Persistent, async, large quota, well-supported. |
| localStorage | 5-10 MB hard cap; sync API blocks main thread. |
| In-memory | Lost on reload. |
| Cache API | Viable but more associated with HTTP than key-value blobs. |

## 3. Decision

Adopt **micropython-lib direct** as the stdlib source, with our own additions in a separate `nanopython-lib/` directory. Use the **upstream registry** for `mip`-style installs initially. Deliver to the WASM binary via a **frozen-tiny core plus lazy-fetch** model, cached in IndexedDB; on native, the same library resolves from the filesystem via `sys.path` and a `mip`-compatible installer. Wire the import hook on a **Zig-side resolver**. Treat the library test corpus as a first-class deliverable alongside the byte-exact basics.

### D1. Stdlib source: micropython-lib direct + separate `nanopython-lib/`

Use `github.com/micropython/micropython-lib` as the canonical source via git submodule (see D8). Sync periodically; initial cadence quarterly, faster if a critical upstream fix lands.

Local additions go in a separate top-level `nanopython-lib/` directory, for two reasons. A sync can never confuse upstream contents with our own. We can also contribute additions back upstream as discrete PRs.

CPython stdlib porting is out of scope. Some micropython-lib modules are themselves lightly-adapted CPython code; we inherit that work. We do not port additional CPython modules ourselves. The right shape for adding modules is "send a PR upstream."

The name `nanopython-lib/` mirrors the upstream `micropython-lib` convention and signals canonical-for-us status. (Both this directory name and the package manager name in D2 will be revisited when the project itself is renamed.)

### D2. Package manager and registry

The package manager (provisionally **`zpip`**, name TBD with project rename) is a `mip`-compatible client. It talks to `micropython.org/pi/v2` directly for now; the registry protocol is well-defined (JSON index + tarball-style packaging), and upstream's index covers everything micropython-lib ships. The MicroPython project already uses the name `mip`; we need a distinct name to avoid the clash.

Running our own proxy (mirroring upstream and serving `nanopython-lib/`) is a separate, deferred decision. The proxy would buy us a single-bundle frozen-tiny CDN delivery, controlled cache headers, and unified upstream + local serving, at the cost of a real operational dependency. Not in scope here.

The trade: if `micropython.org/pi/v2` goes down, `zpip install` stops working. The IndexedDB cache (D7) shields the browser demo from registry downtime once a module is fetched, and upstream's registry has been stable for years.

### D3. Tests as a first-class deliverable

Library tests get a new test track under `tests/stdlib/`, alongside `corpus/basics/`. Each module in `nanopython-lib/` and each explicitly-supported `micropython-lib` module gets at least one test file exercising basic functionality. CI gains a row that runs the stdlib track and produces a **public matrix** of supported and unsupported modules, published at `docs/stdlib-matrix.md`, linked from the demo, answering "is `requests` supported?" without users having to try it.

The goal is catching regressions our import-hook plumbing introduces; upstream has its own discipline, and certifying it is out of scope. Failure mode is non-strict: a stdlib test failure is not a project regression. The byte-exact `corpus/basics/` detector remains the only merge gate.

### D4. Delivery model: frozen-tiny core + lazy-fetch (WASM); filesystem `sys.path` (native)

Hybrid. A tiny set of modules ships frozen in the WASM binary; everything else is fetched on demand from the registry and cached in IndexedDB. On native, the same modules resolve via the filesystem along `sys.path`, with `zpip install` writing into a configured lib directory.

The frozen-tiny core is the set of modules that are (a) small enough that bundling costs less than the round-trip, (b) required by enough others that they would be fetched on every import anyway, and (c) part of the "Python works out of the box" mental model.

Proposed frozen-tiny list:

| Module | Why frozen |
|---|---|
| `sys`, `errno`, `gc` | Already builtins. |
| `types` | Tiny; depended on by class machinery and introspection. |
| `_collections_abc` | Required by `collections` and `typing`-lite; tiny. |
| `io` (StringIO, BytesIO only) | The `print(file=...)` story; small. |
| `os` (`os.path` only, no real FS) | Users type `os.path.join`; the non-path surface raises `NotImplementedError`. |
| `_thread` (stub) | Many imports incidentally pull `_thread`; single-threaded stub is tiny. |

Estimated added weight: 30-50 KB. The demo binary stays under 350 KB.

Everything else (`json`, `re`, `base64`, `urllib.parse`, `collections` proper, `functools`, `itertools`, `datetime`, `hashlib`, …) is lazy-fetched in WASM and filesystem-resolved on native.

The frozen list is **per-build-configuration** via ADR-002's per-feature mechanism: `make wasm-tiny` freezes the list above; `make build` (native default) freezes only what is structurally required by builtins; full builds may freeze more. The list lives in one place (`build.zig` or an adjacent `frozen.zon`) so revisiting the boundary is a one-line change.

### D5. Module finder/loader: Zig-side resolver

Extend the existing `module_get_builtin` path with a Zig-side resolver chain: builtin → frozen → filesystem (native) or IndexedDB cache (WASM) → registry fetch. The chain returns a parsed module on success or raises `ImportError` on exhaustion.

The Python-side `sys.meta_path` / `sys.path_hooks` machinery is more extensible but slower, with a larger surface and harder failure modes. At this scale (three known loader strategies, all known at build time) a 200-line Zig resolver is right; `sys.meta_path` stays an available future addition if a real user demands it.

The resolver's interface to user code stays minimal: `sys.path` exists, is a list, and is read on every import attempt. Users append from Python; the resolver picks up changes on the next import. `importlib.import_module` / `importlib.reload` are deferred.

The sketch below is pseudocode, subject to revision during implementation:

```zig
fn resolve_module(name: []const u8) ?*Module {
    if (module_get_builtin(name)) |m| return m;
    if (frozen_table.get(name)) |bytes| return parse_mpy(bytes);
    for (sys.path.items) |p| {
        if (vfs_load(p, name)) |bytes| return parse_mpy(bytes);
    }
    if (lazy_fetch_enabled and registry_fetch(name)) |bytes| {
        cache_put(name, bytes);
        return parse_mpy(bytes);
    }
    return null;  // caller raises ImportError
}
```

Three properties matter: every stage produces raw bytes through one common parser; stages 1-3 are synchronous and fast; stage 4 is the only stage with latency or JS-side cooperation.

### D6. IndexedDB cache strategy (WASM)

Single object store keyed by `module-name@version`. Value is the raw `.mpy` byte string (resolver parses on read).

**LRU with a 10 MB cap.** The cap holds all of micropython-lib plus headroom and stays well under any browser's quota. At that size a more elaborate policy is unnecessary.

Offline behavior: cache miss + no network → `ImportError("module X not found; offline")`. No speculative pre-warming. The frozen-tiny core ensures the first-run offline case still reaches a working REPL.

Version pinning is light: the cache key includes the version string from the registry index, so a new release of `json` does not invalidate the cached old version. `--upgrade` semantics are deferred.

Entries look like:

| Key | Value |
|---|---|
| `nanopython:0.x.x:json@1.2.0` | raw `.mpy` bytes |
| `nanopython:0.x.x:_meta:lru` | LRU queue (small JSON array) |

The runtime-version prefix scopes the cache so a future upgrade does not stumble on bytes from an older runtime. The out-of-band LRU entry avoids scanning all entries on every put.

### D7. Sync upstream: git submodule

Track `github.com/micropython/micropython-lib` as a git submodule under `vendor/micropython-lib/`. Updates are explicit (`git submodule update --remote && git commit`), so every sync is a reviewable PR with the version bump pinned. CI runs the stdlib track against the new SHA; if anything regresses, the PR rolls back.

We rejected three alternatives: periodic manual copy (lossy, without provenance), build-time fetch (CI fragility), and vendoring the relevant subset (loses upstream provenance, makes future PRs upstream harder).

The existing `vendor/` is `.gitignored` and generated by `make port`. Reconciliation: rename the generated target to `vendor/micropython/` and add `vendor/micropython-lib/` as a peer submodule. The hands-off rule for `vendor/` applies to both: read-only territory.

**Amended 2026-10-21: the submodule is gone; the three modules we use are copied.** The submodule ended up feeding exactly three files: `types.py`, `heapq.py` and `bisect.py`, frozen into the binary and shipped in the wheel. Every other micropython-lib module the runtime needed was replaced by a `nanopython-lib/` version (itertools, random, string, collections, functools), and lazy-fetch reads the registry, not the submodule. A 3.9 MB checkout for about 750 lines cost a setup step that nothing enforced: a fresh clone without `git submodule update --init` failed the wheel build. The three files now live in `nanopython-lib/` as verbatim copies of micropython-lib commit `381ac746`; `LICENSE` records that commit and their Python license. This reverses the "vendoring the relevant subset" rejection above, which assumed a large, growing subset. Syncing is now a manual copy of three files, reviewed like any other change.

The same review settled where upstream code lives. `sandbox/` is local scratch space: nothing in it is committed, and nothing a build or a gate needs may live there. Vendored code bases go under `vendor/`. Upstream MicroPython therefore moved from `sandbox/micropython` to `vendor/micropython`: still a gitignored clone pinned by `MICROPY_REV` (`make bootstrap` makes it; CI and maintainers may symlink an existing checkout), and still the input to `make port` and the tree the oracle binaries are built in. `vendor/micropython_embed/` stays generated from it and gitignored, so `vendor/` holds no committed file. D7's planned rename of the generated tree is dropped; the upstream clone took the `vendor/micropython` name instead.

The gates used to read 552 test programs from upstream's `tests/basics/` through that clone, while only their `.out` goldens were committed. They are now verbatim copies in `corpus/basics/*.py`, taken at `MICROPY_REV`, so the corpus holds both halves of each pair and the gate scripts need no upstream tree.

This amendment supersedes the submodule wording in D1 and L2, and the submodule risks below (UX friction, update-cadence drift, frozen-vs-lazy SHA pinning).

### D8. Test corpus shape

`tests/stdlib/` mirrors `nanopython-lib/` plus a sampling of supported `micropython-lib` modules. Each test is small, self-contained, and exercises the "would a user notice?" path of the module: the user-visible happy path, sized below an exhaustive surface check.

| Test file | Tests |
|---|---|
| `test_json.py` | Round-trip `dumps` / `loads`; check a known string. |
| `test_re.py` | `match`, `search`, `findall`, a substitution. |
| `test_collections.py` | `namedtuple` + `deque` push/pop. |
| `test_base64.py` | Round-trip bytes. |
| `test_urllib_parse.py` | `urlparse`, `urlencode`. |
| `test_datetime.py` | Construct, compute a timedelta. |

The matrix is generated from per-test status: `ok` / `imports-but-broken` / `not-supported`, with the last-tested date and a link to the test. An `ImportError` for an unsupported module is the *expected* result for many tests; the matrix surfaces it. A module that imports but produces wrong results is flagged `imports-but-broken` and gets an issue. Only `corpus/basics/` blocks individual merges. Stdlib tracking is non-strict per merge and blocks the release.

## 4. Sequencing

Six work items. L1 unblocks everything downstream; L1 and L2 are independent and can run in parallel.

1. **L1.** Wire `sys.path` into the existing import machinery. Add the resolver's filesystem stage on native. Prove the resolver shape on a platform with real filesystem before porting to IndexedDB / fetch.
2. **L2.** Add `vendor/micropython-lib/` as a submodule pinned to a known-good SHA. Freeze-tool walks a per-feature list, compiles each to `.mpy`, embeds the bytes.
3. **L3.** `zpip` install client on native: a small `mip`-compatible client fetching from `micropython.org/pi/v2`, writing to a configured `lib/` directory on `sys.path`. It is reimplemented, so it composes cleanly into the resolver chain.
4. **L4.** Port the registry client to wasm. Wasm calls into JS for `fetch()` and IndexedDB; the JS side handles LRU eviction after every write.
5. **L5.** Test corpus (`tests/stdlib/`) with representative files. CI row runs the stdlib track and publishes the matrix as a build artifact.
6. **L6.** Documentation ("Importing modules" section) and a web-demo update.

Dependencies: L3 requires L1 (native `sys.path`) and benefits from L2. L4 requires L3 (shared registry client). L5 benefits from L1-L4 but can begin in parallel with L4. L6 goes last. If L4 stalls (wasm-JS blocking-on-promise is the unknown-unknown), fall back to shipping L1-L3 + L5 + L6 with wasm lazy-fetch marked "in development."

## 5. Out of scope (deferred on purpose)

| Direction | Why deferred |
|---|---|
| **CPython stdlib porting** | D1 rules it out; the right shape is upstream PRs to micropython-lib. |
| **Our own registry proxy** | A real operational dependency. Out of scope here; revisit if registry latency or outages become measurable user pain, or if we want a single CDN bundle for wasm-tiny. |
| **Native code modules / `.mpy.so`** | No WASM analog; on native it duplicates what a Zig extension already does. |
| **Threading + multiprocessing** | Out of scope per ADR-001 §3. |
| **asyncio runtime library** | `async`/`await` syntax landed previously. The event-loop / transports / tasks layer is a separate beast. `uasyncio` may appear via lazy-fetch if it imports cleanly; not tested or matrix-promoted. |
| **`importlib.reload`, custom loaders, namespace packages** | Go with the Python-side `sys.meta_path` machinery rejected in D5. |
| **PyPI gateway** | Different ecosystem, different dependencies. Not on the roadmap. |
| **Bundling user packages into a single .wasm archive** | Conceivable later; needs a manifest format and probably the proxy. |

## 6. Risks

**micropython-lib quality drift.** Upstream is well-maintained but not CPython; corner-case modules have bugs, missing features, or subtle CPython-API deviations. A user who hits one reports a petitpy bug; the fix is upstream. *Mitigation*: the matrix's `imports-but-broken` status makes upstream-vs-us responsibility legible.

**Registry protocol details.** The protocol is documented but sparsely; chunked encoding, redirects, signing-scheme nuances may surface only when we hit them. *Mitigation*: L3 includes a small spike against the live registry before writing the client.

**IndexedDB cross-browser quirks.** Safari historically has different quota / eviction. The 10 MB LRU budget assumes any browser gives us at least that. *Mitigation*: L4 measures actual quota at runtime and degrades to in-memory-only with a one-time warning. The frozen-tiny core means the first-run experience is unaffected.

**The "frozen + lazy" mental model has corner cases.**
- *Offline first import*: user goes offline before a lazy module has been cached → import fails. Frozen-tiny mitigates the common case; the error message is explicit (`ImportError: module 'X' not found; offline (cache miss)`).
- *Version mismatch between frozen and lazy*: `io` (frozen) and `json` (lazy) could drift in upstream versions. *Mitigation*: both are pinned to the same micropython-lib SHA at build time, and the build checks this.
- *Cache invalidation across runtime updates*: old cached modules + new runtime. *Mitigation*: cache keys include a runtime-version prefix; old entries are implicitly orphaned and LRU-evicted.

**Test infrastructure as a maintenance burden.** 20-30 test files is a modest number. They still need to be kept current as upstream evolves. *Mitigation*: we do not aspire to be a CPython-conformance suite; the matrix tracks *our wire-up* correctness. Upstream-semantics changes update the test (or accept the new semantics) without counting against the project.

**Submodule UX friction for contributors.** Git submodules are notorious for stale checkouts. *Mitigation*: a `make setup` target wraps init/update; CI fails on stale pointers.

**Demo binary size growth.** Frozen-tiny adds 30-50 KB. If it overshoots, we demote modules from the frozen list (`io`, `_thread` are the first candidates). *Mitigation*: the freeze script reports per-module sizes; the build fails if WASM exceeds a configurable cap (default 400 KB for `wasm-tiny`).

**Coupling between resolver and bytecode loader.** The resolver hands raw `.mpy` bytes to the existing loader. The loader may have gaps, such as `.mpy` v6 features the project does not fully support. Every affected module then fails as "module broken" while the actual cause is "loader broken." *Mitigation*: L1 includes a smoke test loading a known-good `.mpy` through the resolver path, surfacing loader gaps before L4 wires the production path.

**Adversarial registry content.** A user pointing `zpip` at a malicious registry can fetch malicious `.mpy`. The wasm sandbox limits blast radius (it allows neither FS escape nor native code). CPU and memory consumption remain possible. *Mitigation*: ship with a single default registry (upstream); native exposes `--registry` with a documented warning. Signature verification (upstream's scheme) catches tampering of cached-but-stale bytes.

**Submodule update cadence drift.** Quarterly sync is easy to forget. *Mitigation*: weekly CI job that opens a draft PR if the submodule SHA differs from upstream `main`.

## 7. Success criteria

The work ships when:

| Criterion | Verified by |
|---|---|
| `import json; print(json.dumps({"a": 1}))` works in the browser demo | manual smoke on the public URL |
| `zpip install <package>` (or current name) works on native for at least 10 representative packages | `tests/stdlib/test_zpip.py` |
| A public matrix at `docs/stdlib-matrix.md` shows module support; published from CI on every push to main | docs site review |
| The frozen-tiny core adds ≤50 KB to the WASM binary | size measurement in CI artifacts |
| Lazy-fetch first-import round-trip is <200 ms cold, <10 ms warm | benchmark page in `docs/` |
| The byte-exact regression detector stays at 537/541 | `make check` on every commit |
| The submodule sync workflow is documented and exercised at least once | a release-candidate tag with a documented submodule bump |
| At least 20 stdlib tests are present and tracked in the matrix | `tests/stdlib/` directory inventory |

## 8. Open questions (deferred to future ADRs)

- **Our own registry proxy.** Trigger to revisit: measurable user pain from registry latency / outages, or a desire to ship the wasm-tiny + frozen-tiny bundle as a single CDN asset.
- **Embedded story.** Per ADR-001 §3 this gets its own ADR if and when the audience materializes. The per-feature `registry-client` flag from ADR-002 is the lever for "frozen-only, no fetch."
- **Real `sys.meta_path`.** D5 defers the Python-side hook. If a future user demands custom loaders (likely use case: a tutorial site intercepting imports for sandboxing), we add it on top of the Zig resolver.
- **Stdlib matrix as a sustainability commitment.** Once published and treated as authoritative, the matrix is a real maintenance cost that scales with module count. A future ADR may bound the matrix size or define a deprecation policy.
- **`nanopython-lib/` contribution guide.** Naming conventions, test expectations, upstream-PR policy ("can we upstream this? if so, do it instead of carrying it here"). Needed once the first petitpy-specific module lands.
- **Package manager name.** The project is published as petitpy since 0.8 ([ADR 016](016-distribution.md)); `zpip` and the `nanopython:` cache keys above keep the development name until the internal rename, which the explicit placeholders keep mechanical.
- **Cache design across multiple runtime versions side-by-side.** Today's cache key assumes a single global runtime version. If we ever embed two petitpy binaries on the same page, the cache design needs revisiting.

## 9. References

- `001-roadmap-v04.md`: WASM-primary positioning that motivates the browser story here.
- `002-feature-selection.md`: the `-Dfeature-*` mechanism this ADR composes with for frozen-tiny build configurations.
- `github.com/micropython/micropython-lib`: upstream stdlib source (D1, D7).
- `docs.micropython.org/en/latest/reference/packages.html`: mip protocol documentation (D2, L3).

---

*This ADR is Proposed. Accept by editing the Status field once the maintainers agree.*
