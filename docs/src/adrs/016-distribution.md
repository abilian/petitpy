# ADR 016. Distribution: PyPI wheels and sdist, built by Zig from one machine

- **Status**: Accepted (2026-10-19). Revision 3: prebuilt wheels beside the sdist, the binary itself as the installed command, releases built and published from the maintainer's machine, Homebrew deferred, published under the name petitpy.
- **Decider**: project maintainer
- **Branches from**: [ADR 003](003-library-and-module-loading.md) (the runtime's stdlib search path), [ADR 011](011-everyday-stdlib.md) (what the wheel ships), [ADR 012](012-profiles-and-feature-matrix.md) (the wheel ships the `full` profile).
- **Consequences**: `pip install petitpy`, `uv tool install petitpy` and `uvx petitpy` install a prebuilt binary on macOS (arm64, x86_64) and Linux (x86_64, aarch64), and build from the sdist elsewhere; `make release-dist` builds every artifact on one machine and `make release-publish` uploads them; the runtime finds its stdlib next to its own executable.

## 1. Context

Until 0.8 the only way to run petitpy was to clone the repository and build it with Zig. The audience for the first public release is browser users and command-line users (W43 plan); the command-line channel is PyPI, used as a tool installer the way ruff and uv are.

The draft of this ADR (revision 2, 2026-07-03) chose an sdist only: `pip install` would compile the binary with the `ziglang` package from PyPI. That works, and is kept as the fallback, but measured on 2026-10-19 it takes about 70 s per install. The installed command was also a Python script that started CPython to launch the binary. Zig cross-compiles every target from one machine, which removes the reason the draft gave against wheels (a per-platform CI matrix).

## 2. Decision

**The name: petitpy, with `ppy` as the short command.** PyPI refused `nanopython` as too close to an existing project. The package and its main command share the name so that `uvx petitpy` works; the npm package is `petitpy` too. The repository and the internal names (build targets, `NANOPYTHON_*` macros, `nanopython-lib/`) keep the development name for now.

**PyPI: one sdist and four prebuilt wheels per release.** The wheels are built by `uv build --wheel` with `NANOPYTHON_TARGET=<zig-triple>:<wheel-tag>`, which `scripts/hatch_build.py` passes to `zig build -Dtarget=`:

| Target | Wheel tag |
|---|---|
| `aarch64-macos.11.0` | `macosx_11_0_arm64` |
| `x86_64-macos.11.0` | `macosx_11_0_x86_64` |
| `x86_64-linux-gnu.2.17` | `manylinux_2_17_x86_64` |
| `aarch64-linux-gnu.2.17` | `manylinux_2_17_aarch64` |

The tags are `py3-none-<platform>`: the wheel holds no Python extension. On any other platform pip falls back to the sdist, which builds with `ziglang` in pip's isolated environment.

**The wheel layout.** The binary is a wheel script twice (`.data/scripts/petitpy` and `.data/scripts/ppy`; a wheel cannot hold a symlink), so `bin/petitpy` and `bin/ppy` in the environment are the binary itself, with no Python in between. The stdlib (every module under `nanopython-lib/`, plus the vendor `types`, `heapq` and `bisect`) is shared data at `share/petitpy/lib/`. A small `petitpy` Python package remains for `python -m petitpy` and `petitpy.find_bin()`.

**The runtime finds its stdlib next to itself.** After `PYTHONPATH` and `PETITPY_LIB` (or `~/.petitpy/lib`), `src/main.zig` appends `<exe dir>/../share/petitpy/lib` when that directory exists. The same relative layout serves a venv, `uv tool`, a Homebrew keg or an unpacked tarball; a development build has no such directory and adds nothing.

**The binary is not frozen.** The wheel ships `-Dconfig=full -Doptimize=ReleaseFast` without `-Dfrozen-tiny`, and the stdlib as `.py` files. Freezing would need a two-pass build with `zigpy-compile` inside pip's build environment for the sdist path, so the two paths would then differ. `make test-wheel-layout` (part of `make test`) lays out `bin/` and `share/` exactly as the wheel does and imports every module with a non-frozen binary.

**The binary is optimized for speed.** ReleaseFast, stripped (`-Dstrip=true`), makes the binary about 60% larger (about 850 KB against 540 KB on Linux x86_64) and runs Python 1.3 to 2 times faster than ReleaseSmall. A daemon or a script pays for speed on every request and for size once, at install time. The browser build stays ReleaseSmall, where every kilobyte is downloaded.

**Releases are built and published from the maintainer's machine; CI publishes nothing.** `make release-dist` builds the sdist and the four wheels into `dist/` (Zig cross-compiles them all on one machine), assembles the npm package in `npm/dist/`, and smoke-tests the wheel for that machine in a fresh venv. `make release-publish` uploads them with `uv publish` and `npm publish`, using the maintainer's own credentials, and refuses unless HEAD has the tag `v<version>` matching `build.zig`. CI (sourcehut) keeps testing every push; it holds no publishing credentials.

## 3. Verified (2026-10-19)

- The four wheels cross-built on one macOS arm64 machine, each with the binary for its target.
- Installed with pip in `python:3.12-slim` containers, the Linux aarch64 and x86_64 wheels run, find their stdlib and handle Unicode, floats and the stdlib imports; `python -m petitpy` works.
- The macOS x86_64 binary runs under Rosetta; the arm64 wheel installs in a venv and its command is the Mach-O binary.
- The sdist still installs from source (about 70 s).

## 4. Consequences

**Positive:**

- Installing takes seconds on the four main platforms, and `uvx petitpy script.py` works without a prior install.
- No CPython process per `petitpy` invocation.
- One machine and two make targets produce and publish every artifact, without cibuildwheel, maturin or per-platform runners.

**Negative:**

- **Releases depend on one machine** having Zig, uv and the publishing credentials; nothing is published from CI, so there is no CI secret to leak, and nothing provenance-signs the artifacts.
- **The macOS binaries are not signed or notarised.** pip-installed command-line binaries are not quarantined, so this does not block `pip install`; a downloaded tarball would be.
- **Windows has no wheel** and the sdist is untested there.

## 5. Alternatives considered

- **sdist only** (revision 2). Kept as the fallback; rejected as the main path for its 70 s install and its Python launcher.
- **cibuildwheel or maturin.** Built for CPython extensions or Rust; Zig already cross-compiles.
- **Frozen modules in the wheel.** See §2.
- **Releasing from sourcehut builds** (revision 2, and a first version of revision 3 gated on `GIT_REF`). Declined by the maintainer: a CI job would need the PyPI token as a secret, while the local build already produces every artifact.
- **Trusted publishing from GitHub Actions.** Possible later; it would need a GitHub mirror and moves the release off the maintainer's machine.

## 6. Non-goals for 0.8

- **A Homebrew tap** (revision 2 planned `abilian/tap/nanopython`). The install layout already suits a keg; the tap needs a GitHub repository and a deploy-key secret, and can follow when asked for.
- conda-forge, Debian packages, a Docker image.
- Signed or notarised binaries; Windows wheels.
- The wasm binary on PyPI: it is a browser artifact, distributed through npm and the hosted playground (W43 plan).

## 7. See also

- `scripts/hatch_build.py`, `python/petitpy/`, `pyproject.toml`, the `release-dist` and `release-publish` targets in the `Makefile`.
