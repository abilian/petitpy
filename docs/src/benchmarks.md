# petitpy benchmarks

_For contributors evaluating optimization arcs, and for embedded/systems developers calibrating perf expectations. The figures below were measured on 2026-06-07. The current longitudinal data lives in `metrics/history.ndjson` (run `make metrics-report` for the trend). This page captures one point-in-time comparison for context._

- Date: 2026-06-07 14:13:08 CEST
- Platform: Darwin arm64 (macOS-14.8.4-arm64-arm-64bit-Mach-O)
- Commit: `6f9ca14`
- Methodology: K=2 warmup, N=5 timed iterations per (interpreter, benchmark). Reported value is the median wall-clock; minimum shown in tooltip-style parens. Full methodology in [ADR 004](adrs/004-benchmarking.md).

## Interpreters

| Name | Binary | Size | Version |
|---|---|---|---|
| petitpy | `nanopython` | 954 KB | nanopython 0.4.0 |
| MicroPython | `micropython` | 652 KB | MicroPython v1.28.0-preview.80.gb14d129a16 on 2026-05-17; darwin (Clang 15.0.0) version |
| CPython | `python3` | 51 KB | Python 3.14.5 |

petitpy is built with `make build-release` (`-Doptimize=ReleaseFast -Dconfig=nano`). MicroPython is the upstream `unix-standard` build. CPython is the system `python3`.

## Results

| benchmark | petitpy median (s) | MicroPython median (s) | CPython median (s) | nano / MicroPython | nano / CPython | output match |
|---|---|---|---|---|---|---|
| dictops | 0.185 (min 0.184) | 0.117 (min 0.115) | 0.125 (min 0.123) | 1.57× | 1.48× | yes |
| fannkuch | 0.554 (min 0.546) | 0.558 (min 0.545) | 0.338 (min 0.330) | 0.99× | 1.64× | yes |
| fib | 0.545 (min 0.530) | 0.430 (min 0.427) | 0.272 (min 0.265) | 1.27× | 2.00× | yes |
| listops | 0.150 (min 0.146) | 0.109 (min 0.108) | 0.113 (min 0.112) | 1.37× | 1.33× | yes |
| sieve | 0.326 (min 0.315) | 0.160 (min 0.155) | 0.151 (min 0.148) | 2.04× | 2.16× | yes |
| strops | 0.225 (min 0.183) | 0.285 (min 0.272) | 0.055 (min 0.052) | 0.79× | 4.10× | yes |
| **geomean** | n/a | n/a | n/a | **1.28×** | **1.96×** | n/a |

Ratio reading: `nano / X` means petitpy's median divided by X's median. A value of `1.50×` means petitpy took 1.5× as long as X (i.e. X is faster). Lower is better for petitpy.

## The build `pip` installs

The tables above measure `nano`. `pip install petitpy` installs the `full` build, compiled with ReleaseFast and stripped (about 850 KB). The figures below were measured on 2026-10-20.

**A daemon request** (Linux x86_64, Debian 12 container, against CPython 3.11; method in the [case study](case-study-daemon.md)): build the request, find the handler, run it, encode the JSON response.

| | petitpy | CPython 3.11 |
|---|---|---|
| CPU per request | 0.027 ms | 0.006 ms |
| The same, before 2026-10-20 | 0.17 ms | |
| RAM after 10,000 requests | 4.0 MB | 17.1 MB |

Three changes made requests about 6 times faster:

- **Python calls.** The `full` build runs each Python call through a `setjmp`, so that exceptions can cross vendor C code ([ADR 013](adrs/013-exception-unwind-vendor-c.md)). On macOS, `setjmp` also saves the signal mask with a system call, which made every call about 8 times slower. `_setjmp` skips it.
- **Native JSON.** `json.dumps` and `json.loads` handle plain values in Zig, falling back to the Python code for the rest.
- **A speed-optimized wheel.** ReleaseFast runs Python 1.3 to 2 times faster than ReleaseSmall, for a binary 60% larger.

**JSON** (macOS arm64, 10,000 calls on a small document):

| | `json.dumps` | `json.loads` |
|---|---|---|
| petitpy, before | 0.312 s | 0.619 s |
| petitpy | 0.015 s | 0.023 s |
| CPython 3.14 | 0.020 s | 0.016 s |
| MicroPython | 0.029 s | 0.149 s |

**Function calls** (macOS arm64, 2 million calls inside a function): petitpy 0.100 s, CPython 3.14 0.140 s, MicroPython 0.212 s.

## Output equivalence

All benchmarks produce byte-identical stdout across all available interpreters.

## Reproduce

```sh
# 1. Build a ReleaseFast petitpy (Debug is artificially slow).
make build-release

# 2. (Optional) Build MicroPython unix-standard if absent.
(cd vendor/micropython/ports/unix && make submodules && make)

# 3. Run the suite.
python3 benchmarks/runner.py
```
