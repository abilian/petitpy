"""Color picker demo — HSL/RGB linked sliders, hex output.

J5b-style: one wasm instance per page load. main.py wires "input" event
handlers on six sliders (H, S, L, R, G, B) and exits; the instance stays
alive because the JS bridge holds wasmExports.

Internal state is RGB integers in 0..255. HSL is for display + slider
input only. All math is integer; the HSL chroma/sector formula is scaled
so every intermediate stays well inside the nano-build's 30-bit smallint
range (max ~5.4e8, our max intermediate is ~10^5).
"""

import js

STATE = {"r": 0, "g": 0, "b": 0, "updating": False}


# ---------------------------------------------------------------------------
# HSL <-> RGB (integer-only)
# ---------------------------------------------------------------------------


def _abs(x):
    return -x if x < 0 else x


def hsl_to_rgb(h, s, l):
    """h in 0..360, s in 0..100, l in 0..100 -> (r,g,b) each 0..255."""
    if s == 0:
        v = (l * 255) // 100
        return v, v, v

    # Chroma scaled by 100: C100 in 0..100.
    c100 = (100 - _abs(2 * l - 100)) * s // 100

    # Sector by H/60. H mod 120 collapses pairs of sectors so we can derive
    # X100 from a triangle wave: distance from the midpoint of each 120-deg
    # window, scaled into 0..C100.
    h_mod = h % 360
    sector = h_mod // 60
    hh = h_mod % 120
    delta = _abs(hh - 60)
    x100 = c100 * (60 - delta) // 60

    if sector == 0:
        r100, g100, b100 = c100, x100, 0
    elif sector == 1:
        r100, g100, b100 = x100, c100, 0
    elif sector == 2:
        r100, g100, b100 = 0, c100, x100
    elif sector == 3:
        r100, g100, b100 = 0, x100, c100
    elif sector == 4:
        r100, g100, b100 = x100, 0, c100
    else:
        r100, g100, b100 = c100, 0, x100

    # m = L - C/2. Fold the /2 into the final 255/100 scale to keep all
    # arithmetic in ints: R = (2*r100 + 2L - C100) * 255 / 200.
    base = 2 * l - c100
    r = (2 * r100 + base) * 255 // 200
    g = (2 * g100 + base) * 255 // 200
    b = (2 * b100 + base) * 255 // 200
    return r, g, b


def rgb_to_hsl(r, g, b):
    """r,g,b each 0..255 -> (h 0..360, s 0..100, l 0..100)."""
    mx = r
    if g > mx:
        mx = g
    if b > mx:
        mx = b
    mn = r
    if g < mn:
        mn = g
    if b < mn:
        mn = b

    sum_v = mx + mn
    l = sum_v * 100 // 510

    if mx == mn:
        return 0, 0, l

    d = mx - mn
    if sum_v <= 255:
        s = d * 100 // sum_v
    else:
        s = d * 100 // (510 - sum_v)

    if mx == r:
        h_raw = (g - b) * 60 // d
    elif mx == g:
        h_raw = (b - r) * 60 // d + 120
    else:
        h_raw = (r - g) * 60 // d + 240
    h = (h_raw + 360) % 360
    return h, s, l


# ---------------------------------------------------------------------------
# DOM helpers
# ---------------------------------------------------------------------------


def _g(idn):
    return js.document.getElementById(idn)


def _set_text(el, text):
    el.textContent = text


def _hex2(v):
    """Format 0..255 as two lowercase hex digits."""
    return f"{v:02x}"


# ---------------------------------------------------------------------------
# Render: write RGB state into every output (swatch, hex, slider labels).
# When `set_sliders` is True, also write back into the slider .value's
# (used when an HSL slider just fired; we sync the RGB sliders too).
# ---------------------------------------------------------------------------


def render(set_rgb_sliders, set_hsl_sliders):
    r, g, b = STATE["r"], STATE["g"], STATE["b"]
    h, s, l = rgb_to_hsl(r, g, b)

    # When an RGB slider fired, push the freshly-derived HSL into the HSL
    # sliders (and vice versa). The `updating` flag in the input handlers
    # prevents the resulting "input" events from looping back.
    if set_hsl_sliders:
        _g("h").value = str(h)
        _g("s").value = str(s)
        _g("l").value = str(l)
    if set_rgb_sliders:
        _g("r").value = str(r)
        _g("g").value = str(g)
        _g("b").value = str(b)

    _set_text(_g("h-out"), str(h))
    _set_text(_g("s-out"), str(s))
    _set_text(_g("l-out"), str(l))
    _set_text(_g("r-out"), str(r))
    _set_text(_g("g-out"), str(g))
    _set_text(_g("b-out"), str(b))

    hex_str = "#" + _hex2(r) + _hex2(g) + _hex2(b)
    _set_text(_g("hex-out"), hex_str)
    _g("swatch").style.backgroundColor = hex_str


# ---------------------------------------------------------------------------
# Input handlers
# ---------------------------------------------------------------------------


def on_rgb_input(*_):
    if STATE["updating"]:
        return
    STATE["updating"] = True
    STATE["r"] = _g("r").value.to_int()
    STATE["g"] = _g("g").value.to_int()
    STATE["b"] = _g("b").value.to_int()
    render(False, True)
    STATE["updating"] = False


def on_hsl_input(*_):
    if STATE["updating"]:
        return
    STATE["updating"] = True
    h = _g("h").value.to_int()
    s = _g("s").value.to_int()
    l = _g("l").value.to_int()
    r, g, b = hsl_to_rgb(h, s, l)
    STATE["r"], STATE["g"], STATE["b"] = r, g, b
    render(True, False)
    STATE["updating"] = False


for sid in ("r", "g", "b"):
    _g(sid).addEventListener("input", on_rgb_input)
for sid in ("h", "s", "l"):
    _g(sid).addEventListener("input", on_hsl_input)

# Initial paint — sync everything from the default RGB=(0,0,0) state.
render(False, True)
