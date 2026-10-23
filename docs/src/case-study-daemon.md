# Case study: a Linux daemon

[hop3-rootd](https://github.com/abilian/hop3) is the privileged agent of Hop3, Abilian's hosting platform. It runs as root on every managed host and performs firewall, cgroup, mount and systemd operations for the Hop3 server, over a Unix socket. It is written for CPython, uses only the standard library, and comes with a substantial unit-test suite. This page measures how it runs on petitpy.

Measured in October 2026 with the petitpy 0.8.0 development tree. The tests ran on macOS (arm64) and Linux; the figures below are from Linux on x86_64.

## Method

The daemon and its tests run from their own source, unedited in the hop3-rootd repository. A runner (`tools/hop3-rootd-tests.py`) copies them into a temporary tree next to petitpy's stdlib, laid out as `pip install petitpy` installs it, and runs each test file with petitpy's small `pytest`. It reads fixtures and `parametrize` rows with CPython's `ast` module, since petitpy has no `inspect`.

The petitpy binary is the one `pip install petitpy` installs on Linux (ReleaseFast, stdlib as `.py` files). Memory is the peak resident set size, read by GNU `time` in a Debian 12 container against Debian's CPython 3.11, median of five runs (`tools/measure-hop3-footprint.py`). CPU time per request is the difference between 10,000 and 100 requests, divided by 9,900. A request is what the daemon's accept loop does for one client, minus the socket: build the request, find the handler, run `daemon.health`, encode the JSON response.

## Results

**Tests.** All tests pass on CPython, and all but two on petitpy, on macOS and Linux alike. Both skip the test that needs `systemctl`. The two failures:

- `test_audit_log_counts_fsync_failures` patches `os.fsync`. petitpy's built-in modules are read-only, so the patch itself fails.
- `test_app_name_re_matches_hop3_server_upstream` imports the separate `hop3-server` package, which the test tree does not include.

**Memory on Linux.**

| Workload | petitpy | CPython 3.11 | Ratio |
|---|---|---|---|
| Start, running `pass` | 2.3 MB | 7.4 MB | 3.2× |
| Import the whole daemon | 3.8 MB | 17.1 MB | 4.5× |
| After 100 requests | 3.9 MB | 17.3 MB | 4.4× |
| After 10,000 requests | 4.0 MB | 17.1 MB | 4.3× |

Memory stays flat from 100 to 10,000 requests because petitpy collects garbage. The size-optimized build (`make build-small`) uses a little less.

**Disk and time on Linux.**

| | petitpy | CPython 3.11 |
|---|---|---|
| Interpreter binary | 833 KB | 6.5 MB |
| Standard library on disk | 216 KB | 28 MB |
| Start, running `pass` | 2 ms | 10 ms |
| Import the whole daemon | 26 ms | 68 ms |
| CPU time per request | 0.027 ms | 0.006 ms |

petitpy starts and imports the daemon faster. A request costs about 4.5 times the CPU it takes on CPython.

## What the daemon found in petitpy

The daemon has grown since it was first measured in July 2026, and its current version found gaps, fixed for this run: `re.fullmatch`, `typing.TypeAlias`, `os.lseek` (so that files opened through `pathlib` can `seek`), test classes and monkeypatch cleanup in the small `pytest`, and JSON. JSON encoding and decoding moved to native code, and Python function calls became about three times faster on the build `pip` installs, which is now built for speed. Together these cut the CPU cost of a request about sixfold ([benchmarks](benchmarks.md)). Dataclass fields, `os.path`, `os.environ`, `str` enums and `list[str] | None` used to need text rewrites of the copies; all now work as in CPython, and the copies are not edited.

## Limits

- One program. A second daemon would show how much of this holds in general.
- No production run. These are unit tests and a request loop; weeks of uptime under real load remain unmeasured.
- Throughput. An agent that handles a few requests per second does not notice 0.03 ms each; a service that handles thousands per second should measure first.
- Built-in modules are read-only, so tests that monkeypatch `os` or `time` must patch the daemon's own module instead.
