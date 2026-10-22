# Catch — pro variant of web/catch-lite/main.py (kid). Source comparison only.

from nanopy import Canvas, Ticker, choice, on_key, randint, set_text, status, storage

canvas = Canvas("board")
W = canvas.width
H = canvas.height

PADDLE_W = 80
PADDLE_H = 14
PADDLE_Y = H - 30
PADDLE_SPEED = 12
FRUIT_R = 14
FRUIT_SPEED_START = 4
FRUIT_SPEED_MAX = 11
FRUIT_COLORS = ("red", "orange", "yellow", "green", "purple", "pink")


class Game:
    def __init__(self):
        self.high = storage.get_int("catch_pro_high", 0)
        set_text("high", self.high)
        self.ticker = Ticker(self._tick, 33)
        self.left_held = False
        self.right_held = False
        self.reset()
        self.ticker.start()

    def reset(self):
        self.paddle_x = W // 2 - PADDLE_W // 2
        self.fruit_speed = FRUIT_SPEED_START
        self.score = 0
        self.misses = 0
        self.over = False
        self._reset_fruit()
        set_text("score", 0)
        set_text("misses", 0)
        status("Use arrow keys (or A/D) to move the paddle.", "ok")

    def _reset_fruit(self):
        self.fruit_x = randint(FRUIT_R, W - FRUIT_R)
        self.fruit_y = -FRUIT_R
        self.fruit_color = choice(FRUIT_COLORS)

    def _tick(self, *_):
        if self.over:
            return
        if self.left_held:
            self.paddle_x -= PADDLE_SPEED
        if self.right_held:
            self.paddle_x += PADDLE_SPEED
        if self.paddle_x < 0:
            self.paddle_x = 0
        if self.paddle_x > W - PADDLE_W:
            self.paddle_x = W - PADDLE_W

        self.fruit_y += self.fruit_speed

        caught_top = PADDLE_Y - FRUIT_R
        if (
            caught_top <= self.fruit_y <= PADDLE_Y + PADDLE_H
            and self.paddle_x <= self.fruit_x <= self.paddle_x + PADDLE_W
        ):
            self.score += 1
            set_text("score", self.score)
            if self.score > self.high:
                self.high = self.score
                set_text("high", self.score)
                storage.set_int("catch_pro_high", self.score)
            if self.fruit_speed < FRUIT_SPEED_MAX:
                self.fruit_speed += 1
            self._reset_fruit()
            self.render()
            return

        if self.fruit_y > H:
            self.misses += 1
            set_text("misses", self.misses)
            if self.misses >= 3:
                self.over = True
                if self.score > self.high:
                    self.high = self.score
                    set_text("high", self.score)
                    storage.set_int("catch_pro_high", self.score)
                status("Game over. Press R to play again.", "err")
            else:
                self._reset_fruit()
        self.render()

    def render(self):
        canvas.fill("dark")
        canvas.line(0, PADDLE_Y + PADDLE_H + 4, W, PADDLE_Y + PADDLE_H + 4, "#2a3650")
        canvas.rounded_rect(self.paddle_x, PADDLE_Y, PADDLE_W, PADDLE_H, 6, "blue")
        canvas.rounded_rect(
            self.fruit_x - FRUIT_R,
            self.fruit_y - FRUIT_R,
            FRUIT_R * 2,
            FRUIT_R * 2,
            FRUIT_R // 2,
            self.fruit_color,
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
                "Caught " + str(self.score) + ". Press R to play again",
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
    if not game.over:
        game.left_held = True
        game.right_held = False


@on_key("ArrowRight", "d", "D")
def right():
    if not game.over:
        game.right_held = True
        game.left_held = False


@on_key(" ")
def stop():
    game.left_held = False
    game.right_held = False


@on_key("r", "R")
def restart():
    game.reset()
