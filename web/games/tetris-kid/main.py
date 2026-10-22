# Tetris — kid variant of web/tetris-lite/main.py (pro). Source comparison only.

import nanopy

screen = nanopy.canvas("board")
preview = nanopy.canvas("next")

COLS, ROWS = 10, 20
CELL = 30

SHAPES = {
    1: [
        [(0, 1), (1, 1), (2, 1), (3, 1)],
        [(2, 0), (2, 1), (2, 2), (2, 3)],
        [(0, 2), (1, 2), (2, 2), (3, 2)],
        [(1, 0), (1, 1), (1, 2), (1, 3)],
    ],
    2: [
        [(1, 0), (2, 0), (1, 1), (2, 1)],
        [(1, 0), (2, 0), (1, 1), (2, 1)],
        [(1, 0), (2, 0), (1, 1), (2, 1)],
        [(1, 0), (2, 0), (1, 1), (2, 1)],
    ],
    3: [
        [(1, 0), (0, 1), (1, 1), (2, 1)],
        [(1, 0), (1, 1), (2, 1), (1, 2)],
        [(0, 1), (1, 1), (2, 1), (1, 2)],
        [(1, 0), (0, 1), (1, 1), (1, 2)],
    ],
    4: [
        [(1, 0), (2, 0), (0, 1), (1, 1)],
        [(1, 0), (1, 1), (2, 1), (2, 2)],
        [(1, 1), (2, 1), (0, 2), (1, 2)],
        [(0, 0), (0, 1), (1, 1), (1, 2)],
    ],
    5: [
        [(0, 0), (1, 0), (1, 1), (2, 1)],
        [(2, 0), (1, 1), (2, 1), (1, 2)],
        [(0, 1), (1, 1), (1, 2), (2, 2)],
        [(1, 0), (0, 1), (1, 1), (0, 2)],
    ],
    6: [
        [(0, 0), (0, 1), (1, 1), (2, 1)],
        [(1, 0), (2, 0), (1, 1), (1, 2)],
        [(0, 1), (1, 1), (2, 1), (2, 2)],
        [(1, 0), (1, 1), (0, 2), (1, 2)],
    ],
    7: [
        [(2, 0), (0, 1), (1, 1), (2, 1)],
        [(1, 0), (1, 1), (1, 2), (2, 2)],
        [(0, 1), (1, 1), (2, 1), (0, 2)],
        [(0, 0), (1, 0), (1, 1), (1, 2)],
    ],
}

COLORS = {
    1: "blue",
    2: "yellow",
    3: "purple",
    4: "green",
    5: "pink",
    6: "#3b82f6",
    7: "orange",
}

LINE_SCORES = [0, 40, 100, 300, 1200]

board = [0] * (COLS * ROWS)
piece = 0
rot = 0
px = 0
py = 0
next_piece = 0
score = 0
lines = 0
level = 1
paused = False
over = False
high = nanopy.storage.get_int("tetris_kid_high", 0)
interval = 800
ticker_handle = [None]  # box for mutating handle


def cells_for(p, r, ox, oy):
    return [(ox + c, oy + r2) for c, r2 in SHAPES[p][r]]


def collides(p, r, ox, oy):
    for c, rr in cells_for(p, r, ox, oy):
        if c < 0 or c >= COLS or rr >= ROWS:
            return True
        if rr >= 0 and board[rr * COLS + c] != 0:
            return True
    return False


def new_piece():
    return nanopy.randrange(7) + 1


def spawn(p):
    global piece, rot, px, py
    piece = p
    rot = 0
    px = 3
    py = 0
    if collides(p, 0, 3, 0):
        game_over()


def clear_lines():
    global board, lines, score, level, interval, high
    cleared = 0
    kept = []
    for r in range(ROWS - 1, -1, -1):
        row = board[r * COLS : (r + 1) * COLS]
        if 0 in row:
            kept.append(row)
        else:
            cleared += 1
    new_board = [0] * (cleared * COLS)
    for row in reversed(kept):
        new_board.extend(row)
    board = new_board
    if cleared:
        gained = LINE_SCORES[cleared] * level
        score += gained
        lines += cleared
        nanopy.set_text("score", score)
        nanopy.set_text("lines", lines)
        if score > high:
            high = score
            nanopy.set_text("high", high)
            nanopy.storage.set_int("tetris_kid_high", high)
        new_level = 1 + lines // 10
        if new_level != level:
            level = new_level
            nanopy.set_text("level", level)
            interval = max(80, 800 - (new_level - 1) * 70)
            _stop_ticker()
            _start_ticker()


def lock_piece():
    global next_piece
    for c, r in cells_for(piece, rot, px, py):
        if 0 <= r < ROWS and 0 <= c < COLS:
            board[r * COLS + c] = piece
    clear_lines()
    nxt = next_piece
    next_piece = new_piece()
    draw_next()
    spawn(nxt)


def move(dx):
    global px
    if over or paused or piece == 0:
        return
    nx = px + dx
    if not collides(piece, rot, nx, py):
        px = nx
        draw()


def rotate():
    global rot, px
    if over or paused or piece == 0:
        return
    new_rot = (rot + 1) % 4
    for kick in (0, -1, 1, -2, 2):
        if not collides(piece, new_rot, px + kick, py):
            rot = new_rot
            px += kick
            draw()
            return


def soft_drop():
    global py, score
    if over or paused or piece == 0:
        return
    ny = py + 1
    if collides(piece, rot, px, ny):
        lock_piece()
    else:
        py = ny
        score += 1
        nanopy.set_text("score", score)
    draw()


def hard_drop():
    global py, score
    if over or paused or piece == 0:
        return
    ny = py
    while not collides(piece, rot, px, ny + 1):
        ny += 1
        score += 2
    py = ny
    nanopy.set_text("score", score)
    lock_piece()
    draw()


def gravity():
    global py
    if over or paused:
        return
    ny = py + 1
    if collides(piece, rot, px, ny):
        lock_piece()
    else:
        py = ny
    draw()


def game_over():
    global over
    over = True
    _stop_ticker()
    draw()
    nanopy.status("Game over. Press R to restart.", "err")


# Manual timer wrap (couldn't use Ticker class without falling back to OO).
import js


def _stop_ticker():
    if ticker_handle[0] is not None:
        js.window.clearInterval(ticker_handle[0])
        ticker_handle[0] = None


def _start_ticker():
    ticker_handle[0] = js.window.setInterval(gravity, interval).to_int()


def draw_next():
    preview.fill("dark")
    if next_piece == 0:
        return
    side = 26
    offset = (preview.width - 4 * side) // 2
    for c, r in SHAPES[next_piece][0]:
        preview.rect(
            offset + c * side + 1,
            offset + r * side + 1,
            side - 2,
            side - 2,
            COLORS[next_piece],
        )


def draw():
    screen.fill("dark")
    for i in range(1, COLS):
        screen.line(i * CELL, 0, i * CELL, ROWS * CELL, "#2a3650")
    for j in range(1, ROWS):
        screen.line(0, j * CELL, COLS * CELL, j * CELL, "#2a3650")
    if not over and piece != 0:
        ny = py
        while not collides(piece, rot, px, ny + 1):
            ny += 1
        if ny != py:
            for c, r in cells_for(piece, rot, px, ny):
                if r >= 0:
                    screen.rect(
                        c * CELL + 1, r * CELL + 1, CELL - 2, CELL - 2, "#3b4659"
                    )
    for r in range(ROWS):
        for c in range(COLS):
            v = board[r * COLS + c]
            if v:
                screen.rect(c * CELL + 1, r * CELL + 1, CELL - 2, CELL - 2, COLORS[v])
    if piece != 0:
        for c, r in cells_for(piece, rot, px, py):
            if r >= 0:
                screen.rect(
                    c * CELL + 1, r * CELL + 1, CELL - 2, CELL - 2, COLORS[piece]
                )
    if over:
        _overlay("Game over", "Press R to restart.")
    elif paused:
        _overlay("Paused", "Press P to resume.")


def _overlay(title, subtitle):
    screen.rect(0, ROWS * CELL // 2 - 60, COLS * CELL, 120, "rgba(0, 0, 0, 0.78)")
    screen.text(
        title,
        COLS * CELL // 2,
        ROWS * CELL // 2 - 10,
        "white",
        size=28,
        align="center",
        baseline="middle",
        bold=True,
    )
    screen.text(
        subtitle,
        COLS * CELL // 2,
        ROWS * CELL // 2 + 22,
        "gray",
        size=14,
        align="center",
        baseline="middle",
    )


def reset():
    global board, score, lines, level, paused, over, interval, next_piece
    _stop_ticker()
    board = [0] * (COLS * ROWS)
    score = 0
    lines = 0
    level = 1
    paused = False
    over = False
    interval = 800
    nanopy.set_text("score", 0)
    nanopy.set_text("lines", 0)
    nanopy.set_text("level", 1)
    next_piece = new_piece()
    draw_next()
    spawn(new_piece())
    draw()
    if not over:
        _start_ticker()
        nanopy.status("Stack 'em up. Arrows to move; up rotates; space drops.", "ok")


def on_press(key):
    global paused
    if over:
        if key == "r" or key == "R":
            reset()
        return
    if key == "ArrowLeft" or key == "a" or key == "A":
        move(-1)
    elif key == "ArrowRight" or key == "d" or key == "D":
        move(1)
    elif key == "ArrowUp" or key == "w" or key == "W" or key == "z" or key == "Z":
        rotate()
    elif key == "ArrowDown" or key == "s" or key == "S":
        soft_drop()
    elif key == " ":
        hard_drop()
    elif key == "p" or key == "P":
        paused = not paused
        nanopy.status(
            "Paused. Press P to resume." if paused else "Stack 'em up.",
            "" if paused else "ok",
        )
        draw()
    elif key == "r" or key == "R":
        reset()


nanopy.set_text("high", high)
reset()
nanopy.run(on_press=on_press)
