// 2048 — JS port. Same structure as the kid-style Python (procedural).
import * as nanopy from "../../lib/nanopy.js";

const screen = nanopy.canvas("board");

const N = 4;
const CELL = 90;
const GAP = 8;
const PAD = 8;
const W = N * CELL + (N + 1) * GAP + 2 * PAD - 2 * GAP;

const BG = "#1e293b";
const EMPTY = "#334155";
const TEXT_LIGHT = "#1a1b26";
const TEXT_DARK = "#e6e6e6";
const DIM = "#94a3b8";

const TILE_COLORS = {
  1: "#cdd6f4",
  2: "#b4c4e8",
  3: "#f5c2a7",
  4: "#f5b78a",
  5: "#f3a06b",
  6: "#e07b3a",
  7: "#fae3a4",
  8: "#f5d575",
  9: "#f0c449",
  10: "#ebb31a",
  11: "#f7768e",
};

let grid = new Array(N * N).fill(0);
let score = 0;
let high = nanopy.storage.get_int("g2048_js_high", 0);
let over = false;
let won = false;

function slide_row(row) {
  const tight = row.filter((v) => v !== 0);
  const out = [];
  let gained = 0;
  for (let i = 0; i < tight.length; ) {
    if (i + 1 < tight.length && tight[i] === tight[i + 1]) {
      const merged = tight[i] * 2;
      out.push(merged);
      gained += merged;
      i += 2;
    } else {
      out.push(tight[i++]);
    }
  }
  while (out.length < N) out.push(0);
  return [out, gained];
}

function slide_left(g) {
  let moved = false;
  let total = 0;
  const out = new Array(N * N).fill(0);
  for (let r = 0; r < N; r++) {
    const row = g.slice(r * N, (r + 1) * N);
    const [new_row, gained] = slide_row(row);
    total += gained;
    for (let c = 0; c < N; c++) out[r * N + c] = new_row[c];
    if (row.some((v, i) => v !== new_row[i])) moved = true;
  }
  return [out, moved, total];
}

function reverse_rows(g) {
  const out = new Array(N * N).fill(0);
  for (let r = 0; r < N; r++) for (let c = 0; c < N; c++) out[r * N + c] = g[r * N + (N - 1 - c)];
  return out;
}

function transpose(g) {
  const out = new Array(N * N).fill(0);
  for (let r = 0; r < N; r++) for (let c = 0; c < N; c++) out[c * N + r] = g[r * N + c];
  return out;
}

function slide_right(g) {
  const [rg, m, s] = slide_left(reverse_rows(g));
  return [reverse_rows(rg), m, s];
}

function slide_up(g) {
  const [rg, m, s] = slide_left(transpose(g));
  return [transpose(rg), m, s];
}

function slide_down(g) {
  const [rg, m, s] = slide_right(transpose(g));
  return [transpose(rg), m, s];
}

function spawn() {
  const empties = [];
  for (let i = 0; i < grid.length; i++) if (grid[i] === 0) empties.push(i);
  if (!empties.length) return;
  const pick = empties[nanopy.randrange(empties.length)];
  grid[pick] = nanopy.randrange(10) === 0 ? 4 : 2;
}

function any_move_possible() {
  if (grid.includes(0)) return true;
  for (let r = 0; r < N; r++) {
    for (let c = 0; c < N; c++) {
      const v = grid[r * N + c];
      if (c + 1 < N && grid[r * N + c + 1] === v) return true;
      if (r + 1 < N && grid[(r + 1) * N + c] === v) return true;
    }
  }
  return false;
}

function log2(v) {
  let k = 0,
    n = v;
  while (n > 1) {
    n = Math.floor(n / 2);
    k++;
  }
  return k;
}

function draw_tile(r, c, v) {
  const x = PAD + c * (CELL + GAP);
  const y = PAD + r * (CELL + GAP);
  if (v === 0) {
    screen.rounded_rect(x, y, CELL, CELL, 4, EMPTY);
    return;
  }
  screen.rounded_rect(x, y, CELL, CELL, 4, TILE_COLORS[log2(v)] || "#7aa2f7");
  const text_color = v < 512 ? TEXT_LIGHT : TEXT_DARK;
  let size = 36;
  if (v >= 100) size = 30;
  if (v >= 1000) size = 24;
  screen.text(String(v), x + CELL / 2, y + CELL / 2, text_color, size, "center", "middle", true);
}

function draw() {
  screen.fill(BG);
  for (let r = 0; r < N; r++) for (let c = 0; c < N; c++) draw_tile(r, c, grid[r * N + c]);
  if (won && !over) {
    screen.rect(0, W / 2 - 60, W, 120, "rgba(0, 0, 0, 0.78)");
    screen.text("You win!", W / 2, W / 2 - 10, TEXT_DARK, 32, "center", "middle", true);
    screen.text(
      "Press R to restart, or keep merging.",
      W / 2,
      W / 2 + 22,
      DIM,
      14,
      "center",
      "middle",
    );
  } else if (over) {
    screen.rect(0, W / 2 - 60, W, 120, "rgba(0, 0, 0, 0.78)");
    screen.text("Game over", W / 2, W / 2 - 10, TEXT_DARK, 32, "center", "middle", true);
    screen.text("Press R to restart.", W / 2, W / 2 + 22, DIM, 14, "center", "middle");
  }
}

function add_score(gained) {
  score += gained;
  nanopy.set_text("score", score);
  if (score > high) {
    high = score;
    nanopy.set_text("high", score);
    nanopy.storage.set_int("g2048_js_high", score);
  }
}

function reset() {
  grid = new Array(N * N).fill(0);
  score = 0;
  over = false;
  won = false;
  nanopy.set_text("score", 0);
  spawn();
  spawn();
  draw();
  nanopy.status("Use arrow keys or WASD to slide.", "ok");
}

const SLIDES = {
  ArrowLeft: slide_left,
  a: slide_left,
  A: slide_left,
  ArrowRight: slide_right,
  d: slide_right,
  D: slide_right,
  ArrowUp: slide_up,
  w: slide_up,
  W: slide_up,
  ArrowDown: slide_down,
  s: slide_down,
  S: slide_down,
};

function on_press(key) {
  if (over) {
    if (key === "r" || key === "R") reset();
    return;
  }
  if (key === "r" || key === "R") {
    reset();
    return;
  }
  const slide_fn = SLIDES[key];
  if (!slide_fn) return;
  const [new_grid, moved, gained] = slide_fn(grid);
  if (!moved) return;
  grid = new_grid;
  if (gained) add_score(gained);
  if (!won && grid.includes(2048)) {
    won = true;
    nanopy.status("2048 reached. Keep going or restart with R.", "ok");
  }
  spawn();
  if (!any_move_possible()) {
    over = true;
    nanopy.status("Game over — press R to restart.", "err");
  }
  draw();
}

nanopy.set_text("high", high);
reset();
nanopy.run({ on_press });
