# 2048 — kid variant of web/2048-lite/main.py (pro). Source comparison only.
# Pure procedural: module state, functions, on_press dispatch by key.

import nanopy

screen = nanopy.canvas("board")

N = 4
CELL = 90
GAP = 8
PAD = 8
W = N * CELL + (N + 1) * GAP + 2 * PAD - 2 * GAP

BG = "#1e293b"
EMPTY = "#334155"
TEXT_LIGHT = "#1a1b26"
TEXT_DARK = "#e6e6e6"
DIM = "#94a3b8"

TILE_COLORS = {
    1: "#cdd6f4",
    2: "#b4c4e8",
    3: "#f5c2a7",
    4: "#f5b78a",
    5: "#f3a06b",
    6: "#e07b3a",
    7: "#fae3a4",
    8: "#f5d575",
    9: "#f0c449",
    10: "#ebb31a",
    11: "#f7768e",
}

grid = [0] * (N * N)
score = 0
high = nanopy.storage.get_int("g2048_kid_high", 0)
over = False
won = False


def slide_row(row):
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


def slide_left(g):
    moved = False
    total = 0
    out = [0] * (N * N)
    for r in range(N):
        row = [g[r * N + c] for c in range(N)]
        new_row, gained = slide_row(row)
        total += gained
        for c in range(N):
            out[r * N + c] = new_row[c]
        if row != new_row:
            moved = True
    return out, moved, total


def reverse_rows(g):
    out = [0] * (N * N)
    for r in range(N):
        for c in range(N):
            out[r * N + c] = g[r * N + (N - 1 - c)]
    return out


def transpose(g):
    out = [0] * (N * N)
    for r in range(N):
        for c in range(N):
            out[c * N + r] = g[r * N + c]
    return out


def slide_right(g):
    rg, m, s = slide_left(reverse_rows(g))
    return reverse_rows(rg), m, s


def slide_up(g):
    rg, m, s = slide_left(transpose(g))
    return transpose(rg), m, s


def slide_down(g):
    rg, m, s = slide_right(transpose(g))
    return transpose(rg), m, s


def spawn():
    empties = [i for i in range(N * N) if grid[i] == 0]
    if not empties:
        return
    pick = empties[nanopy.randrange(len(empties))]
    grid[pick] = 4 if nanopy.randrange(10) == 0 else 2


def any_move_possible():
    if 0 in grid:
        return True
    for r in range(N):
        for c in range(N):
            v = grid[r * N + c]
            if c + 1 < N and grid[r * N + c + 1] == v:
                return True
            if r + 1 < N and grid[(r + 1) * N + c] == v:
                return True
    return False


def log2(v):
    k = 0
    n = v
    while n > 1:
        n //= 2
        k += 1
    return k


def draw_tile(r, c, v):
    x = PAD + c * (CELL + GAP)
    y = PAD + r * (CELL + GAP)
    if v == 0:
        screen.rounded_rect(x, y, CELL, CELL, 4, EMPTY)
        return
    screen.rounded_rect(x, y, CELL, CELL, 4, TILE_COLORS.get(log2(v), "#7aa2f7"))
    screen["fillStyle"] = TEXT_LIGHT if v < 512 else TEXT_DARK
    if v < 100:
        screen["font"] = "bold 36px system-ui"
    elif v < 1000:
        screen["font"] = "bold 30px system-ui"
    else:
        screen["font"] = "bold 24px system-ui"
    screen["textAlign"] = "center"
    screen["textBaseline"] = "middle"
    screen.fillText(str(v), x + CELL // 2, y + CELL // 2)


def draw():
    screen.fill(BG)
    for r in range(N):
        for c in range(N):
            draw_tile(r, c, grid[r * N + c])
    if won and not over:
        screen.rect(0, W // 2 - 60, W, 120, "rgba(0, 0, 0, 0.78)")
        screen.text(
            "You win!",
            W // 2,
            W // 2 - 10,
            TEXT_DARK,
            size=32,
            align="center",
            baseline="middle",
            bold=True,
        )
        screen.text(
            "Press R to restart, or keep merging.",
            W // 2,
            W // 2 + 22,
            DIM,
            size=14,
            align="center",
            baseline="middle",
        )
    elif over:
        screen.rect(0, W // 2 - 60, W, 120, "rgba(0, 0, 0, 0.78)")
        screen.text(
            "Game over",
            W // 2,
            W // 2 - 10,
            TEXT_DARK,
            size=32,
            align="center",
            baseline="middle",
            bold=True,
        )
        screen.text(
            "Press R to restart.",
            W // 2,
            W // 2 + 22,
            DIM,
            size=14,
            align="center",
            baseline="middle",
        )


def add_score(gained):
    global score, high
    score += gained
    nanopy.set_text("score", score)
    if score > high:
        high = score
        nanopy.set_text("high", score)
        nanopy.storage.set_int("g2048_kid_high", score)


def reset():
    global grid, score, over, won
    grid = [0] * (N * N)
    score = 0
    over = False
    won = False
    nanopy.set_text("score", 0)
    spawn()
    spawn()
    draw()
    nanopy.status("Use arrow keys or WASD to slide.", "ok")


SLIDES = {
    "ArrowLeft": slide_left,
    "a": slide_left,
    "A": slide_left,
    "ArrowRight": slide_right,
    "d": slide_right,
    "D": slide_right,
    "ArrowUp": slide_up,
    "w": slide_up,
    "W": slide_up,
    "ArrowDown": slide_down,
    "s": slide_down,
    "S": slide_down,
}


def on_press(key):
    global grid, over, won
    if over:
        if key == "r" or key == "R":
            reset()
        return
    if key == "r" or key == "R":
        reset()
        return
    slide_fn = SLIDES.get(key)
    if slide_fn is None:
        return
    new_grid, moved, gained = slide_fn(grid)
    if not moved:
        return
    grid = new_grid
    if gained:
        add_score(gained)
    if not won and 2048 in grid:
        won = True
        nanopy.status("2048 reached. Keep going or restart with R.", "ok")
    spawn()
    if not any_move_possible():
        over = True
        nanopy.status("Game over — press R to restart.", "err")
    draw()


nanopy.set_text("high", high)
reset()
nanopy.run(on_press=on_press)
