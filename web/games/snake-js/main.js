// Snake — JavaScript version, using web/lib/nanopy.js.
// Mirror of web/snake-lite/main.py (kid-style Python).

import * as nanopy from "../../lib/nanopy.js";

const GRID = 20;
const CELL = 20;
const W = GRID * CELL;

const screen = nanopy.canvas("board");

let snake = [
  [10, 10],
  [9, 10],
  [8, 10],
];
let dx = 1,
  dy = 0;
let nextDx = 1,
  nextDy = 0;
let apple = [5, 5];
let score = 0;
let high = nanopy.storage.get_int("snake_js_high", 0);
let gameOver = false;

function spawnApple() {
  const body = new Set(snake.map((p) => p.join(",")));
  while (true) {
    const x = nanopy.randrange(GRID);
    const y = nanopy.randrange(GRID);
    if (!body.has(`${x},${y}`)) {
      apple = [x, y];
      return;
    }
  }
}

function reset() {
  snake = [
    [10, 10],
    [9, 10],
    [8, 10],
  ];
  dx = 1;
  dy = 0;
  nextDx = 1;
  nextDy = 0;
  score = 0;
  gameOver = false;
  nanopy.set_text("score", 0);
  spawnApple();
  nanopy.status("Use arrow keys or WASD to steer.", "ok");
}

function update() {
  if (gameOver) return;
  dx = nextDx;
  dy = nextDy;
  const [hx, hy] = snake[0];
  const nx = hx + dx,
    ny = hy + dy;

  if (nx < 0 || nx >= GRID || ny < 0 || ny >= GRID) {
    gameOver = true;
    nanopy.status("Game over — press R to restart.", "err");
    return;
  }

  const newHead = [nx, ny];
  const ate = newHead[0] === apple[0] && newHead[1] === apple[1];
  const check = ate ? snake : snake.slice(0, -1);
  if (check.some((p) => p[0] === newHead[0] && p[1] === newHead[1])) {
    gameOver = true;
    nanopy.status("Game over — press R to restart.", "err");
    return;
  }

  snake = [newHead, ...(ate ? snake : snake.slice(0, -1))];
  if (ate) {
    score++;
    nanopy.set_text("score", score);
    if (score > high) {
      high = score;
      nanopy.set_text("high", score);
      nanopy.storage.set_int("snake_js_high", score);
    }
    spawnApple();
  }
}

function draw() {
  screen.fill("dark");

  for (let i = 1; i < GRID; i++) {
    screen.line(i * CELL, 0, i * CELL, W, "#2a3650");
    screen.line(0, i * CELL, W, i * CELL, "#2a3650");
  }

  const [ax, ay] = apple;
  screen.rect(ax * CELL + 1, ay * CELL + 1, CELL - 2, CELL - 2, "pink");

  snake.forEach(([x, y], i) => {
    screen.rect(x * CELL + 1, y * CELL + 1, CELL - 2, CELL - 2, i === 0 ? "blue" : "green");
  });

  if (gameOver) {
    screen.rect(0, W / 2 - 50, W, 100, "rgba(0, 0, 0, 0.78)");
    screen.text("Game over", W / 2, W / 2 - 10, "white", 28, "center", "middle", true);
    screen.text(
      `Score ${score} — press R to restart`,
      W / 2,
      W / 2 + 18,
      "gray",
      14,
      "center",
      "middle",
    );
  }
}

function onPress(key) {
  if (gameOver) {
    if (key === "r" || key === "R") reset();
    return;
  }
  if (key === "ArrowUp" || key === "w" || key === "W") {
    if (!(dx === 0 && dy === 1)) {
      nextDx = 0;
      nextDy = -1;
    }
  } else if (key === "ArrowDown" || key === "s" || key === "S") {
    if (!(dx === 0 && dy === -1)) {
      nextDx = 0;
      nextDy = 1;
    }
  } else if (key === "ArrowLeft" || key === "a" || key === "A") {
    if (!(dx === 1 && dy === 0)) {
      nextDx = -1;
      nextDy = 0;
    }
  } else if (key === "ArrowRight" || key === "d" || key === "D") {
    if (!(dx === -1 && dy === 0)) {
      nextDx = 1;
      nextDy = 0;
    }
  } else if (key === "r" || key === "R") {
    reset();
  }
}

nanopy.set_text("high", high);
reset();
nanopy.run({ update, draw, on_press: onPress, fps: 7 });
