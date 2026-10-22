"""Space Invaders — pro-style. Multiple entity types (player, aliens,
bullets, bombs) read more naturally as classes than as parallel lists.

The Game class owns the world; a Ticker runs the gameplay update; the
input bindings are six @on_key decorators. nanopy still hides the
runtime (DOM, canvas, RNG, storage, key dispatch).
"""

from nanopy import (
    Canvas,
    Ticker,
    choice,
    on_key,
    randrange,
    set_text,
    status,
    storage,
)

# ---------------------------------------------------------------------------
# Geometry
# ---------------------------------------------------------------------------

canvas = Canvas("board")
W = canvas.width  # 600
H = canvas.height  # 500

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

STORAGE_KEY = "nanopython:invaders_lite:high"


# ---------------------------------------------------------------------------
# Entities
# ---------------------------------------------------------------------------


class Player:
    def __init__(self):
        self.x = W // 2 - SHIP_W // 2
        self.alive = True
        self.left_held = False
        self.right_held = False
        self.cool = 0  # frames until next shot is allowed

    def update(self):
        if self.left_held:
            self.x -= SHIP_SPEED
        if self.right_held:
            self.x += SHIP_SPEED
        if self.x < 0:
            self.x = 0
        if self.x > W - SHIP_W:
            self.x = W - SHIP_W
        if self.cool > 0:
            self.cool -= 1

    def shoot(self):
        if self.cool == 0:
            self.cool = 12
            return Bullet(
                self.x + SHIP_W // 2 - BULLET_W // 2,
                SHIP_Y - BULLET_H,
                -BULLET_SPEED,
                "yellow",
            )
        return None

    def draw(self):
        if not self.alive:
            return
        # Ship body — a stylized triangle-ish shape using rects.
        cx = self.x + SHIP_W // 2
        canvas.rect(self.x, SHIP_Y + 4, SHIP_W, SHIP_H - 4, "blue")
        canvas.rect(self.x + 8, SHIP_Y, SHIP_W - 16, 5, "blue")
        canvas.rect(cx - 2, SHIP_Y - 6, 4, 7, "blue")


class Alien:
    def __init__(self, x, y, kind):
        self.x = x
        self.y = y
        self.kind = kind  # row index, used for color + score
        self.alive = True

    def draw(self):
        if not self.alive:
            return
        canvas.rect(
            self.x + 2,
            self.y + 2,
            ALIEN_W - 4,
            ALIEN_H - 4,
            ALIEN_ROW_COLORS[self.kind],
        )
        # Two "eyes" so it doesn't look like just a colored rect.
        canvas.rect(self.x + 7, self.y + 7, 4, 4, "dark")
        canvas.rect(self.x + ALIEN_W - 11, self.y + 7, 4, 4, "dark")


class Bullet:
    def __init__(self, x, y, dy, color):
        self.x = x
        self.y = y
        self.dy = dy
        self.color = color
        self.alive = True

    def update(self):
        self.y += self.dy
        if self.y < -BULLET_H or self.y > H:
            self.alive = False

    def draw(self):
        if self.alive:
            canvas.rect(self.x, self.y, BULLET_W, BULLET_H, self.color)


# ---------------------------------------------------------------------------
# Game
# ---------------------------------------------------------------------------


class Game:
    def __init__(self):
        self.high = storage.get_int(STORAGE_KEY, 0)
        set_text("high", self.high)
        self.ticker = Ticker(self._tick, 33)  # ~30 fps
        self.reset()

    # ---- lifecycle -------------------------------------------------------

    def reset(self):
        self.player = Player()
        self.aliens = self._make_wave()
        self.bullets = []
        self.bombs = []
        self.alien_dx = 1  # current march direction
        self.alien_step = 0  # frames since last step
        self.alien_step_interval = 18
        self.score = 0
        self.over = False
        self.won = False
        set_text("score", 0)
        set_text("wave", 1)
        self.wave = 1
        self.ticker.start()
        status("A/D to move, space to fire. R to restart.", "ok")

    def _make_wave(self):
        # 4 rows × 8 columns.
        aliens = []
        for r in range(4):
            for c in range(8):
                x = ALIEN_LEFT + c * (ALIEN_W + ALIEN_GAP_X)
                y = ALIEN_TOP + r * (ALIEN_H + ALIEN_GAP_Y)
                aliens.append(Alien(x, y, r))
        return aliens

    def _live_aliens(self):
        return [a for a in self.aliens if a.alive]

    def _alien_score(self, kind):
        # Closer-to-top aliens (low kind) score more.
        return (4 - kind) * 10

    def game_over(self, message):
        self.over = True
        self.ticker.stop()
        if self.score > self.high:
            self.high = self.score
            set_text("high", self.high)
            storage.set_int(STORAGE_KEY, self.high)
        status(message + ". Press R to play again.", "err")

    def wave_clear(self):
        self.won = True
        self.ticker.stop()
        if self.score > self.high:
            self.high = self.score
            set_text("high", self.high)
            storage.set_int(STORAGE_KEY, self.high)
        status("Wave cleared! Press space for the next wave.", "ok")

    def next_wave(self):
        self.wave += 1
        set_text("wave", self.wave)
        self.aliens = self._make_wave()
        self.bullets = []
        self.bombs = []
        self.alien_dx = 1
        self.alien_step = 0
        # Faster every wave, capped.
        self.alien_step_interval = max(6, 18 - (self.wave - 1) * 2)
        self.won = False
        self.over = False
        self.ticker.start()
        status("Wave " + str(self.wave) + ": A/D to move, space to fire.", "ok")

    # ---- per-tick update + render ----------------------------------------

    def _tick(self, *_):
        if self.over or self.won:
            return
        self._update()
        self._render()

    def _update(self):
        self.player.update()

        # Aliens march.
        self.alien_step += 1
        if self.alien_step >= self.alien_step_interval:
            self.alien_step = 0
            self._march_aliens()

        # Aliens drop bombs occasionally.
        live = self._live_aliens()
        if live and randrange(40) == 0:
            shooter = choice(live)
            self.bombs.append(
                Bullet(
                    shooter.x + ALIEN_W // 2 - BULLET_W // 2,
                    shooter.y + ALIEN_H,
                    BOMB_SPEED,
                    "red",
                )
            )

        # Move bullets/bombs.
        for b in self.bullets + self.bombs:
            b.update()
        self.bullets = [b for b in self.bullets if b.alive]
        self.bombs = [b for b in self.bombs if b.alive]

        # Collisions: player bullets vs aliens.
        for bullet in self.bullets:
            for a in self.aliens:
                if a.alive and _overlap(
                    bullet.x, bullet.y, BULLET_W, BULLET_H, a.x, a.y, ALIEN_W, ALIEN_H
                ):
                    a.alive = False
                    bullet.alive = False
                    self.score += self._alien_score(a.kind)
                    set_text("score", self.score)
                    break
        self.bullets = [b for b in self.bullets if b.alive]

        # Collisions: bombs vs player.
        for bomb in self.bombs:
            if _overlap(
                bomb.x,
                bomb.y,
                BULLET_W,
                BULLET_H,
                self.player.x,
                SHIP_Y - 6,
                SHIP_W,
                SHIP_H + 6,
            ):
                self.player.alive = False
                self.game_over("Hit")
                return

        # Win/lose checks.
        if not self._live_aliens():
            self.wave_clear()
            return
        for a in self._live_aliens():
            if a.y + ALIEN_H >= SHIP_Y:
                self.game_over("They landed")
                return

    def _march_aliens(self):
        # Compute the bounding x range of live aliens.
        live = self._live_aliens()
        if not live:
            return
        min_x = min(a.x for a in live)
        max_x = max(a.x for a in live) + ALIEN_W

        # Would the next step push past either wall?
        step = 12 * self.alien_dx
        if (self.alien_dx > 0 and max_x + step > W) or (
            self.alien_dx < 0 and min_x + step < 0
        ):
            # Reverse and descend.
            self.alien_dx = -self.alien_dx
            for a in self.aliens:
                if a.alive:
                    a.y += 18
        else:
            for a in self.aliens:
                if a.alive:
                    a.x += step

    # ---- render ----------------------------------------------------------

    def _render(self):
        canvas.fill("dark")
        # subtle ground line.
        canvas.line(0, SHIP_Y + SHIP_H + 6, W, SHIP_Y + SHIP_H + 6, "#2a3650")
        for a in self.aliens:
            a.draw()
        for b in self.bullets:
            b.draw()
        for b in self.bombs:
            b.draw()
        self.player.draw()

        if self.over:
            self._overlay("Game over", "Press R to play again.")
        elif self.won:
            self._overlay(
                "Wave " + str(self.wave) + " cleared", "Press space for the next wave."
            )

    def _overlay(self, title, subtitle):
        canvas.rect(0, H // 2 - 60, W, 120, "rgba(0, 0, 0, 0.78)")
        canvas.text(
            title,
            W // 2,
            H // 2 - 10,
            "white",
            size=30,
            align="center",
            baseline="middle",
            bold=True,
        )
        canvas.text(
            subtitle,
            W // 2,
            H // 2 + 22,
            "gray",
            size=14,
            align="center",
            baseline="middle",
        )


def _overlap(ax, ay, aw, ah, bx, by, bw, bh):
    return ax < bx + bw and ax + aw > bx and ay < by + bh and ay + ah > by


game = Game()


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------


@on_key("ArrowLeft", "a", "A")
def left():
    game.player.left_held = True
    game.player.right_held = False


@on_key("ArrowRight", "d", "D")
def right():
    game.player.right_held = True
    game.player.left_held = False


@on_key("s", "S")
def stop_moving():
    game.player.left_held = False
    game.player.right_held = False


@on_key(" ")
def fire():
    if game.won:
        game.next_wave()
        return
    if game.over:
        return
    b = game.player.shoot()
    if b is not None:
        game.bullets.append(b)


@on_key("r", "R")
def restart():
    game.ticker.stop()
    game.reset()
