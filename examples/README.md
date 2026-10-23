# petitpy examples

Small, self-contained programs that exercise different parts of the language. Each runs identically on native and WASM:

```sh
./zig-out/bin/petitpy examples/fizzbuzz.py
wasmtime --dir=. zig-out/bin/petitpy.wasm examples/fizzbuzz.py
```

| File | Demonstrates |
|---|---|
| `fizzbuzz.py` | Basic control flow |
| `fibonacci.py` | Recursion + memoization |
| `classes.py` | Inheritance, `@property`, descriptors |
| `generators.py` | `yield`, iterator protocol, send/throw/close |
| `exceptions.py` | `try`/`except`/`finally`/`raise`, custom exception classes |
| `closures.py` | Nested functions, free variables, `nonlocal` |
| `data_pipeline.py` | Real-world data processing (dict + list comprehensions + sorted + min/max) |
| `graph_algos.py` | BFS, topological sort, recursive DFS |
| `sort_quicksort.py` | List slicing, recursion |
| `state_machine.py` | A traffic-light FSM using classes |
| `floats.py` | float arithmetic, math module, formatting |
| `fstrings.py` | f-string features (substitution, debug, format specs) |
| `walrus.py` | `:=` operator |
| `repl_session.py` | Pipe-stdin script that simulates an interactive session |
