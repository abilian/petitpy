# golden-programs/

Curated real Python programs that we explicitly want nanopython to run. **Filesystem-level "what works."**

See `docs/src/adrs/008-golden-programs.md` for the design + rationale.

## Layout

Each program lives in **one bucket** — the minimal profile it needs:

| Bucket | Meaning |
|---|---|
| [`works/`](works/) | Runs correctly on current nanopython (native AND wasm) |
| [`works-native-only/`](works-native-only/) | Runs on native, fails on wasm (longjmp issues, etc.) |
| [`needs-stdlib/`](needs-stdlib/) | Would run with pure-Python stdlib stubs (`heapq`, `bisect`, ...) |
| [`needs-grammar/`](needs-grammar/) | Would run with parser features (walrus `:=`, match/case) |
| [`needs-async/`](needs-async/) | Would run with `async def` / `await` support |
| [`needs-fs/`](needs-fs/) | Would run with file-system access (open, read, write) |
| [`needs-mpz/`](needs-mpz/) | Would run with arbitrary-precision integers (> 2^63) |
| [`disagreement/`](disagreement/) | MicroPython and CPython disagree on the program's behavior |

A program with multiple needs lands in the **strictly larger** bucket (e.g. `needs=heapq,async` → `needs-async/`, since async grammar is the bigger feature). The principle: bucket names answer "what profile do I need to ship?"

## Annotation format

Each `.py` file has a header comment:

```python
# golden: source=tryalgo; needs=heapq
# golden: works-on=micropython,nanopython-native,nanopython-wasm
"""Program docstring."""
```

Keys:
- `source` — origin corpus (`tryalgo`, `prescrypt-internal`, `p2w-internal`)
- `needs` — features the program depends on
- `works-on` — verified by running; auto-maintained by `tools/golden_run.py`
- `disagreement` — flag with details when MicroPython and CPython diverge

## How to use

| Question | Where to look |
|---|---|
| "What runs on nanopython today?" | `works/` and `works-native-only/` directories |
| "What feature is missing for *my* program?" | Search for the program by name; check its bucket + `needs=` |
| "What does adding `heapq` unlock?" | `ls needs-stdlib/` (and filter for `needs=heapq`) |
| "What's the user-facing compatibility view?" | [`docs/src/COMPATIBILITY.md`](../docs/src/COMPATIBILITY.md) (auto-generated) |

## How to add a program

1. Put the `.py` under the appropriate bucket directory.
2. Add the golden header comments.
3. Run `make compat` to verify the program runs on the oracles and the bucket is correct.

The bootstrap tool (`tools/golden_bootstrap.py`) maintains the directory: re-running it picks up new programs from the source corpora and proposes bucket assignments, but never overwrites manual placements.

## See also

- `docs/src/adrs/008-golden-programs.md` — design + decision record
- `docs/src/COMPATIBILITY.md` — auto-generated user view
- `profiles.md` — feature profile definitions
