# Breakout — pro variant of web/breakout-lite/main.py (kid). Source comparison only.

from nanopy import Canvas, Ticker, on_key, set_text, status, storage

canvas = Canvas("board")
W = canvas.width
H = canvas.height

PADDLE_W = 80
PADDLE_H = 12
PADDLE_Y = H - 36
PADDLE_SPEED = 9
BALL_R = 6
BRICK_TOP = 50
BRICK_ROWS = 5
BRICK_COLS = 10
BRICK_W = W // BRICK_COLS
BRICK_H = 18
ROW_COLORS = ("red", "orange", "yellow", "green", "blue")


class Game:
    def __init__(self):
        self.high = storage.get_int("breakout_pro_high", 0)
        set_text("high", self.high)
        self.ticker = Ticker(self._tick, 22)
        self.left_held = False
        self.right_held = False
        self.reset()
        self.ticker.start()

    def reset(self):
        self.bricks = []
        for r in range(BRICK_ROWS):
            for c in range(BRICK_COLS):
                self.bricks.append(
                    {"col": c, "row": r, "alive": True, "color": ROW_COLORS[r]}
                )
        self.paddle_x = W // 2 - PADDLE_W // 2
        self.score = 0
        self.lives = 3
        self.over = False
        self.won = False
        self._park_ball()
        set_text("score", 0)
        set_text("lives", 3)
        status("Space to launch. Arrows (or A/D) to move.", "ok")

    def _park_ball(self):
        self.ball_x = self.paddle_x + PADDLE_W // 2
        self.ball_y = PADDLE_Y - BALL_R - 1
        self.ball_dx = 3
        self.ball_dy = -4
        self.launched = False

    def launch(self):
        self.launched = True

    def _brick_at(self, col, row):
        if col < 0 or col >= BRICK_COLS or row < 0 or row >= BRICK_ROWS:
            return None
        b = self.bricks[row * BRICK_COLS + col]
        return b if b["alive"] else None

    def _bounce_off_paddle(self):
        offset = self.ball_x - (self.paddle_x + PADDLE_W // 2)
        self.ball_dx = max(-5, min(5, offset // 8))
        self.ball_dy = -abs(self.ball_dy)
        if self.ball_dy > -3:
            self.ball_dy = -3

    def _handle_brick_hits(self):
        if self.ball_y - BALL_R > BRICK_TOP + BRICK_ROWS * BRICK_H:
            return
        if self.ball_y + BALL_R < BRICK_TOP:
            return
        c = self.ball_x // BRICK_W
        r = (self.ball_y - BRICK_TOP) // BRICK_H
        b = self._brick_at(c, r)
        if b is None:
            return
        b["alive"] = False
        self.score += 10
        set_text("score", self.score)
        prev_c = (self.ball_x - self.ball_dx) // BRICK_W
        prev_r = (self.ball_y - self.ball_dy - BRICK_TOP) // BRICK_H
        if prev_r != r:
            self.ball_dy = -self.ball_dy
        elif prev_c != c:
            self.ball_dx = -self.ball_dx
        else:
            self.ball_dy = -self.ball_dy
            self.ball_dx = -self.ball_dx

    def _tick(self, *_):
        if self.over or self.won:
            return
        if self.left_held:
            self.paddle_x -= PADDLE_SPEED
        if self.right_held:
            self.paddle_x += PADDLE_SPEED
        if self.paddle_x < 0:
            self.paddle_x = 0
        if self.paddle_x > W - PADDLE_W:
            self.paddle_x = W - PADDLE_W

        if not self.launched:
            self.ball_x = self.paddle_x + PADDLE_W // 2
            self.render()
            return

        self.ball_x += self.ball_dx
        self.ball_y += self.ball_dy

        if self.ball_x < BALL_R:
            self.ball_x = BALL_R
            self.ball_dx = -self.ball_dx
        elif self.ball_x > W - BALL_R:
            self.ball_x = W - BALL_R
            self.ball_dx = -self.ball_dx
        if self.ball_y < BALL_R:
            self.ball_y = BALL_R
            self.ball_dy = -self.ball_dy

        if (
            self.ball_y + BALL_R >= PADDLE_Y
            and self.ball_y - BALL_R <= PADDLE_Y + PADDLE_H
            and self.paddle_x <= self.ball_x <= self.paddle_x + PADDLE_W
            and self.ball_dy > 0
        ):
            self._bounce_off_paddle()

        self._handle_brick_hits()

        if self.ball_y > H:
            self.lives -= 1
            set_text("lives", self.lives)
            if self.lives <= 0:
                self.over = True
                if self.score > self.high:
                    self.high = self.score
                    set_text("high", self.score)
                    storage.set_int("breakout_pro_high", self.score)
                status("Game over — press R to play again.", "err")
            else:
                self._park_ball()

        if not any(b["alive"] for b in self.bricks):
            self.won = True
            if self.score > self.high:
                self.high = self.score
                set_text("high", self.score)
                storage.set_int("breakout_pro_high", self.score)
            status("All bricks cleared! Press R to play again.", "ok")

        self.render()

    def render(self):
        canvas.fill("dark")
        for b in self.bricks:
            if b["alive"]:
                bx = b["col"] * BRICK_W
                by = BRICK_TOP + b["row"] * BRICK_H
                canvas.rect(bx + 1, by + 1, BRICK_W - 2, BRICK_H - 2, b["color"])
        canvas.rounded_rect(self.paddle_x, PADDLE_Y, PADDLE_W, PADDLE_H, 4, "blue")
        canvas.rect(
            self.ball_x - BALL_R, self.ball_y - BALL_R, BALL_R * 2, BALL_R * 2, "white"
        )
        if self.over:
            canvas.rect(0, H // 2 - 50, W, 100, "rgba(0, 0, 0, 0.78)")
            canvas.text(
                "Game over",
                W // 2,
                H // 2 - 10,
                "white",
                size=28,
                align="center",
                baseline="middle",
                bold=True,
            )
            canvas.text(
                "Score " + str(self.score) + " — press R to play again",
                W // 2,
                H // 2 + 18,
                "gray",
                size=14,
                align="center",
                baseline="middle",
            )
        elif self.won:
            canvas.rect(0, H // 2 - 50, W, 100, "rgba(0, 0, 0, 0.78)")
            canvas.text(
                "Cleared!",
                W // 2,
                H // 2 - 10,
                "yellow",
                size=28,
                align="center",
                baseline="middle",
                bold=True,
            )
            canvas.text(
                "Score " + str(self.score) + " — press R for another round",
                W // 2,
                H // 2 + 18,
                "gray",
                size=14,
                align="center",
                baseline="middle",
            )


game = Game()


@on_key("ArrowLeft", "a", "A")
def left():
    if game.over or game.won:
        return
    game.left_held = True
    game.right_held = False


@on_key("ArrowRight", "d", "D")
def right():
    if game.over or game.won:
        return
    game.right_held = True
    game.left_held = False


@on_key(" ")
def launch():
    if not game.over and not game.won and not game.launched:
        game.launch()


@on_key("r", "R")
def restart():
    game.reset()
