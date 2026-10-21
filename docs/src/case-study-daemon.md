# Case study: a Linux daemon

[hop3-rootd](https://github.com/abilian/hop3) is the privileged agent of Hop3, Abilian's hosting platform. It runs as root on every managed host and performs firewall, cgroup, mount and systemd operations for the Hop3 server, over a Unix socket. It is written for CPython and uses the standard library only: 6.7 KLOC of Python in 28 modules, with 6.0 KLOC of unit tests (439 test cases). This page measures how it runs on petitpy.

Measured on 2026-10-20, with the petitpy 0.8.0 development tree, against the hop3-rootd tree of 2026-10-19. The tests ran on Apple silicon (arm64) and on Linux; the measurements below are from Linux on x86_64.

## Method

The daemon and its tests run from their own source; the hop3-rootd repository is not edited. A runner (`tools/hop3-rootd-tests.py`) copies them into a temporary tree next to petitpy's stdlib, laid out as `pip install petitpy` installs it, and runs each test file with petitpy's small `pytest`. It reads fixtures and `parametrize` rows with CPython's `ast` module, since petitpy has no `inspect`.

The copies still get five text rewrites, for things petitpy does not do yet:

- `os.environ` and `os.fdopen` (5 uses) go through petitpy's `os_ext` module, whose `environ` holds a snapshot of common variables only.
- `bytes.decode(..., errors=...)` and `str.split(maxsplit=...)` (1 use each) get positional arguments: these built-in methods take no keyword arguments.
- `ErrorCode.X.value` becomes `ErrorCode.X` (1 use in the daemon, 7 in the tests): a petitpy `Enum` member is its raw value.
- The one `TypeAlias` assignment gets `object` as its value: petitpy does not evaluate `list[str]` or `int | None` at run time yet.

The petitpy binary is the one `pip install petitpy` installs on Linux (ReleaseFast, stdlib as `.py` files). Memory is the peak resident set size, read by GNU `time` in a Debian 12 container (x86_64), against Debian's CPython 3.11, median of five runs (`tools/measure-hop3-footprint.py`). CPU time per request is the difference between 10,000 and 100 requests, divided by 9,900. A request is what the daemon's accept loop does for one client, minus the socket: build the request, find the handler, run `daemon.health`, encode the JSON response.

## Results

**Tests.** 436 of 439 pass, on macOS and on Linux alike; CPython passes 438. Both skip the test that needs `systemctl`. The two failures:

- `test_audit_log_counts_fsync_failures` patches `os.fsync`. petitpy's built-in modules are read-only, so the patch itself fails.
- `test_app_name_re_matches_hop3_server_upstream` imports the separate `hop3-server` package, which the test tree does not include.

**Memory on Linux.**

| Workload | petitpy | CPython 3.11 | Ratio |
|---|---|---|---|
| Start, running `pass` | 2.3 MB | 7.4 MB | 3.2× |
| Import the whole daemon | 3.8 MB | 17.1 MB | 4.5× |
| After 100 requests | 3.9 MB | 17.3 MB | 4.4× |
| After 10,000 requests | 4.0 MB | 17.1 MB | 4.3× |

The figure stays flat from 100 to 10,000 requests because petitpy collects garbage. The size-optimized build (`make build-small`) uses 0.3 MB less; on arm64 it measured 3.2 MB against CPython's 17.5 MB after 100 requests.

**Disk and time on Linux.**

| | petitpy | CPython 3.11 |
|---|---|---|
| Interpreter binary | 833 KB | 6.5 MB |
| Standard library on disk | 216 KB (34 files) | 28 MB |
| Start, running `pass` | 2 ms | 10 ms |
| Import the whole daemon | 26 ms | 68 ms |
| CPU time per request | 0.027 ms | 0.006 ms |

petitpy starts faster and imports the daemon faster. A request costs about 4.5 times more CPU than on CPython, down from about 30 times before this run: the same build of 2026-10-20 morning took 0.17 ms per request on this machine.

## What this run fixed in petitpy

The daemon has grown since the first measurement in July 2026. Its current version found gaps in petitpy, fixed for this run: `re.fullmatch`, `typing.TypeAlias`, `os.lseek` (so that files opened through `pathlib` can `seek`), test classes and monkeypatch cleanup in the small `pytest`, and native JSON encoding and decoding. Python function calls became about three times faster on the build `pip` installs, which is also built for speed now. The July rewrites for dataclass fields and `os.path` are gone: both now work as in CPython.

## Limits

- One program. A second daemon would show how much of this holds in general.
- No production run. These are unit tests and a request loop; weeks of uptime under real load remain unmeasured.
- Throughput. An agent that handles a few requests per second does not notice 0.03 ms each; a service that handles thousands per second should measure first.
- Built-in modules are read-only, so tests that monkeypatch `os` or `time` must patch the daemon's own module instead.
