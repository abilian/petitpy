# ADR 013. Restoring exception unwinding across vendor-C frames (the try/except-over-MPZ wall)

- **Status**: Implemented in v0.7.0 as B' (§4): native `full` only; wasm kept `exit(1)` for vendor-C raises (drafted 2026-06-13). Amended in v0.9 (§7): the same trampoline runs on every wasm build, its setjmp/longjmp lowered to wasm exception handling. The runtime layout check this ADR planned to re-enable (§4 step 4) was deleted instead: its constants came from the same Zig types it checked. The comptime assertions in `src/runtime/mpstate.zig` guard the state layout.
- **Decider**: project maintainers
- **Supersedes**: nothing
- **Branches from**: ADR 012 §3 D2 (per-feature flags as the only durable gate; this ADR introduces `build_options.exception_unwind` following that discipline). Phase 3.5 step 4 + 6 retrospectives documented the limitation that this ADR resolves.
- **Consequences**: introduces a second exception-propagation discipline (setjmp/longjmp trampolines around enumerated vendor-C entry points) alongside the existing polled-sentinel; gated on a new `build_options.exception_unwind` flag (default true on `full`, false on `nano` + wasm32 carveout per spike result); commits to maintaining a small, explicit wrapped-set in `src/runtime/nlr_trampoline.zig`; re-enables `npy_mirror_layout_check()` to defend the dual-discipline ABI; commits to porting wrapped vendor-C subsystems to Zig over time (Alternative E) as the eventual destination, with each port retiring its trampoline.

## 1. Context

The strangler retired NLR (vendor MicroPython's `setjmp` / `longjmp` over `mp_nlr_buf_t` chains) in favor of a polled-sentinel protocol: `pyerr.pending_exc` is set at the raise site, every caller polls after a potentially-raising call, and the VM dispatch loop polls between every opcode (`src/runtime/vm.zig:415-435`). `try`/`except` dispatch (`src/runtime/vm.zig:199-271`) just works under this discipline as long as every frame between the raise and the handler is Zig-with-`try` or C-that-polls. NLR removal was the prerequisite for wasm32-wasi (no clean `setjmp`/`longjmp` there).

Phase 3.5 of ADR 012 brought the `full` arm to 524/552 (94.9%) by re-adding vendor C subsystems that the strangler had removed: `py/objint_mpz.c`, `py/mpz.c`, `py/objint.c`, `py/modio.c`, `py/objstringio.c`, `extmod/modre.c`, etc. These files contain `mp_raise_msg` / `mp_raise_ValueError` / `mp_raise_TypeError` / `mp_raise_OSError` call sites that assume NLR will unwind back to a registered handler. Without NLR, the strangler ported these helpers as @panic stubs ("unreachable under nano"). Phase 3.5 steps 4 + 6 liberated them to a graceful exit path: `pyerr.pending_exc = exc; print traceback; exit(1)`. The `exit(1)` bypasses Python `try`/`except` entirely.

**Affected tests today (residual after ADR 012 Phase 3.5):**

- 4 intbig (`builtin_divmod_intbig`, `builtin_pow3_intbig`, `int_big_error`, `int_bytes_intbig`). Example: `try: divmod(1<<65, 0); except ZeroDivisionError:`
- 2 io (`io_bytesio_ext2`, `io_stringio1`). Example: `try: bio.read(); except: ...`
- parts of `builtin_pow3` (`try: pow("x", 5, 6); except TypeError:`)
- probably more once additional vendor C lands in the link

Affected vendor C raise sites enumerated by exploration:

- `py/objint_mpz.c:240,279,295,358,360,444,462`: divide-by-zero, negative shift, negative power, pow3 type-check, OverflowError
- `extmod/modre.c:454,468`: "regex too complex", "error in regex"
- `py/modio.c:173`: `mp_raise_OSError(err)` in I/O paths

The strangler removed both NLR AND the ability to add C frames that raise back to Python frames without reintroducing the mechanism somehow. Adding more vendor C to the link (which Phase 3.5 will continue) widens this gap.

## 2. Decision space

How do we let Python `try`/`except` catch exceptions raised inside vendor C code that's still in the link, without losing the strangler's gains (no defer-across-longjmp hazards in nano, wasm32 stays clean, native 541/541 sacrosanct, vendor C surface trending down not up)?

The decision splits along three axes:

1. **Where the unwind discipline lives.** Vendor-C-side via NLR (re-add setjmp/longjmp), or polled-sentinel extended into vendor C via patches, or accept the exit.
2. **Which arms/platforms get the fix.** Full-only or both arms; native-only or wasm too.
3. **How much vendor C surface we re-add or patch.** The strangler's "net-shrink C" discipline constrains this.

## 3. Alternatives

### A. Restore vendor NLR under full only (setjmp + nlr_buf_t shim)

Re-add `vendor/micropython_embed/py/nlrsetjmp.c` (+ `nlr.c`) to `build.zig` gated on a new `build_options.exception_unwind` flag (default on for full, off for nano). Rewrite `longlongRaiseDie` under full to call `nlr_jump(exc)` where it now calls `exit(1)`. Re-author the lost `npy_nlr_run` trampolines (~3-4 entry pads at the VM frame boundaries; note these were removed entirely, beyond being disabled, per `vm.zig:6,276` and `raise.zig:13` removal-of comments).

| Dimension | Value |
|---|---|
| LOC change | +180-220 net Zig/build; re-adds 124 LOC vendor C; corrected from the original +150 estimate (audit found `npy_nlr_run` trampolines are *gone* and must be reauthored) |
| Binary size | Native full: +5-15 KB. Nano + wasm: unchanged. |
| Runtime overhead | ~10ns setjmp per protected VM-frame entry on amd64; ~2-5% perf hit on bytecode benchmarks |
| Nano risk | Zero by construction if strictly gated on `build_options.exception_unwind=false` for nano |
| Wasm portability | Conditional on the setjmp spike (open question) |
| Tests unblocked | ~10 |

**Pros:** highest fidelity to vendor MP; centralized push pad covers all vendor-C raises that follow.

**Cons:** it reintroduces the defer-across-longjmp footgun the strangler removed; the scope is full only, yet the bug class returns. The runtime under full gets two disciplines (polled-sentinel + NLR), and mixing them races: Zig sets `pending_exc`, vendor C runs and longjumps, and `pending_exc` is now stale, so every NLR unwind must clear `pending_exc`. It also re-adds 124 LOC of vendor C, violating the strangler-discipline "net-shrink" rule.

### B. Hybrid trampoline: setjmp per high-value vendor-C call site (RECOMMENDED)

No global NLR chain. Write a small Zig/C trampoline `npy_call_vendor_with_setjmp(fn, args)` that does setjmp locally, registers an `nlr_buf_t` for the duration of the call, and on longjmp converts to polled-sentinel (`pyerr.pending_exc = val; return error sentinel`). Wrap an enumerable set of vendor-C entry points: the binary-op dispatcher (covers all 7 MPZ raises), the stream write/flush path (covers `modio.c:173`), and 3-4 more high-value sites identified by triage.

| Dimension | Value |
|---|---|
| LOC change | +110-150 net Zig/C; corrected from the original +70-110 estimate (audit found 6 raise helpers in raise.zig need dual-mode rewrite, and wrap-site coverage was undercounted) |
| Binary size | +1-3 KB (one trampoline + jmpbuf per active wrapped call). Smaller than A. |
| Runtime overhead | setjmp paid per wrapped vendor-C call (not per VM entry). 10-30% overhead on MPZ-heavy microbenchmarks; invisible on real programs. |
| Nano risk | Zero if exception_unwind=false on nano. Trampolines compile to no-ops there. |
| Wasm portability | Conditional on the setjmp spike (open question). If spike fails, B becomes B' = native-only B (Alternative C shape). |
| Tests unblocked | ~7 (after the modio.c wrap-target correction; modre raises stay blocked pending E port) |

**Pros:** best tests-unblocked-per-LOC ratio; no vendor C re-added (preserves strangler-discipline "net-shrink C" rule); scopes the defer-across-longjmp footgun to a small enumerable set of wrapped sites; aligns with the natural boundaries where polled-sentinel polls already live.

**Cons:** inconsistent UX (`try/except` catches `ZeroDivisionError` from wrapped MPZ and misses `re.error` from unwrapped modre); the wrapped-set tends to grow as new tests expose unwrapped raises, paying scaling interest over time until E completes the ports. The verifier flagged that the original `modio.c:173` wrap target was wrong (the raise fires from the `mp_stream_write_exactly` flush path; `mp_stream_read` never raises it); fixed in this draft.

### C. POSIX-only NLR (A + explicit wasm `exit(1)` carveout)

Alternative A applied with a clean target-gate: `nlrsetjmp.c` + the `longlongRaiseDie` rewrite compile only when `target.os.tag != .wasi`. Wasm full arm keeps `exit(1)`. Documents the platform divergence in the feature matrix (ADR 012 update). Same `is_wasm` gate pattern already used at `build.zig:189` (`LongintImpl`) + `build.zig:385`.

| Dimension | Value |
|---|---|
| LOC change | +180-220 (same as A); 124 LOC vendor C (native-target only) |
| Binary size | Native full: +5-15 KB. Wasm: unchanged. |
| Runtime overhead | Native: same as A. Wasm: zero (still exits). |
| Nano risk | Zero (same gating as A) |
| Wasm portability | Wasm semantics unchanged by construction |
| Tests unblocked | ~10 on native; 0 incremental on wasm |

**Pros:** closes the visible native test gaps with vendor-MP fidelity; preserves the strangler's original wasm-clean invariant.

**Cons:** permanent native-vs-wasm semantic divergence (`try: 10**100 except OverflowError:` works on the dev binary, dies on the wasm build): ages badly; cuts against ADR 012's "default is the powerful CPython experience" framing.

### D. Wasm-exceptions proposal (true exception unwinding via WasmEH)

Use the WebAssembly exception-handling proposal (`-fwasm-exceptions`, `__builtin_wasm_throw` / `__builtin_wasm_catch`). Write a new `nlrwasm.c` (~80 LOC, parallel to `nlrsetjmp.c`). Toolchain transforms the unwind into wasm `throw` / `catch` with out-of-line unwind tables.

| Dimension | Value |
|---|---|
| LOC change | +50 build glue + ~100 Zig shim + ~80 LOC new nlrwasm.c; combined: +200-250 total |
| Binary size | Wasm: +1-3 KB shim. WasmEH unwind tables are out-of-line: can be size-NEUTRAL or smaller than setjmp. |
| Runtime overhead | Wasm: zero per-frame entry cost (only pays on raise). Best perf profile of all alternatives on the unwind path. |
| Nano risk | Low if cleanly gated on `build_options.wasm_exceptions` |
| Wasm portability | The whole point; toolchain readiness is UNVERIFIED |
| Tests unblocked | ~10 |

**Pros:** best long-term wasm story; closes the platform divergence Alternative C documents; best perf profile (zero per-frame cost; only pay on raise).

**Cons:** toolchain readiness unverified (needs spike: 10-line C with `__builtin_wasm_throw`, build with current zig 0.x + wasi-sdk, run under wasmtime); WasmEH spec has had two iterations (legacy + new), and zig / wasi-libc may pin only one of them.

### E. Stay course + document + replace vendor C with Zig over time

Keep `exit(1)`. Document the ~10 affected tests as "vendor-C raise across non-NLR boundary" in a new `corpus/full-known-fails.txt` (analogous to wasm's). Track each affected vendor file (`objint_mpz.c`, `mpz.c`, `objint.c`, `modre.c`, `modio.c`, `objstringio.c`) as a port target. Each port lands a Zig replacement that natively uses polled-sentinel; the corresponding tests close as ports complete.

| Dimension | Value |
|---|---|
| LOC change | 0 today; ~3000-5000 LOC of vendor C to port over multiple cycles |
| Binary size | Zero short-term. Long-term net SHRINK as ports land. |
| Runtime overhead | Zero new (status quo) |
| Nano risk | Zero (no code change) |
| Wasm portability | N/A (no code change) |
| Tests unblocked | 0 short-term; ~10 across multiple cycles as ports land |

**Pros:** aligns perfectly with the project's stated direction; respects the strangler-discipline rule.

**Cons:** zero tests closed this session: the ~10 affected tests stay broken for cycles; `exit(1)` on `try/except` is a permanent papercut every demo writer and corpus author hits.

### F. Vendor-source patches converting `mp_raise_*` callers to polled-sentinel

Extend the polled-sentinel discipline INTO vendor C via small patches maintained at `make port` time. Convert ~15 vendor `mp_raise_*` call sites to set `pyerr.pending_exc` + return `MP_OBJ_NULL` (or equivalent sentinel for the callee's return type). Cascade fixes: every caller of every patched function must also poll.

| Dimension | Value |
|---|---|
| LOC change | +30 patch lines + cascade fixes (tens of vendor functions deep for MPZ); ~150 LOC patches + ongoing maintenance |
| Binary size | Probably -2 KB (mp_raise_* trampolines simpler; no setjmp infra) |
| Runtime overhead | Zero (one branch per polled check, matches existing nano discipline) |
| Nano risk | Low if patches generate identical C for both arms |
| Wasm portability | Wasm-clean by construction |
| Tests unblocked | ~8 |

**Pros:** extends the project's existing discipline and grafts no competing one; best long-term ideological fit with the strangler philosophy.

**Cons:** patch rot vs upstream MicroPython: every `make port` cycle requires re-merging; quarterly upstream pulls become significantly more expensive; cascade depth: sentinel propagation must thread through tens of vendor MPZ functions, each patched function's callers also need to poll.

## 4. Recommendation

**B (Hybrid trampoline) for v0.7, with E (port-over-time) as the long-term destination and a documented intent to evaluate D (WasmEH) once toolchain readiness is verified.**

**Why B:** it has the best tests-unblocked-per-LOC ratio (~7 tests / ~120 LOC). It re-adds no vendor C, which preserves the strangler-discipline rule. It scopes the defer-across-longjmp footgun to a small enumerable set of wrapped sites, aligned with the natural boundaries where polled-sentinel polls already live. It closes the headline UX papercuts (ZeroDivisionError, OverflowError, OSError, StringIO close) this cycle without committing to a global NLR restoration. A is mechanically cheaper but reintroduces 124 LOC vendor C and a global dual-discipline runtime: too much surface for too little marginal benefit over B. C splits the contract on platform lines (bad for portability + CPython-experience framing). D is the best long-term wasm answer but toolchain readiness is unverified. F is ideologically clean but maintenance-toxic at `make port` cadence.

**Execution outline:**

1. **Spike (30 min)**: write a 10-line setjmp/longjmp roundtrip in C, build with `zig cc -target wasm32-wasi`, run under wasmtime. Settles the wasi-libc setjmp question that gates B (and A and C). If setjmp works on wasm32-wasi, B is single-flag-gated; if it doesn't, B becomes B' (native-only wrap; wasm full retains `exit(1)`).
2. **Add `build_options.exception_unwind` flag** in build.zig (default true on full, false on nano). Do NOT use `is_full` as the gate (ADR 012 §2.4 deprecates it as a feature predicate).
3. **Write the trampoline shim** in `src/runtime/nlr_trampoline.zig` (~30 LOC): `npy_call_vendor_with_setjmp(fn, args)` sets up a local `nlr_buf_t`, registers it in `mp_state_ctx.thread.nlr_top`, calls fn, on longjmp converts `nlr_buf.ret_val` to `pyerr.pending_exc` and returns an error sentinel.
4. **Re-enable `npy_mirror_layout_check()`** at `src/main.zig:202` as a prerequisite: the disabled `mp_state_vm._pad0` layout checks at `mp_mirrors.zig:1199-1203` are the exact ABI-mirror hazard NLR restoration reactivates.
5. **Wrap 3 high-value vendor entry points:**
   - `mp_obj_int_binary_op` at runtime.zig binary-op slot dispatch (covers all 7 MPZ raises)
   - `mp_stream_write_exactly` at the io slot dispatch (covers `modio.c:173`; corrected target per verifier flag)
   - `mp_obj_int_pow3` at modbuiltins powImpl (covers pow3 type-check + divide-by-zero)
6. **For modre.c:** defer to E (port modre wrapper to Zig in a follow-up cycle). Document `re_error` / `re_limit` tests as known failures with a tracking reference.
7. **Land golden refreshes** for the now-passing tests (4 intbig + 2 io + pow3 portions). Verify the wasm gate stays at its baseline.
8. **Update ADR 012's feature matrix** to add "exception unwind across vendor C" as a named feature, on by default for full, with the wrapped-set listed explicitly.

**Success criteria:**

- Native gate stays at 541/541 (the strangler invariant; non-negotiable).
- Full arm corpus moves from 524/552 to ≥530/552 (target: +6 tests from the wrapped-set; +10 if modre is wrapped too).
- Wasm gate stays green (`wasm-known-fails.txt` unchanged or shrinks; never grows).
- Integration suite stays at 30/30 on both arms.
- `npy_mirror_layout_check()` runs at startup and passes on amd64 + wasm32 (validates the ABI-mirror hazard is closed).
- The 4 intbig tests (`builtin_pow3_intbig`, `builtin_divmod_intbig`, `int_bytes_intbig`, `op_error_intbig`) and the 2 io tests (`io_stringio1`, `io_bytesio_ext2`) pass via real `try/except`, verified by reading the test source for the `try/except` shape and confirming byte-exact match against vendor MP.
- An ADR-013-follow-up issue is filed tracking modre + future high-value sites as port targets (Alternative E), with explicit milestones.

## 5. Consequences

**Positive.** The headline UX papercut closes: `try/except ZeroDivisionError`, `OverflowError`, `OSError`, and `ValueError` over StringIO operations behave like CPython on full. ~7 corpus tests move from failing to passing. The strangler-discipline rule (net-shrink C) is preserved (no vendor NLR re-added). The polled-sentinel discipline remains the project's primary error-propagation model; the trampolines are a scoped exception to it. Re-enabling `npy_mirror_layout_check()` pays down deferred v0.6.0 layout debt. The wrapped-set is explicit and enumerable in the codebase, so future maintainers can audit it without surprise.

**Negative.** Two error-propagation disciplines coexist under full (polled-sentinel + scoped NLR), each with distinct hazards. Defer-across-longjmp returns as a bug class for any Zig code that uses `defer` inside a wrapped vendor-C call (mitigation: wrapped-set is small and audit-able; CI-style invariant possible). Wasm full's behavior depends on the setjmp spike: if wasi-libc's setjmp doesn't work cleanly, wasm full retains `exit(1)` and Alternative C's platform divergence reappears (mitigation: WasmEH (D) becomes the explicit follow-up).

## 6. Open questions

- **Does setjmp/longjmp work in the current zig + wasi-sdk bundle for wasm32-wasi?** Investigated: no. `wasm-wasi-musl/setjmp.h` `#error`s out unconditionally ("Setjmp/longjmp support requires Exception handling support, which is not yet standardized"). Even `-mllvm -wasm-enable-sjlj` doesn't bypass the header guard. **Alternative B → B' (native-only trampoline; wasm full retains `exit(1)`).** Wasm divergence gets documented as a known-issue; the projected closures land on native only. WasmEH (D) becomes the explicit follow-up if/when the wasi-libc header guard relaxes.
- Is WasmEH support in zig 0.16+ stable enough to commit to as the wasm-side answer? (30-minute spike: `__builtin_wasm_throw` + wasi-sdk + wasmtime roundtrip.)
- What is the cascade depth of polled-sentinel propagation in vendor MPZ if we ever pursue F? (1-2h spike: manually convert `objint_mpz.c:240` divide-by-zero to `pending_exc` + return null, count how many cascading patches result.)
- Should the trampoline shim live in Zig (cleaner, but Zig's setjmp/longjmp interop is limited) or in a thin C file (matches vendor pattern, easier setjmp ABI)?
- Re-enabling `npy_mirror_layout_check()` may expose latent `mp_state_vm` layout drift on wasm32 (the deferred v0.6.0 hazard). Estimated effort to refit the partial mirror?
- Once modre is wrapped (or ported), does the same trampoline pattern naturally extend to future high-value vendor C subsystems (e.g. when stdlib additions reach for vendor extmod files)?
- Does ADR 012 need an explicit feature-matrix row for "exception unwind across vendor C" with the wrapped-set enumerated, or is a known-failures entry sufficient?
- When E lands its first port (`modio.c` → Zig is smallest at ~150 LOC), does the corresponding trampoline get removed in the same commit, or kept as defense-in-depth?

## 7. Amendment (v0.9): the trampoline on wasm

The wasm build moved to MPZ integers in v0.9, which made far more vendor-C raises reachable in the browser: `big // 0`, a negative shift, `int(None)`, `to_bytes` overflow. Each one ended the program with a traceback instead of reaching `except`. That was already true of `int([])`.

§6's investigation stopped at the `wasm-wasi-musl/setjmp.h` guard. The guard only checks `__wasm_exception_handling__`, and wasi-libc ships the runtime half of LLVM's wasm setjmp/longjmp lowering (`libc-top-half/musl/src/setjmp/wasm32/rt.c`). With those, the trampoline of B' works on wasm unchanged:

- `exception_unwind` is true on every wasm build, as on native `full`.
- `nlr_trampoline.c` and `rt.c` alone compile with `-mllvm -wasm-enable-sjlj` and the exception-handling target feature. A throw unwinds through every other frame, which needs no change.
- The browser build (the one with the `js` bridge, which npm ships) uses the legacy encoding, which browsers and Node have run by default for years. The wasmtime build uses the exnref encoding (`-wasm-use-legacy-eh=false`), the only one wasmtime runs (on by default in 47), which older Node releases do not run by default.
- `rt.c` is compiled by `build.zig`, not taken from Zig's wasi-libc: turning on exception handling for the whole link makes Zig rebuild wasi-libc with it, and LLVM 21 crashes on that build of `rt.c` ("undefined tag symbol cannot be weak").
- `wasm-opt` needs `--enable-exception-handling --enable-reference-types`. The per-call setjmp of `npy_nlr_call_function`, as on native, did not show under wasmtime: a loop of two million Python calls ran no slower. Together with MPZ, the browser build grew by about 9 KB, 3.7 KB gzipped.

This closes Alternative D's open question and §5's wasm divergence. The wrapped set stays the same; one site outside it, the machine-word conversion behind a subscript (`[1][2**100]`), now raises polled on every build instead of through vendor C.
