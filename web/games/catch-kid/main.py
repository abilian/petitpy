# Catch — kid-style demo. Move the paddle left/right to catch fruit
# before it hits the floor. Three misses and you're out.
#
# Pure procedural: global state + four functions (update, draw,
# on_press, and one helper) + the loop call. No classes, no decorators.

import nanopy

# ---- canvas ----
screen = nanopy.canvas("board")
W = screen.width
H = screen.height

# ---- game constants ----
PADDLE_W = 80
PADDLE_H = 14
PADDLE_Y = H - 30
PADDLE_SPEED = 12

FRUIT_R = 14  # half-width of the fruit square
FRUIT_SPEED_START = 4
FRUIT_SPEED_MAX = 11

FRUIT_COLORS = ("red", "orange", "yellow", "green", "purple", "pink")

# ---- game state (module globals) ----
paddle_x = W // 2 - PADDLE_W // 2
fruit_x = W // 2
fruit_y = 0
fruit_color = "red"
fruit_speed = FRUIT_SPEED_START
score = 0
misses = 0
high = nanopy.storage.get_int("catch_lite_high", 0)
game_over = False
left_held = False
right_held = False


def reset_fruit():
    global fruit_x, fruit_y, fruit_color
    fruit_x = nanopy.randint(FRUIT_R, W - FRUIT_R)
    fruit_y = -FRUIT_R
    fruit_color = nanopy.choice(FRUIT_COLORS)


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


def update():
    global paddle_x, fruit_y, fruit_speed, score, misses, high, game_over
    if game_over:
        return

    # Paddle. Holding a direction key keeps it moving.
    if left_held:
        paddle_x -= PADDLE_SPEED
    if right_held:
        paddle_x += PADDLE_SPEED
    if paddle_x < 0:
        paddle_x = 0
    if paddle_x > W - PADDLE_W:
        paddle_x = W - PADDLE_W

    # Fruit.
    fruit_y += fruit_speed

    # Catch?
    caught_zone_top = PADDLE_Y - FRUIT_R
    if (
        caught_zone_top <= fruit_y <= PADDLE_Y + PADDLE_H
        and paddle_x <= fruit_x <= paddle_x + PADDLE_W
    ):
        score += 1
        nanopy.set_text("score", score)
        if score > high:
            high = score
            nanopy.set_text("high", score)
            nanopy.storage.set_int("catch_lite_high", score)
        # Speed up gently — capped so it stays playable.
        if fruit_speed < FRUIT_SPEED_MAX:
            fruit_speed += 1
        reset_fruit()
        return

    # Floor?
    if fruit_y > H:
        misses += 1
        nanopy.set_text("misses", misses)
        if misses >= 3:
            game_over = True
            if score > high:
                high = score
                nanopy.set_text("high", score)
                nanopy.storage.set_int("catch_lite_high", score)
            nanopy.status("Game over. Press R to play again.", "err")
            return
        reset_fruit()


def draw():
    screen.fill("dark")
    # Floor line.
    screen.line(0, PADDLE_Y + PADDLE_H + 4, W, PADDLE_Y + PADDLE_H + 4, "#2a3650")
    # Paddle.
    screen.rounded_rect(paddle_x, PADDLE_Y, PADDLE_W, PADDLE_H, 6, "blue")
    # Fruit (a rounded square works as a simple stand-in).
    screen.rounded_rect(
        fruit_x - FRUIT_R,
        fruit_y - FRUIT_R,
        FRUIT_R * 2,
        FRUIT_R * 2,
        FRUIT_R // 2,
        fruit_color,
    )

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
            "Caught " + str(score) + ". Press R to play again",
            W // 2,
            H // 2 + 18,
            "gray",
            size=14,
            align="center",
            baseline="middle",
        )


def on_press(key):
    global left_held, right_held
    if game_over:
        if key == "r" or key == "R":
            reset_game()
        return
    if key == "ArrowLeft" or key == "a" or key == "A":
        left_held = True
        right_held = False
    elif key == "ArrowRight" or key == "d" or key == "D":
        right_held = True
        left_held = False
    elif key == " ":
        left_held = False
        right_held = False
    elif key == "r" or key == "R":
        reset_game()


# ---- wire-up ----
nanopy.set_text("high", high)
reset_game()
nanopy.run(update=update, draw=draw, on_press=on_press, fps=30)
