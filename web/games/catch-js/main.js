// Catch — JS port of web/catch-lite/main.py (kid-style).
import * as nanopy from "../../lib/nanopy.js";

const screen = nanopy.canvas("board");
const W = screen.width;
const H = screen.height;

const PADDLE_W = 80;
const PADDLE_H = 14;
const PADDLE_Y = H - 30;
const PADDLE_SPEED = 12;
const FRUIT_R = 14;
const FRUIT_SPEED_START = 4;
const FRUIT_SPEED_MAX = 11;
const FRUIT_COLORS = ["red", "orange", "yellow", "green", "purple", "pink"];

let paddle_x = W / 2 - PADDLE_W / 2;
let fruit_x = W / 2;
let fruit_y = 0;
let fruit_color = "red";
let fruit_speed = FRUIT_SPEED_START;
let score = 0;
let misses = 0;
let high = nanopy.storage.get_int("catch_js_high", 0);
let game_over = false;
let left_held = false;
let right_held = false;

function reset_fruit() {
  fruit_x = nanopy.randint(FRUIT_R, W - FRUIT_R);
  fruit_y = -FRUIT_R;
  fruit_color = nanopy.choice(FRUIT_COLORS);
}

function reset_game() {
  score = 0;
  misses = 0;
  fruit_speed = FRUIT_SPEED_START;
  paddle_x = W / 2 - PADDLE_W / 2;
  game_over = false;
  reset_fruit();
  nanopy.set_text("score", 0);
  nanopy.set_text("misses", 0);
  nanopy.status("Use arrow keys (or A/D) to move the paddle.", "ok");
}

function update() {
  if (game_over) return;
  if (left_held) paddle_x -= PADDLE_SPEED;
  if (right_held) paddle_x += PADDLE_SPEED;
  if (paddle_x < 0) paddle_x = 0;
  if (paddle_x > W - PADDLE_W) paddle_x = W - PADDLE_W;

  fruit_y += fruit_speed;

  const caught_top = PADDLE_Y - FRUIT_R;
  if (fruit_y >= caught_top && fruit_y <= PADDLE_Y + PADDLE_H) {
    if (paddle_x <= fruit_x && fruit_x <= paddle_x + PADDLE_W) {
      score++;
      nanopy.set_text("score", score);
      if (score > high) {
        high = score;
        nanopy.set_text("high", score);
        nanopy.storage.set_int("catch_js_high", score);
      }
      if (fruit_speed < FRUIT_SPEED_MAX) fruit_speed++;
      reset_fruit();
      return;
    }
  }

  if (fruit_y > H) {
    misses++;
    nanopy.set_text("misses", misses);
    if (misses >= 3) {
      game_over = true;
      if (score > high) {
        high = score;
        nanopy.set_text("high", score);
        nanopy.storage.set_int("catch_js_high", score);
      }
      nanopy.status("Game over. Press R to play again.", "err");
      return;
    }
    reset_fruit();
  }
}

function draw() {
  screen.fill("dark");
  screen.line(0, PADDLE_Y + PADDLE_H + 4, W, PADDLE_Y + PADDLE_H + 4, "#2a3650");
  screen.rounded_rect(paddle_x, PADDLE_Y, PADDLE_W, PADDLE_H, 6, "blue");
  screen.rounded_rect(
    fruit_x - FRUIT_R,
    fruit_y - FRUIT_R,
    FRUIT_R * 2,
    FRUIT_R * 2,
    FRUIT_R / 2,
    fruit_color,
  );
  if (game_over) {
    screen.rect(0, H / 2 - 50, W, 100, "rgba(0, 0, 0, 0.78)");
    screen.text("Game over", W / 2, H / 2 - 10, "white", 28, "center", "middle", true);
    screen.text(
      `Caught ${score}. Press R to play again`,
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
  if (game_over) {
    if (key === "r" || key === "R") reset_game();
    return;
  }
  if (key === "ArrowLeft" || key === "a" || key === "A") {
    left_held = true;
    right_held = false;
  } else if (key === "ArrowRight" || key === "d" || key === "D") {
    right_held = true;
    left_held = false;
  } else if (key === " ") {
    left_held = false;
    right_held = false;
  } else if (key === "r" || key === "R") {
    reset_game();
  }
}

nanopy.set_text("high", high);
reset_game();
nanopy.run({ update, draw, on_press, fps: 30 });
