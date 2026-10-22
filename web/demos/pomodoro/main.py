"""Pomodoro timer — Python state machine + setInterval tick.

One wasm instance per page load: this module reads the duration <input>
fields on Start, drives a 1 Hz tick via ``js.window.setInterval`` whose
callback decrements ``secs_left`` and advances the phase at zero, and
writes the MM:SS display, phase label, card border, document.title, and
session counter back through the ADR-006 ``js`` bridge.
"""

import js

LABEL = {"work": "Work", "short": "Short Break", "long": "Long Break"}
INPUT_ID = {"work": "work-min", "short": "short-min", "long": "long-min"}


def _g(idn):
    return js.document.getElementById(idn)


def _read_secs(phase):
    return _g(INPUT_ID[phase]).value.to_int() * 60


class PomodoroTimer:
    WORK = "work"
    SHORT = "short"
    LONG = "long"

    def __init__(self):
        self.phase = self.WORK
        self.secs_left = 25 * 60
        self.completed = 0
        self.running = False
        self.timer_id = None
        self.work_secs = 25 * 60
        self.short_secs = 5 * 60
        self.long_secs = 15 * 60

    def _stop_timer(self):
        if self.timer_id is not None:
            js.window.clearInterval(self.timer_id)
            self.timer_id = None

    def _next_phase(self):
        """Advance the state machine; long break every 4th completed work session."""
        if self.phase == self.WORK:
            self.completed += 1
            self.phase = self.LONG if self.completed % 4 == 0 else self.SHORT
        else:
            self.phase = self.WORK
        self.secs_left = _read_secs(self.phase)

    def tick(self):
        """Decrement secs_left; if 0, advance phase. Return True if display needs update."""
        if not self.running:
            return False
        self.secs_left -= 1
        if self.secs_left <= 0:
            self._next_phase()
        return True

    def start(self, work, short, long):
        """Read durations, set running, schedule tick."""
        if self.running:
            return
        self.work_secs = work
        self.short_secs = short
        self.long_secs = long
        if self.secs_left <= 0:
            self.secs_left = _read_secs(self.phase)
        self.running = True
        self.timer_id = js.window.setInterval(on_tick, 1000).to_int()

    def pause(self):
        """Clear timer."""
        if not self.running:
            return
        self.running = False
        self._stop_timer()

    def reset(self):
        """Stop + reset counters."""
        self.running = False
        self._stop_timer()
        self.phase = self.WORK
        self.completed = 0
        self.secs_left = _read_secs(self.WORK)

    def skip(self):
        """Advance to next phase immediately."""
        self._next_phase()

    def display(self):
        """MM:SS"""
        secs = self.secs_left
        m = secs // 60
        s = secs - m * 60
        ms = "0" + str(m) if m < 10 else str(m)
        ss = "0" + str(s) if s < 10 else str(s)
        return ms + ":" + ss

    def phase_label(self):
        return LABEL[self.phase]

    def phase_class(self):
        """work | short | long"""
        return self.phase


TIMER = PomodoroTimer()


def _render():
    _g("display").textContent = TIMER.display()
    _g("counter").textContent = "Pomodoros completed: " + str(TIMER.completed)
    _g("phase").textContent = TIMER.phase_label()
    card = _g("timer-card")
    for p in (PomodoroTimer.WORK, PomodoroTimer.SHORT, PomodoroTimer.LONG):
        card.classList.remove(p)
    card.classList.add(TIMER.phase_class())
    js.document.title = TIMER.display() + " " + TIMER.phase_label()
    _g("start-btn").disabled = TIMER.running
    _g("pause-btn").disabled = not TIMER.running


def on_tick(*_):
    if TIMER.tick():
        _render()


def on_start(*_):
    TIMER.start(
        _read_secs(PomodoroTimer.WORK),
        _read_secs(PomodoroTimer.SHORT),
        _read_secs(PomodoroTimer.LONG),
    )
    _render()


def on_pause(*_):
    TIMER.pause()
    _render()


def on_reset(*_):
    TIMER.reset()
    _render()


def on_skip(*_):
    TIMER.skip()
    _render()


# Wire-up (runs once on page load).
_g("start-btn").addEventListener("click", on_start)
_g("pause-btn").addEventListener("click", on_pause)
_g("reset-btn").addEventListener("click", on_reset)
_g("skip-btn").addEventListener("click", on_skip)

_render()
for bid in ("start-btn", "reset-btn", "skip-btn"):
    _g(bid).disabled = False
_g("status").textContent = "Ready. Press Start to begin a Pomodoro."
_g("status").classList.add("ok")
