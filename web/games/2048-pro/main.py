"""2048 — spike of a library-based cognitive-simplicity refactor.

Delegates DOM lookup, canvas property writes, RNG, localStorage, and
key dispatch to a sibling `nanopy` module. What's left in this file
should be 2048 and only 2048.

Compare with web/snake/main.py, which inlines all the same scaffolding
the helper here absorbs. The helper is 81 code-lines paid once;
every game that adopts it drops ~50-60 lines of its own boilerplate.
"""

from nanopy import Canvas, on_key, randrange, set_text, status, storage

# ---------------------------------------------------------------------------
# Geometry + colors
# ---------------------------------------------------------------------------

N = 4  # grid is N x N
CELL = 90  # px per tile
GAP = 8  # px gap between tiles
PAD = 8  # px outer padding
W = N * CELL + (N + 1) * GAP + 2 * PAD - 2 * GAP  # 400

BG = "#1e293b"
EMPTY = "#334155"
TEXT_LIGHT = "#1a1b26"
TEXT_DARK = "#e6e6e6"
DIM = "#94a3b8"

TILE_COLORS = {
    1: "#cdd6f4",  # 2
    2: "#b4c4e8",  # 4
    3: "#f5c2a7",  # 8
    4: "#f5b78a",  # 16
    5: "#f3a06b",  # 32
    6: "#e07b3a",  # 64
    7: "#fae3a4",  # 128
    8: "#f5d575",  # 256
    9: "#f0c449",  # 512
    10: "#ebb31a",  # 1024
    11: "#f7768e",  # 2048
}

STORAGE_KEY = "nanopython:2048:high"

canvas = Canvas("board")


# ---------------------------------------------------------------------------
# Game state
# ---------------------------------------------------------------------------


class Game:
    def __init__(self):
        self.grid = [0] * (N * N)
        self.score = 0
        self.high = storage.get_int(STORAGE_KEY, 0)
        self.over = False
        self.won = False

    def reset(self):
        self.grid = [0] * (N * N)
        self.score = 0
        self.over = False
        self.won = False
        set_text("score", 0)
        self._spawn()
        self._spawn()
        self.render()
        status("Use arrow keys or WASD to slide.", "ok")

    def _spawn(self):
        empties = [i for i in range(N * N) if self.grid[i] == 0]
        if not empties:
            return
        pick = empties[randrange(len(empties))]
        self.grid[pick] = 4 if randrange(10) == 0 else 2

    def _any_move(self):
        if 0 in self.grid:
            return True
        for r in range(N):
            for c in range(N):
                v = self.grid[r * N + c]
                if c + 1 < N and self.grid[r * N + c + 1] == v:
                    return True
                if r + 1 < N and self.grid[(r + 1) * N + c] == v:
                    return True
        return False

    def _add_score(self, gained):
        self.score += gained
        set_text("score", self.score)
        if self.score > self.high:
            self.high = self.score
            set_text("high", self.score)
            storage.set_int(STORAGE_KEY, self.score)

    def slide(self, direction):
        if self.over:
            return
        new_grid, moved, gained = SLIDES[direction](self.grid)
        if not moved:
            return
        self.grid = new_grid
        if gained:
            self._add_score(gained)
        if not self.won and 2048 in self.grid:
            self.won = True
            status("2048 reached. Keep going or restart with R.", "ok")
        self._spawn()
        if not self._any_move():
            self.over = True
            status("Game over — press R to restart.", "err")
        self.render()

    # ----- rendering -------------------------------------------------------

    def render(self):
        canvas["fillStyle"] = BG
        canvas.fillRect(0, 0, W, W)
        for r in range(N):
            for c in range(N):
                self._draw_tile(r, c, self.grid[r * N + c])
        if self.won and not self.over:
            self._draw_overlay("You win!", "Press R to restart, or keep merging.")
        elif self.over:
            self._draw_overlay("Game over", "Press R to restart.")

    def _draw_tile(self, r, c, v):
        x = PAD + c * (CELL + GAP)
        y = PAD + r * (CELL + GAP)
        if v == 0:
            canvas.rounded_rect(x, y, CELL, CELL, 4, EMPTY)
            return
        canvas.rounded_rect(x, y, CELL, CELL, 4, TILE_COLORS.get(_log2(v), "#7aa2f7"))
        canvas["fillStyle"] = TEXT_LIGHT if v < 512 else TEXT_DARK
        if v < 100:
            canvas["font"] = "bold 36px system-ui"
        elif v < 1000:
            canvas["font"] = "bold 30px system-ui"
        else:
            canvas["font"] = "bold 24px system-ui"
        canvas["textAlign"] = "center"
        canvas["textBaseline"] = "middle"
        canvas.fillText(str(v), x + CELL // 2, y + CELL // 2)

    def _draw_overlay(self, title, subtitle):
        canvas["fillStyle"] = "rgba(0, 0, 0, 0.78)"
        canvas.fillRect(0, W // 2 - 60, W, 120)
        canvas["fillStyle"] = TEXT_DARK
        canvas["font"] = "bold 32px system-ui"
        canvas["textAlign"] = "center"
        canvas["textBaseline"] = "middle"
        canvas.fillText(title, W // 2, W // 2 - 10)
        canvas["font"] = "14px system-ui"
        canvas["fillStyle"] = DIM
        canvas.fillText(subtitle, W // 2, W // 2 + 22)
        canvas["textAlign"] = "left"
        canvas["textBaseline"] = "alphabetic"


# ---------------------------------------------------------------------------
# Slide engine — pure-functional. Identical to the old version since this
# never touched the bridge to begin with.
# ---------------------------------------------------------------------------


def _slide_row(row):
    tight = [v for v in row if v != 0]
    out = []
    gained = 0
    i = 0
    while i < len(tight):
        if i + 1 < len(tight) and tight[i] == tight[i + 1]:
            merged = tight[i] * 2
            out.append(merged)
            gained += merged
            i += 2
        else:
            out.append(tight[i])
            i += 1
    while len(out) < N:
        out.append(0)
    return out, gained


def _slide_left(grid):
    moved = False
    total = 0
    out = [0] * (N * N)
    for r in range(N):
        row = [grid[r * N + c] for c in range(N)]
        new_row, gained = _slide_row(row)
        total += gained
        for c in range(N):
            out[r * N + c] = new_row[c]
        if row != new_row:
            moved = True
    return out, moved, total


def _reverse(grid):
    out = [0] * (N * N)
    for r in range(N):
        for c in range(N):
            out[r * N + c] = grid[r * N + (N - 1 - c)]
    return out


def _transpose(grid):
    out = [0] * (N * N)
    for r in range(N):
        for c in range(N):
            out[c * N + r] = grid[r * N + c]
    return out


def _slide_right(grid):
    g, m, s = _slide_left(_reverse(grid))
    return _reverse(g), m, s


def _slide_up(grid):
    g, m, s = _slide_left(_transpose(grid))
    return _transpose(g), m, s


def _slide_down(grid):
    g, m, s = _slide_right(_transpose(grid))
    return _transpose(g), m, s


SLIDES = {
    "left": _slide_left,
    "right": _slide_right,
    "up": _slide_up,
    "down": _slide_down,
}


# ---------------------------------------------------------------------------
# Tiny helpers — drawing rounded rects (no math.log2 on nano)
# ---------------------------------------------------------------------------


def _log2(v):
    k = 0
    n = v
    while n > 1:
        n //= 2
        k += 1
    return k


# ---------------------------------------------------------------------------
# Wire up
# ---------------------------------------------------------------------------

game = Game()
set_text("high", game.high)


@on_key("ArrowLeft", "a", "A")
def left():
    game.slide("left")


@on_key("ArrowRight", "d", "D")
def right():
    game.slide("right")


@on_key("ArrowUp", "w", "W")
def up():
    game.slide("up")


@on_key("ArrowDown", "s", "S")
def down():
    game.slide("down")


@on_key("r", "R")
def restart():
    game.reset()


game.reset()
