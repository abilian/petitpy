"""Tetris — pro-style: a Game class + @on_key decorators + Ticker.

The whole runtime (gravity timer, key dispatch, DOM, canvas property
writes, localStorage, RNG) is in `nanopy`. This file is about Tetris.

Compare with snake-lite/main.py (kid-style: module-level functions,
nanopy.run loop) — same library, two writing styles.
"""

from nanopy import Canvas, Ticker, on_key, randrange, set_text, status, storage

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

COLS, ROWS = 10, 20
CELL = 30  # px per cell → 300 × 600 canvas

# Each tetromino's four rotations, each rotation as a 4-tuple of (col, row)
# offsets from the piece origin (top-left of a 4×4 bounding box).
SHAPES = {
    1: [  # I
        [(0, 1), (1, 1), (2, 1), (3, 1)],
        [(2, 0), (2, 1), (2, 2), (2, 3)],
        [(0, 2), (1, 2), (2, 2), (3, 2)],
        [(1, 0), (1, 1), (1, 2), (1, 3)],
    ],
    2: [  # O
        [(1, 0), (2, 0), (1, 1), (2, 1)],
        [(1, 0), (2, 0), (1, 1), (2, 1)],
        [(1, 0), (2, 0), (1, 1), (2, 1)],
        [(1, 0), (2, 0), (1, 1), (2, 1)],
    ],
    3: [  # T
        [(1, 0), (0, 1), (1, 1), (2, 1)],
        [(1, 0), (1, 1), (2, 1), (1, 2)],
        [(0, 1), (1, 1), (2, 1), (1, 2)],
        [(1, 0), (0, 1), (1, 1), (1, 2)],
    ],
    4: [  # S
        [(1, 0), (2, 0), (0, 1), (1, 1)],
        [(1, 0), (1, 1), (2, 1), (2, 2)],
        [(1, 1), (2, 1), (0, 2), (1, 2)],
        [(0, 0), (0, 1), (1, 1), (1, 2)],
    ],
    5: [  # Z
        [(0, 0), (1, 0), (1, 1), (2, 1)],
        [(2, 0), (1, 1), (2, 1), (1, 2)],
        [(0, 1), (1, 1), (1, 2), (2, 2)],
        [(1, 0), (0, 1), (1, 1), (0, 2)],
    ],
    6: [  # J
        [(0, 0), (0, 1), (1, 1), (2, 1)],
        [(1, 0), (2, 0), (1, 1), (1, 2)],
        [(0, 1), (1, 1), (2, 1), (2, 2)],
        [(1, 0), (1, 1), (0, 2), (1, 2)],
    ],
    7: [  # L
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

LINE_SCORES = [0, 40, 100, 300, 1200]  # NES-style scoring

STORAGE_KEY = "nanopython:tetris_lite:high"


# ---------------------------------------------------------------------------
# Game
# ---------------------------------------------------------------------------

canvas = Canvas("board")
preview = Canvas("next")


class Game:
    def __init__(self):
        self.high = storage.get_int(STORAGE_KEY, 0)
        set_text("high", self.high)
        self.ticker = Ticker(self._gravity, 800)
        self.reset()

    # ---- lifecycle -------------------------------------------------------

    def reset(self):
        self.board = [0] * (COLS * ROWS)
        self.score = 0
        self.lines = 0
        self.level = 1
        self.paused = False
        self.over = False
        self.next_piece = self._new_piece()
        set_text("score", 0)
        set_text("lines", 0)
        set_text("level", 1)
        self._spawn(self._new_piece())
        self.ticker.set_interval(800)
        self.ticker.start()
        self._draw_preview()
        self.render()
        status("Stack 'em up. Arrows to move; up rotates; space drops.", "ok")

    def game_over(self):
        self.over = True
        self.ticker.stop()
        self.render()
        status("Game over — press R to restart.", "err")

    # ---- piece + collision ----------------------------------------------

    def _new_piece(self):
        return randrange(7) + 1

    def _cells(self, piece, rot, ox, oy):
        return [(ox + c, oy + r) for c, r in SHAPES[piece][rot]]

    def _collides(self, piece, rot, ox, oy):
        for c, r in self._cells(piece, rot, ox, oy):
            if c < 0 or c >= COLS or r >= ROWS:
                return True
            if r >= 0 and self.board[r * COLS + c] != 0:
                return True
        return False

    def _spawn(self, piece):
        self.piece = piece
        self.rot = 0
        self.px = 3
        self.py = 0
        if self._collides(piece, 0, 3, 0):
            self.game_over()

    # ---- movement --------------------------------------------------------

    def move(self, dx):
        if self.over or self.paused:
            return
        nx = self.px + dx
        if not self._collides(self.piece, self.rot, nx, self.py):
            self.px = nx
            self.render()

    def rotate(self):
        if self.over or self.paused:
            return
        new_rot = (self.rot + 1) % 4
        for kick in (0, -1, 1, -2, 2):
            if not self._collides(self.piece, new_rot, self.px + kick, self.py):
                self.rot = new_rot
                self.px += kick
                self.render()
                return

    def soft_drop(self):
        if self.over or self.paused:
            return
        ny = self.py + 1
        if self._collides(self.piece, self.rot, self.px, ny):
            self._lock()
        else:
            self.py = ny
            self.score += 1
            set_text("score", self.score)
        self.render()

    def hard_drop(self):
        if self.over or self.paused:
            return
        ny = self.py
        while not self._collides(self.piece, self.rot, self.px, ny + 1):
            ny += 1
            self.score += 2
        self.py = ny
        set_text("score", self.score)
        self._lock()
        self.render()

    def _gravity(self, *_):
        if self.over or self.paused:
            return
        ny = self.py + 1
        if self._collides(self.piece, self.rot, self.px, ny):
            self._lock()
        else:
            self.py = ny
        self.render()

    def _lock(self):
        for c, r in self._cells(self.piece, self.rot, self.px, self.py):
            if 0 <= r < ROWS and 0 <= c < COLS:
                self.board[r * COLS + c] = self.piece
        self._clear_lines()
        nxt = self.next_piece
        self.next_piece = self._new_piece()
        self._draw_preview()
        self._spawn(nxt)

    def _clear_lines(self):
        cleared = 0
        kept = []
        for r in range(ROWS - 1, -1, -1):
            row = self.board[r * COLS : (r + 1) * COLS]
            if 0 in row:
                kept.append(row)
            else:
                cleared += 1
        new_board = [0] * (cleared * COLS)
        for row in reversed(kept):
            new_board.extend(row)
        self.board = new_board

        if cleared:
            gained = LINE_SCORES[cleared] * self.level
            self.score += gained
            self.lines += cleared
            set_text("score", self.score)
            set_text("lines", self.lines)
            if self.score > self.high:
                self.high = self.score
                set_text("high", self.high)
                storage.set_int(STORAGE_KEY, self.high)
            new_level = 1 + self.lines // 10
            if new_level != self.level:
                self.level = new_level
                set_text("level", new_level)
                self.ticker.set_interval(max(80, 800 - (new_level - 1) * 70))

    # ---- render ----------------------------------------------------------

    def render(self):
        canvas.fill("dark")
        # grid lines
        for i in range(1, COLS):
            canvas.line(i * CELL, 0, i * CELL, ROWS * CELL, "#2a3650")
        for j in range(1, ROWS):
            canvas.line(0, j * CELL, COLS * CELL, j * CELL, "#2a3650")
        # ghost piece (where it would land on a hard drop)
        if not self.over:
            ny = self.py
            while not self._collides(self.piece, self.rot, self.px, ny + 1):
                ny += 1
            if ny != self.py:
                for c, r in self._cells(self.piece, self.rot, self.px, ny):
                    if r >= 0:
                        canvas.rect(
                            c * CELL + 1, r * CELL + 1, CELL - 2, CELL - 2, "#3b4659"
                        )
        # locked cells
        for r in range(ROWS):
            for c in range(COLS):
                v = self.board[r * COLS + c]
                if v:
                    canvas.rect(
                        c * CELL + 1, r * CELL + 1, CELL - 2, CELL - 2, COLORS[v]
                    )
        # active piece
        for c, r in self._cells(self.piece, self.rot, self.px, self.py):
            if r >= 0:
                canvas.rect(
                    c * CELL + 1, r * CELL + 1, CELL - 2, CELL - 2, COLORS[self.piece]
                )
        # overlays
        if self.over:
            self._overlay("Game over", "Press R to restart.")
        elif self.paused:
            self._overlay("Paused", "Press P to resume.")

    def _overlay(self, title, subtitle):
        canvas.rect(0, ROWS * CELL // 2 - 60, COLS * CELL, 120, "rgba(0, 0, 0, 0.78)")
        canvas.text(
            title,
            COLS * CELL // 2,
            ROWS * CELL // 2 - 10,
            "white",
            size=28,
            align="center",
            baseline="middle",
            bold=True,
        )
        canvas.text(
            subtitle,
            COLS * CELL // 2,
            ROWS * CELL // 2 + 22,
            "gray",
            size=14,
            align="center",
            baseline="middle",
        )

    def _draw_preview(self):
        preview.fill("dark")
        p = self.next_piece
        if p == 0:
            return
        side = 26
        offset = (preview.width - 4 * side) // 2
        for c, r in SHAPES[p][0]:
            preview.rect(
                offset + c * side + 1,
                offset + r * side + 1,
                side - 2,
                side - 2,
                COLORS[p],
            )


game = Game()


# ---------------------------------------------------------------------------
# Input — one function per binding. The decorator hides everything else.
# ---------------------------------------------------------------------------


@on_key("ArrowLeft", "a", "A")
def left():
    game.move(-1)


@on_key("ArrowRight", "d", "D")
def right():
    game.move(1)


@on_key("ArrowUp", "w", "W", "z", "Z")
def rotate():
    game.rotate()


@on_key("ArrowDown", "s", "S")
def soft():
    game.soft_drop()


@on_key(" ")
def hard():
    game.hard_drop()


@on_key("p", "P")
def pause():
    if game.over:
        return
    game.paused = not game.paused
    status(
        "Paused — press P to resume." if game.paused else "Stack 'em up.",
        "" if game.paused else "ok",
    )
    game.render()


@on_key("r", "R")
def restart():
    game.reset()
