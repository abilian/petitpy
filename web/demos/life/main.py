"""Conway's Game of Life — Python-dominant, persistent wasm + js bridge.

One wasm instance is booted by ``app.js`` on page load. main.py:
  - owns the 60x40 cell grid (flat list of ints, 0 or 1),
  - computes each next generation using the classic B3/S23 rules with
    wrap-around (torus) edges,
  - paints cells on click + drag (via a 0-arg callback that app.js
    invokes after stashing the cursor coords on ``window``, since the
    bridge currently drops callback args),
  - wires the Start / Step / Clear / Random buttons via the ADR-006 js
    bridge,
  - runs the animation through ``js.window.setInterval`` with a Python
    callback,
  - repaints only the cells that flipped between the previous draw and
    the current grid, keeping the per-frame canvas calls minimal.

The nano build is float-less and has 30-bit smallints with no long-int
fallback, so the random fill uses a 16-bit-state integer LCG.
"""

import js

# ---------------------------------------------------------------------------
# Grid configuration
# ---------------------------------------------------------------------------

COLS = 60
ROWS = 40
CELL = 12
CANVAS_W = COLS * CELL  # 720
CANVAS_H = ROWS * CELL  # 480

ALIVE_COLOR = "#000000"
DEAD_COLOR = "#cccccc"


# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

STATE = {
    "grid": [0] * (COLS * ROWS),
    "prev": [0] * (COLS * ROWS),  # last-drawn snapshot; for differential redraw
    "generation": 0,
    "running": False,
    "timer": None,
}


# ---------------------------------------------------------------------------
# DOM helpers
# ---------------------------------------------------------------------------


def _g(idn):
    return js.document.getElementById(idn)


def _set_text(el, text):
    el.textContent = text


# ---------------------------------------------------------------------------
# Game of Life rules — torus topology
# ---------------------------------------------------------------------------


def _idx(c, r):
    return r * COLS + c


def next_generation(grid):
    """Classic B3/S23 with wrap-around edges. Returns a new flat list."""
    out = [0] * (COLS * ROWS)
    for r in range(ROWS):
        rm = (r - 1) % ROWS
        rp = (r + 1) % ROWS
        row_m = rm * COLS
        row_0 = r * COLS
        row_p = rp * COLS
        for c in range(COLS):
            cm = (c - 1) % COLS
            cp = (c + 1) % COLS
            n = (
                grid[row_m + cm]
                + grid[row_m + c]
                + grid[row_m + cp]
                + grid[row_0 + cm]
                + grid[row_0 + cp]
                + grid[row_p + cm]
                + grid[row_p + c]
                + grid[row_p + cp]
            )
            alive = grid[row_0 + c]
            if alive:
                out[row_0 + c] = 1 if (n == 2 or n == 3) else 0
            else:
                out[row_0 + c] = 1 if n == 3 else 0
    return out


# ---------------------------------------------------------------------------
# Canvas drawing
# ---------------------------------------------------------------------------


def _ctx():
    canvas = _g("life-canvas")
    return canvas.getContext("2d")


def draw_full(ctx):
    """Repaint the entire canvas (background + all alive cells)."""
    ctx.fillStyle = DEAD_COLOR
    ctx.fillRect(0, 0, CANVAS_W, CANVAS_H)
    ctx.fillStyle = ALIVE_COLOR
    grid = STATE["grid"]
    for r in range(ROWS):
        row = r * COLS
        for c in range(COLS):
            if grid[row + c]:
                ctx.fillRect(c * CELL, r * CELL, CELL, CELL)
    # snapshot what is now on screen so future redraws are differential
    STATE["prev"] = list(grid)


def draw_diff(ctx):
    """Repaint only the cells that changed since the last draw."""
    grid = STATE["grid"]
    prev = STATE["prev"]
    # First pass: dead cells (painted gray). Second pass: alive (black).
    # Two passes lets us set fillStyle just twice instead of per cell.
    ctx.fillStyle = DEAD_COLOR
    for r in range(ROWS):
        row = r * COLS
        for c in range(COLS):
            i = row + c
            if prev[i] == 1 and grid[i] == 0:
                ctx.fillRect(c * CELL, r * CELL, CELL, CELL)
    ctx.fillStyle = ALIVE_COLOR
    for r in range(ROWS):
        row = r * COLS
        for c in range(COLS):
            i = row + c
            if prev[i] == 0 and grid[i] == 1:
                ctx.fillRect(c * CELL, r * CELL, CELL, CELL)
    STATE["prev"] = list(grid)


def paint_cell(c, r, value):
    """Set one cell, redraw just that square."""
    i = _idx(c, r)
    if STATE["grid"][i] == value:
        return
    STATE["grid"][i] = value
    ctx = _ctx()
    ctx.fillStyle = ALIVE_COLOR if value else DEAD_COLOR
    ctx.fillRect(c * CELL, r * CELL, CELL, CELL)
    STATE["prev"][i] = value
    update_stats()


# ---------------------------------------------------------------------------
# Stats
# ---------------------------------------------------------------------------


def alive_count():
    s = 0
    for v in STATE["grid"]:
        s += v
    return s


def update_stats():
    _set_text(_g("generation"), str(STATE["generation"]))
    _set_text(_g("alive"), str(alive_count()))


# ---------------------------------------------------------------------------
# RNG — 16-bit-state LCG (nano build has 30-bit smallints and no long ints,
# so the multiplier and state must both fit safely in 30 bits).
# ---------------------------------------------------------------------------

_RAND_STATE = 1


def _next_rand():
    global _RAND_STATE
    _RAND_STATE = (_RAND_STATE * 1103 + 12345) & 0xFFFF
    return _RAND_STATE


def _rand_below(n):
    return _next_rand() % n


# ---------------------------------------------------------------------------
# Animation tick
# ---------------------------------------------------------------------------


def step_once():
    STATE["grid"] = next_generation(STATE["grid"])
    STATE["generation"] += 1
    draw_diff(_ctx())
    update_stats()


def on_tick(*_):
    if not STATE["running"]:
        return
    step_once()


def _start_timer():
    speed = _g("speed").value.to_int()
    STATE["timer"] = js.window.setInterval(on_tick, speed).to_int()


def _stop_timer():
    if STATE["timer"] is not None:
        js.window.clearInterval(STATE["timer"])
        STATE["timer"] = None


# ---------------------------------------------------------------------------
# Button handlers
# ---------------------------------------------------------------------------


def on_run(*_):
    if STATE["running"]:
        STATE["running"] = False
        _stop_timer()
        _set_text(_g("run-btn"), "Start")
    else:
        STATE["running"] = True
        _start_timer()
        _set_text(_g("run-btn"), "Pause")


def on_step(*_):
    if STATE["running"]:
        return
    step_once()


def on_clear(*_):
    if STATE["running"]:
        STATE["running"] = False
        _stop_timer()
        _set_text(_g("run-btn"), "Start")
    STATE["grid"] = [0] * (COLS * ROWS)
    STATE["generation"] = 0
    draw_full(_ctx())
    update_stats()


def on_random(*_):
    grid = [0] * (COLS * ROWS)
    # ~30% density gives an interesting starting field.
    for i in range(COLS * ROWS):
        if _rand_below(100) < 30:
            grid[i] = 1
    STATE["grid"] = grid
    STATE["generation"] = 0
    draw_full(_ctx())
    update_stats()


def on_speed(*_):
    _set_text(_g("speed-out"), _g("speed").value.to_str())
    if STATE["running"]:
        _stop_timer()
        _start_timer()


# ---------------------------------------------------------------------------
# Mouse painting — globals-stash workaround
#
# The js bridge currently drops callback args when wasm has no malloc/free
# exports (see web/lib/js-bridge.js), so a Python mousedown
# handler attached via ``canvas.addEventListener`` would receive no event
# object and cannot read ``offsetX``/``offsetY``. Instead JS does the
# wrapping: ``app.js`` listens for mousedown/mousemove/mouseup, stashes the
# canvas-relative cursor coords on ``window._paintX``/``_paintY``, then
# calls the 0-arg ``window._py_paint`` we publish below. Python reads the
# stashed coords and paints the cell.
# ---------------------------------------------------------------------------


def on_paint():
    px = js.window._paintX.to_int()
    py = js.window._paintY.to_int()
    cx = px // CELL
    cy = py // CELL
    if 0 <= cx < COLS and 0 <= cy < ROWS:
        paint_cell(cx, cy, 1)


# ---------------------------------------------------------------------------
# Wire-up (runs once on page load, then this module returns; the wasm
# instance stays alive because the bridge holds wasmExports).
# ---------------------------------------------------------------------------

draw_full(_ctx())
update_stats()

# Mouse paint: app.js owns the mousedown/mousemove listeners (so it can read
# event coords) and calls window._py_paint after stashing offsets on window.
js.window.set("_py_paint", on_paint)

_g("run-btn").addEventListener("click", on_run)
_g("step-btn").addEventListener("click", on_step)
_g("clear-btn").addEventListener("click", on_clear)
_g("random-btn").addEventListener("click", on_random)
_g("speed").addEventListener("input", on_speed)

for bid in ("run-btn", "step-btn", "clear-btn", "random-btn"):
    _g(bid).disabled = False

status = _g("status")
_set_text(status, "Ready — click or drag to paint, then press Start.")
status.classList.add("ok")
