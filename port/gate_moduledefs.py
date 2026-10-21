#!/usr/bin/env python3
"""Post-process genhdr/moduledefs.h so optional modules' MODULE_DEF_X
expansion is gated on the matching MICROPY_PY_X flag.

The makemoduledefs scanner runs with NANOPYTHON_CONFIG_FULL=1, so it sees
modules registered under the full arm even when the nano compile won't
provide them. Without gating, the unconditional `MODULE_DEF_X { ... &mp_module_X ... }`
references symbols that don't exist under nano -> link error.

This script rewrites:

    extern const struct _mp_obj_module_t mp_module_io;
    #undef MODULE_DEF_IO
    #define MODULE_DEF_IO { MP_ROM_QSTR(MP_QSTR_io), MP_ROM_PTR(&mp_module_io) },

into:

    #if MICROPY_PY_IO
    extern const struct _mp_obj_module_t mp_module_io;
    #undef MODULE_DEF_IO
    #define MODULE_DEF_IO { MP_ROM_QSTR(MP_QSTR_io), MP_ROM_PTR(&mp_module_io) },
    #else
    #define MODULE_DEF_IO
    #endif

Only modules listed in OPTIONAL_MODULES are gated; the rest (always-on
under nano too: builtins, sys, gc, math, etc.) stay as-is.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# Map module name (uppercase, matches MODULE_DEF_<NAME>) -> MICROPY_PY flag.
# Add an entry here when a new optional module gets enabled under
# NANOPYTHON_CONFIG_FULL.
OPTIONAL_MODULES: dict[str, str] = {
    "IO": "MICROPY_PY_IO",
    "MATH": "MICROPY_PY_MATH",
    "COLLECTIONS": "MICROPY_PY_COLLECTIONS",
    "STRUCT": "MICROPY_PY_STRUCT",
    "ARRAY": "MICROPY_PY_ARRAY",
    "ERRNO": "MICROPY_PY_ERRNO",
    "MICROPYTHON": "MICROPY_PY_MICROPYTHON",
    "GC": "MICROPY_PY_GC",
    # ADR-006 J1 — JS interop. The leading underscore in the qstr
    # (`_nanopython_js`) becomes part of the macro name produced by
    # makemoduledefs.py: `MODULE_DEF__NANOPYTHON_JS`. The obj_module
    # extern that ships in moduledefs.h is `mp_module_nanopython_js`
    # (the leading underscore of the qstr is NOT carried into the C
    # symbol — that's the literal name from MP_REGISTER_MODULE's 2nd
    # arg in the shadow block).
    "_NANOPYTHON_JS": "MICROPY_PY_NANOPYTHON_JS",
    # ADR 010 §A3a slice 2 — `re` module (extmod/modre.c). MICROPY_PY_RE
    # is set in port/mpconfigport.h under NANOPYTHON_FEATURE_RE; the
    # registration gating here lets the moduledefs reference vanish
    # cleanly when feature-re=false (e.g. on wasm32, where re1.5's
    # function-pointer ABI breaks).
    "RE": "MICROPY_PY_RE",
    # notes/plans/full-unix-profile.md phase 1 — `os` module (Zig-native).
    # MICROPY_PY_OS is set in port/mpconfigport.h under NANOPYTHON_FEATURE_OS;
    # this gate keeps the moduledefs reference off under nano (and wasm),
    # where `mp_module_os` isn't defined.
    "OS": "MICROPY_PY_OS",
    # notes/plans/full-unix-profile.md phase 2 — `time` module (Zig-native).
    "TIME": "MICROPY_PY_TIME",
    # notes/plans/full-unix-profile.md phase 3 — `socket` module (Zig-native).
    "SOCKET": "MICROPY_PY_SOCKET",
    # notes/plans/full-unix-profile.md phase 4 — `select` module (Zig-native).
    "SELECT": "MICROPY_PY_SELECT",
    # notes/plans/full-unix-profile.md phase 5 — `signal` module MVP.
    "SIGNAL": "MICROPY_PY_SIGNAL",
    # notes/plans/full-unix-profile.md phase 7 — `pwd` + `grp`.
    "PWD": "MICROPY_PY_PWD",
    "GRP": "MICROPY_PY_GRP",
    # notes/plans/full-unix-profile.md phase 6 — `_subprocess` low-level.
    # The qstr is `_subprocess` (leading underscore) — MODULE_DEF macro is
    # generated as MODULE_DEF__SUBPROCESS (underscore preserved).
    "_SUBPROCESS": "MICROPY_PY__SUBPROCESS",
}

# Map MODULE_DEF_<MOD> to the C-side obj_module symbol when it diverges
# from `mp_module_<mod.lower()>`. For most entries the convention holds;
# `_NANOPYTHON_JS` is the exception — `_nanopython_js` qstr -> `mp_module_nanopython_js`.
OBJ_MODULE_OVERRIDES: dict[str, str] = {
    "_NANOPYTHON_JS": "mp_module_nanopython_js",
}


def gate(text: str) -> str:
    for mod, flag in OPTIONAL_MODULES.items():
        obj_module = OBJ_MODULE_OVERRIDES.get(mod, "mp_module_" + mod.lower())
        pattern = re.compile(
            r"^extern const struct _mp_obj_module_t " + re.escape(obj_module) + r";\n"
            r"#undef MODULE_DEF_" + mod + r"\n"
            r"#define MODULE_DEF_" + mod + r" \{ [^\n]* \},\n",
            re.MULTILINE,
        )
        m = pattern.search(text)
        if not m:
            continue
        block = m.group(0)
        gated = f"#if {flag}\n" + block + f"#else\n#define MODULE_DEF_{mod}\n#endif\n"
        text = text.replace(block, gated, 1)
    return text


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} <moduledefs.h>", file=sys.stderr)
        return 1
    p = Path(argv[1])
    src = p.read_text()
    out = gate(src)
    if out != src:
        p.write_text(out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
