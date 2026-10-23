# Writing games with nanopy

A small browser game in petitpy looks the way it would in Pygame: a `screen` to draw on, an `update` to move things, a `draw` to repaint, an `on_press` for keys. A small Python library called `nanopy` and a JS loader handle the wasm, the canvas, the keyboard, audio and `localStorage`, so your `main.py` calls `screen.rect(...)`, `score.add(1)` and `nanopy.run(...)`.

This tutorial builds **Catch** (a paddle catching falling fruit), then shows the same game written with classes and decorators. The gallery under `web/games/` (Snake, Breakout, 2048, Tetris, Space Invaders, Memory Match, most in kid, pro and JS variants) uses the same library and is a good reference afterwards.

## Setup

Work in a checkout of the repository. `make web` builds `web/petitpy.wasm`. Copy an existing game directory, such as `web/games/catch-kid/`, to `web/games/my-game/`. It holds four files:

```
my-game/
├── index.html      ← page with the canvas and score widgets
├── app.js          ← generic loader: fetches the wasm, mounts main.py, forwards key presses
├── nanopy.py       ← symlink to ../../lib/nanopy.py
└── main.py         ← your game
```

`app.js` stays as it is. You adapt `index.html` and write the game in `main.py`. Serve the pages with `python3 -m http.server -d web 8000` and open `http://localhost:8000/games/my-game/`. Opening `index.html` as a `file://` URL does not work, because browsers refuse to fetch `.wasm` from a file URL.

## Step 1: the empty page

The page needs a `<canvas id="board">`, three text spans (score, misses, high) and a `<p id="status">` for messages.

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

`main.py` refers to the elements by ID: `board`, `score`, `misses`, `high` and `status`. If you rename one in the HTML, rename it in Python too.

## Step 2: the canvas, with one line

```python
import nanopy
screen = nanopy.canvas("board")
W = screen.width
H = screen.height
```

`screen` wraps the canvas's 2D context:

```python
screen.fill("dark")                              # paint the whole thing
screen.rect(x, y, w, h, "red")                   # filled rectangle
screen.stroke_rect(x, y, w, h, "white", width=2) # outlined rectangle
screen.line(x1, y1, x2, y2, "blue")
screen.text("Hello", 200, 100, "white", size=24, align="center", bold=True)
screen.rounded_rect(x, y, w, h, 6, "green")     # corner radius 6
```

A color is a name (`"red"`, `"blue"`, `"dark"`, `"pink"`, …), a hex string (`"#ff5252"`), any CSS color (`"rgba(0, 0, 0, 0.78)"`), or an `(r, g, b)` tuple.

## Step 3: game state

The game keeps its state in module-level globals.

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

`nanopy.storage` wraps `localStorage`. `get_int(key, default)` returns the saved value, or `default` on first run or when storage is unavailable; `set_int(key, value)` saves it.

## Step 4: update, draw, on_press

nanopy calls three functions for you:

- **`update()`** runs every tick: it moves things, checks collisions and updates the score.
- **`draw()`** runs after each `update` and repaints the canvas.
- **`on_press(key)`** runs on each key press. `key` is the JavaScript `KeyboardEvent.key` string (`"ArrowLeft"`, `"a"`, `" "`, `"Enter"`, …).

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

Only key presses reach Python, not key releases, so this handler treats the direction keys as toggles: left starts moving left, right switches direction, space stops.

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

`nanopy.run(...)` starts a timer at the requested fps and routes the arrow keys, WASD, space, Enter, Escape, P, R, Z, X and C to `on_press`. For a turn-based game (2048, memory match), pass only `on_press`: no timer starts, and the game advances from inside the handler.

Reload the page in your browser. Catch should run.

## Adding sound

```python
nanopy.beep(440, 80)                    # single 440Hz tone for 80ms
nanopy.beep(880, 50, kind="square")     # square wave for a chiptune feel
nanopy.tone([523, 659, 784], ms_per=90) # C–E–G arpeggio for "won the level"
```

Browsers keep audio silent until the user has clicked or pressed a key, so a sound on page load plays nothing. `beep` returns at once and the sound plays in the background.

In Catch, try a rising tone on every catch and a low buzz on every miss:

```python
# in the "caught it" branch
nanopy.beep(440 + score * 20, 60)

# in the "missed" branch
nanopy.beep(180, 120, kind="sawtooth")
```

## Score and Lives as widgets

Catch updates the score elements and saves the high score by hand. The `Score` and `Lives` widgets do that bookkeeping for you:

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

Setting `.value` updates the page and, when the score beats the best, the high-score element and `localStorage`.

## The pro variant: classes and decorators

The same game with its state on a `Game` instance, a `Ticker` that it owns, and one decorated function per key. Use whichever style you find easier to read.

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

This style needs no `global` declarations, and the `Ticker` can be stopped, restarted or given a new interval (`set_interval(ms)`). The `web/games/<name>-pro/` games follow it.

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

`on_click(x, y)` receives canvas-relative integer coordinates; the loader in `web/games/memory-kid/app.js` shows how to forward clicks. `@on_key("ArrowLeft", "a")` fires on any of the listed keys, and `@on_click` decorates a `def click(x, y):`.

`nanopy.stop()` stops the timer but leaves the key handlers installed, so R can still restart the game.

## What to read next

- **`web/lib/nanopy.py`:** the library itself, short enough to read end to end.
- **`web/games/<game>-kid/main.py`:** grid games (Snake, Tetris), a bounce game (Breakout), a shooter (Invaders) and turn-based games (2048, memory match).
- **`web/games/<game>-pro/main.py`:** the same games with classes, and `<game>-js/` the same games in JavaScript.
- **[ADR 006: JS interop](adrs/006-js-interop.md)** to go below `nanopy` and use the DOM directly through `import js`.
