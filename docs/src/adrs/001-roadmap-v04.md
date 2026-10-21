# ADR 001. v0.4 roadmap: WASM-primary positioning + feature completeness

- **Status**: Closed. Implemented in v0.4. Superseded by [ADR 009](009-roadmap-v05.md) (v0.5 roadmap).
- **Decider**: project maintainers
- **Supersedes**: nothing (this is the first ADR).
- **Consequences**: pivots the project to WASM-primary positioning; scopes v0.4 to six themes; defers embedded, threading, and pre-existing nano gaps to v0.5+.

## 1. Context

v0.3.0 is the strangler-complete + multi-arch + wasm-demo milestone. In numbers:

| Surface | State at v0.3.0 |
|---|---|
| Compiled C under nano | ~86 LOC (`objmodule_shim.c`, qstr-gen tombstone holding `MICROPY_REGISTERED_MODULES`) |
| Compiled C under full | ~3,300 LOC vendor (mpz + objint + modio + objstringio + warning + builtinhelp) |
| Zig surface | ~14.8 KLOC + ~9.6 KLOC of C shims + ~3.8 KLOC of generated headers |
| nano corpus (arm64-macos) | 537/541 byte-identical to the nano-C reference |
| full corpus (arm64-macos) | 511/552 (~92.6%) vs upstream-MicroPython oracle |
| x86_64-macos | builds; runtime untested (no host) |
| x86_64-linux | broken; Darwin externs in `file_io.zig` |
| wasm32-wasi | builds and runs Python (~286 KB ReleaseSmall) |
| Web demo | functional locally (`web/index.html` + `app.js` + `nanopython.wasm`) |

The strangler arc has converged: nano compiles zero vendor C and the byte-exact oracle catches faithful-port regressions in seconds. The full arm went through F0-F5 rehab and landed at 92.6%, within reach of the pre-break 96.9% baseline, with the remaining gap dominated by one cluster (async/await, ~28 tests).

v0.1.0 also crossed the *portability ledge*: a working wasm binary that executes Python in the browser. That ledge makes v0.4 a coherent next step, avoiding "more of the same."

### 1.1 What v0.1.0 deferred

v0.1.0 deferred five things: async/await, mpz → Zig (F2b), CI, a public web demo and benchmarks against upstream. The rationale for postponing all five was disciplined scope. v0.1.0 was about *finishing the strangle and proving wasm*. Adding any of the above would have diluted that invariant.

### 1.2 Why a v0.4 at all

v0.1 is a successful research artifact. v0.4 should make it a **usable artifact**:

- A contributor can clone, build, run tests in CI, and trust the green light.
- A curious Python person can hit a URL and run code without a toolchain.
- The corpus reaches near-parity with upstream's feature surface.
- It works on the platforms a researcher would actually try (arm64 macOS AND Linux x86_64).

v0.4 stays narrow: no architecture rewrites, no speculative features, no embedded pivot. Those belong in v0.5+.

### 1.3 Strategic pivot: WASM is the primary target

As of this ADR, WebAssembly is the primary positioning of petitpy. The 286 KB ReleaseSmall wasm binary that runs Python in the browser is the most distinctive artifact the project produces, far more communicable than corpus counts or LOC savings. v0.4's priorities reflect that: a public web demo, a smaller wasm binary, and per-feature stripping so users can pick exactly the surface they need. The strangler-narrative and native-binary stories stay as supporting material; embedded targeting and threading remain deferred to v0.5+. This shift is purely positional; the source structure stays put.

## 2. Decision: six themes for v0.4

Themes are independent, each has a clear deliverable, each closes when its success metric trips. The dependency graph is shallow enough that they can run in parallel; §3 gives the intended sequencing.

### Theme A. Feature completeness under full (async/await arc)

Close the largest single feature gap on the full corpus by porting async/await:

- Lexer: recognize `async`, `await` as PEP 492 soft keywords.
- Parser: add the four grammar productions (`async def`, `await EXPR`, `async for`, `async with`).
- compile.zig: emit `GET_AWAITABLE`, `YIELD_FROM` reuse for `await`, `SETUP_ASYNC_WITH` for `async with`.
- Runtime: native coroutine type backed by the existing generator machinery (the same trick MicroPython uses).
- Nano corpus unchanged at 537/541.

**Success metric**: `CONFIG=full make check` reports the async cluster passing.

**Risk**: async/await touches lexer state. The "soft keyword" semantics (only inside `async def`) require tracking nesting context. If the spike reveals deeper interaction with the f-string mini-parser, regroup.

### Theme B. Production tooling (CI + releases)

Every commit gets validated automatically; tagged releases produce downloadable artifacts. CI is also the prerequisite for any future "accept PRs from strangers" posture.

**Why SourceHut over GitHub Actions**: config-as-code, vendor-neutral, aligned with the project's open-toolchain ethos. Manifests are first-class repo artifacts. Runner pool is Linux/BSD (the platforms the strangler targets natively). Free tier is generous for a single-maintainer project. The trade-off is that there are no macOS runners.

Deliverables:

- `.builds/debian-nano.yml`. Primary "must-pass" gate: `make port` → `make build` → `make check` → `make test-unit` → `make test-integration` → `make lint`.
- `.builds/debian-full.yml`. Secondary gate: same setup, `CONFIG=full`, softer threshold.
- `.builds/cross-arch.yml`. Cross-compile matrix: `x86_64-macos`, `aarch64-macos`, `wasm32-wasi` (with wasmtime run), `x86_64-linux` (host build + smoke test). `aarch64-linux` was skipped in v0.4 due to a Zig 0.16 toolchain limit.
- Releases: tagged-build manifest that cross-compiles for the four shippable targets and publishes binaries + SHA-256 sums.
- README badge pointing at the nano manifest.

macOS coverage is "cross-compile from Linux" plus a maintainer-gated runtime check on their own arm64 mac.

**Success metric**: SourceHut badge green on every commit landed to `main`. Tagging `v0.4.0` produces four downloadable binaries.

### Theme C. Web reach (public demo + polish)

Anyone can visit a URL to run Python in the browser. Under WASM-primary positioning, this URL is the primary surface a new visitor encounters: the README, project tagline, and v0.4.0 release narrative all hang off it.

Deliverables:

- Public deployment to GitHub Pages (default; fallback to Netlify/Vercel if size limits bite).
- A Web Worker wraps the interpreter loop so long-running scripts keep the page responsive.
- A `<textarea>` for stdin, mapped to the WASI stdin descriptor so `input()` works.
- Script library in `localStorage`: save / load / list, three preloaded examples.
- Share button producing a URL with the script base64-encoded in the fragment.

**Non-deliverables**: REPL-style stateful session, graphical output, file uploads.

**Success metric**: URL exists; preloaded examples run without page-freeze; long-running scripts can be canceled.

**Risk**: browser WASI shims differ from wasmtime. Scope Theme C's stdin to a textarea-fed implementation; a true WASI stdin descriptor can come later.

### Theme D. Cross-platform reach (x86_64-linux fix + target tiering)

Fix the x86_64-linux build (gate `__stdinp` / `__error` references in `src/modules/file_io.zig` via `@hasDecl`, fall through to `stdin` / `errno` on glibc). Document the target tier:

- **Tier 1**: arm64-macos, x86_64-linux. CI-gated, corpus-verified, supported.
- **Tier 2**: x86_64-macos, wasm32-wasi. CI-built, smoke-tested, expected to work.
- **Tier 3**: Windows (via WSL or `-Dtarget=x86_64-windows-gnu`). Community-supported.

**Success metric**: `make build` succeeds on stock Ubuntu LTS; corpus runs to 537/541.

### Theme F. Size + per-feature stripping

Shrink the wasm binary and let users pick the surface they need. Ship a DCE audit, document a "Tier 4 wasm-only" config, and (once [ADR 002](002-feature-selection.md) picks the per-feature approach) wire it through so a downstream user can build a `nanopython.wasm` with only the modules and features they need.

Under WASM-primary positioning, every kilobyte of the wasm binary is a download cost paid on every page-load. Per-feature picking is also the lever that makes petitpy *differently useful* from MicroPython: the positioning shifts from "MicroPython with Zig" to "the Python runtime you can shrink to fit."

**Blocked on**: ADR 002 picks Path A (config-flag matrix) / Path B (module-level Zig comptime) / Path C (link-time DCE). This ADR reserves the slot.

**Deliverables (post-ADR 002)**:
- DCE audit measuring which functions and symbols remain in the wasm binary today.
- Per-feature picking implemented per ADR 002's chosen path.
- Two or three reduced configs (`wasm-minimal`, `wasm-no-fp`, ...) with measured binary deltas.
- Tier 4 "wasm-only" config documented.

**Success metric**: `wasm-minimal` is ≥20% smaller than the 286 KB baseline.

**Risk**: per-feature picking can metastasize into config-explosion. Ship exactly the configs the wasm-primary story needs; resist adding more until v0.5+ user demand.

### Theme E. Performance baseline (optional)

Measure petitpy vs upstream MicroPython on a representative microbenchmark suite. Publish the numbers.

Under WASM-primary positioning, size eats speed's lunch as the headline metric. Perf becomes a v0.5 differentiator if Theme F lands cleanly. Ship Theme E in v0.4 only if the four required themes have landed with budget remaining.

**Success metric**: `docs/benchmarks.md` exists with a comparison table. No specific number target; the deliverable is *information*.

## 3. Sequencing

The intended order is D → A → B → C. F runs concurrently once ADR 002 lands; E is optional.

- **D first** because it's the smallest and it unblocks B's CI matrix. ~1 session.
- **A second** because it's the longest theme and we want to start the long pole early. 3-5 sessions with architectural risk (lexer state machine).
- **B third** because A's deliverable makes CI meaningful: the CI gate immediately validates the biggest new code.
- **C next** because under WASM-primary positioning the URL is the project. The web demo gets a curious visitor from a tweet to running code in seconds.
- **F concurrent with C** because size and demo are the same story. Per-feature stripping shrinks the binary the public demo serves. F is blocked on ADR 002; once that lands, F and C run in parallel.
- **E last (and optional)** because its value is informational.

## 4. Out of scope for v0.4

These directions are explicitly deferred, each with its rationale:

| Direction | Why deferred | Earliest target |
|---|---|---|
| Project rename | The naming question is real but gates no v0.4 deliverable. Revisit post-Theme C launch. | v0.5+ |
| F2b: port mpz.c to Zig | Well-tuned arbitrary-precision arithmetic; porting buys zero user-visible behavior. Purely architectural cleanup. | v0.5 or v0.6 |
| Embedded port | Different problem class (HAL, board bring-up, flash constraints). Under WASM-primary positioning, embedded slips further out. Deserves its own ADR with a differentiator statement. | v0.5+ (after WASM-primary settles) |
| Threading + GIL | Zero threading tests, zero threading infrastructure. Browsers lack pthread-equivalents in WASI. | v0.5+ at earliest; v1.0+ for full support |
| Walrus-in-genexpr fix (3 tests) | Blocked by the nano-frozen-bug discipline. Right resolution is a separate ADR about *what nano-C-reference means going forward*. | needs design ADR first |
| `__set_name__` hook (3 tests) | ~150 LOC port of vendor `objtype.c`. Tractable but uninspiring. | v0.5 long-tail sweep |
| New strangler experiments on other projects | Lessons-learned doc captures the reusable principles. Pointing the strangler at Lua/Ruby is a genuinely interesting move but it's a different project. | post-v1.0 / separate repo |
| Remaining nano gaps at 537/541 | `builtin_dir`, `builtin_help`, `gc1`, `memoryerror`, `special_methods2`, `string_fstring`, `string_strip`. Each needs its own focused arc. | rolling; close opportunistically |

## 5. Risks and trade-offs

- **The async/await arc could grow.** Vendor `compile.c`'s async path interacts with generator infrastructure in ways F-rehab didn't touch. Mitigation: bounded spike first; read vendor before writing new code. If the read reveals 20+ vendor functions need porting, regroup.
- **CI compute budget could constrain.** SourceHut's free-tier minutes are finite. Mitigation: pin a MicroPython SHA in `sources:` so `make port` is one shot. If volume grows, swap to a paid tier.
- **Public web demo invites scrutiny.** A URL means adversarial Python (infinite loops, memory bombs, WASI-sandbox probing). Mitigation: Web Worker isolates compute; the docs say "demo, not a service"; static-only deployment leaves no persistent storage.
- **WASM-primary positioning could be marketing more than substance.** If the demo fails to gain traction, the fallback is repositioning toward the embedded angle (with its own ADR). The v0.4 themes themselves (web demo, size shrink) ship value either way. Repositioning is reversible at the README level.

## 6. Success criteria

v0.4.0 ships when:

- Theme A: full-corpus async cluster passes.
- Theme B: SourceHut manifests present and working; v0.4.0 tag produces release artifacts.
- Theme C: public URL serves the demo; preloaded examples run; Web Worker isolates the runtime.
- Theme D: `make build` succeeds on stock Ubuntu LTS x86_64; corpus runs 537/541 there.
- Theme F: per-feature picking shipped; wasm binary ≥20% smaller than 286 KB.
- (Optional E): `docs/benchmarks.md` exists.
- Nano invariant preserved on every commit: `make check` = 537/541.

The themes are independent enough that none singly gates a v0.4.0 ship; v0.4.0 needs at least Theme C (the public demo) to justify the version bump. Theme F is the strong second.

## 7. Open questions for v0.5+

- **Does nano-C-reference still serve us?** As the strangler converges, the nano-C oracle is constraining design choices (walrus, `__set_name__`) we'd otherwise fix. A future ADR should decide: refreeze against our own output, retire nano as a separate corpus, or live with the constraint.
- **Is the strangler "done"?** A v0.5 ADR should pick a definition and declare.
- **Should we add a CPython oracle?** It would expose MicroPython-vs-CPython semantic divergences our current oracle hides.
- **What's the embedded story?** If ever in scope, needs its own ADR with the differentiator versus stock MicroPython stated.

## 8. See also

- `README.md`: public-facing surface.
