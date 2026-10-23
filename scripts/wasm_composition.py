#!/usr/bin/env python3
"""wasm_composition.py — inspect a .wasm binary and report its composition.

Prints:
  - Per-section sizes (Code, Data, Export, …)
  - Function-size distribution (median, average, top-N, buckets)
  - Code section by inferred subsystem, classified by exported function names
  - Data section: printable-string count + total bytes
  - Imports: full list grouped by module

The script is read-only and has no third-party dependencies — just the
WebAssembly binary format. No name section is required (ReleaseSmall
strips it); whatever subsystem labelling we can do comes from the Export
section, which lists ~600 named functions.

Usage:
    python3 scripts/wasm_composition.py [path/to/file.wasm]

Default path is web/petitpy.wasm.

Companion doc: docs/internals/wasm-composition.md walks through the
output and discusses opportunities for size reduction.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


SECTION_NAMES = {
    0: "Custom", 1: "Type", 2: "Import", 3: "Function", 4: "Table",
    5: "Memory", 6: "Global", 7: "Export", 8: "Start", 9: "Element",
    10: "Code", 11: "Data", 12: "DataCount",
}

# Subsystem classification by exported-function-name pattern.
# Order matters: first match wins. Names without a match fall through to
# "unnamed (internal Zig)" if they have no export at all, or "other named"
# if they have an export the table doesn't recognize.
SUBSYSTEM_PATTERNS: list[tuple[str, list[str]]] = [
    ("Compiler driver",      ["zig_compile", "compile_to_mpy"]),
    ("WASI startup",         ["__main", "_start", "wasi"]),
    ("Lexer",                ["lex", "mp_lexer"]),
    ("Parser",               ["parse"]),
    ("JS bridge",            ["js_", "npy_js"]),
    ("GC",                   ["gc_", "gc"]),
    ("Allocator (m_*)",      ["m_malloc", "m_realloc", "m_free", "m_new"]),
    ("qstr pool",            ["qstr"]),
    ("Object: str",          ["str_", "mp_str", "mp_obj_str", "unichar", "vstr"]),
    ("Object: int/bool/bignum", ["int_", "mp_int", "bool", "mpz", "bignum"]),
    ("Object: float",        ["float_", "mp_float", "mp_obj_float", "mp_format_float"]),
    ("Object: list/tuple/array", ["list_", "tuple_", "mp_obj_list", "mp_obj_tuple",
                                  "npy_lst", "npy_array", "array_"]),
    ("Object: dict/map/set", ["dict_", "mp_obj_dict", "mp_map", "set_",
                              "mp_obj_set", "frozenset"]),
    ("Object: range",        ["range_", "mp_obj_range"]),
    ("Object: iter",         ["iter", "gen_instance", "enumerate", "filter",
                              "reversed", "zip"]),
    ("Object: type/instance/module", ["mp_obj_new_type", "instance_",
                                       "mp_obj_get_type", "mp_module"]),
    ("Object: fun/closure",  ["fun_", "closure", "boundmeth"]),
    ("Object: deque/bytearray", ["deque", "bytearray"]),
    ("Runtime dispatch",     ["mp_binary_op", "mp_unary_op", "mp_call",
                              "mp_load", "mp_store", "mp_subscr", "mp_getiter",
                              "mp_iternext", "mp_get_", "mp_attr", "opmethod"]),
    ("VM (bytecode)",        ["mp_execute_bytecode", "mp_setup_code", "mp_vm", "vm_"]),
    ("Modules: builtins",    ["mp_builtin", "fun_builtin", "mp_repl", "builtin"]),
    ("Modules: sys",         ["mp_module_sys", "sys_"]),
    ("Modules: io/struct/math/gc/…", ["mod", "pack", "unpack", "mp_print",
                                       "mp_format", "gc_collect", "gc_info"]),
    ("Exception machinery",  ["nlr_", "mp_raise", "except", "exc", "raise_"]),
    ("Print / format",       ["mp_vprintf", "mp_print", "mp_format"]),
    ("Stream / readline",    ["mp_stream", "readline", "tx_strn", "rx_byte"]),
    ("Misc mp_*",            ["mp_"]),
    ("Strangler bridges (npy_*)", ["npy_"]),
]


def read_leb128(buf: bytes, ofs: int) -> tuple[int, int]:
    r = 0
    shift = 0
    while True:
        b = buf[ofs]
        ofs += 1
        r |= (b & 0x7F) << shift
        if not (b & 0x80):
            return r, ofs
        shift += 7


def classify(name: str | None) -> str:
    if not name:
        return "unnamed (internal Zig)"
    for cat, pats in SUBSYSTEM_PATTERNS:
        if any(p in name for p in pats):
            return cat
    return "other named"


def parse(data: bytes) -> dict:
    if data[:4] != b"\x00asm":
        raise ValueError("not a wasm file")

    ofs = 8  # skip magic + version
    sections: dict[int, tuple[int, int]] = {}
    custom_sections: list[tuple[str, int]] = []
    while ofs < len(data):
        sid = data[ofs]; ofs += 1
        sz, ofs = read_leb128(data, ofs)
        if sid == 0:  # Custom
            nstart = ofs
            nlen, after_nlen = read_leb128(data, ofs)
            cname = data[after_nlen:after_nlen + nlen].decode("utf-8", "replace")
            custom_sections.append((cname, sz))
            sections[sid] = sections.get(sid, (ofs, 0))
            ofs = nstart + sz
        else:
            sections[sid] = (ofs, sz)
            ofs += sz

    # Imports — needed because function indices begin with imported ones
    imports: list[tuple[str, str, str]] = []  # (module, field, kind_str)
    n_func_imports = 0
    if 2 in sections:
        i_ofs, _ = sections[2]
        n_imp, i_ofs = read_leb128(data, i_ofs)
        for _ in range(n_imp):
            ml, i_ofs = read_leb128(data, i_ofs)
            module = data[i_ofs:i_ofs + ml].decode("utf-8", "replace")
            i_ofs += ml
            fl, i_ofs = read_leb128(data, i_ofs)
            field = data[i_ofs:i_ofs + fl].decode("utf-8", "replace")
            i_ofs += fl
            kind = data[i_ofs]; i_ofs += 1
            kind_str = ["func", "table", "memory", "global"][kind]
            imports.append((module, field, kind_str))
            if kind == 0:
                n_func_imports += 1
                _, i_ofs = read_leb128(data, i_ofs)
            elif kind == 1:
                i_ofs += 2
                _, i_ofs = read_leb128(data, i_ofs)
            elif kind == 2:
                flags = data[i_ofs]; i_ofs += 1
                _, i_ofs = read_leb128(data, i_ofs)
                if flags & 1:
                    _, i_ofs = read_leb128(data, i_ofs)
            elif kind == 3:
                i_ofs += 2

    # Function sizes (Code section)
    sizes: list[int] = []
    if 10 in sections:
        c_ofs, _ = sections[10]
        n_funcs, c_ofs = read_leb128(data, c_ofs)
        for _ in range(n_funcs):
            body_sz, body_ofs = read_leb128(data, c_ofs)
            sizes.append(body_sz)
            c_ofs = body_ofs + body_sz

    # Export — map function indices to names
    func_names: dict[int, str] = {}
    if 7 in sections:
        e_ofs, _ = sections[7]
        n_exp, e_ofs = read_leb128(data, e_ofs)
        for _ in range(n_exp):
            nl, e_ofs = read_leb128(data, e_ofs)
            name = data[e_ofs:e_ofs + nl].decode("utf-8", "replace")
            e_ofs += nl
            kind = data[e_ofs]; e_ofs += 1
            idx, e_ofs = read_leb128(data, e_ofs)
            if kind == 0:
                func_names[idx] = name

    # Data section — count printable ASCII strings
    data_info = {"bytes": 0, "ascii_bytes": 0, "ascii_runs": 0, "samples": []}
    if 11 in sections:
        d_ofs, d_sz = sections[11]
        data_info["bytes"] = d_sz
        segment = data[d_ofs:d_ofs + d_sz]
        runs = re.findall(rb"[\x20-\x7e]{4,}", segment)
        data_info["ascii_runs"] = len(runs)
        data_info["ascii_bytes"] = sum(len(r) for r in runs)
        # 15 longest distinct samples
        data_info["samples"] = sorted(set(runs), key=len, reverse=True)[:15]

    return {
        "total_bytes": len(data),
        "sections": sections,
        "custom_sections": custom_sections,
        "imports": imports,
        "n_func_imports": n_func_imports,
        "func_sizes": sizes,
        "func_names": func_names,
        "data_info": data_info,
    }


def report(info: dict) -> None:
    total = info["total_bytes"]
    print(f"File size: {total:,} bytes ({total / 1024:.1f} KB)\n")

    # Section table — recompute size including header bytes
    print("Section sizes:")
    section_totals: dict[str, int] = {}
    for sid, (ofs, sz) in info["sections"].items():
        name = SECTION_NAMES.get(sid, f"?{sid}")
        section_totals[name] = section_totals.get(name, 0) + sz
    for name, sz in sorted(section_totals.items(), key=lambda x: -x[1]):
        print(f"  {name:<12s} {sz:>10,} bytes ({sz / 1024:6.1f} KB) {sz * 100 / total:5.1f}%")

    if info["custom_sections"]:
        print("\nCustom sections:")
        for n, sz in info["custom_sections"]:
            print(f"  {n:<30s} {sz:>10,} bytes")

    # Function-size distribution
    sizes = info["func_sizes"]
    if sizes:
        srt = sorted(sizes, reverse=True)
        print(f"\nCode section: {len(sizes):,} defined functions, "
              f"{sum(sizes):,} bytes total")
        print(f"  Largest:  {srt[0]:>8,} bytes")
        print(f"  Median:   {sorted(sizes)[len(sizes) // 2]:>8,} bytes")
        print(f"  Average:  {sum(sizes) // len(sizes):>8,} bytes")
        print("\n  Function-size buckets:")
        buckets = [(0, 32), (32, 128), (128, 512), (512, 2048),
                   (2048, 8192), (8192, 1 << 24)]
        for lo, hi in buckets:
            n = sum(1 for s in sizes if lo <= s < hi)
            sub_total = sum(s for s in sizes if lo <= s < hi)
            pct = sub_total * 100 // sum(sizes)
            label = f"{lo}-{hi}" if hi < 1 << 23 else f"{lo}+"
            print(f"    {label:<14s} {n:>5} functions  {sub_total:>9,} bytes ({pct:>2}%)")

    # Subsystem classification
    n_imp = info["n_func_imports"]
    names = info["func_names"]
    cats: dict[str, list[int]] = {}
    for i, sz in enumerate(sizes):
        nm = names.get(i + n_imp)
        c = classify(nm)
        cats.setdefault(c, [0, 0])
        cats[c][0] += sz
        cats[c][1] += 1

    total_code = sum(c[0] for c in cats.values())
    print(f"\nCode section by subsystem (classified via export names):")
    print(f"  {'Subsystem':<45s} {'Bytes':>8} {'%':>4} {'# funcs':>7}")
    print(f"  {'-' * 70}")
    for c, (sz, n) in sorted(cats.items(), key=lambda x: -x[1][0]):
        print(f"  {c:<45s} {sz:>8,} {sz * 100 // total_code:>3d}% {n:>7,}")

    # Data section
    di = info["data_info"]
    if di["bytes"]:
        print(f"\nData section: {di['bytes']:,} bytes")
        print(f"  Printable ASCII strings: {di['ascii_runs']:,} runs, "
              f"{di['ascii_bytes']:,} bytes "
              f"({di['ascii_bytes'] * 100 // di['bytes']}%)")
        print(f"  Binary tables: {di['bytes'] - di['ascii_bytes']:,} bytes "
              f"(qstr hash table, ROM type structs, slot vtables)")
        print("\n  Sample of longest strings:")
        for r in di["samples"]:
            print(f"    {len(r):>3}B: {r[:80].decode('ascii', 'replace')}")

    # Imports
    print(f"\nImports ({len(info['imports'])} total, "
          f"{info['n_func_imports']} are functions):")
    by_module: dict[str, list[tuple[str, str]]] = {}
    for module, field, kind in info["imports"]:
        by_module.setdefault(module, []).append((field, kind))
    for module, entries in by_module.items():
        print(f"  {module} ({len(entries)} entries):")
        for field, kind in entries[:6]:
            print(f"    {kind:<7s} {field}")
        if len(entries) > 6:
            print(f"    … and {len(entries) - 6} more")


def main(argv: list[str]) -> int:
    path = Path(argv[0]) if argv else Path("web/petitpy.wasm")
    if not path.exists():
        print(f"error: {path} not found", file=sys.stderr)
        return 1
    info = parse(path.read_bytes())
    print(f"=== {path} ===\n")
    report(info)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
