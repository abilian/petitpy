# Writing games with nanopy

A small browser game in petitpy looks the way it would in Pygame: a `screen` to draw on, an `update` to move things, a `draw` to repaint, an `on_press` for keys. The hosting (WebAssembly load, canvas wiring, key listener, audio context, `localStorage`) lives in a sibling JS loader and a small Python library called `nanopy`. Your `main.py` never says "canvas context" or "setInterval" or "localStorage". It says `screen.rect(...)`, `score.add(1)`, `nanopy.run(...)`.

This tutorial walks through building **Catch** (a paddle catching falling fruit) from an empty directory to a playable browser game. It then shows the same game written the "pro" way (classes + decorators) so you can pick whichever style you find more readable. The companion gallery (Snake, Breakout, 2048, Tetris, Space Invaders, Memory Match, each in kid / pro / JS variants) lives under `web/games/`; they all use the same `nanopy.py` and are a good reference once you've finished here.

## What you'll need

- A petitpy build with the `nanopython.wasm` shipping artifact (`make wasm` in the repo root produces `web/nanopython.wasm`).
- The `web/lib/` directory next to your demo (it holds the JS host shim, the JS bridge, and `nanopy.py` itself).
- A local web server to serve the page. `python3 -m http.server 8000` from the repo root works; opening `index.html` via `file://` does **not** because the browser refuses to fetch `.wasm` from a file URL.

## The four files per game

Every game in `web/games/` is exactly four files:

```
my-game/
├── index.html      ← page scaffold + canvas element + score widgets
├── app.js          ← generic loader: fetches the wasm, mounts main.py, installs keydown
├── nanopy.py       ← symlink to ../../lib/nanopy.py (the library)
└── main.py         ← your game logic — what this tutorial is about
```

`app.js` and `index.html` are boilerplate you copy from any existing game. **The game lives in `main.py`.**

## Step 1: the empty page

Start with an `index.html` that has a `<canvas id="board">` plus three text spans (score, misses, high) and a `<p id="status">` for the welcome / game-over message.

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Catch — petitpy</title>
<link rel="stylesheet" href="../../shared.css">
</head>
<body>
<main>
  <h1>Catch</h1>
  <p class="status" id="status">Loading…</p>

  <div>
    <span>Score: <span id="score">0</span></span>
    <span>Misses: <span id="misses">0</span></span>
    <span>High: <span id="high">0</span></span>
  </div>

  <canvas id="board" width="500" height="400"></canvas>
  <p>Arrow keys or A/D to move. R to restart.</p>
</main>
<script type="module" src="./app.js"></script>
</body>
</html>
```

`main.py` reaches for four IDs by name: `board`, `score`, `misses`, `high`, `status`. Change them in HTML, you change them in Python; same as any other DOM-driven app.

## Step 2: the canvas, with one line

```python
import nanopy
screen = nanopy.canvas("board")
W = screen.width
H = screen.height
```

`screen` is a wrapper around the `<canvas>`'s 2D context. You don't have to know that; you call methods on it:

```python
screen.fill("dark")                              # paint the whole thing
screen.rect(x, y, w, h, "red")                   # filled rectangle
screen.stroke_rect(x, y, w, h, "white", width=2) # outlined rectangle
screen.line(x1, y1, x2, y2, "blue")
screen.text("Hello", 200, 100, "white", size=24, align="center", bold=True)
screen.rounded_rect(x, y, w, h, radius=6, c="green")
```

Colors are either friendly names (`"red"`, `"blue"`, `"dark"`, `"pink"`, …), hex strings (`"#ff5252"`), CSS expressions (`"rgba(0, 0, 0, 0.78)"`), or `(r, g, b)` tuples. Anything CSS accepts, the library accepts.

## Step 3: game state

The game uses pure module-level globals, with no `Game` class or setup function: the simplest readable shape.

```python
PADDLE_W = 80
PADDLE_H = 14
PADDLE_Y = H - 30
PADDLE_SPEED = 12

FRUIT_R = 14
FRUIT_SPEED_START = 4

paddle_x = W // 2 - PADDLE_W // 2
fruit_x = W // 2
fruit_y = 0
fruit_color = "red"
fruit_speed = FRUIT_SPEED_START
score = 0
misses = 0
high = nanopy.storage.get_int("catch_high", 0)
game_over = False
left_held = False
right_held = False
```

`nanopy.storage` is a thin wrapper around `localStorage`. `get_int(key, default)` returns the saved high score or zero on first run; `set_int(key, value)` saves it. Quota errors and disabled-storage errors are swallowed silently; the game keeps working, the high just doesn't persist.

## Step 4: update, draw, on_press

The shape of every frame-driven game is three functions that nanopy calls for you:

- **`update()`:** runs every tick. Moves things. Checks for collisions. Updates the score. **No drawing here.**
- **`draw()`:** runs every tick after `update`. Repaints the canvas. **No state changes here.**
- **`on_press(key)`:** runs once per keydown event. `key` is the JavaScript `KeyboardEvent.key` string (`"ArrowLeft"`, `"a"`, `" "`, `"Enter"`, …).

Split this way, the code reads top-to-bottom: physics, then rendering, then input.

```python
def reset_fruit():
    global fruit_x, fruit_y, fruit_color
    fruit_x = nanopy.randint(FRUIT_R, W - FRUIT_R)
    fruit_y = -FRUIT_R
    fruit_color = nanopy.choice(("red", "orange", "yellow", "green", "purple"))


def update():
    global paddle_x, fruit_y, fruit_speed, score, misses, high, game_over
    if game_over:
        return

    # Paddle — holding a direction key keeps it moving.
    if left_held:
        paddle_x -= PADDLE_SPEED
    if right_held:
        paddle_x += PADDLE_SPEED
    paddle_x = max(0, min(W - PADDLE_W, paddle_x))

    # Fruit falls.
    fruit_y += fruit_speed

    # Caught it?
    if PADDLE_Y - FRUIT_R <= fruit_y <= PADDLE_Y + PADDLE_H:
        if paddle_x <= fruit_x <= paddle_x + PADDLE_W:
            score += 1
            nanopy.set_text("score", score)
            if score > high:
                high = score
                nanopy.set_text("high", score)
                nanopy.storage.set_int("catch_high", score)
            fruit_speed = min(fruit_speed + 1, 11)
            reset_fruit()
            return

    # Missed — hit the floor.
    if fruit_y > H:
        misses += 1
        nanopy.set_text("misses", misses)
        if misses >= 3:
            game_over = True
            nanopy.status("Game over — press R to play again.", "err")
            return
        reset_fruit()


def draw():
    screen.fill("dark")
    screen.line(0, PADDLE_Y + PADDLE_H + 4, W, PADDLE_Y + PADDLE_H + 4, "#2a3650")
    screen.rounded_rect(paddle_x, PADDLE_Y, PADDLE_W, PADDLE_H, 6, "blue")
    screen.rounded_rect(
        fruit_x - FRUIT_R, fruit_y - FRUIT_R,
        FRUIT_R * 2, FRUIT_R * 2,
        FRUIT_R // 2, fruit_color,
    )

    if game_over:
        screen.rect(0, H // 2 - 50, W, 100, "rgba(0, 0, 0, 0.78)")
        screen.text(
            "Game over", W // 2, H // 2 - 10,
            "white", size=28, align="center", baseline="middle", bold=True,
        )


def on_press(key):
    global left_held, right_held
    if game_over and key in ("r", "R"):
        reset_game()
        return
    if key in ("ArrowLeft", "a", "A"):
        left_held = True
        right_held = False
    elif key in ("ArrowRight", "d", "D"):
        right_held = True
        left_held = False
    elif key == " ":
        left_held = False
        right_held = False
```

This handler treats arrow keys as toggles (press left → start moving left, press right → switch direction, space → stop); it does not react to keydown/keyup pairs. The browser fires keydown only; no keyup signal reaches Python. So "holding a key" really means "the most recent direction key pressed". This simplification is intended; in practice it feels close to keyup-driven control because you press a direction once and let it ride.

## Step 5: wire it up

```python
def reset_game():
    global score, misses, fruit_speed, paddle_x, game_over
    score = 0
    misses = 0
    fruit_speed = FRUIT_SPEED_START
    paddle_x = W // 2 - PADDLE_W // 2
    game_over = False
    reset_fruit()
    nanopy.set_text("score", 0)
    nanopy.set_text("misses", 0)
    nanopy.status("Use arrow keys (or A/D) to move the paddle.", "ok")


nanopy.set_text("high", high)
reset_game()
nanopy.run(update=update, draw=draw, on_press=on_press, fps=30)
```

`nanopy.run(...)` is the one line that turns your three functions into a running game. It starts a `setInterval` at the requested fps and installs key listeners for everything in the kid-key set (arrow keys, WASD, space, Enter, R, ZXC). For turn-based games (2048, memory match), pass only `on_press`: without `update` / `draw`, no timer starts and the game advances from inside the keypress handler.

Open the page in your browser. Catch should run.

## What you got for free

Every line of the host plumbing you didn't write:

- The browser-side WASI shim that lets the wasm binary read your `main.py` from a virtual filesystem.
- The JS bridge that lets `import js` give you `js.window.localStorage.getItem(...)`.
- A `setInterval` at the right ms cadence for your fps.
- A `keydown` listener that routes through a dispatch table so each Python handler gets called.
- The audio context (used by `nanopy.beep` / `nanopy.tone`) and its gesture-gate.

You can see all of it under `web/lib/` (`nanopy-host.js` for sound, `js-bridge.js` for the bridge, plus the per-game `app.js` loader which is genuinely generic).

## Adding sound

```python
nanopy.beep(440, 80)                    # single 440Hz tone for 80ms
nanopy.beep(880, 50, kind="square")     # square wave for a chiptune feel
nanopy.tone([523, 659, 784], ms_per=90) # C–E–G arpeggio for "won the level"
```

Two practical notes:

1. **Browsers gate audio behind a user gesture.** Calling `beep` before the user has clicked or pressed a key produces silence and no error. Once they've pressed any key (which any keyboard-driven game requires anyway), audio starts working.
2. **`beep` is async.** The call returns immediately, the sound plays via the Web Audio scheduler. Don't `sleep` after it.

In Catch, a satisfying tweak is a rising tone on every catch and a low blat on every miss:

```python
# in the "caught it" branch
nanopy.beep(440 + score * 20, 60)

# in the "missed" branch
nanopy.beep(180, 120, kind="sawtooth")
```

## Score and Lives as widgets

Catch tracks `score` / `misses` / `high` as module-level integers, calls `nanopy.set_text(...)` after each change, and persists `high` by hand. For a small game that's fine. For anything bigger, nanopy ships two reactive widgets that fold the bookkeeping into property setters:

```python
from nanopy import Score, Lives

score = Score("score", storage_key="catch_high", best_id="high")
lives = Lives("misses", start=3)

# In your update loop:
score.value = score.value + 1           # → DOM updates, persists high if exceeded
score.add(1)                            # shorthand for the same thing
lives.lose()                            # → DOM updates, lives.empty turns True at 0
if lives.empty:
    game_over = True
```

Setting `.value` updates the DOM element, updates the high-score element, and persists to localStorage, all in one assignment.

## The pro variant: classes and decorators

Same game, different shape. Globals become attributes on a `Game` instance, the timer becomes a `Ticker` you own, key dispatch becomes individual decorated functions. Pick whichever you find more readable; both compile to the same wasm.

```python
from nanopy import Canvas, Ticker, on_key, Score, Lives, storage, randint, choice, status

CANVAS = Canvas("board")
W, H = CANVAS.width, CANVAS.height
PADDLE_W, PADDLE_H, PADDLE_Y = 80, 14, H - 30


class Game:
    def __init__(self):
        self.score = Score("score", storage_key="catch_high", best_id="high")
        self.lives = Lives("misses", start=3)
        self.ticker = Ticker(self.tick, 33)
        self.left = False
        self.right = False
        self.reset()
        self.ticker.start()

    def reset(self):
        self.score.reset()
        self.lives.reset()
        self.paddle_x = W // 2 - PADDLE_W // 2
        self.fruit_speed = 4
        self.over = False
        self._spawn_fruit()
        status("Use arrow keys to move.", "ok")

    def _spawn_fruit(self):
        self.fruit_x = randint(14, W - 14)
        self.fruit_y = -14
        self.fruit_color = choice(("red", "orange", "yellow", "green"))

    def tick(self, *_):
        if self.over:
            return
        if self.left:
            self.paddle_x = max(0, self.paddle_x - 12)
        if self.right:
            self.paddle_x = min(W - PADDLE_W, self.paddle_x + 12)
        self.fruit_y += self.fruit_speed
        # ... collision + scoring identical to the kid version ...
        self.render()

    def render(self):
        CANVAS.fill("dark")
        CANVAS.rounded_rect(self.paddle_x, PADDLE_Y, PADDLE_W, PADDLE_H, 6, "blue")
        CANVAS.rounded_rect(
            self.fruit_x - 14, self.fruit_y - 14, 28, 28, 7, self.fruit_color,
        )


game = Game()


@on_key("ArrowLeft", "a", "A")
def left():
    game.left, game.right = True, False


@on_key("ArrowRight", "d", "D")
def right():
    game.right, game.left = True, False


@on_key("r", "R")
def restart():
    game.reset()
```

The pro variant pays a small cost in vertical space (the class body + `self.` everywhere) and gets back: scoped state, no `global` declarations, easy multi-instance (multiplayer or "play again" without re-importing), and a `Ticker` you can pause / change interval on without touching `nanopy.run`. Every game in `web/games/<name>-pro/` follows this pattern.

## What's in nanopy: the quick reference

```python
import nanopy

# Drawing
screen = nanopy.canvas(element_id)
screen.fill(color)
screen.rect(x, y, w, h, color)
screen.stroke_rect(x, y, w, h, color, width=1)
screen.line(x1, y1, x2, y2, color, width=1)
screen.text(s, x, y, color, size=16, align="left", baseline="alphabetic", bold=False)
screen.rounded_rect(x, y, w, h, r, color)

# DOM text + status
nanopy.set_text(element_id, value)
nanopy.status(message, kind="")            # kind is "" / "ok" / "err"

# Storage
nanopy.storage.get_int(key, default=0)
nanopy.storage.set_int(key, value)

# Random
nanopy.randrange(n)                        # [0, n)
nanopy.randint(a, b)                       # [a, b] inclusive
nanopy.choice(seq)

# Collision
nanopy.overlap_rect((x1, y1, w1, h1), (x2, y2, w2, h2))
nanopy.point_in_rect(x, y, (rx, ry, rw, rh))
nanopy.dist_sq((ax, ay), (bx, by))         # integer; compare against r*r

# Sound (after first user gesture)
nanopy.beep(freq=440, ms=80, kind="sine")
nanopy.tone(notes, ms_per=120, kind="sine")

# Game loop
nanopy.run(update=None, draw=None, on_press=None, on_click=None, fps=30)
nanopy.stop()

# Pro-only
from nanopy import Canvas, Ticker, Score, Lives, on_key, on_click, storage
```

`kind` for the sound functions is `"sine"` / `"square"` / `"triangle"` / `"sawtooth"`.

`on_press(key)` and `on_click(x, y)` receive their argument as a string and as a pair of canvas-relative integers respectively. The pro decorators `@on_key("ArrowLeft", "a")` fire on any of the listed keys; `@on_click` decorates a `def click(x, y):` for canvas-relative pointer clicks.

## A couple of things to know

- **Audio needs a user gesture.** The browser silences `beep` / `tone` until the user has clicked or pressed a key on the page. For a keyboard game this is invisible: by the time anything interesting happens, they've already pressed something. But it means a "play a welcome chime on load" trick won't work; the first sound has to follow the first input.
- **`nanopy.run` starts a timer; `nanopy.stop()` stops it.** Key handlers stay installed afterwards, which is the usual behavior for most games (e.g. so R can restart). For a clean restart, calling `reset_game()` from inside `on_press` is the usual shape, as Catch does.

## What to read next

- **`web/lib/nanopy.py`:** the library itself, ~530 lines, fully readable. The implementation is short enough that reading it end-to-end is the fastest way to understand what's happening under each method.
- **`web/games/<game>-kid/main.py`** for any of the six gallery games: concrete patterns for grid games (Snake, Tetris), bounce games (Breakout), shooters (Invaders), and turn-based games (2048, memory match).
- **`web/games/<game>-pro/main.py`:** same six, class-shaped.
- **`web/games/<game>-js/main.js`:** what the JS version of the same game looks like, for side-by-side comparison.
- **[ADR 006: JS interop](adrs/006-js-interop.md)** if you want to go below `nanopy` and write to the DOM directly via `import js`.
