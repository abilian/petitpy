# Snake — pro variant of web/snake-lite/main.py (kid).
# Same game, classes + decorators instead of module globals.
# Not wired up to the HTML; for source comparison only.

from nanopy import Canvas, Ticker, on_key, randrange, set_text, status, storage

GRID = 20
CELL = 20
W = GRID * CELL

canvas = Canvas("board")


class Snake:
    def __init__(self):
        self.high = storage.get_int("snake_pro_high", 0)
        set_text("high", self.high)
        self.ticker = Ticker(self._tick, 150)
        self.reset()

    def reset(self):
        self.body = [(10, 10), (9, 10), (8, 10)]
        self.dx, self.dy = 1, 0
        self.next_dx, self.next_dy = 1, 0
        self.score = 0
        self.over = False
        set_text("score", 0)
        self._spawn_apple()
        self.ticker.start()
        status("Use arrow keys or WASD to steer.", "ok")

    def _spawn_apple(self):
        occupied = set(self.body)
        while True:
            x = randrange(GRID)
            y = randrange(GRID)
            if (x, y) not in occupied:
                self.apple = (x, y)
                return

    def _tick(self, *_):
        if self.over:
            return
        self.dx, self.dy = self.next_dx, self.next_dy
        hx, hy = self.body[0]
        nx, ny = hx + self.dx, hy + self.dy
        if nx < 0 or nx >= GRID or ny < 0 or ny >= GRID:
            self._game_over()
            return
        new_head = (nx, ny)
        ate = new_head == self.apple
        check = self.body if ate else self.body[:-1]
        if new_head in check:
            self._game_over()
            return
        self.body = [new_head] + (self.body if ate else self.body[:-1])
        if ate:
            self.score += 1
            set_text("score", self.score)
            if self.score > self.high:
                self.high = self.score
                set_text("high", self.score)
                storage.set_int("snake_pro_high", self.score)
            self._spawn_apple()
        self.render()

    def render(self):
        canvas.fill("dark")
        for i in range(1, GRID):
            canvas.line(i * CELL, 0, i * CELL, W, "#2a3650")
            canvas.line(0, i * CELL, W, i * CELL, "#2a3650")
        ax, ay = self.apple
        canvas.rect(ax * CELL + 1, ay * CELL + 1, CELL - 2, CELL - 2, "pink")
        for i, (x, y) in enumerate(self.body):
            c = "blue" if i == 0 else "green"
            canvas.rect(x * CELL + 1, y * CELL + 1, CELL - 2, CELL - 2, c)
        if self.over:
            canvas.rect(0, W // 2 - 50, W, 100, "rgba(0, 0, 0, 0.78)")
            canvas.text(
                "Game over",
                W // 2,
                W // 2 - 10,
                "white",
                size=28,
                align="center",
                baseline="middle",
                bold=True,
            )
            canvas.text(
                "Score " + str(self.score) + " — press R to restart",
                W // 2,
                W // 2 + 18,
                "gray",
                size=14,
                align="center",
                baseline="middle",
            )

    def _game_over(self):
        self.over = True
        self.ticker.stop()
        self.render()
        status("Game over — press R to restart.", "err")

    def turn(self, dx, dy):
        if self.over:
            return
        if (self.dx, self.dy) != (-dx, -dy):
            self.next_dx, self.next_dy = dx, dy


game = Snake()


@on_key("ArrowUp", "w", "W")
def up():
    game.turn(0, -1)


@on_key("ArrowDown", "s", "S")
def down():
    game.turn(0, 1)


@on_key("ArrowLeft", "a", "A")
def left():
    game.turn(-1, 0)


@on_key("ArrowRight", "d", "D")
def right():
    game.turn(1, 0)


@on_key("r", "R")
def restart():
    game.reset()
