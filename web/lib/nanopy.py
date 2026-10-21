"""nanopy — a small browser-game library for nanopython demos.

Two parallel APIs share the same primitives:

  Kid-friendly (procedural):

      import nanopy
      screen = nanopy.canvas("board")

      x = 50
      def update():
          global x
          x += 1
      def draw():
          screen.fill("black")
          screen.rect(x, 100, 30, 30, "red")
      def on_press(key):
          global x
          if key == "ArrowLeft":  x -= 10
          if key == "ArrowRight": x += 10
      nanopy.run(update=update, draw=draw, on_press=on_press, fps=30)

  Pro-friendly (classes + decorators):

      from nanopy import Canvas, Ticker, on_key, storage

      canvas = Canvas("board")
      class Game:
          def __init__(self): ...
          def render(self): canvas.rect(0, 0, 100, 100, "red")
      g = Game()
      Ticker(g.render, 33).start()
      @on_key("ArrowLeft")
      def left(): ...

Pygame inspires the *naming* of the drawing primitives — `screen.fill`,
`screen.rect(x, y, w, h, color)`, `screen.text(s, x, y, color, size)`,
`screen.line` — and the procedural-loop shape (`update` / `draw` /
event handler). It does NOT inspire the architecture: there's no
`init()`, no `Surface`, no module-level event queue. Web is event-
driven and we lean into that rather than poll-emulate it.

Lives at `web/lib/nanopy.py`. Per-demo `*-lite/nanopy.py` is a
symlink to this one. Eventual home is `nanopython-lib/dom.py` as a
frozen-tiny module (Tier 1 item 2 in
`notes/07-js-vs-nanopython-games.md`, modulo the file being rewound).
"""

import js

# ---------------------------------------------------------------------------
# Color normalization
# ---------------------------------------------------------------------------

# A few CSS named colors that don't always work as-is across browsers.
# Anything not in this map gets passed through verbatim — CSS accepts
# hex, rgb(), rgba(), named colors, etc.
_NAMED = {
    "black": "#000000",
    "white": "#ffffff",
    "red": "#ff5252",
    "green": "#9ece6a",
    "blue": "#7aa2f7",
    "yellow": "#f0c449",
    "orange": "#f5a06b",
    "purple": "#bb9af7",
    "pink": "#f7768e",
    "gray": "#94a3b8",
    "grey": "#94a3b8",
    "dark": "#1e293b",
    "light": "#cdd6f4",
}


def color(c):
    """Normalize a color spec to a CSS string.

    Accepts:
      - "red", "black", … — see _NAMED for the friendly palette.
      - "#abc", "#abcdef", "rgb(...)", "rgba(...)" — passed through.
      - (r, g, b) tuple of ints in 0..255.
    """
    if isinstance(c, tuple) and len(c) == 3:
        return "rgb(" + str(c[0]) + "," + str(c[1]) + "," + str(c[2]) + ")"
    if isinstance(c, str):
        return _NAMED.get(c.lower(), c)
    return str(c)


# ---------------------------------------------------------------------------
# Canvas — the shared drawing surface
#
# Exposes Pygame-style drawing primitives as methods. The pro escape
# hatches (`canvas.fillRect(...)` via __getattr__ + `canvas["fillStyle"]
# = X` via __setitem__) are still there for anything the friendly API
# doesn't cover.
# ---------------------------------------------------------------------------


class Canvas:
    def __init__(self, element_id):
        self._el = js.document.getElementById(element_id)
        self._ctx = self._el.getContext("2d")
        self.width = self._el.width.to_int()
        self.height = self._el.height.to_int()

    # -- pro escape hatches ------------------------------------------------
    def __getattr__(self, name):
        return getattr(self._ctx, name)

    def __setitem__(self, name, value):
        self._ctx.set(name, value)

    # -- kid-friendly primitives -------------------------------------------
    # Since v0.7, `__setattr__` works on user classes on nano — so
    # plain attribute writes (`self._ctx.fillStyle = X`) route through
    # JsProxy.__setattr__ and push to JS directly. No more bracket dance.
    def fill(self, c):
        """Fill the whole canvas with color `c`."""
        self._ctx.fillStyle = color(c)
        self._ctx.fillRect(0, 0, self.width, self.height)

    def rect(self, x, y, w, h, c):
        """Filled rectangle."""
        self._ctx.fillStyle = color(c)
        self._ctx.fillRect(x, y, w, h)

    def stroke_rect(self, x, y, w, h, c, width=1):
        """Outlined rectangle."""
        self._ctx.strokeStyle = color(c)
        self._ctx.lineWidth = width
        self._ctx.strokeRect(x, y, w, h)

    def line(self, x1, y1, x2, y2, c, width=1):
        """Line from (x1, y1) to (x2, y2)."""
        self._ctx.strokeStyle = color(c)
        self._ctx.lineWidth = width
        self._ctx.beginPath()
        self._ctx.moveTo(x1, y1)
        self._ctx.lineTo(x2, y2)
        self._ctx.stroke()

    def text(
        self,
        s,
        x,
        y,
        c="white",
        size=16,
        align="left",
        baseline="alphabetic",
        bold=False,
    ):
        """Draw text. (x, y) is the baseline-left by default."""
        weight = "bold " if bold else ""
        self._ctx.font = weight + str(size) + "px system-ui"
        self._ctx.fillStyle = color(c)
        self._ctx.textAlign = align
        self._ctx.textBaseline = baseline
        self._ctx.fillText(s, x, y)

    def rounded_rect(self, x, y, w, h, r, c):
        """Filled rectangle with corner radius r."""
        self._ctx.fillStyle = color(c)
        self._ctx.beginPath()
        self._ctx.moveTo(x + r, y)
        self._ctx.lineTo(x + w - r, y)
        self._ctx.arcTo(x + w, y, x + w, y + r, r)
        self._ctx.lineTo(x + w, y + h - r)
        self._ctx.arcTo(x + w, y + h, x + w - r, y + h, r)
        self._ctx.lineTo(x + r, y + h)
        self._ctx.arcTo(x, y + h, x, y + h - r, r)
        self._ctx.lineTo(x, y + r)
        self._ctx.arcTo(x, y, x + r, y, r)
        self._ctx.closePath()
        self._ctx.fill()


def canvas(element_id):
    """Friendly factory: `screen = nanopy.canvas("board")`."""
    return Canvas(element_id)


# ---------------------------------------------------------------------------
# DOM text helpers — separate from Canvas.text (which draws on the canvas)
# ---------------------------------------------------------------------------


def set_text(element_id, value):
    """Set textContent on an element by id."""
    el = js.document.getElementById(element_id)
    el.set("textContent", str(value))


def status(message, kind=""):
    """Update the page's #status element and toggle ok/err class."""
    s = js.document.getElementById("status")
    s.set("textContent", message)
    s.classList.remove("err")
    s.classList.remove("ok")
    if kind:
        s.classList.add(kind)


# ---------------------------------------------------------------------------
# Storage — localStorage with quota/disabled errors caught once
# ---------------------------------------------------------------------------


class _Storage:
    def get_int(self, key, default=0):
        store = js.window.localStorage
        if store._h == 0:
            return default
        v = store.getItem(key).to_str()
        if not v or v in ("null", "undefined"):
            return default
        try:
            return int(v)
        except ValueError:
            # Corrupt/hand-edited value — fall back rather than propagate.
            return default

    def set_int(self, key, value):
        store = js.window.localStorage
        if store._h == 0:
            return
        store.setItem(key, str(value))


storage = _Storage()


# ---------------------------------------------------------------------------
# Score — reactive score widget.
#
# Every game in the gallery does the same dance: bump an integer,
# `set_text` the matching DOM element, check against high, persist.
# Five-or-seven lines per increment site, six globals to track.
# A `@property` setter folds it all into `score.value = n`. Works on
# nano because v0.6.1 enabled DELATTR_SETATTR so user-class property
# setters fire correctly.
#
# Usage:
#     score = Score("score", storage_key="snake_high", best_id="high")
#     score.value = 5             # → updates DOM, persists high if exceeded
#     score.add(1)                # → score.value = score.value + 1
#     score.reset()               # → back to 0 (best is preserved)
#
# The `Lives` and `Counter` siblings are the same shape with different
# vocabulary (`lives.lose(1)` instead of `score.add(1)`).
# ---------------------------------------------------------------------------


class Score:
    def __init__(self, element_id, storage_key=None, best_id=None):
        self._element_id = element_id
        self._storage_key = storage_key
        self._best_id = best_id
        self._value = 0
        self._best = storage.get_int(storage_key, 0) if storage_key else 0
        set_text(element_id, 0)
        if best_id is not None:
            set_text(best_id, self._best)

    @property
    def value(self):
        return self._value

    @value.setter
    def value(self, n):
        self._value = n
        set_text(self._element_id, n)
        if self._storage_key is not None and n > self._best:
            self._best = n
            if self._best_id is not None:
                set_text(self._best_id, n)
            storage.set_int(self._storage_key, n)

    @property
    def best(self):
        return self._best

    def add(self, delta):
        """`score.add(10)` instead of `score.value = score.value + 10`."""
        self.value = self._value + delta

    def reset(self):
        """Back to 0 (best is preserved)."""
        self.value = 0


class Lives:
    """Reactive lives counter. `lives.lose(1)` and `lives.gain(1)`
    update the DOM. `lives.empty` is True once depleted."""

    def __init__(self, element_id, start=3):
        self._element_id = element_id
        self._start = start
        self._value = start
        set_text(element_id, start)

    @property
    def value(self):
        return self._value

    @value.setter
    def value(self, n):
        self._value = n
        set_text(self._element_id, n)

    @property
    def empty(self):
        return self._value <= 0

    def lose(self, n=1):
        self.value = max(0, self._value - n)

    def gain(self, n=1):
        self.value = self._value + n

    def reset(self):
        self.value = self._start


# ---------------------------------------------------------------------------
# Random — 16-bit LCG. Once float marshal lands across the bridge this
# block becomes `import random` and callers don't change because the
# API is the same.
# ---------------------------------------------------------------------------

_rand_state = 1


def randrange(n):
    """Random integer in [0, n)."""
    global _rand_state
    _rand_state = (_rand_state * 1103 + 12345) & 0xFFFF
    return _rand_state % n


def randint(a, b):
    """Random integer in [a, b] (inclusive on both ends)."""
    return a + randrange(b - a + 1)


def choice(seq):
    """Pick a random element from a non-empty sequence."""
    return seq[randrange(len(seq))]


# ---------------------------------------------------------------------------
# Collision helpers — every game inlines its own _overlap. Hoist.
# Rectangles are (x, y, w, h) tuples.
# ---------------------------------------------------------------------------


def overlap_rect(a, b):
    """True if rectangles a and b overlap. Each is (x, y, w, h)."""
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    return ax < bx + bw and ax + aw > bx and ay < by + bh and ay + ah > by


def point_in_rect(x, y, rect):
    """True if (x, y) is inside the rectangle (rx, ry, rw, rh)."""
    rx, ry, rw, rh = rect
    return rx <= x < rx + rw and ry <= y < ry + rh


def dist_sq(a, b):
    """Squared Euclidean distance between (ax, ay) and (bx, by).
    Integer-only — avoid sqrt for the smallint floor. Use this for
    comparisons (`dist_sq(p, q) < r * r`); avoid for visual computations."""
    return (a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2


# ---------------------------------------------------------------------------
# Sound primitives — thin wrapper over the JS-side helper installed by
# the demo's app.js loader. See `web/lib/nanopy-host.js` for the JS half.
#
# Single tones via `beep(freq_hz, ms, kind="sine")`. Chord-y rewards
# via `tone([440, 550, 660], ms_per=120)`. Both are no-ops if the host
# hasn't installed the helper or the user hasn't gestured yet (browser
# audio policy requires a click or keypress before audio plays).
# ---------------------------------------------------------------------------


def beep(freq=440, ms=80, kind="sine"):
    """Play a single tone. `kind` is one of sine / square / triangle / sawtooth.

    A no-op on pages that don't load `nanopy-host.js`.
    """
    fn = js.window.__np_beep
    if fn._h == 0:
        return
    fn(freq, ms, kind)


def tone(notes, ms_per=120, kind="sine"):
    """Play a sequence of notes. Each `note` is a frequency in Hz.

    A no-op on pages that don't load `nanopy-host.js`.
    """
    # Hoisted out of the loop: one bridge read, not one per note.
    fn = js.window.__np_beep_at
    if fn._h == 0:
        return
    delay = 0
    for n in notes:
        fn(n, ms_per, kind, delay)
        delay += ms_per


# ---------------------------------------------------------------------------
# Key dispatch
#
# Two surfaces:
#
#   Pro:   @on_key("ArrowLeft", "a") def left(): ...
#                    fires for exactly these keys
#
#   Kid:   def on_press(key): ...
#                    nanopy.run(..., on_press=on_press)
#                    fires for any key in the pre-registered set
#
# Both work by registering callbacks at `window["__np_key_<key>"]`.
# The companion JS shim (one per demo, generic) calls
# `window["__np_key_" + e.key]?.()` on every keydown.
# ---------------------------------------------------------------------------

# Keys the kid-mode `on_press` handler binds. Pro mode uses on_key
# with explicit names, so it doesn't need this list.
_KID_KEYS = (
    "ArrowLeft",
    "ArrowRight",
    "ArrowUp",
    "ArrowDown",
    "w",
    "W",
    "a",
    "A",
    "s",
    "S",
    "d",
    "D",
    "r",
    "R",
    "p",
    "P",
    " ",
    "Enter",
    "Escape",
    "z",
    "Z",
    "x",
    "X",
    "c",
    "C",
)


def on_key(*keys):
    """Pro decorator. Wrap a function to fire when any of `keys` is pressed."""

    def decorator(fn):
        def _wrapped(*_):
            fn()

        for k in keys:
            js.window.set("__np_key_" + k, _wrapped)
        return fn

    return decorator


def _install_kid_keys(on_press):
    # The closure-over-loop-variable trick: bind `key` per iteration
    # via a default arg so each wrapper closes over its own value.
    for k in _KID_KEYS:

        def make(key=k):
            def wrap(*_):
                on_press(key)

            return wrap

        js.window.set("__np_key_" + k, make())


# ---------------------------------------------------------------------------
# Game loop — the kid procedural API
#
# `run(update=, draw=, on_press=, fps=)` calls update + draw every tick
# at the requested fps and dispatches keys to on_press. Each callback
# is optional. Stop with `stop()`.
#
# For finer control (pause, level-up gravity changes, multiple timers),
# pros can use `Ticker` directly — see below.
# ---------------------------------------------------------------------------

_run_handle = [None]


def run(update=None, draw=None, on_press=None, on_click=None, fps=30):
    """Start the game loop. Call once at the bottom of main.py.

    For turn-based games (2048, memory match, …) pass only `on_press`
    or `on_click` and the game updates from inside the handler — no
    loop is started. `update`/`draw` callbacks are optional; if both
    are None, no `setInterval` is created.

    `on_click(x, y)` fires on mouse click anywhere on the canvas
    (the demo's app.js installs the listener on whichever canvas it
    declares the primary game surface for).
    """
    if update is not None or draw is not None:
        interval = max(16, 1000 // fps)

        def tick(*_):
            if update is not None:
                update()
            if draw is not None:
                draw()

        _run_handle[0] = js.window.setInterval(tick, interval).to_int()
    if on_press is not None:
        _install_kid_keys(on_press)
    if on_click is not None:
        _install_click(on_click)


# ---------------------------------------------------------------------------
# Mouse / pointer dispatch
#
# Similar shape to keys: the JS-side click listener writes canvas-relative
# (x, y) into `window.__np_click_x` / `__np_click_y` then calls
# `window.__np_click()`. Python reads the globals.
#
# Two surfaces:
#   Pro:   @on_click def click(x, y): ...
#   Kid:   def on_click(x, y): ...; nanopy.run(..., on_click=on_click)
# ---------------------------------------------------------------------------


def on_click(fn):
    """Pro decorator. Register `fn(x, y)` for canvas click events."""

    def _wrapped(*_):
        x = js.window.__np_click_x.to_int()
        y = js.window.__np_click_y.to_int()
        fn(x, y)

    js.window.set("__np_click", _wrapped)
    return fn


def _install_click(handler):
    def _wrapped(*_):
        x = js.window.__np_click_x.to_int()
        y = js.window.__np_click_y.to_int()
        handler(x, y)

    js.window.set("__np_click", _wrapped)


def stop():
    """Stop the run-loop timer. The keydown handlers stay installed."""
    if _run_handle[0] is not None:
        js.window.clearInterval(_run_handle[0])
        _run_handle[0] = None


# ---------------------------------------------------------------------------
# Ticker — pro alternative when you want to own the timer lifecycle
# (pause, restart, dynamic interval). Used by Tetris-lite.
# ---------------------------------------------------------------------------


class Ticker:
    def __init__(self, fn, ms):
        self._fn = fn
        self._ms = ms
        self._handle = None

    def start(self):
        if self._handle is None:
            self._handle = js.window.setInterval(self._fn, self._ms).to_int()

    def stop(self):
        if self._handle is not None:
            js.window.clearInterval(self._handle)
            self._handle = None

    def set_interval(self, ms):
        self._ms = ms
        if self._handle is not None:
            self.stop()
            self.start()
