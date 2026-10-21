"""Reaction-diffusion (Gray-Scott) demo — Python-dominant via the js bridge.

The 80x80 grid of two chemicals U and V is integrated in Q-scaled integer
math (Q=10000) because the nano build has no float marshaling. Python owns
the grid, steps the PDE each setInterval tick, renders one fillRect per
cell, and listens to mouse drag events to paint V. JS only boots the wasm.

Numerics:
  - U_q, V_q in [0, Q]. Q=10000 means 1.0 in plain units.
  - F slider value 545 -> F = 0.0545; consumed directly as F_RAW so
    F * (1 - U) becomes (F_RAW * (Q - U_q)) // Q.
  - Du = 16, Dv = 8 (Du * lap // 100 gives the per-step contribution).
  - Triple product U*V*V is staged: (U*V // Q) * V // Q stays under 10^8.
"""

import js

GRID = 80
CELL = 5  # pixels per cell -> 400x400 canvas
N = GRID * GRID
Q = 10000  # fixed-point scale for U, V

DU = 16  # 0.16 * 100
DV = 8  # 0.08 * 100
DU_DEN = 100
DV_DEN = 100


U_A = [Q] * N
V_A = [0] * N
U_B = [Q] * N
V_B = [0] * N


def _seed_center():
    half = GRID // 2
    for y in range(half - 10, half + 10):
        for x in range(half - 10, half + 10):
            i = y * GRID + x
            V_A[i] = (Q * 5) // 10
            U_A[i] = (Q * 5) // 10


def reset_grid():
    for i in range(N):
        U_A[i] = Q
        V_A[i] = 0
        U_B[i] = Q
        V_B[i] = 0
    _seed_center()


def step(f_raw, k_raw):
    """One Gray-Scott timestep; A -> B then copy back into A."""
    g = GRID
    q = Q
    du = DU
    dv = DV
    dud = DU_DEN
    dvd = DV_DEN
    fk_raw = f_raw + k_raw
    ua = U_A
    va = V_A
    ub = U_B
    vb = V_B

    for y in range(1, g - 1):
        row = y * g
        for x in range(1, g - 1):
            i = row + x
            u = ua[i]
            v = va[i]
            lap_u = (ua[i - 1] + ua[i + 1] + ua[i - g] + ua[i + g]) // 4 - u
            lap_v = (va[i - 1] + va[i + 1] + va[i - g] + va[i + g]) // 4 - v
            uv = (u * v) // q
            uvv = (uv * v) // q
            d_u = (du * lap_u) // dud - uvv + (f_raw * (q - u)) // q
            d_v = (dv * lap_v) // dvd + uvv - (fk_raw * v) // q
            nu = u + d_u
            nv = v + d_v
            if nu < 0:
                nu = 0
            elif nu > q:
                nu = q
            if nv < 0:
                nv = 0
            elif nv > q:
                nv = q
            ub[i] = nu
            vb[i] = nv

    # Neumann (zero-flux) border: copy verbatim.
    for x in range(g):
        ub[x] = ua[x]
        vb[x] = va[x]
        last = (g - 1) * g + x
        ub[last] = ua[last]
        vb[last] = va[last]
    for y in range(g):
        left = y * g
        right = left + g - 1
        ub[left] = ua[left]
        vb[left] = va[left]
        ub[right] = ua[right]
        vb[right] = va[right]

    # Mutate A in place so the module-level lists stay the same objects.
    for i in range(N):
        ua[i] = ub[i]
        va[i] = vb[i]


# 16-step grayscale palette indexed by V_q.
PALETTE = []
for _i in range(16):
    _g = (_i * 255) // 15
    _s = "0123456789abcdef"
    _hex2 = _s[_g // 16] + _s[_g % 16]
    PALETTE.append("#" + _hex2 + _hex2 + _hex2)


def _ctx():
    canvas = js.document.getElementById("rd-canvas")
    return canvas.getContext("2d")


def render():
    ctx = _ctx()
    ctx.fillStyle = PALETTE[0]
    ctx.fillRect(0, 0, GRID * CELL, GRID * CELL)
    cell = CELL
    bucket = Q // 16
    cur = -1
    for y in range(GRID):
        row = y * GRID
        py = y * cell
        for x in range(GRID):
            v = V_A[row + x]
            idx = v // bucket
            if idx > 15:
                idx = 15
            if idx == 0:
                continue
            if idx != cur:
                ctx.fillStyle = PALETTE[idx]
                cur = idx
            ctx.fillRect(x * cell, py, cell, cell)


STATE = {
    "timer": None,
    "running": False,
    "steps_per_frame": 8,
}


def _slider_int(idn):
    return js.document.getElementById(idn).value.to_int()


def _set_text(el, text):
    el.textContent = text


def _update_buttons():
    js.document.getElementById("start-btn").disabled = STATE["running"]
    js.document.getElementById("pause-btn").disabled = not STATE["running"]


def _stop_timer():
    if STATE["timer"] is not None:
        js.window.clearInterval(STATE["timer"])
        STATE["timer"] = None


def set_status(text, kind=""):
    s = js.document.getElementById("status")
    _set_text(s, text)
    s.classList.remove("err")
    s.classList.remove("ok")
    if kind:
        s.classList.add(kind)


def on_tick(*_):
    if not STATE["running"]:
        return
    f_raw = _slider_int("feed")
    k_raw = _slider_int("kill")
    for _ in range(STATE["steps_per_frame"]):
        step(f_raw, k_raw)
    render()


def on_start(*_):
    if STATE["running"]:
        return
    STATE["running"] = True
    _update_buttons()
    set_status("Running.", "ok")
    STATE["timer"] = js.window.setInterval(on_tick, 50).to_int()


def on_pause(*_):
    if not STATE["running"]:
        return
    STATE["running"] = False
    _stop_timer()
    _update_buttons()
    set_status("Paused.", "ok")


def on_reset(*_):
    STATE["running"] = False
    _stop_timer()
    reset_grid()
    render()
    _update_buttons()
    set_status("Reset.", "ok")


MOUSE = {"down": False}


def _paint_at(event):
    ox = event.offsetX.to_int()
    oy = event.offsetY.to_int()
    cx = ox // CELL
    cy = oy // CELL
    if cx < 0 or cx >= GRID or cy < 0 or cy >= GRID:
        return
    for dy in range(-2, 3):
        for dx in range(-2, 3):
            x = cx + dx
            y = cy + dy
            if x <= 0 or x >= GRID - 1 or y <= 0 or y >= GRID - 1:
                continue
            i = y * GRID + x
            V_A[i] = (Q * 9) // 10
            U_A[i] = Q // 4


def on_mousedown(event):
    MOUSE["down"] = True
    _paint_at(event)
    render()


def on_mousemove(event):
    if not MOUSE["down"]:
        return
    _paint_at(event)
    if not STATE["running"]:
        render()


def on_mouseup(*_):
    MOUSE["down"] = False


def _fmt_q4(v_raw):
    whole = v_raw // 10000
    frac = v_raw - whole * 10000
    s = str(frac)
    while len(s) < 4:
        s = "0" + s
    return str(whole) + "." + s


def _make_slider_handler(idn):
    out = js.document.getElementById(idn + "-out")
    el = js.document.getElementById(idn)

    def handler(*_):
        _set_text(out, _fmt_q4(el.value.to_int()))

    return handler


def _wire_sliders():
    for sid in ("feed", "kill"):
        js.document.getElementById(sid).addEventListener(
            "input", _make_slider_handler(sid)
        )


js.document.getElementById("start-btn").addEventListener("click", on_start)
js.document.getElementById("pause-btn").addEventListener("click", on_pause)
js.document.getElementById("reset-btn").addEventListener("click", on_reset)
_wire_sliders()

_canvas = js.document.getElementById("rd-canvas")
_canvas.addEventListener("mousedown", on_mousedown)
_canvas.addEventListener("mousemove", on_mousemove)
_canvas.addEventListener("mouseup", on_mouseup)
_canvas.addEventListener("mouseleave", on_mouseup)

reset_grid()
render()
_update_buttons()
set_status("Ready — press Start, or drag on the canvas to paint V.", "ok")
