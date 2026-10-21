// nanopy-host.js — host-side JS helpers that nanopy.py (Python) calls.
//
// Why this is a separate file: every demo's app.js needs the same
// keydown / click listener and audio context. Hoisting them here means
// each per-demo app.js shrinks to "boot wasm + import this".
//
// Three concerns:
//   1. keydown dispatcher  — calls window["__np_key_" + e.key]?.()
//   2. click  dispatcher  — fills coords on window, then calls __np_click()
//   3. audio              — lazy AudioContext, beep(freq, ms), beep_at(...)

export function installKeydown() {
  window.addEventListener("keydown", (e) => {
    const cb = window["__np_key_" + e.key];
    if (typeof cb === "function") {
      cb();
      e.preventDefault();
    }
  });
}

export function installClick(canvasId) {
  const el = document.getElementById(canvasId);
  if (!el) return;
  el.addEventListener("click", (e) => {
    const rect = el.getBoundingClientRect();
    window.__np_click_x = Math.floor(e.clientX - rect.left);
    window.__np_click_y = Math.floor(e.clientY - rect.top);
    const cb = window.__np_click;
    if (typeof cb === "function") cb();
  });
}

// ── Audio ─────────────────────────────────────────────────────────────
//
// Browsers require a user gesture (click or keydown) before audio
// plays — we lazy-create the AudioContext on first call so the demo
// doesn't have to think about timing.

let _audio = null;

function _getAudio() {
  if (_audio === null) {
    const Ctor = window.AudioContext || window.webkitAudioContext;
    if (!Ctor) return null;
    _audio = new Ctor();
  }
  return _audio;
}

export function installAudio() {
  // Single-tone beep.
  window.__np_beep = (freq, ms, kind) => _beep_at(freq, ms, kind || "sine", 0);

  // Tone in a sequence — `delay_ms` from now.
  window.__np_beep_at = (freq, ms, kind, delay_ms) =>
    _beep_at(freq, ms, kind || "sine", delay_ms || 0);
}

function _beep_at(freq, ms, kind, delay_ms) {
  const ctx = _getAudio();
  if (!ctx) return;
  const start = ctx.currentTime + delay_ms / 1000;
  const end = start + ms / 1000;

  const osc = ctx.createOscillator();
  const gain = ctx.createGain();
  osc.type = kind;
  osc.frequency.value = freq;
  // Short attack + exponential decay so beeps don't click.
  gain.gain.setValueAtTime(0.0001, start);
  gain.gain.exponentialRampToValueAtTime(0.2, start + 0.005);
  gain.gain.exponentialRampToValueAtTime(0.0001, end);
  osc.connect(gain);
  gain.connect(ctx.destination);
  osc.start(start);
  osc.stop(end + 0.02);
}
