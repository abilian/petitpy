"""Predator-Prey (Lotka-Volterra) demo — Python-dominant.

J5b-style: one wasm instance per page load. main.py reads the slider
DOM values, integrates the trajectory in Q3 fixed-point, and drives a
``setInterval`` animation loop whose callback fires straight back into
this Python module for every frame draw. JavaScript only boots the
wasm.

All Q3 math is unchanged from the prior ``simulation.py`` stdout-batch
version (Q=1000, DT=0.1s, MAX_STEPS=2000). The nano build is float-less,
so:

  - rate sliders are integer-valued and pre-scaled by Q=1000 in the
    HTML (e.g. value="100" means rate 0.100). main.py reads them as
    ints directly and formats "0.100"-style display strings by hand.

  - population sliders are integer counts and get scaled up by Q on the
    Python side.

  - the animation loop walks the precomputed trajectory at ~20fps via
    ``js.window.setInterval(callback, 50)``; the callback is a Python
    function passed through the ADR-006 callback bridge.
"""

import js

# ---------------------------------------------------------------------------
# Lotka-Volterra core (Q3 fixed-point, integer-only)
# ---------------------------------------------------------------------------

Q = 1000
DT_Q = 100  # DT = 0.1 scaled by Q
MAX_STEPS = 2000  # 200s / DT
MAX_POP_Q = 5000 * Q  # cap populations to keep within 30-bit small-int


def _mul_q_v(rate_q, val_q):
    """rate_q * val_q (both Q-scaled) → Q-scaled product, no overflow."""
    val_int = val_q // Q
    val_frac_q = val_q - val_int * Q
    return rate_q * val_int + (rate_q * val_frac_q) // Q


def lotka_volterra_step(prey_q, pred_q, birth_q, predation_q, death_q, conv_q):
    term_birth_q = _mul_q_v(birth_q, prey_q)
    pp_q = _mul_q_v(predation_q, prey_q)
    term_pred_q = _mul_q_v(pp_q, pred_q)
    delta_prey_q = (term_birth_q - term_pred_q) * DT_Q // Q

    cp_q = _mul_q_v(conv_q, prey_q)
    term_conv_q = _mul_q_v(cp_q, pred_q)
    term_death_q = _mul_q_v(death_q, pred_q)
    delta_pred_q = (term_conv_q - term_death_q) * DT_Q // Q

    new_prey = prey_q + delta_prey_q
    new_pred = pred_q + delta_pred_q
    if new_prey < 0:
        new_prey = 0
    if new_pred < 0:
        new_pred = 0
    if new_prey > MAX_POP_Q:
        new_prey = MAX_POP_Q
    if new_pred > MAX_POP_Q:
        new_pred = MAX_POP_Q
    return new_prey, new_pred


def compute_trajectory(prey0, pred0, birth_q, predation_q, death_q, conv_q):
    """Run the simulation, return three int lists: t_tenths, prey, predators."""
    prey_q = prey0 * Q
    pred_q = pred0 * Q
    t_tenths = []  # time in tenths of a second (int)
    prey_out = []
    pred_out = []
    for t in range(MAX_STEPS):
        t_tenths.append(t)
        prey_out.append(prey_q // Q)
        pred_out.append(pred_q // Q)
        prey_q, pred_q = lotka_volterra_step(
            prey_q, pred_q, birth_q, predation_q, death_q, conv_q
        )
        if prey_q < Q and pred_q < Q:
            break
    return t_tenths, prey_out, pred_out


# ---------------------------------------------------------------------------
# DOM helpers
# ---------------------------------------------------------------------------


def _g(idn):
    return js.document.getElementById(idn)


def _slider_int(idn):
    """Read an <input type=range> value as an int (sliders are integer-valued)."""
    return _g(idn).value.to_int()


def _fmt_rate(v_q):
    """Format an integer Q-scaled rate as "<whole>.<3-frac>"."""
    whole = v_q // Q
    frac = v_q - whole * Q
    # zero-pad to 3 digits
    s = str(frac)
    while len(s) < 3:
        s = "0" + s
    return str(whole) + "." + s


def _set_text(el, text):
    el.textContent = text


def set_status(text, kind=""):
    s = _g("status")
    _set_text(s, text)
    s.classList.remove("err")
    s.classList.remove("ok")
    if kind:
        s.classList.add(kind)


# ---------------------------------------------------------------------------
# Canvas drawing
# ---------------------------------------------------------------------------


def _ctx(canvas_id):
    canvas = _g(canvas_id)
    return canvas, canvas.getContext("2d")


def _canvas_wh(canvas):
    return canvas.width.to_int(), canvas.height.to_int()


def _clear(ctx, w, h):
    ctx.fillStyle = "#1e293b"
    ctx.fillRect(0, 0, w, h)


def _axes(ctx, w, h, pad):
    ctx.strokeStyle = "#64748b"
    ctx.lineWidth = 1
    ctx.beginPath()
    ctx.moveTo(pad, pad)
    ctx.lineTo(pad, h - pad)
    ctx.lineTo(w - pad, h - pad)
    ctx.stroke()


def _max(seq):
    m = seq[0]
    for v in seq:
        if v > m:
            m = v
    return m


def draw_idle():
    canvas, ctx = _ctx("sim-canvas")
    w, h = _canvas_wh(canvas)
    _clear(ctx, w, h)
    _axes(ctx, w, h, 50)
    ctx.fillStyle = "#64748b"
    ctx.font = "13px system-ui"
    ctx.fillText("Press Start to run a simulation.", 70, 40)

    pcanvas, pctx = _ctx("phase-canvas")
    pw, ph = _canvas_wh(pcanvas)
    _clear(pctx, pw, ph)
    _axes(pctx, pw, ph, 50)


def draw_chart(t_tenths, prey, predators, max_step):
    canvas, ctx = _ctx("sim-canvas")
    w, h = _canvas_wh(canvas)
    pad = 50
    _clear(ctx, w, h)
    _axes(ctx, w, h, pad)
    if max_step < 2:
        return

    n = max_step
    max_t = t_tenths[n - 1]
    if max_t < 1:
        max_t = 1
    max_pop = _max(prey[:n])
    mp = _max(predators[:n])
    if mp > max_pop:
        max_pop = mp
    if max_pop < 1:
        max_pop = 1
    chart_w = w - 2 * pad
    chart_h = h - 2 * pad

    # Stride bounds the per-frame bridge calls to ~300 per series — every
    # lineTo crosses wasm <-> JS, so a naive 2000-point loop at 20 fps was
    # noticeably laggy. Sampling every Nth point is invisible at this scale.
    stride = n // 300
    if stride < 1:
        stride = 1

    def _series(series_q, color):
        ctx.strokeStyle = color
        ctx.beginPath()
        ctx.moveTo(
            pad + (t_tenths[0] * chart_w) // max_t,
            h - pad - (series_q[0] * chart_h) // max_pop,
        )
        for i in range(stride, n, stride):
            ctx.lineTo(
                pad + (t_tenths[i] * chart_w) // max_t,
                h - pad - (series_q[i] * chart_h) // max_pop,
            )
        # always include the latest point so the head of the line is
        # anchored on the current value, not "stride - 1" steps behind.
        if (n - 1) % stride != 0:
            ctx.lineTo(
                pad + (t_tenths[n - 1] * chart_w) // max_t,
                h - pad - (series_q[n - 1] * chart_h) // max_pop,
            )
        ctx.stroke()

    ctx.lineWidth = 2
    _series(prey, "#7aa2f7")  # prey, blue
    _series(predators, "#f7768e")  # predators, red

    # legend + current values
    ctx.font = "13px system-ui"
    ctx.fillStyle = "#7aa2f7"
    ctx.fillRect(w - 150, 18, 14, 14)
    ctx.fillStyle = "#e2e8f0"
    ctx.fillText("Prey: " + str(prey[n - 1]), w - 132, 30)

    ctx.fillStyle = "#f7768e"
    ctx.fillRect(w - 150, 44, 14, 14)
    ctx.fillStyle = "#e2e8f0"
    ctx.fillText("Predators: " + str(predators[n - 1]), w - 132, 56)

    ctx.fillStyle = "#94a3b8"
    sec = t_tenths[n - 1] // 10
    tenth = t_tenths[n - 1] - sec * 10
    ctx.fillText("t = " + str(sec) + "." + str(tenth), pad + 10, pad + 16)


def draw_phase(prey, predators, max_step):
    canvas, ctx = _ctx("phase-canvas")
    w, h = _canvas_wh(canvas)
    pad = 50
    _clear(ctx, w, h)
    _axes(ctx, w, h, pad)
    if max_step < 2:
        return

    n = max_step
    # 10% headroom on both axes (integer arithmetic).
    max_prey = (_max(prey[:n]) * 11) // 10
    if max_prey < 1:
        max_prey = 1
    max_pred = (_max(predators[:n]) * 11) // 10
    if max_pred < 1:
        max_pred = 1
    chart_w = w - 2 * pad
    chart_h = h - 2 * pad

    # Stride keeps the per-segment bridge-call count bounded (~200) even on
    # full 2000-step trajectories — at 20 fps that's still a lot of JS round
    # trips. A single purple stroke keeps it cheap and the cycle shape is
    # what carries the meaning here.
    stride = n // 200
    if stride < 1:
        stride = 1
    ctx.strokeStyle = "#bb9af7"
    ctx.lineWidth = 2
    ctx.beginPath()
    ctx.moveTo(
        pad + (prey[0] * chart_w) // max_prey,
        h - pad - (predators[0] * chart_h) // max_pred,
    )
    for i in range(stride, n, stride):
        x = pad + (prey[i] * chart_w) // max_prey
        y = h - pad - (predators[i] * chart_h) // max_pred
        ctx.lineTo(x, y)
    ctx.stroke()

    # current point — drawn as a small filled square rather than an arc()
    # because the nano build has no floats and arc() needs radians (Math.PI).
    cx = pad + (prey[n - 1] * chart_w) // max_prey
    cy = h - pad - (predators[n - 1] * chart_h) // max_pred
    ctx.fillStyle = "#e0af68"
    ctx.fillRect(cx - 4, cy - 4, 8, 8)

    # axis labels. The y-axis label is rotated -90° via setTransform(0, -1,
    # 1, 0, tx, ty) — an integer transform that avoids Math.PI / floats.
    ctx.fillStyle = "#94a3b8"
    ctx.font = "12px system-ui"
    ctx.textAlign = "center"
    ctx.fillText("Prey", w // 2, h - 12)
    ctx.save()
    ctx.setTransform(0, -1, 1, 0, 14, h // 2)
    ctx.fillText("Predators", 0, 0)
    ctx.restore()
    ctx.textAlign = "left"


# ---------------------------------------------------------------------------
# Animation loop (setInterval-driven)
# ---------------------------------------------------------------------------

STATE = {
    "t_tenths": None,
    "prey": None,
    "pred": None,
    "step": 0,
    "timer": None,
    "running": False,
}

STEP_PER_TICK = 5  # ~ 250 ms of sim-time advanced per frame at 50 ms interval


def _update_buttons():
    _g("start-btn").disabled = STATE["running"]
    _g("stop-btn").disabled = not STATE["running"]


def _stop_timer():
    if STATE["timer"] is not None:
        js.window.clearInterval(STATE["timer"])
        STATE["timer"] = None


def on_tick(*_):
    if not STATE["running"] or STATE["t_tenths"] is None:
        return
    n = len(STATE["t_tenths"])
    step = STATE["step"] + STEP_PER_TICK
    if step >= n:
        step = n
    draw_chart(STATE["t_tenths"], STATE["prey"], STATE["pred"], step)
    draw_phase(STATE["prey"], STATE["pred"], step)
    STATE["step"] = step
    if step >= n:
        STATE["running"] = False
        _stop_timer()
        _update_buttons()
        set_status("Done — " + str(n) + " steps. Press Start to rerun.", "ok")


def on_start(*_):
    if STATE["running"]:
        return
    prey0 = _slider_int("initial-prey")
    pred0 = _slider_int("initial-predators")
    birth_q = _slider_int("birth-rate")
    predation_q = _slider_int("predation-rate")
    death_q = _slider_int("death-rate")
    conv_q = _slider_int("conversion-rate")
    set_status("Integrating trajectory…")
    t_tenths, prey, pred = compute_trajectory(
        prey0, pred0, birth_q, predation_q, death_q, conv_q
    )
    STATE["t_tenths"] = t_tenths
    STATE["prey"] = prey
    STATE["pred"] = pred
    STATE["step"] = 0
    STATE["running"] = True
    _update_buttons()
    set_status(
        "Trajectory: " + str(len(t_tenths)) + " steps. Replaying…",
        "ok",
    )
    STATE["timer"] = js.window.setInterval(on_tick, 50).to_int()


def on_stop(*_):
    if not STATE["running"]:
        return
    STATE["running"] = False
    _stop_timer()
    _update_buttons()
    set_status("Paused.", "ok")


def on_reset(*_):
    STATE["running"] = False
    _stop_timer()
    STATE["t_tenths"] = None
    STATE["prey"] = None
    STATE["pred"] = None
    STATE["step"] = 0
    draw_idle()
    _update_buttons()
    set_status("Reset.", "ok")


# ---------------------------------------------------------------------------
# Slider-display sync (rate sliders show "0.100"-style human form)
# ---------------------------------------------------------------------------

RATE_SLIDERS = ("birth-rate", "predation-rate", "death-rate", "conversion-rate")
INT_SLIDERS = ("initial-prey", "initial-predators")


def _make_slider_handler(idn, fmt_rate):
    out = _g(idn + "-out")
    el = _g(idn)
    if fmt_rate:

        def handler(*_):
            _set_text(out, _fmt_rate(el.value.to_int()))
    else:

        def handler(*_):
            _set_text(out, el.value.to_str())

    return handler


def _wire_sliders():
    for sid in RATE_SLIDERS:
        h = _make_slider_handler(sid, True)
        _g(sid).addEventListener("input", h)
    for sid in INT_SLIDERS:
        h = _make_slider_handler(sid, False)
        _g(sid).addEventListener("input", h)


# ---------------------------------------------------------------------------
# Wire-up (runs once on page load, then this module returns; the wasm
# instance stays alive because the JS bridge holds wasmExports).
# ---------------------------------------------------------------------------

_g("start-btn").addEventListener("click", on_start)
_g("stop-btn").addEventListener("click", on_stop)
_g("reset-btn").addEventListener("click", on_reset)
_wire_sliders()

draw_idle()
_g("start-btn").disabled = False
set_status("Ready — press Start to run a simulation.", "ok")
