"""Snake game — Python-dominant, persistent-wasm + bridge callbacks.

J5b shape: one wasm instance per page load. main.py owns the snake
state, redraws the canvas every tick through the js bridge, and runs
the game loop via ``js.window.setInterval``. JavaScript only boots the
wasm and translates ``keydown`` events into one of five zero-arg
callbacks exposed on ``window`` (Up / Down / Left / Right / Restart) —
the bridge currently drops callback args when the wasm has no
malloc/free exports, so this split keeps key handling in JS while all
game logic stays in Python.
"""

import js

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

GRID = 20  # 20 x 20 logical board
CELL = 20  # px per cell -> 400 x 400 canvas
W = GRID * CELL
START_INTERVAL = 150  # ms per tick
MIN_INTERVAL = 60  # cap on speed
SPEED_STEP = 10  # ms shaved off per 5-apple threshold

BG = "#1e293b"
GRID_COL = "#334155"
SNAKE = "#9ece6a"
HEAD = "#7aa2f7"
APPLE = "#f7768e"
TEXT = "#e6e6e6"
DIM = "#94a3b8"

STORAGE_KEY = "petitpy:snake:high"


# ---------------------------------------------------------------------------
# 16-bit-state LCG — integer-only random.
# Math.random() returns a float; the bridge has no float marshal. The nano
# build has MICROPY_LONGINT_IMPL=NONE (30-bit smallints, cap ~5.4e8), so
# both the seed and the recurrence must stay well inside that range. The
# state is masked to 16 bits; max(state * 1103 + 12345) = 72,290,250.
# ---------------------------------------------------------------------------

_RAND_STATE = 1


def _next_rand():
    global _RAND_STATE
    _RAND_STATE = (_RAND_STATE * 1103 + 12345) & 0xFFFF
    return _RAND_STATE


def _rand_int(n):
    """Return a pseudo-random int in [0, n)."""
    return _next_rand() % n


# ---------------------------------------------------------------------------
# DOM helpers
# ---------------------------------------------------------------------------


def _g(idn):
    return js.document.getElementById(idn)


def _set_text(el, text):
    el.textContent = text


def _set_status(text, kind=""):
    s = _g("status")
    _set_text(s, text)
    s.classList.remove("err")
    s.classList.remove("ok")
    if kind:
        s.classList.add(kind)


# ---------------------------------------------------------------------------
# localStorage (read/write high score; tolerate quota/disabled errors)
# ---------------------------------------------------------------------------


def _load_high():
    # The bridge never raises: a missing localStorage is a 0 handle, and
    # .to_str() on one yields "null". int() on a corrupt value is the only
    # catchable failure here.
    store = js.window.localStorage
    if store._h == 0:
        return 0
    v = store.getItem(STORAGE_KEY).to_str()
    if not v or v in ("null", "undefined"):
        return 0
    try:
        return int(v)
    except ValueError:
        return 0


def _save_high(n):
    store = js.window.localStorage
    if store._h == 0:
        return
    store.setItem(STORAGE_KEY, str(n))


# ---------------------------------------------------------------------------
# Canvas drawing
# ---------------------------------------------------------------------------


def _ctx():
    return _g("board").getContext("2d")


def _draw_grid(ctx):
    ctx.fillStyle = BG
    ctx.fillRect(0, 0, W, W)
    ctx.strokeStyle = GRID_COL
    ctx.lineWidth = 1
    for i in range(1, GRID):
        p = i * CELL
        ctx.beginPath()
        ctx.moveTo(p, 0)
        ctx.lineTo(p, W)
        ctx.stroke()
        ctx.beginPath()
        ctx.moveTo(0, p)
        ctx.lineTo(W, p)
        ctx.stroke()


def _draw_cell(ctx, x, y, color):
    ctx.fillStyle = color
    ctx.fillRect(x * CELL + 1, y * CELL + 1, CELL - 2, CELL - 2)


def _draw_overlay(ctx, score):
    # Translucent strip behind the text.
    ctx.fillStyle = "#000000"
    ctx.fillRect(0, W // 2 - 50, W, 100)
    ctx.fillStyle = TEXT
    ctx.font = "bold 28px system-ui"
    ctx.textAlign = "center"
    ctx.fillText("Game over", W // 2, W // 2 - 10)
    ctx.font = "14px system-ui"
    ctx.fillStyle = DIM
    ctx.fillText("Score " + str(score) + ". Press R to restart", W // 2, W // 2 + 18)
    ctx.textAlign = "left"


def _render():
    ctx = _ctx()
    _draw_grid(ctx)
    ax, ay = STATE["apple"]
    _draw_cell(ctx, ax, ay, APPLE)
    body = STATE["snake"]
    for i in range(1, len(body)):
        x, y = body[i]
        _draw_cell(ctx, x, y, SNAKE)
    hx, hy = body[0]
    _draw_cell(ctx, hx, hy, HEAD)
    if STATE["over"]:
        _draw_overlay(ctx, STATE["score"])


# ---------------------------------------------------------------------------
# Game state + logic
# ---------------------------------------------------------------------------

STATE = {
    "snake": None,  # list of (x, y) tuples; head at index 0
    "dx": 1,
    "dy": 0,
    "next_dx": 1,  # buffered direction (applied at tick boundary)
    "next_dy": 0,
    "apple": (0, 0),
    "score": 0,
    "high": 0,
    "over": False,
    "timer": None,
    "interval": START_INTERVAL,
}


def _spawn_apple():
    occupied = set(STATE["snake"])
    # Grid is small; rejection-sample.
    while True:
        x = _rand_int(GRID)
        y = _rand_int(GRID)
        if (x, y) not in occupied:
            STATE["apple"] = (x, y)
            return


def _set_score(n):
    STATE["score"] = n
    _set_text(_g("score"), str(n))
    if n > STATE["high"]:
        STATE["high"] = n
        _set_text(_g("high"), str(n))
        _save_high(n)


def _stop_timer():
    if STATE["timer"] is not None:
        js.window.clearInterval(STATE["timer"])
        STATE["timer"] = None


def _start_timer():
    STATE["timer"] = js.window.setInterval(on_tick, STATE["interval"]).to_int()


def _reset():
    _stop_timer()
    # Snake of length 3 in the middle, heading right.
    mid = GRID // 2
    STATE["snake"] = [(mid, mid), (mid - 1, mid), (mid - 2, mid)]
    STATE["dx"] = 1
    STATE["dy"] = 0
    STATE["next_dx"] = 1
    STATE["next_dy"] = 0
    STATE["over"] = False
    STATE["interval"] = START_INTERVAL
    _set_score(0)
    _spawn_apple()
    _render()
    _start_timer()
    _set_status("Use arrow keys or WASD to steer.", "ok")


def on_tick(*_):
    if STATE["over"]:
        return
    # Apply buffered direction.
    STATE["dx"] = STATE["next_dx"]
    STATE["dy"] = STATE["next_dy"]
    body = STATE["snake"]
    hx, hy = body[0]
    nx = hx + STATE["dx"]
    ny = hy + STATE["dy"]

    # Wall collision.
    if nx < 0 or nx >= GRID or ny < 0 or ny >= GRID:
        _game_over()
        return

    new_head = (nx, ny)
    ate = new_head == STATE["apple"]

    # Self-collision: the tail cell is freed unless we ate (because then
    # the snake grows by one and the old tail stays).
    if ate:
        check = body
    else:
        check = body[:-1]
    if new_head in check:
        _game_over()
        return

    body.insert(0, new_head)
    if ate:
        _set_score(STATE["score"] + 1)
        # Speed up every 5 apples.
        if STATE["score"] % 5 == 0 and STATE["interval"] > MIN_INTERVAL:
            STATE["interval"] -= SPEED_STEP
            if STATE["interval"] < MIN_INTERVAL:
                STATE["interval"] = MIN_INTERVAL
            _stop_timer()
            _start_timer()
        _spawn_apple()
    else:
        body.pop()
    _render()


def _game_over():
    STATE["over"] = True
    _stop_timer()
    _render()
    _set_status("Game over. Press R to restart.", "err")


# ---------------------------------------------------------------------------
# Direction inputs — exposed on `window` so the JS keydown handler can
# dispatch by key without the bridge needing to marshal event args.
# Each guards against the 180-degree reversal.
# ---------------------------------------------------------------------------


def _turn(dx, dy):
    if STATE["over"]:
        return
    # Block reversal: compare against the *committed* heading, not the
    # buffered one, so a quick two-key tap within one tick can't fold the
    # snake onto itself.
    if STATE["dx"] == -dx and STATE["dy"] == -dy:
        return
    STATE["next_dx"] = dx
    STATE["next_dy"] = dy


def on_up(*_):
    _turn(0, -1)


def on_down(*_):
    _turn(0, 1)


def on_left(*_):
    _turn(-1, 0)


def on_right(*_):
    _turn(1, 0)


def on_restart(*_):
    _reset()


# ---------------------------------------------------------------------------
# Wire-up
# ---------------------------------------------------------------------------

STATE["high"] = _load_high()
_set_text(_g("high"), str(STATE["high"]))

js.window.set("__snakeUp", on_up)
js.window.set("__snakeDown", on_down)
js.window.set("__snakeLeft", on_left)
js.window.set("__snakeRight", on_right)
js.window.set("__snakeRestart", on_restart)

_reset()
