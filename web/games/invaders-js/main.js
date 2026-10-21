// Space Invaders — JS port (kid-style: arrays of objects, no classes).
import * as nanopy from "../../lib/nanopy.js";

const screen = nanopy.canvas("board");
const W = screen.width;
const H = screen.height;

const SHIP_W = 36,
  SHIP_H = 14,
  SHIP_Y = H - 30,
  SHIP_SPEED = 6;
const ALIEN_W = 30,
  ALIEN_H = 20;
const ALIEN_GAP_X = 14,
  ALIEN_GAP_Y = 12;
const ALIEN_LEFT = 30,
  ALIEN_TOP = 50;
const BULLET_W = 4,
  BULLET_H = 12;
const BULLET_SPEED = 8,
  BOMB_SPEED = 4;
const ALIEN_ROW_COLORS = ["pink", "purple", "blue", "green"];

let player_x = W / 2 - SHIP_W / 2;
let player_left = false;
let player_right = false;
let player_cool = 0;

let aliens = [];
let bullets = [];
let bombs = [];
let alien_dx = 1;
let alien_step = 0;
let alien_step_interval = 18;
let score = 0;
let wave = 1;
let high = nanopy.storage.get_int("invaders_js_high", 0);
let over = false;
let won = false;
let ticker_handle = null;

function make_wave() {
  const out = [];
  for (let r = 0; r < 4; r++) {
    for (let c = 0; c < 8; c++) {
      out.push({
        x: ALIEN_LEFT + c * (ALIEN_W + ALIEN_GAP_X),
        y: ALIEN_TOP + r * (ALIEN_H + ALIEN_GAP_Y),
        kind: r,
        alive: true,
      });
    }
  }
  return out;
}

function overlap(ax, ay, aw, ah, bx, by, bw, bh) {
  return ax < bx + bw && ax + aw > bx && ay < by + bh && ay + ah > by;
}

function alien_score(kind) {
  return (4 - kind) * 10;
}

function live_aliens() {
  return aliens.filter((a) => a.alive);
}

function shoot() {
  if (player_cool === 0) {
    player_cool = 12;
    bullets.push({
      x: player_x + SHIP_W / 2 - BULLET_W / 2,
      y: SHIP_Y - BULLET_H,
      dy: -BULLET_SPEED,
      color: "yellow",
      alive: true,
    });
  }
}

function march() {
  const live = live_aliens();
  if (!live.length) return;
  const min_x = Math.min(...live.map((a) => a.x));
  const max_x = Math.max(...live.map((a) => a.x)) + ALIEN_W;
  const step = 12 * alien_dx;
  if ((alien_dx > 0 && max_x + step > W) || (alien_dx < 0 && min_x + step < 0)) {
    alien_dx = -alien_dx;
    for (const a of aliens) if (a.alive) a.y += 18;
  } else {
    for (const a of aliens) if (a.alive) a.x += step;
  }
}

function game_over_msg(message) {
  over = true;
  stop_ticker();
  if (score > high) {
    high = score;
    nanopy.set_text("high", high);
    nanopy.storage.set_int("invaders_js_high", high);
  }
  nanopy.status(message + " — press R to play again.", "err");
}

function wave_clear() {
  won = true;
  stop_ticker();
  if (score > high) {
    high = score;
    nanopy.set_text("high", high);
    nanopy.storage.set_int("invaders_js_high", high);
  }
  nanopy.status("Wave cleared! Press space for the next wave.", "ok");
}

function next_wave() {
  wave++;
  nanopy.set_text("wave", wave);
  aliens = make_wave();
  bullets = [];
  bombs = [];
  alien_dx = 1;
  alien_step = 0;
  alien_step_interval = Math.max(6, 18 - (wave - 1) * 2);
  won = false;
  over = false;
  start_ticker();
  nanopy.status(`Wave ${wave} — A/D move, space fire.`, "ok");
}

function update() {
  if (over || won) return;

  if (player_left) player_x -= SHIP_SPEED;
  if (player_right) player_x += SHIP_SPEED;
  if (player_x < 0) player_x = 0;
  if (player_x > W - SHIP_W) player_x = W - SHIP_W;
  if (player_cool > 0) player_cool--;

  alien_step++;
  if (alien_step >= alien_step_interval) {
    alien_step = 0;
    march();
  }

  const live = live_aliens();
  if (live.length && nanopy.randrange(40) === 0) {
    const shooter = nanopy.choice(live);
    bombs.push({
      x: shooter.x + ALIEN_W / 2 - BULLET_W / 2,
      y: shooter.y + ALIEN_H,
      dy: BOMB_SPEED,
      color: "red",
      alive: true,
    });
  }

  for (const b of bullets) {
    b.y += b.dy;
    if (b.y < -BULLET_H || b.y > H) b.alive = false;
  }
  for (const b of bombs) {
    b.y += b.dy;
    if (b.y < -BULLET_H || b.y > H) b.alive = false;
  }

  for (const bullet of bullets) {
    if (!bullet.alive) continue;
    for (const a of aliens) {
      if (a.alive && overlap(bullet.x, bullet.y, BULLET_W, BULLET_H, a.x, a.y, ALIEN_W, ALIEN_H)) {
        a.alive = false;
        bullet.alive = false;
        score += alien_score(a.kind);
        nanopy.set_text("score", score);
        break;
      }
    }
  }

  for (const bomb of bombs) {
    if (!bomb.alive) continue;
    if (overlap(bomb.x, bomb.y, BULLET_W, BULLET_H, player_x, SHIP_Y - 6, SHIP_W, SHIP_H + 6)) {
      game_over_msg("Hit");
      return;
    }
  }

  bullets = bullets.filter((b) => b.alive);
  bombs = bombs.filter((b) => b.alive);

  if (!live_aliens().length) {
    wave_clear();
    return;
  }
  for (const a of live_aliens()) {
    if (a.y + ALIEN_H >= SHIP_Y) {
      game_over_msg("They landed");
      return;
    }
  }
}

function draw_player() {
  const cx = player_x + SHIP_W / 2;
  screen.rect(player_x, SHIP_Y + 4, SHIP_W, SHIP_H - 4, "blue");
  screen.rect(player_x + 8, SHIP_Y, SHIP_W - 16, 5, "blue");
  screen.rect(cx - 2, SHIP_Y - 6, 4, 7, "blue");
}

function draw() {
  screen.fill("dark");
  screen.line(0, SHIP_Y + SHIP_H + 6, W, SHIP_Y + SHIP_H + 6, "#2a3650");
  for (const a of aliens) {
    if (!a.alive) continue;
    screen.rect(a.x + 2, a.y + 2, ALIEN_W - 4, ALIEN_H - 4, ALIEN_ROW_COLORS[a.kind]);
    screen.rect(a.x + 7, a.y + 7, 4, 4, "dark");
    screen.rect(a.x + ALIEN_W - 11, a.y + 7, 4, 4, "dark");
  }
  for (const b of bullets) if (b.alive) screen.rect(b.x, b.y, BULLET_W, BULLET_H, b.color);
  for (const b of bombs) if (b.alive) screen.rect(b.x, b.y, BULLET_W, BULLET_H, b.color);
  draw_player();
  if (over) overlay("Game over", "Press R to play again.");
  else if (won) overlay(`Wave ${wave} cleared`, "Press space for the next wave.");
}

function overlay(title, subtitle) {
  screen.rect(0, H / 2 - 60, W, 120, "rgba(0, 0, 0, 0.78)");
  screen.text(title, W / 2, H / 2 - 10, "white", 30, "center", "middle", true);
  screen.text(subtitle, W / 2, H / 2 + 22, "gray", 14, "center", "middle");
}

function tick() {
  update();
  draw();
}
function stop_ticker() {
  if (ticker_handle !== null) {
    clearInterval(ticker_handle);
    ticker_handle = null;
  }
}
function start_ticker() {
  ticker_handle = setInterval(tick, 33);
}

function reset() {
  stop_ticker();
  player_x = W / 2 - SHIP_W / 2;
  aliens = make_wave();
  bullets = [];
  bombs = [];
  alien_dx = 1;
  alien_step = 0;
  alien_step_interval = 18;
  score = 0;
  over = false;
  won = false;
  wave = 1;
  nanopy.set_text("score", 0);
  nanopy.set_text("wave", 1);
  start_ticker();
  nanopy.status("A/D to move, space to fire. R to restart.", "ok");
}

function on_press(key) {
  if (key === "ArrowLeft" || key === "a" || key === "A") {
    player_left = true;
    player_right = false;
  } else if (key === "ArrowRight" || key === "d" || key === "D") {
    player_right = true;
    player_left = false;
  } else if (key === "s" || key === "S") {
    player_left = false;
    player_right = false;
  } else if (key === " ") {
    if (won) next_wave();
    else if (!over) shoot();
  } else if (key === "r" || key === "R") {
    reset();
  }
}

nanopy.set_text("high", high);
reset();
nanopy.run({ on_press });
