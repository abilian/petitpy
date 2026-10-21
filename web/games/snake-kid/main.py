# Snake — kid-style: just functions and module globals. No classes, no
# decorators. Pygame-shaped: update() + draw() + on_press(key), all
# wired up at the bottom with one call to nanopy.run(...).
#
# Compare with web/snake/main.py (320 lines, all the bridge ceremony
# inline) to see where the cognitive complexity went.

import nanopy

# ---- constants ----
GRID = 20  # 20x20 cells
CELL = 20  # px per cell
W = GRID * CELL  # 400

# ---- canvas ----
screen = nanopy.canvas("board")

# ---- game state (module-level — no classes) ----
snake = [(10, 10), (9, 10), (8, 10)]  # head first
dx, dy = 1, 0  # current direction
next_dx, next_dy = 1, 0  # buffered direction
apple = (5, 5)
score = nanopy.Score("score", storage_key="snake_lite_high", best_id="high")
game_over = False


def spawn_apple():
    global apple
    body = set(snake)
    while True:
        x = nanopy.randrange(GRID)
        y = nanopy.randrange(GRID)
        if (x, y) not in body:
            apple = (x, y)
            return


def reset():
    global snake, dx, dy, next_dx, next_dy, game_over
    snake = [(10, 10), (9, 10), (8, 10)]
    dx, dy = 1, 0
    next_dx, next_dy = 1, 0
    game_over = False
    score.reset()
    spawn_apple()
    nanopy.status("Use arrow keys or WASD to steer.", "ok")


def update():
    global snake, dx, dy, game_over
    if game_over:
        return
    dx, dy = next_dx, next_dy
    hx, hy = snake[0]
    nx, ny = hx + dx, hy + dy

    # Wall collision.
    if nx < 0 or nx >= GRID or ny < 0 or ny >= GRID:
        game_over = True
        nanopy.status("Game over — press R to restart.", "err")
        return

    new_head = (nx, ny)
    ate = new_head == apple
    body_to_check = snake if ate else snake[:-1]
    if new_head in body_to_check:
        game_over = True
        nanopy.status("Game over — press R to restart.", "err")
        return

    snake = [new_head] + (snake if ate else snake[:-1])
    if ate:
        score.add(1)
        nanopy.beep(660, ms=60)  # short reward chirp
        spawn_apple()


def draw():
    screen.fill("dark")

    # grid
    for i in range(1, GRID):
        screen.line(i * CELL, 0, i * CELL, W, "#2a3650")
        screen.line(0, i * CELL, W, i * CELL, "#2a3650")

    ax, ay = apple
    screen.rect(ax * CELL + 1, ay * CELL + 1, CELL - 2, CELL - 2, "pink")

    for i, (x, y) in enumerate(snake):
        c = "blue" if i == 0 else "green"
        screen.rect(x * CELL + 1, y * CELL + 1, CELL - 2, CELL - 2, c)

    if game_over:
        screen.rect(0, W // 2 - 50, W, 100, "rgba(0, 0, 0, 0.78)")
        screen.text(
            "Game over",
            W // 2,
            W // 2 - 10,
            "white",
            size=28,
            align="center",
            baseline="middle",
            bold=True,
        )
        screen.text(
            "Score " + str(score.value) + " — press R to restart",
            W // 2,
            W // 2 + 18,
            "gray",
            size=14,
            align="center",
            baseline="middle",
        )


def on_press(key):
    global next_dx, next_dy
    if game_over:
        if key == "r" or key == "R":
            reset()
        return
    # Block the 180-degree reversal against the *committed* heading,
    # so a quick two-key tap within one tick can't fold the snake.
    if key == "ArrowUp" or key == "w" or key == "W":
        if (dx, dy) != (0, 1):
            next_dx, next_dy = 0, -1
    elif key == "ArrowDown" or key == "s" or key == "S":
        if (dx, dy) != (0, -1):
            next_dx, next_dy = 0, 1
    elif key == "ArrowLeft" or key == "a" or key == "A":
        if (dx, dy) != (1, 0):
            next_dx, next_dy = -1, 0
    elif key == "ArrowRight" or key == "d" or key == "D":
        if (dx, dy) != (-1, 0):
            next_dx, next_dy = 1, 0
    elif key == "r" or key == "R":
        reset()


# ---- wire-up ----
reset()
nanopy.run(update=update, draw=draw, on_press=on_press, fps=7)
