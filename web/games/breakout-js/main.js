// Breakout — JS port of web/breakout-lite/main.py (kid-style).
import * as nanopy from "../../lib/nanopy.js";

const screen = nanopy.canvas("board");
const W = screen.width;
const H = screen.height;

const PADDLE_W = 80;
const PADDLE_H = 12;
const PADDLE_Y = H - 36;
const PADDLE_SPEED = 9;
const BALL_R = 6;
const BRICK_TOP = 50;
const BRICK_ROWS = 5;
const BRICK_COLS = 10;
const BRICK_W = Math.floor(W / BRICK_COLS);
const BRICK_H = 18;
const ROW_COLORS = ["red", "orange", "yellow", "green", "blue"];

let paddle_x = W / 2 - PADDLE_W / 2;
let ball_x = W / 2;
let ball_y = H - 80;
let ball_dx = 3;
let ball_dy = -4;
let bricks = [];
let score = 0;
let lives = 3;
let high = nanopy.storage.get_int("breakout_js_high", 0);
let game_over = false;
let won = false;
let launched = false;
let left_held = false;
let right_held = false;

function reset_bricks() {
  bricks = [];
  for (let r = 0; r < BRICK_ROWS; r++) {
    for (let c = 0; c < BRICK_COLS; c++) {
      bricks.push({ col: c, row: r, alive: true, color: ROW_COLORS[r] });
    }
  }
}

function park_ball() {
  ball_x = paddle_x + PADDLE_W / 2;
  ball_y = PADDLE_Y - BALL_R - 1;
  ball_dx = 3;
  ball_dy = -4;
  launched = false;
}

function reset_game() {
  score = 0;
  lives = 3;
  game_over = false;
  won = false;
  reset_bricks();
  park_ball();
  nanopy.set_text("score", 0);
  nanopy.set_text("lives", 3);
  nanopy.status("Space to launch. Arrows (or A/D) to move.", "ok");
}

function brick_at(col, row) {
  if (col < 0 || col >= BRICK_COLS || row < 0 || row >= BRICK_ROWS) return null;
  const b = bricks[row * BRICK_COLS + col];
  return b.alive ? b : null;
}

function bounce_off_paddle() {
  const offset = ball_x - (paddle_x + PADDLE_W / 2);
  ball_dx = Math.max(-5, Math.min(5, Math.floor(offset / 8)));
  ball_dy = -Math.abs(ball_dy);
  if (ball_dy > -3) ball_dy = -3;
}

function handle_brick_hits() {
  if (ball_y - BALL_R > BRICK_TOP + BRICK_ROWS * BRICK_H) return;
  if (ball_y + BALL_R < BRICK_TOP) return;
  const c = Math.floor(ball_x / BRICK_W);
  const r = Math.floor((ball_y - BRICK_TOP) / BRICK_H);
  const b = brick_at(c, r);
  if (b == null) return;
  b.alive = false;
  score += 10;
  nanopy.set_text("score", score);
  const prev_c = Math.floor((ball_x - ball_dx) / BRICK_W);
  const prev_r = Math.floor((ball_y - ball_dy - BRICK_TOP) / BRICK_H);
  if (prev_r !== r) ball_dy = -ball_dy;
  else if (prev_c !== c) ball_dx = -ball_dx;
  else {
    ball_dy = -ball_dy;
    ball_dx = -ball_dx;
  }
}

function update() {
  if (game_over || won) return;

  if (left_held) paddle_x -= PADDLE_SPEED;
  if (right_held) paddle_x += PADDLE_SPEED;
  if (paddle_x < 0) paddle_x = 0;
  if (paddle_x > W - PADDLE_W) paddle_x = W - PADDLE_W;

  if (!launched) {
    ball_x = paddle_x + PADDLE_W / 2;
    return;
  }

  ball_x += ball_dx;
  ball_y += ball_dy;

  if (ball_x < BALL_R) {
    ball_x = BALL_R;
    ball_dx = -ball_dx;
  } else if (ball_x > W - BALL_R) {
    ball_x = W - BALL_R;
    ball_dx = -ball_dx;
  }
  if (ball_y < BALL_R) {
    ball_y = BALL_R;
    ball_dy = -ball_dy;
  }

  if (
    ball_y + BALL_R >= PADDLE_Y &&
    ball_y - BALL_R <= PADDLE_Y + PADDLE_H &&
    paddle_x <= ball_x &&
    ball_x <= paddle_x + PADDLE_W &&
    ball_dy > 0
  ) {
    bounce_off_paddle();
  }

  handle_brick_hits();

  if (ball_y > H) {
    lives--;
    nanopy.set_text("lives", lives);
    if (lives <= 0) {
      game_over = true;
      if (score > high) {
        high = score;
        nanopy.set_text("high", score);
        nanopy.storage.set_int("breakout_js_high", score);
      }
      nanopy.status("Game over. Press R to play again.", "err");
      return;
    }
    park_ball();
  }

  if (!bricks.some((b) => b.alive)) {
    won = true;
    if (score > high) {
      high = score;
      nanopy.set_text("high", score);
      nanopy.storage.set_int("breakout_js_high", score);
    }
    nanopy.status("All bricks cleared! Press R to play again.", "ok");
  }
}

function draw() {
  screen.fill("dark");
  for (const b of bricks) {
    if (!b.alive) continue;
    const bx = b.col * BRICK_W;
    const by = BRICK_TOP + b.row * BRICK_H;
    screen.rect(bx + 1, by + 1, BRICK_W - 2, BRICK_H - 2, b.color);
  }
  screen.rounded_rect(paddle_x, PADDLE_Y, PADDLE_W, PADDLE_H, 4, "blue");
  screen.rect(ball_x - BALL_R, ball_y - BALL_R, BALL_R * 2, BALL_R * 2, "white");
  if (game_over) {
    screen.rect(0, H / 2 - 50, W, 100, "rgba(0, 0, 0, 0.78)");
    screen.text("Game over", W / 2, H / 2 - 10, "white", 28, "center", "middle", true);
    screen.text(
      `Score ${score}. Press R to play again`,
      W / 2,
      H / 2 + 18,
      "gray",
      14,
      "center",
      "middle",
    );
  } else if (won) {
    screen.rect(0, H / 2 - 50, W, 100, "rgba(0, 0, 0, 0.78)");
    screen.text("Cleared!", W / 2, H / 2 - 10, "yellow", 28, "center", "middle", true);
    screen.text(
      `Score ${score}. Press R for another round`,
      W / 2,
      H / 2 + 18,
      "gray",
      14,
      "center",
      "middle",
    );
  }
}

function on_press(key) {
  if (game_over || won) {
    if (key === "r" || key === "R") reset_game();
    return;
  }
  if (key === "ArrowLeft" || key === "a" || key === "A") {
    left_held = true;
    right_held = false;
  } else if (key === "ArrowRight" || key === "d" || key === "D") {
    right_held = true;
    left_held = false;
  } else if (key === " " && !launched) {
    launched = true;
  } else if (key === "r" || key === "R") {
    reset_game();
  }
}

nanopy.set_text("high", high);
reset_game();
nanopy.run({ update, draw, on_press, fps: 45 });
