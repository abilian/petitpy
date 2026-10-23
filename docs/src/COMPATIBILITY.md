# What works on petitpy

_Auto-generated from `golden-programs/` by `tools/gen_compatibility.py`. Don't edit by hand; re-run `make compatibility` after changing the bucket assignments._

This page answers **"does my program work on petitpy?"** for a collection of real programs taken from MicroPython's tests, CPython's tests, PEP examples and project demos. [ADR 008](adrs/008-golden-programs.md) explains the buckets.

## Headline

- **584 / 756 programs (77.2%) run on both native AND wasm.**
- **585 / 756 (77.4%) run on native (incl. native-only).**
- The remaining 171 programs are bucketed by what they need; see below.

## How to read this

Each bucket names what its programs need. `make check` and `make wasm-check` run the programs in `works/` on every build.

## The buckets

### `works/`: 584 programs

Runs on **both** native and wasm, with the same output as MicroPython or CPython.

By source corpus: `prescrypt-micropython`=421, `prescrypt-tryalgo`=79, `prescrypt-internal`=54, `p2w-internal`=30

Top requirements: `async`×9, `grammar.walrus`×6, `stdlib.bisect`×2, `fs.open`×1, `stdlib.heapq`×1, `grammar.match`×1, `stdlib.collections.Counter`×1

Programs (first 30):

`0prelim`, `__init__`, `anagrams`, `andor`, `annotate_var`, `arithm`, `arithm_expr_eval`, `arithm_expr_target`, `array_add`, `array_construct`, `array_construct2`, `array_construct_endian`, `array_micropython`, `assert_statements`, `assign`, `assign1`, `assign_expr`, `assign_expr_scope`, `async`, `async_await`, `async_def`, `async_for`, `async_syntaxerror`, `async_with`, `async_with_break`, `async_with_return`, `bellman_ford`, `bfs`, `biconnected_components`, `binary_search`

_…and 554 more; see `golden-programs/works/`._

### `works-native-only/`: 1 program

Runs on native but not wasm, usually because wasm stores array, memoryview and struct values in a 32-bit word.

By source corpus: `prescrypt-micropython`=1

Programs (first 1):

`memoryview_intbig`

### `needs-stdlib/`: 123 programs

Needs a stdlib module petitpy does not ship yet. The header of each program names it. See [ADR 003](adrs/003-library-and-module-loading.md).

By source corpus: `prescrypt-micropython`=88, `prescrypt-tryalgo`=17, `p2w-internal`=10, `prescrypt-internal`=8

Top requirements: `stdlib.tryalgo-internal`×14, `stdlib.random`×4, `stdlib.heapq`×1, `stdlib.collections.namedtuple`×1

Programs (first 30):

`array1`, `array_intbig`, `attrtuple1`, `bipartite_vertex_cover`, `builtin_abs_intbig`, `builtin_bin_intbig`, `builtin_compile`, `builtin_divmod_intbig`, `builtin_hash_intbig`, `builtin_help`, `builtin_hex_intbig`, `builtin_oct_intbig`, `builtin_override`, `builtin_pow3`, `builtin_pow3_intbig`, `builtin_round_int`, `builtin_round_intbig`, `builtins_introspection`, `builtins_iteration_simple`, `builtins_iteration_tools`, `builtins_numeric_extra`, `builtins_numeric_simple`, `bytearray_append`, `bytearray_byte_operations`, `bytearray_intbig`, `bytearray_slice_assign`, `bytes_construct`, `bytes_construct_intbig`, `bytes_encoding`, `class_bases`

_…and 93 more; see `golden-programs/needs-stdlib/`._

### `needs-grammar/`: 1 program

Uses syntax petitpy does not parse.

By source corpus: `prescrypt-micropython`=1

Top requirements: `grammar.walrus`×1

Programs (first 1):

`assign_expr_syntaxerror`

### `needs-async/`: 3 programs

Needs more `async` support than petitpy has ([ADR 002](adrs/002-feature-selection.md)).

By source corpus: `prescrypt-micropython`=3

Top requirements: `async`×3

Programs (first 3):

`async_await2`, `async_for2`, `async_with2`

### `needs-fs/`: 8 programs

Uses `open()`, `sys.stdin` or other file system access.

By source corpus: `prescrypt-tryalgo`=7, `prescrypt-micropython`=1

Top requirements: `fs.sys.stdin`×4, `fs.open`×4, `stdlib.random`×2, `stdlib.tryalgo-internal`×2, `stdlib.collections.defaultdict`×1

Programs (first 8):

`freivalds`, `horn_sat`, `interval_cover`, `kruskal`, `our_std`, `range_minimum_query`, `shortest_cycle`, `sys_path`

### `needs-mpz/`: 0 programs

Needs integers beyond 64 bits on wasm.

_No programs in this bucket._

### `disagreement/`: 36 programs

MicroPython and CPython print **different** output for these programs, so there is no single expected result.

By source corpus: `prescrypt-micropython`=36

Programs (first 30):

`attrtuple2`, `builtin_range_binop`, `builtin_str_hex`, `bytes_compare3`, `bytes_escape_unicode`, `class_inplace_op2`, `errno1`, `exception_chain`, `fun_code`, `fun_code_colines`, `fun_code_full`, `fun_code_micropython`, `gen_yield_from_throw_multi_arg`, `generator_pend_throw`, `generator_throw_multi_arg`, `is_isnot_literal`, `memoryview_itemsize`, `memoryview_slice_size`, `module2`, `namedtuple_asdict`, `op_error_literal`, `python34`, `slice_op`, `string_escape_invalid`, `string_fstring_invalid`, `subclass_native_call`, `subclass_native_exc_new`, `sys_getsizeof`, `sys_tracebacklimit`, `try_finally_break`

_…and 6 more; see `golden-programs/disagreement/`._

