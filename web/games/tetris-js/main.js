// Tetris — JS port (kid-style structure: module-level state).
import * as nanopy from "../../lib/nanopy.js";

const screen = nanopy.canvas("board");
const preview = nanopy.canvas("next");

const COLS = 10,
  ROWS = 20;
const CELL = 30;

const SHAPES = {
  1: [
    [
      [0, 1],
      [1, 1],
      [2, 1],
      [3, 1],
    ],
    [
      [2, 0],
      [2, 1],
      [2, 2],
      [2, 3],
    ],
    [
      [0, 2],
      [1, 2],
      [2, 2],
      [3, 2],
    ],
    [
      [1, 0],
      [1, 1],
      [1, 2],
      [1, 3],
    ],
  ],
  2: [
    [
      [1, 0],
      [2, 0],
      [1, 1],
      [2, 1],
    ],
    [
      [1, 0],
      [2, 0],
      [1, 1],
      [2, 1],
    ],
    [
      [1, 0],
      [2, 0],
      [1, 1],
      [2, 1],
    ],
    [
      [1, 0],
      [2, 0],
      [1, 1],
      [2, 1],
    ],
  ],
  3: [
    [
      [1, 0],
      [0, 1],
      [1, 1],
      [2, 1],
    ],
    [
      [1, 0],
      [1, 1],
      [2, 1],
      [1, 2],
    ],
    [
      [0, 1],
      [1, 1],
      [2, 1],
      [1, 2],
    ],
    [
      [1, 0],
      [0, 1],
      [1, 1],
      [1, 2],
    ],
  ],
  4: [
    [
      [1, 0],
      [2, 0],
      [0, 1],
      [1, 1],
    ],
    [
      [1, 0],
      [1, 1],
      [2, 1],
      [2, 2],
    ],
    [
      [1, 1],
      [2, 1],
      [0, 2],
      [1, 2],
    ],
    [
      [0, 0],
      [0, 1],
      [1, 1],
      [1, 2],
    ],
  ],
  5: [
    [
      [0, 0],
      [1, 0],
      [1, 1],
      [2, 1],
    ],
    [
      [2, 0],
      [1, 1],
      [2, 1],
      [1, 2],
    ],
    [
      [0, 1],
      [1, 1],
      [1, 2],
      [2, 2],
    ],
    [
      [1, 0],
      [0, 1],
      [1, 1],
      [0, 2],
    ],
  ],
  6: [
    [
      [0, 0],
      [0, 1],
      [1, 1],
      [2, 1],
    ],
    [
      [1, 0],
      [2, 0],
      [1, 1],
      [1, 2],
    ],
    [
      [0, 1],
      [1, 1],
      [2, 1],
      [2, 2],
    ],
    [
      [1, 0],
      [1, 1],
      [0, 2],
      [1, 2],
    ],
  ],
  7: [
    [
      [2, 0],
      [0, 1],
      [1, 1],
      [2, 1],
    ],
    [
      [1, 0],
      [1, 1],
      [1, 2],
      [2, 2],
    ],
    [
      [0, 1],
      [1, 1],
      [2, 1],
      [0, 2],
    ],
    [
      [0, 0],
      [1, 0],
      [1, 1],
      [1, 2],
    ],
  ],
};

const COLORS = {
  1: "blue",
  2: "yellow",
  3: "purple",
  4: "green",
  5: "pink",
  6: "#3b82f6",
  7: "orange",
};
const LINE_SCORES = [0, 40, 100, 300, 1200];

let board = new Array(COLS * ROWS).fill(0);
let piece = 0;
let rot = 0;
let px = 0;
let py = 0;
let next_piece = 0;
let score = 0;
let lines = 0;
let level = 1;
let paused = false;
let over = false;
let high = nanopy.storage.get_int("tetris_js_high", 0);
let interval = 800;
let ticker_handle = null;

function cells_for(p, r, ox, oy) {
  return SHAPES[p][r].map(([c, rr]) => [ox + c, oy + rr]);
}

function collides(p, r, ox, oy) {
  for (const [c, rr] of cells_for(p, r, ox, oy)) {
    if (c < 0 || c >= COLS || rr >= ROWS) return true;
    if (rr >= 0 && board[rr * COLS + c] !== 0) return true;
  }
  return false;
}

function new_piece() {
  return nanopy.randrange(7) + 1;
}

function spawn(p) {
  piece = p;
  rot = 0;
  px = 3;
  py = 0;
  if (collides(p, 0, 3, 0)) game_over();
}

function clear_lines() {
  let cleared = 0;
  const kept = [];
  for (let r = ROWS - 1; r >= 0; r--) {
    const row = board.slice(r * COLS, (r + 1) * COLS);
    if (row.includes(0)) kept.push(row);
    else cleared++;
  }
  const new_board = new Array(cleared * COLS).fill(0);
  for (let i = kept.length - 1; i >= 0; i--) new_board.push(...kept[i]);
  board = new_board;
  if (cleared) {
    const gained = LINE_SCORES[cleared] * level;
    score += gained;
    lines += cleared;
    nanopy.set_text("score", score);
    nanopy.set_text("lines", lines);
    if (score > high) {
      high = score;
      nanopy.set_text("high", high);
      nanopy.storage.set_int("tetris_js_high", high);
    }
    const new_level = 1 + Math.floor(lines / 10);
    if (new_level !== level) {
      level = new_level;
      nanopy.set_text("level", level);
      interval = Math.max(80, 800 - (new_level - 1) * 70);
      stop_ticker();
      start_ticker();
    }
  }
}

function lock_piece() {
  for (const [c, r] of cells_for(piece, rot, px, py)) {
    if (r >= 0 && r < ROWS && c >= 0 && c < COLS) board[r * COLS + c] = piece;
  }
  clear_lines();
  const nxt = next_piece;
  next_piece = new_piece();
  draw_next();
  spawn(nxt);
}

function move(dx) {
  if (over || paused || piece === 0) return;
  const nx = px + dx;
  if (!collides(piece, rot, nx, py)) {
    px = nx;
    draw();
  }
}

function rotate() {
  if (over || paused || piece === 0) return;
  const new_rot = (rot + 1) % 4;
  for (const kick of [0, -1, 1, -2, 2]) {
    if (!collides(piece, new_rot, px + kick, py)) {
      rot = new_rot;
      px += kick;
      draw();
      return;
    }
  }
}

function soft_drop() {
  if (over || paused || piece === 0) return;
  const ny = py + 1;
  if (collides(piece, rot, px, ny)) lock_piece();
  else {
    py = ny;
    score++;
    nanopy.set_text("score", score);
  }
  draw();
}

function hard_drop() {
  if (over || paused || piece === 0) return;
  let ny = py;
  while (!collides(piece, rot, px, ny + 1)) {
    ny++;
    score += 2;
  }
  py = ny;
  nanopy.set_text("score", score);
  lock_piece();
  draw();
}

function gravity() {
  if (over || paused) return;
  const ny = py + 1;
  if (collides(piece, rot, px, ny)) lock_piece();
  else py = ny;
  draw();
}

function game_over() {
  over = true;
  stop_ticker();
  draw();
  nanopy.status("Game over. Press R to restart.", "err");
}

function stop_ticker() {
  if (ticker_handle !== null) {
    clearInterval(ticker_handle);
    ticker_handle = null;
  }
}

function start_ticker() {
  ticker_handle = setInterval(gravity, interval);
}

function draw_next() {
  preview.fill("dark");
  if (next_piece === 0) return;
  const side = 26;
  const offset = (preview.width - 4 * side) / 2;
  for (const [c, r] of SHAPES[next_piece][0]) {
    preview.rect(
      offset + c * side + 1,
      offset + r * side + 1,
      side - 2,
      side - 2,
      COLORS[next_piece],
    );
  }
}

function draw() {
  screen.fill("dark");
  for (let i = 1; i < COLS; i++) screen.line(i * CELL, 0, i * CELL, ROWS * CELL, "#2a3650");
  for (let j = 1; j < ROWS; j++) screen.line(0, j * CELL, COLS * CELL, j * CELL, "#2a3650");
  if (!over && piece !== 0) {
    let ny = py;
    while (!collides(piece, rot, px, ny + 1)) ny++;
    if (ny !== py) {
      for (const [c, r] of cells_for(piece, rot, px, ny)) {
        if (r >= 0) screen.rect(c * CELL + 1, r * CELL + 1, CELL - 2, CELL - 2, "#3b4659");
      }
    }
  }
  for (let r = 0; r < ROWS; r++) {
    for (let c = 0; c < COLS; c++) {
      const v = board[r * COLS + c];
      if (v) screen.rect(c * CELL + 1, r * CELL + 1, CELL - 2, CELL - 2, COLORS[v]);
    }
  }
  if (piece !== 0) {
    for (const [c, r] of cells_for(piece, rot, px, py)) {
      if (r >= 0) screen.rect(c * CELL + 1, r * CELL + 1, CELL - 2, CELL - 2, COLORS[piece]);
    }
  }
  if (over) overlay("Game over", "Press R to restart.");
  else if (paused) overlay("Paused", "Press P to resume.");
}

function overlay(title, subtitle) {
  screen.rect(0, (ROWS * CELL) / 2 - 60, COLS * CELL, 120, "rgba(0, 0, 0, 0.78)");
  screen.text(
    title,
    (COLS * CELL) / 2,
    (ROWS * CELL) / 2 - 10,
    "white",
    28,
    "center",
    "middle",
    true,
  );
  screen.text(subtitle, (COLS * CELL) / 2, (ROWS * CELL) / 2 + 22, "gray", 14, "center", "middle");
}

function reset() {
  stop_ticker();
  board = new Array(COLS * ROWS).fill(0);
  score = 0;
  lines = 0;
  level = 1;
  paused = false;
  over = false;
  interval = 800;
  nanopy.set_text("score", 0);
  nanopy.set_text("lines", 0);
  nanopy.set_text("level", 1);
  next_piece = new_piece();
  draw_next();
  spawn(new_piece());
  draw();
  if (!over) {
    start_ticker();
    nanopy.status("Stack 'em up. Arrows to move; up rotates; space drops.", "ok");
  }
}

function on_press(key) {
  if (over) {
    if (key === "r" || key === "R") reset();
    return;
  }
  if (key === "ArrowLeft" || key === "a" || key === "A") move(-1);
  else if (key === "ArrowRight" || key === "d" || key === "D") move(1);
  else if (key === "ArrowUp" || key === "w" || key === "W" || key === "z" || key === "Z") rotate();
  else if (key === "ArrowDown" || key === "s" || key === "S") soft_drop();
  else if (key === " ") hard_drop();
  else if (key === "p" || key === "P") {
    paused = !paused;
    nanopy.status(paused ? "Paused. Press P to resume." : "Stack 'em up.", paused ? "" : "ok");
    draw();
  } else if (key === "r" || key === "R") reset();
}

nanopy.set_text("high", high);
reset();
nanopy.run({ on_press });
