"""Pins the js-bridge failure semantics: failures return a null handle, never raise.

These cannot live in tests/integration.py: that suite runs under wasmtime,
which cannot instantiate the demo artifact at all (no JS host to satisfy
`env::js_create_callback`). So they are gated here instead, in a browser,
against the same web/petitpy.wasm the demos load.

Only the NON-trapping half is assertable. Calling through a null handle and
JSON.parse on malformed input both trap at the host level and kill the
instance, which by construction cannot be observed from inside it; those two
are guarded by code review.

Writes a single verdict line into #out so `--assert-text` can gate the run.
"""

import js

results = []


def check(label, got, want):
    ok = got == want
    results.append((ok, label, got, want))
    status = "ok" if ok else "FAIL"
    print(f"{status:<4} {label:<34} got={got!r} want={want!r}")


missing = js.window.__np_definitely_not_here__

# A missing attribute is a null handle, not an exception.
check("missing attr -> handle 0", missing._h, 0)
# ...and it is still truthy, so `if proxy:` does NOT detect it.
check("null handle is truthy", bool(missing), True)
# to_str() on a null handle yields the STRING "null", not a default.
check("null handle to_str", missing.to_str(), "null")
# to_int() on a null handle yields 0.
check("null handle to_int", missing.to_int(), 0)
# A missing DOM element behaves the same way.
check("missing element -> handle 0", js.document.getElementById("nope-xyz")._h, 0)
# A present global resolves to a live (non-zero) handle.
check("present global is live", js.document._h != 0, True)

# The documented escape hatch: push a throwing JS API behind a wrapper that
# returns null, and test the handle. This is the shape services_storage.py and
# pages_options.py use.
safe_parse = js.get("eval")(
    "(function(s){try{return JSON.parse(s);}catch(e){return null;}})"
)
check("js-side catch, bad input", safe_parse("{not json")._h, 0)
check("js-side catch, good input", safe_parse('{"a":1}').a.to_int(), 1)

failed = [r for r in results if not r[0]]
if failed:
    verdict = f"BRIDGE-CONFORMANCE: FAIL ({len(failed)} of {len(results)})"
    detail = "; ".join(f"{lbl} got={g!r} want={w!r}" for _, lbl, g, w in failed)
    verdict = verdict + " :: " + detail
else:
    verdict = f"BRIDGE-CONFORMANCE: OK ({len(results)} checks)"

print(verdict)
js.document.getElementById("out").set("textContent", verdict)
