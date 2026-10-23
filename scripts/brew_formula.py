"""Print the Homebrew formula for a published petitpy release (ADR 016).

The formula installs the PyPI wheel for the user's platform: the binary
into bin/, and the stdlib into share/petitpy/lib, where the binary looks
for it next to itself.

Usage: python3 scripts/brew_formula.py VERSION > petitpy.rb
"""

import json
import sys
import urllib.request

# Wheel platform tag -> Homebrew's (OS block, CPU block).
PLATFORMS = {
    "macosx_11_0_arm64": ("on_macos", "on_arm"),
    "macosx_11_0_x86_64": ("on_macos", "on_intel"),
    "manylinux_2_17_aarch64": ("on_linux", "on_arm"),
    "manylinux_2_17_x86_64": ("on_linux", "on_intel"),
}

TEMPLATE = """\
class Petitpy < Formula
  desc "Small Python runtime, MicroPython-compatible, written in Zig"
  homepage "https://petitpy.lab.abilian.com/"
  version "{version}"
  license all_of: ["MIT", "PSF-2.0"]

  uses_from_macos "unzip"

{platforms}
  def install
    # Homebrew unpacks archives by extension, and leaves a .whl as it is.
    system "unzip", "-q", Dir["*.whl"].first
    data = buildpath/"petitpy-#{{version}}.data"
    bin.install data/"scripts/petitpy"
    bin.install_symlink "petitpy" => "ppy"
    (share/"petitpy").install data/"data/share/petitpy/lib"
  end

  test do
    assert_equal "[1, 2]\\n", shell_output("#{{bin}}/petitpy -c 'import json; print(json.loads(\\"[1, 2]\\"))'")
  end
end
"""


def main() -> None:
    version = sys.argv[1]
    with urllib.request.urlopen(f"https://pypi.org/pypi/petitpy/{version}/json") as r:
        files = json.load(r)["urls"]
    wheels = {}
    for f in files:
        for tag, block in PLATFORMS.items():
            if f["filename"].endswith(f"-{tag}.whl"):
                wheels[block] = (f["url"], f["digests"]["sha256"])
    missing = set(PLATFORMS.values()) - set(wheels)
    if missing:
        sys.exit(f"petitpy {version} on PyPI lacks wheels for {sorted(missing)}")

    blocks = []
    for os_block in ("on_macos", "on_linux"):
        cpus = []
        for cpu in ("on_arm", "on_intel"):
            url, sha = wheels[(os_block, cpu)]
            cpus.append(f'    {cpu} do\n      url "{url}"\n      sha256 "{sha}"\n    end')
        blocks.append(f"  {os_block} do\n" + "\n".join(cpus) + "\n  end\n")
    print(TEMPLATE.format(version=version, platforms="\n".join(blocks)), end="")


if __name__ == "__main__":
    main()
