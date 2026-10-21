// nanopy.js — same API as nanopy.py, JavaScript edition.
// One file. Procedural API for kids (canvas, run, onPress callback);
// class/decorator-ish API for pros (Canvas, Ticker, onKey).

const _NAMED = {
  black: "#000000",
  white: "#ffffff",
  red: "#ff5252",
  green: "#9ece6a",
  blue: "#7aa2f7",
  yellow: "#f0c449",
  orange: "#f5a06b",
  purple: "#bb9af7",
  pink: "#f7768e",
  gray: "#94a3b8",
  grey: "#94a3b8",
  dark: "#1e293b",
  light: "#cdd6f4",
};

export function color(c) {
  if (Array.isArray(c) && c.length === 3) return `rgb(${c[0]},${c[1]},${c[2]})`;
  if (typeof c === "string") return _NAMED[c.toLowerCase()] || c;
  return String(c);
}

export class Canvas {
  constructor(elementId) {
    this._el = document.getElementById(elementId);
    this._ctx = this._el.getContext("2d");
    this.width = this._el.width;
    this.height = this._el.height;
  }
  fill(c) {
    this._ctx.fillStyle = color(c);
    this._ctx.fillRect(0, 0, this.width, this.height);
  }
  rect(x, y, w, h, c) {
    this._ctx.fillStyle = color(c);
    this._ctx.fillRect(x, y, w, h);
  }
  stroke_rect(x, y, w, h, c, width = 1) {
    this._ctx.strokeStyle = color(c);
    this._ctx.lineWidth = width;
    this._ctx.strokeRect(x, y, w, h);
  }
  line(x1, y1, x2, y2, c, width = 1) {
    this._ctx.strokeStyle = color(c);
    this._ctx.lineWidth = width;
    this._ctx.beginPath();
    this._ctx.moveTo(x1, y1);
    this._ctx.lineTo(x2, y2);
    this._ctx.stroke();
  }
  text(s, x, y, c = "white", size = 16, align = "left", baseline = "alphabetic", bold = false) {
    this._ctx.font = (bold ? "bold " : "") + size + "px system-ui";
    this._ctx.fillStyle = color(c);
    this._ctx.textAlign = align;
    this._ctx.textBaseline = baseline;
    this._ctx.fillText(s, x, y);
  }
  rounded_rect(x, y, w, h, r, c) {
    this._ctx.fillStyle = color(c);
    this._ctx.beginPath();
    this._ctx.moveTo(x + r, y);
    this._ctx.lineTo(x + w - r, y);
    this._ctx.arcTo(x + w, y, x + w, y + r, r);
    this._ctx.lineTo(x + w, y + h - r);
    this._ctx.arcTo(x + w, y + h, x + w - r, y + h, r);
    this._ctx.lineTo(x + r, y + h);
    this._ctx.arcTo(x, y + h, x, y + h - r, r);
    this._ctx.lineTo(x, y + r);
    this._ctx.arcTo(x, y, x + r, y, r);
    this._ctx.closePath();
    this._ctx.fill();
  }
}

export function canvas(elementId) {
  return new Canvas(elementId);
}

export function set_text(id, value) {
  document.getElementById(id).textContent = String(value);
}

export function status(message, kind = "") {
  const s = document.getElementById("status");
  s.textContent = message;
  s.classList.remove("err", "ok");
  if (kind) s.classList.add(kind);
}

export const storage = {
  get_int(key, defaultValue = 0) {
    try {
      const v = window.localStorage.getItem(key);
      if (v && v !== "null" && v !== "undefined") return parseInt(v, 10);
    } catch (e) {}
    return defaultValue;
  },
  set_int(key, value) {
    try {
      window.localStorage.setItem(key, String(value));
    } catch (e) {}
  },
};

export function randrange(n) {
  return Math.floor(Math.random() * n);
}
export function randint(a, b) {
  return a + randrange(b - a + 1);
}
export function choice(seq) {
  return seq[randrange(seq.length)];
}

// Key handling — same dispatcher serves both `on_key(...)` and `run({onPress})`.
const _keyHandlers = {};
window.addEventListener("keydown", (e) => {
  const fn = _keyHandlers[e.key];
  if (fn) {
    fn(e.key);
    e.preventDefault();
  }
});

export function on_key(keys, fn) {
  for (const k of Array.isArray(keys) ? keys : [keys]) _keyHandlers[k] = fn;
}

let _runHandle = null;

export function run({ update, draw, on_press, fps = 30 } = {}) {
  if (update || draw) {
    const interval = Math.max(16, Math.floor(1000 / fps));
    _runHandle = setInterval(() => {
      if (update) update();
      if (draw) draw();
    }, interval);
  }
  if (on_press) {
    // JS has no smallint floor — register a single catch-all keydown
    // handler that calls on_press with the actual key string.
    window.addEventListener("keydown", (e) => {
      if (!_keyHandlers[e.key]) on_press(e.key);
    });
  }
}

export function stop() {
  if (_runHandle) {
    clearInterval(_runHandle);
    _runHandle = null;
  }
}

export class Ticker {
  constructor(fn, ms) {
    this._fn = fn;
    this._ms = ms;
    this._handle = null;
  }
  start() {
    if (this._handle === null) this._handle = setInterval(this._fn, this._ms);
  }
  stop() {
    if (this._handle !== null) {
      clearInterval(this._handle);
      this._handle = null;
    }
  }
  set_interval(ms) {
    this._ms = ms;
    if (this._handle !== null) {
      this.stop();
      this.start();
    }
  }
}
