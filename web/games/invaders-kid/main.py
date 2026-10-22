# Space Invaders — kid variant of web/invaders-lite/main.py (pro).
# Multiple entity kinds expressed as lists of dicts instead of class instances.
# Source comparison only.

import js
import nanopy

screen = nanopy.canvas("board")
W = screen.width
H = screen.height

SHIP_W = 36
SHIP_H = 14
SHIP_Y = H - 30
SHIP_SPEED = 6

ALIEN_W = 30
ALIEN_H = 20
ALIEN_GAP_X = 14
ALIEN_GAP_Y = 12
ALIEN_LEFT = 30
ALIEN_TOP = 50

BULLET_W = 4
BULLET_H = 12
BULLET_SPEED = 8
BOMB_SPEED = 4

ALIEN_ROW_COLORS = ("pink", "purple", "blue", "green")

# ---- state ----
player_x = W // 2 - SHIP_W // 2
player_left = False
player_right = False
player_cool = 0

aliens = []
bullets = []  # player bullets
bombs = []  # alien bombs
alien_dx = 1
alien_step = 0
alien_step_interval = 18
score = 0
wave = 1
high = nanopy.storage.get_int("invaders_kid_high", 0)
over = False
won = False
ticker_handle = [None]


def make_wave():
    out = []
    for r in range(4):
        for c in range(8):
            x = ALIEN_LEFT + c * (ALIEN_W + ALIEN_GAP_X)
            y = ALIEN_TOP + r * (ALIEN_H + ALIEN_GAP_Y)
            out.append({"x": x, "y": y, "kind": r, "alive": True})
    return out


def overlap(ax, ay, aw, ah, bx, by, bw, bh):
    return ax < bx + bw and ax + aw > bx and ay < by + bh and ay + ah > by


def alien_score(kind):
    return (4 - kind) * 10


def shoot():
    global player_cool
    if player_cool == 0:
        player_cool = 12
        bullets.append(
            {
                "x": player_x + SHIP_W // 2 - BULLET_W // 2,
                "y": SHIP_Y - BULLET_H,
                "dy": -BULLET_SPEED,
                "color": "yellow",
                "alive": True,
            }
        )


def live_aliens():
    return [a for a in aliens if a["alive"]]


def march():
    live = live_aliens()
    if not live:
        return
    min_x = min(a["x"] for a in live)
    max_x = max(a["x"] for a in live) + ALIEN_W
    global alien_dx
    step = 12 * alien_dx
    if (alien_dx > 0 and max_x + step > W) or (alien_dx < 0 and min_x + step < 0):
        alien_dx = -alien_dx
        for a in aliens:
            if a["alive"]:
                a["y"] += 18
    else:
        for a in aliens:
            if a["alive"]:
                a["x"] += step


def game_over(message):
    global over, high
    over = True
    _stop_ticker()
    if score > high:
        high = score
        nanopy.set_text("high", high)
        nanopy.storage.set_int("invaders_kid_high", high)
    nanopy.status(message + ". Press R to play again.", "err")


def wave_clear():
    global won, high
    won = True
    _stop_ticker()
    if score > high:
        high = score
        nanopy.set_text("high", high)
        nanopy.storage.set_int("invaders_kid_high", high)
    nanopy.status("Wave cleared! Press space for the next wave.", "ok")


def next_wave():
    global wave, aliens, bullets, bombs, alien_dx, alien_step
    global alien_step_interval, won, over
    wave += 1
    nanopy.set_text("wave", wave)
    aliens = make_wave()
    bullets = []
    bombs = []
    alien_dx = 1
    alien_step = 0
    alien_step_interval = max(6, 18 - (wave - 1) * 2)
    won = False
    over = False
    _start_ticker()
    nanopy.status("Wave " + str(wave) + ": A/D to move, space to fire.", "ok")


def update():
    global player_x, player_cool, alien_step
    if over or won:
        return

    if player_left:
        player_x -= SHIP_SPEED
    if player_right:
        player_x += SHIP_SPEED
    if player_x < 0:
        player_x = 0
    if player_x > W - SHIP_W:
        player_x = W - SHIP_W
    if player_cool > 0:
        player_cool -= 1

    alien_step += 1
    if alien_step >= alien_step_interval:
        alien_step = 0
        march()

    live = live_aliens()
    if live and nanopy.randrange(40) == 0:
        shooter = nanopy.choice(live)
        bombs.append(
            {
                "x": shooter["x"] + ALIEN_W // 2 - BULLET_W // 2,
                "y": shooter["y"] + ALIEN_H,
                "dy": BOMB_SPEED,
                "color": "red",
                "alive": True,
            }
        )

    for b in bullets + bombs:
        b["y"] += b["dy"]
        if b["y"] < -BULLET_H or b["y"] > H:
            b["alive"] = False

    # Bullets vs aliens.
    global score
    for bullet in bullets:
        if not bullet["alive"]:
            continue
        for a in aliens:
            if a["alive"] and overlap(
                bullet["x"],
                bullet["y"],
                BULLET_W,
                BULLET_H,
                a["x"],
                a["y"],
                ALIEN_W,
                ALIEN_H,
            ):
                a["alive"] = False
                bullet["alive"] = False
                score += alien_score(a["kind"])
                nanopy.set_text("score", score)
                break

    # Bombs vs player.
    for bomb in bombs:
        if not bomb["alive"]:
            continue
        if overlap(
            bomb["x"],
            bomb["y"],
            BULLET_W,
            BULLET_H,
            player_x,
            SHIP_Y - 6,
            SHIP_W,
            SHIP_H + 6,
        ):
            game_over("Hit")
            return

    bullets[:] = [b for b in bullets if b["alive"]]
    bombs[:] = [b for b in bombs if b["alive"]]

    if not live_aliens():
        wave_clear()
        return

    for a in live_aliens():
        if a["y"] + ALIEN_H >= SHIP_Y:
            game_over("They landed")
            return


def draw_player():
    cx = player_x + SHIP_W // 2
    screen.rect(player_x, SHIP_Y + 4, SHIP_W, SHIP_H - 4, "blue")
    screen.rect(player_x + 8, SHIP_Y, SHIP_W - 16, 5, "blue")
    screen.rect(cx - 2, SHIP_Y - 6, 4, 7, "blue")


def draw():
    screen.fill("dark")
    screen.line(0, SHIP_Y + SHIP_H + 6, W, SHIP_Y + SHIP_H + 6, "#2a3650")
    for a in aliens:
        if not a["alive"]:
            continue
        screen.rect(
            a["x"] + 2,
            a["y"] + 2,
            ALIEN_W - 4,
            ALIEN_H - 4,
            ALIEN_ROW_COLORS[a["kind"]],
        )
        screen.rect(a["x"] + 7, a["y"] + 7, 4, 4, "dark")
        screen.rect(a["x"] + ALIEN_W - 11, a["y"] + 7, 4, 4, "dark")
    for b in bullets + bombs:
        if b["alive"]:
            screen.rect(b["x"], b["y"], BULLET_W, BULLET_H, b["color"])
    draw_player()
    if over:
        _overlay("Game over", "Press R to play again.")
    elif won:
        _overlay("Wave " + str(wave) + " cleared", "Press space for the next wave.")


def _overlay(title, subtitle):
    screen.rect(0, H // 2 - 60, W, 120, "rgba(0, 0, 0, 0.78)")
    screen.text(
        title,
        W // 2,
        H // 2 - 10,
        "white",
        size=30,
        align="center",
        baseline="middle",
        bold=True,
    )
    screen.text(
        subtitle,
        W // 2,
        H // 2 + 22,
        "gray",
        size=14,
        align="center",
        baseline="middle",
    )


def _tick(*_):
    update()
    draw()


def _stop_ticker():
    if ticker_handle[0] is not None:
        js.window.clearInterval(ticker_handle[0])
        ticker_handle[0] = None


def _start_ticker():
    ticker_handle[0] = js.window.setInterval(_tick, 33).to_int()


def reset():
    global player_x, aliens, bullets, bombs, alien_dx, alien_step
    global alien_step_interval, score, over, won, wave
    _stop_ticker()
    player_x = W // 2 - SHIP_W // 2
    aliens = make_wave()
    bullets = []
    bombs = []
    alien_dx = 1
    alien_step = 0
    alien_step_interval = 18
    score = 0
    over = False
    won = False
    wave = 1
    nanopy.set_text("score", 0)
    nanopy.set_text("wave", 1)
    _start_ticker()
    nanopy.status("A/D to move, space to fire. R to restart.", "ok")


def on_press(key):
    global player_left, player_right
    if key == "ArrowLeft" or key == "a" or key == "A":
        player_left = True
        player_right = False
    elif key == "ArrowRight" or key == "d" or key == "D":
        player_right = True
        player_left = False
    elif key == "s" or key == "S":
        player_left = False
        player_right = False
    elif key == " ":
        if won:
            next_wave()
        elif not over:
            shoot()
    elif key == "r" or key == "R":
        reset()


nanopy.set_text("high", high)
reset()
nanopy.run(on_press=on_press)
