# nanopython differential-test corpus

This corpus is the **regression safety net** for the strangler migration. The
invariant it enforces: *every nanopython build must produce byte-identical
output to the frozen reference.*

## Reference

The strangler reference is the **nano-C build** itself:
`zig-out/bin/nanopython` (the embed C package built by `build.zig` with
`port/mpconfigport.h`). Its own output — including errors from
deliberately-disabled nano features — is the contract every C→Zig replacement
must reproduce exactly. This gives a baseline the strangler can hold at 100%.

The standard unix oracle
(`vendor/micropython/ports/unix/build-standard/micropython`, MicroPython
v1.28.0-preview) is kept as a sanity reference; the nano build is 274/552
against *it*, the 278-test gap being legitimate config difference, not bugs.
(`corpus.py gen` with no argument still uses the oracle; pass a command to use
another reference.)

## Corpus

- Source: `corpus/basics/*.py` — 552 core-language tests, verbatim copies of
  upstream MicroPython's `tests/basics/` at the Makefile's `MICROPY_REV`,
  exactly the "nano" scope (no `extmod`, ports, or hardware tests).
- Golden output: `corpus/basics/<name>.out` — combined stdout+stderr plus an
  `[exit N]` marker, captured from the reference.
- **Inclusions:** 550 tests. Each run twice through the reference with
  identical output.
- **Exclusions:** 2 (`builtin_hash`, `class_inherit1`) — output varies across
  runs (object hashes / addresses). Recorded in `corpus/EXCLUDED.txt`,
  auto-detected.

## Harness

One tool, `tools/corpus.py`:

```sh
python3 tools/corpus.py gen ./zig-out/bin/nanopython   # freeze reference
python3 tools/corpus.py verify <binary>     # diff a build against goldens
python3 tools/corpus.py stats               # corpus / exclusion counts
```

`verify` exits non-zero and lists failing tests if any output drifts. This is
the single command every strangler step must keep green.

## Progress meter

`tools/progress.py` reports the headline migration number: the percentage of
the corpus the candidate interpreter runs **byte-identically to the frozen
reference**. It reuses `corpus.run_cmd`, so output is framed exactly as the
goldens were frozen.

```sh
python3 tools/progress.py <command...>       # how to invoke the candidate
python3 tools/progress.py wasmtime zig-out/bin/nanopython.wasm --
python3 tools/progress.py --json <command...>          # CI / badge
python3 tools/progress.py --show 10 <command...>        # list first failures
```

The script path replaces a literal `{script}` token if present, else is
appended. An unbuilt candidate reports `0.0%` (exit 0) so the meter works as a
dashboard from day one. Calibration check: pointed at the nano-C build it
reports **100.0%**.

## ⚠️ Goldens are byte-exact binary fixtures

`corpus/basics/*.out` capture reference stdout+stderr *exactly*. Trailing
whitespace and line endings in them are **significant** — they are part of
the byte-identical contract. Do **not** run text-normalizing tools
(`trailing-whitespace`, `mixed-line-ending`, formatters) over them; doing so
silently corrupts the safety net. Commits touching the corpus bypass those
hooks (`--no-verify`); regenerate with `corpus.py gen` if ever mangled.

## Status

Phase 0–1 complete. Reference = nano-C build; baseline **550/550 (100%)**.
The strangler must hold this at 100% as C is replaced by Zig.
