# petitpy benchmarks

_One comparison of petitpy, MicroPython and CPython on a small benchmark suite, measured on one machine. `make metrics-report` shows the trend over time._

- Date: 2026-10-21
- Platform: Linux x86_64 (AMD Ryzen 7 6800U), Debian 12 container
- Method: 3 warmup runs, then 11 timed runs per interpreter and benchmark. Each cell is the median wall-clock time, with the minimum in parentheses. A second run agreed within 3%. See [ADR 004](adrs/004-benchmarking.md).

## Interpreters

| Name | Binary | Size (stripped) | Version |
|---|---|---|---|
| petitpy | `petitpy` | 737 KB | petitpy 0.8.0 |
| MicroPython | `micropython` | 807 KB | MicroPython v1.28.0-preview.80.gb14d129a16, GCC 12.2 |
| CPython | `python3` | n/a | Python 3.14.8 |

petitpy is built with `-Doptimize=ReleaseFast -Dconfig=nano`. MicroPython is the upstream `unix-standard` build at its default flags, which optimize for size (`-Os`). CPython is the `python:3.14-slim-bookworm` image.

## Results

| benchmark | petitpy median (s) | MicroPython median (s) | CPython median (s) | nano / MicroPython | nano / CPython | output match |
|---|---|---|---|---|---|---|
| dictops | 0.159 (min 0.156) | 0.176 (min 0.170) | 0.188 (min 0.181) | 0.90× | 0.84× | yes |
| fannkuch | 0.484 (min 0.468) | 0.580 (min 0.574) | 0.418 (min 0.403) | 0.83× | 1.16× | yes |
| fib | 0.392 (min 0.387) | 0.620 (min 0.609) | 0.235 (min 0.229) | 0.63× | 1.67× | yes |
| listops | 0.152 (min 0.147) | 0.165 (min 0.160) | 0.132 (min 0.127) | 0.92× | 1.15× | yes |
| sieve | 0.194 (min 0.189) | 0.262 (min 0.248) | 0.187 (min 0.174) | 0.74× | 1.04× | yes |
| strops | 0.194 (min 0.191) | 0.254 (min 0.243) | 0.049 (min 0.046) | 0.76× | 3.99× | yes |
| **geomean** | n/a | n/a | n/a | **0.79×** | **1.41×** | n/a |

`nano / X` is petitpy's median divided by X's. Below 1, petitpy is faster; `1.50×` means it took 1.5 times as long.

## The build `pip` installs

The tables above measure `nano`. `pip install petitpy` installs the `full` build, compiled with ReleaseFast and stripped.

**A daemon request** (Linux x86_64, Debian 12 container, against CPython 3.11; method in the [case study](case-study-daemon.md)): build the request, find the handler, run it, encode the JSON response.

| | petitpy | CPython 3.11 |
|---|---|---|
| CPU per request | 0.027 ms | 0.006 ms |
| The same, before 2026-10-20 | 0.17 ms | |
| RAM after 10,000 requests | 4.0 MB | 17.1 MB |

Three changes made requests about six times faster:

- **Python calls.** The `full` build runs each Python call through a `setjmp`, so that exceptions can cross vendor C code ([ADR 013](adrs/013-exception-unwind-vendor-c.md)). On macOS, `setjmp` also saves the signal mask with a system call, which made calls several times slower. `_setjmp` skips it.
- **Native JSON.** `json.dumps` and `json.loads` handle plain values in Zig, falling back to the Python code for the rest.
- **A speed-optimized wheel.** ReleaseFast runs Python 1.3 to 2 times faster than ReleaseSmall, for a larger binary.

**JSON** (macOS arm64, 10,000 calls on a small document):

| | `json.dumps` | `json.loads` |
|---|---|---|
| petitpy, before | 0.312 s | 0.619 s |
| petitpy | 0.015 s | 0.023 s |
| CPython 3.14 | 0.020 s | 0.016 s |
| MicroPython | 0.029 s | 0.149 s |

**Function calls** (macOS arm64, 2 million calls inside a function): petitpy 0.100 s, CPython 3.14 0.140 s, MicroPython 0.212 s.

## Output equivalence

Every benchmark prints the same output on all three interpreters.

## Reproduce

```sh
# 1. Build a ReleaseFast petitpy (Debug is artificially slow).
make build-release

# 2. (Optional) Build MicroPython unix-standard if absent.
(cd vendor/micropython/ports/unix && make submodules && make)

# 3. Run the suite with the method above.
python3 benchmarks/runner.py --warmup 3 --runs 11
```
