# Breakout — kid-style. Move the paddle, bounce the ball, break the
# bricks. Lose a life when the ball falls below the paddle; three
# lives total. Win when every brick is gone.
#
# Module globals + a handful of functions. No classes. The bounce
# math is integer-only: the paddle imparts horizontal velocity based
# on where you hit it, with the speed capped so things stay sane.

import nanopy

# ---- canvas ----
screen = nanopy.canvas("board")
W = screen.width
H = screen.height

# ---- shapes ----
PADDLE_W = 80
PADDLE_H = 12
PADDLE_Y = H - 36
PADDLE_SPEED = 9

BALL_R = 6
BALL_SPEED = 5

BRICK_TOP = 50
BRICK_ROWS = 5
BRICK_COLS = 10
BRICK_W = W // BRICK_COLS
BRICK_H = 18

ROW_COLORS = ("red", "orange", "yellow", "green", "blue")

# ---- state ----
paddle_x = W // 2 - PADDLE_W // 2
ball_x = W // 2
ball_y = H - 80
ball_dx = 3
ball_dy = -4
bricks = []  # flat list of dicts; one per brick
score = 0
lives = 3
high = nanopy.storage.get_int("breakout_lite_high", 0)
game_over = False
won = False
launched = False  # True once the player launches the ball
left_held = False
right_held = False


def reset_bricks():
    bricks.clear()
    for r in range(BRICK_ROWS):
        for c in range(BRICK_COLS):
            bricks.append({"col": c, "row": r, "alive": True, "color": ROW_COLORS[r]})


def park_ball():
    """Put the ball on the paddle, waiting for launch."""
    global ball_x, ball_y, ball_dx, ball_dy, launched
    ball_x = paddle_x + PADDLE_W // 2
    ball_y = PADDLE_Y - BALL_R - 1
    ball_dx = 3
    ball_dy = -4
    launched = False


def reset_game():
    global score, lives, game_over, won
    score = 0
    lives = 3
    game_over = False
    won = False
    reset_bricks()
    park_ball()
    nanopy.set_text("score", 0)
    nanopy.set_text("lives", 3)
    nanopy.status("Space to launch. Arrows (or A/D) to move.", "ok")


def alive_bricks_remaining():
    return any(b["alive"] for b in bricks)


def brick_at(col, row):
    """Return the alive brick at (col, row) or None."""
    if col < 0 or col >= BRICK_COLS or row < 0 or row >= BRICK_ROWS:
        return None
    # bricks list is row-major: index = row * BRICK_COLS + col
    b = bricks[row * BRICK_COLS + col]
    return b if b["alive"] else None


def bounce_off_paddle():
    """Adjust ball velocity after a paddle hit. The paddle imparts
    horizontal english based on where the ball lands: dead-center
    gives a pure vertical bounce, edges throw the ball sideways."""
    global ball_dx, ball_dy
    offset = ball_x - (paddle_x + PADDLE_W // 2)
    # Map offset (-40..+40 for an 80-wide paddle) to a signed step.
    # Cap so the ball never goes purely sideways.
    ball_dx = max(-5, min(5, offset // 8))
    ball_dy = -abs(ball_dy)
    # Ensure a minimum upward speed.
    if ball_dy > -3:
        ball_dy = -3


def handle_brick_hits():
    """If the ball overlaps a live brick, kill the brick and bounce."""
    global ball_dy, ball_dx, score
    if ball_y - BALL_R > BRICK_TOP + BRICK_ROWS * BRICK_H:
        return  # below all bricks
    if ball_y + BALL_R < BRICK_TOP:
        return  # above all bricks
    c = ball_x // BRICK_W
    r = (ball_y - BRICK_TOP) // BRICK_H
    b = brick_at(c, r)
    if b is None:
        return
    b["alive"] = False
    score += 10
    nanopy.set_text("score", score)
    # Bounce: figure out which side of the brick was hit.
    # Use the ball's previous position (approximated by subtracting
    # velocity) to decide which axis to flip.
    prev_x = ball_x - ball_dx
    prev_y = ball_y - ball_dy
    prev_c = prev_x // BRICK_W
    prev_r = (prev_y - BRICK_TOP) // BRICK_H
    if prev_r != r:
        ball_dy = -ball_dy
    elif prev_c != c:
        ball_dx = -ball_dx
    else:
        # Same brick coord — corner hit. Flip both.
        ball_dy = -ball_dy
        ball_dx = -ball_dx


def update():
    global paddle_x, ball_x, ball_y, ball_dx, ball_dy, lives
    global game_over, won, high

    if game_over or won:
        return

    # Paddle.
    if left_held:
        paddle_x -= PADDLE_SPEED
    if right_held:
        paddle_x += PADDLE_SPEED
    if paddle_x < 0:
        paddle_x = 0
    if paddle_x > W - PADDLE_W:
        paddle_x = W - PADDLE_W

    if not launched:
        # Ball rides the paddle until launched.
        ball_x = paddle_x + PADDLE_W // 2
        return

    # Ball.
    ball_x += ball_dx
    ball_y += ball_dy

    # Side walls.
    if ball_x < BALL_R:
        ball_x = BALL_R
        ball_dx = -ball_dx
    elif ball_x > W - BALL_R:
        ball_x = W - BALL_R
        ball_dx = -ball_dx

    # Ceiling.
    if ball_y < BALL_R:
        ball_y = BALL_R
        ball_dy = -ball_dy

    # Paddle.
    if (
        ball_y + BALL_R >= PADDLE_Y
        and ball_y - BALL_R <= PADDLE_Y + PADDLE_H
        and paddle_x <= ball_x <= paddle_x + PADDLE_W
        and ball_dy > 0
    ):
        bounce_off_paddle()

    # Bricks.
    handle_brick_hits()

    # Floor — lose a life.
    if ball_y > H:
        lives -= 1
        nanopy.set_text("lives", lives)
        if lives <= 0:
            game_over = True
            if score > high:
                high = score
                nanopy.set_text("high", score)
                nanopy.storage.set_int("breakout_lite_high", score)
            nanopy.status("Game over — press R to play again.", "err")
            return
        park_ball()

    # Win.
    if not alive_bricks_remaining():
        won = True
        if score > high:
            high = score
            nanopy.set_text("high", score)
            nanopy.storage.set_int("breakout_lite_high", score)
        nanopy.status("All bricks cleared! Press R to play again.", "ok")


def draw():
    screen.fill("dark")

    # Bricks.
    for b in bricks:
        if not b["alive"]:
            continue
        bx = b["col"] * BRICK_W
        by = BRICK_TOP + b["row"] * BRICK_H
        screen.rect(bx + 1, by + 1, BRICK_W - 2, BRICK_H - 2, b["color"])

    # Paddle.
    screen.rounded_rect(paddle_x, PADDLE_Y, PADDLE_W, PADDLE_H, 4, "blue")

    # Ball.
    screen.rect(ball_x - BALL_R, ball_y - BALL_R, BALL_R * 2, BALL_R * 2, "white")

    if game_over:
        screen.rect(0, H // 2 - 50, W, 100, "rgba(0, 0, 0, 0.78)")
        screen.text(
            "Game over",
            W // 2,
            H // 2 - 10,
            "white",
            size=28,
            align="center",
            baseline="middle",
            bold=True,
        )
        screen.text(
            "Score " + str(score) + " — press R to play again",
            W // 2,
            H // 2 + 18,
            "gray",
            size=14,
            align="center",
            baseline="middle",
        )
    elif won:
        screen.rect(0, H // 2 - 50, W, 100, "rgba(0, 0, 0, 0.78)")
        screen.text(
            "Cleared!",
            W // 2,
            H // 2 - 10,
            "yellow",
            size=28,
            align="center",
            baseline="middle",
            bold=True,
        )
        screen.text(
            "Score " + str(score) + " — press R for another round",
            W // 2,
            H // 2 + 18,
            "gray",
            size=14,
            align="center",
            baseline="middle",
        )


def on_press(key):
    global left_held, right_held, launched
    if game_over or won:
        if key == "r" or key == "R":
            reset_game()
        return
    if key == "ArrowLeft" or key == "a" or key == "A":
        left_held = True
        right_held = False
    elif key == "ArrowRight" or key == "d" or key == "D":
        right_held = True
        left_held = False
    elif key == " " and not launched:
        launched = True
    elif key == "r" or key == "R":
        reset_game()


# ---- wire-up ----
nanopy.set_text("high", high)
reset_game()
nanopy.run(update=update, draw=draw, on_press=on_press, fps=45)
