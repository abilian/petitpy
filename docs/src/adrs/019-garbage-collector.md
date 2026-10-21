# ADR 019. A garbage collector: vendor's heap, conservative roots, safe points on wasm

- **Status**: Implemented (2026-10-11)
- **Decider**: project maintainers
- **Supersedes**: nothing
- **Branches from**: [ADR 005](005-future-optimization-proto.md) (its allocator row described a collector that did not exist), [ADR 006](006-js-interop.md) (JS interop assumes Python objects are collected)
- **Consequences**: memory is bounded on native and between JS callbacks on wasm; every object pointer must live where the collector looks (heap, writable data segment, C stack); every entry into Python from outside brackets its work for the wasm safe point; gc_lock no longer blocks allocation; files and sockets are closed when collected.

## 1. Context

Until 2026-10, petitpy had no garbage collector. The zigonly bootstrap replaced vendor `py/gc.c` with libc `malloc` and a no-op `gc_collect`, planned as temporary ("leaky libc for v1, real GC for v2"), and nothing picked it up. Memory grew with every object a program ever created: 1M `P(i, -i).norm1()` calls peaked at 66.8 MB, against 3.7 MB for MicroPython. Short scripts never noticed. Long-running ones did: a browser game calls into Python from JS every frame, and 2000 such callbacks took 1362 MB of wasm memory.

## 2. Decision

`src/memory/gc.zig` implements vendor `gc.c`'s heap design with a different root strategy.

**Heap.** Pools of 32-byte blocks (`4 * sizeof(usize)`, vendor's `MICROPY_BYTES_PER_GC_BLOCK`) with a 2-bit allocation table: free, head, tail, mark. As vendor's `MICROPY_GC_SPLIT_HEAP_AUTO`, the heap grows by adding areas: 1 MB, then each new area as large as the heap so far. `m_*` (`alloc.zig`) route through it, as vendor's `malloc.c` routes through `gc.c`; `m_realloc_maybe` grows in place when the next blocks are free.

**Allocation is next fit**, where vendor uses first fit: the search starts where the last allocation ended and wraps around once. With first fit, an explicit free leaves a one-block hole below the search hint, and every multi-block request rescans from it: 127x the instructions on the OO microbenchmark.

**Roots are found by scanning; nothing registers them.** A collection scans conservatively the executable's writable data segments (every Zig and C global, `mp_state_ctx` included), the C stack from the registers `setjmp` spills up to `MP_STATE_THREAD(stack_top)`, and then every marked allocation. Interior pointers mark their allocation (vendor only follows pointers to a head). This replaces vendor's `root_pointers` registration and the audit it would need of every Zig global that holds an object: a forgotten root is a use-after-free that shows up a long way from its cause, and conservative scanning makes forgetting impossible. The segments come from the Mach-O load commands of `_dyld_get_image_header(0)` on macOS, `dl_iterate_phdr` on Linux (each writable `PT_LOAD` separately: the gaps between them can be unmapped), and everything below `__heap_base` on wasm.

**Finalisers**, as vendor's `MICROPY_ENABLE_FINALISER`: an allocation made with `m_malloc_with_finaliser` sets a bit in its area's finaliser table, and after marking, before sweeping, each unmarked flagged object has its `__del__` called through `mp_call_function_1_protected`. Only native types are flagged (file objects and sockets, whose `__del__` is `close`); like vendor, a user class's `__del__` is never called. Vendor fails allocation inside a finaliser (the GC is locked); here a block allocated during the finaliser pass is created marked, so the sweep keeps it.

**Native collects when an allocation finds no room**, then adds an area if more than half the heap is still live, so collection work stays proportional to allocation.

**wasm collects only at safe points.** Values held in wasm locals are invisible to any scan, so collecting in the middle of a call is unsound. Each entry into Python from outside (a script, a REPL line, a `.mpy` run, a JS callback) brackets its work with `enterPython`/`leavePython`; when the outermost returns, no Python frame is live and linear memory below `__heap_base` (data and shadow stack) is the whole root set. A heap that fills mid-entry grows and asks for a collection at the safe point, which also collects once half the heap was allocated since the last one. `gc.collect()` called from Python waits for the next safe point. A single wasmtime script never reaches one before it ends; a browser page collects between callbacks.

## 3. Alternatives

- **Keep leaking, and document it.** Fine for scripts; unacceptable for the playground, games and ADR 006's callbacks.
- **An external collector (Boehm).** A new C dependency the runtime was not written against, and no help with wasm's invisible locals.
- **Vendor `gc.c` as-is, with `root_pointers`.** The heap design is kept; registration is not (above). Compiling `gc.c` as C would also read `MP_STATE_MEM` through a C layout that the Zig mirror does not match (`mpstate.zig`).

## 4. Consequences

- **Memory.** OO microbenchmark 66.8 MB → 3.6 MB native; 2000 garbage-making JS callbacks 1362 MB → 18.8 MB on wasm, flat at 10,000.
- **Cost.** +1–3.5% retired instructions on fibo, bubble and the OO microbenchmark. On fibo and bubble no collector code runs in the hot loop; the difference is code layout in the dispatch loop.
- **Object pointers must live where the collector looks**: the GC heap, the writable data segment, or the C stack. The collector misses `threadlocal` storage (outside the data segment on macOS and Linux; `embed_exec.pending_exc` was one), memory from libc `malloc` or `std.heap` allocators, and pointers hidden by tagging beyond REPR_A's.
- **libc and `m_*` pointers do not mix.** `m_realloc` on a libc pointer crashes, `m_free` ignores it, and libc `free` on a heap pointer corrupts libc.
- **New entry points into Python from outside must bracket** `gc.enterPython()` / `gc.leavePython()`, or wasm never reaches a safe point (or worse, reaches one while Python frames are live).
- **A host trap ends collection on wasm.** A JS exception that unwinds through `npy_dispatch_callback` skips `leavePython`, so the instance never collects again.
- **Departures from vendor semantics.** `gc_lock` defers collection but still allows allocation (vendor returns NULL); a finaliser may allocate; `gc.mem_alloc()`/`gc.mem_free()` report the real heap.
- **A finaliser must not resurrect its object** (store `self` somewhere reachable): the sweep frees it right after, as in vendor.

## 5. Verification

- `NPY_GC_STRESS=N` collects every N allocations (native). With N=1 the nano corpus (541/541), the full arm and the integration suite pass on macOS and Linux, on ReleaseFast builds.
- `make wasm-gc-check` drives the web build like a page, under Node. Memory stays flat; a linked list, closure, suspended generator, list and bytearray stay intact through thousands of collections.
- Integration case `gc_reclaims_garbage`: 300k dropped objects leave a heap under 8 MB (native). `gc_closes_dropped_files_and_sockets`: 200 dropped files and sockets leave no open descriptors.

## 6. See also

- `src/memory/gc.zig` (the collector), `src/memory/alloc.zig` (`m_*`).
- Vendor `py/gc.c`, the heap design this follows.
- [ADR 006](006-js-interop.md), the JS bridge whose callbacks (`npy_dispatch_callback`) are the wasm safe points in practice.
