"""Calculator — integer-only, Python-dominant, persistent-wasm + bridge.

State machine owned by Python. The JS side only boots the wasm and
routes button clicks / keydown events into per-key zero-arg callbacks
installed on `window`. Division is integer division (`//`); overflow
or divide-by-zero shows `Error` until the next key clears it.

Smallint cap is 2^29 - 1 = 536_870_911 (9 digits). We cap typed
entries at 9 digits and wrap every arithmetic op in try/except so a
wrap or OverflowError surfaces as `Error` rather than silent corruption.
"""

import js

MAX_DIGITS = 9


class Calculator:
    def __init__(self):
        self.entry = "0"  # currently displayed value (string of digits, maybe "-")
        self.acc = 0  # left-hand side once an op is pending
        self.op = None  # "+", "-", "*", "/" or None
        self.just_applied = False  # true right after = or after pressing an op
        self.error = False  # latches until any key clears it

    def _entry_int(self):
        s = self.entry
        if s == "-" or s == "":
            return 0
        return int(s)

    def _set_result(self, n):
        s = str(n)
        if len(s.lstrip("-")) > MAX_DIGITS:
            self._set_error()
            return False
        self.entry = s
        return True

    def _set_error(self):
        self.error = True
        self.entry = "0"
        self.acc = 0
        self.op = None
        self.just_applied = False

    def _apply(self, op, a, b):
        try:
            if op == "+":
                return a + b
            if op == "-":
                return a - b
            if op == "*":
                return a * b
            if op == "/":
                if b == 0:
                    return None
                return a // b
        except OverflowError:
            return None
        return None

    def enter_digit(self, d):
        if self.error:
            self.error = False
            self.entry = "0"
        if self.just_applied:
            self.entry = "0"
            self.just_applied = False
        cur = self.entry
        if cur == "0":
            self.entry = d
        elif cur == "-0":
            self.entry = "-" + d
        elif len(cur.lstrip("-")) < MAX_DIGITS:
            self.entry = cur + d

    def apply_op(self, op):
        if self.error:
            return
        if self.op is not None and not self.just_applied:
            r = self._apply(self.op, self.acc, self._entry_int())
            if r is None or not self._set_result(r):
                self._set_error()
                return
            self.acc = r
        else:
            self.acc = self._entry_int()
        self.op = op
        self.just_applied = True

    def equals(self):
        if self.error or self.op is None:
            return
        r = self._apply(self.op, self.acc, self._entry_int())
        if r is None:
            self._set_error()
        else:
            self._set_result(r)
            self.acc = 0
            self.op = None
            self.just_applied = True

    def clear(self):
        self.entry = "0"
        self.acc = 0
        self.op = None
        self.just_applied = False
        self.error = False

    def clear_entry(self):
        self.error = False
        self.entry = "0"
        self.just_applied = False

    def negate(self):
        if self.error or self.entry == "0" or self.entry == "":
            return
        cur = self.entry
        self.entry = cur[1:] if cur.startswith("-") else "-" + cur

    def delete(self):
        if self.error:
            self.error = False
            self.entry = "0"
            return
        if self.just_applied:
            self.entry = "0"
            self.just_applied = False
            return
        cur = self.entry
        if len(cur) <= 1 or (len(cur) == 2 and cur.startswith("-")):
            self.entry = "0"
        else:
            self.entry = cur[:-1]

    def display(self):
        """Return current display text (or 'Error')."""
        if self.error:
            return "Error"
        return self.entry


CALC = Calculator()


def _g(idn):
    return js.document.getElementById(idn)


def _render():
    disp = _g("display")
    disp.textContent = CALC.display()
    if CALC.error:
        disp.classList.add("err")
    else:
        disp.classList.remove("err")


# Per-key zero-arg callbacks. Closures bind the digit / op string so
# the JS dispatcher can call by name (the bridge drops args).
def _mk_digit(d):
    def h(*_):
        CALC.enter_digit(d)
        _render()

    return h


def _mk_op(op):
    def h(*_):
        CALC.apply_op(op)
        _render()

    return h


def on_equals(*_):
    CALC.equals()
    _render()


def on_clear(*_):
    CALC.clear()
    _render()


def on_clear_entry(*_):
    CALC.clear_entry()
    _render()


def on_negate(*_):
    CALC.negate()
    _render()


def on_delete(*_):
    CALC.delete()
    _render()


for _d in "0123456789":
    js.window.set("__calc_" + _d, _mk_digit(_d))
js.window.set("__calc_+", _mk_op("+"))
js.window.set("__calc_-", _mk_op("-"))
js.window.set("__calc_*", _mk_op("*"))
js.window.set("__calc_/", _mk_op("/"))
js.window.set("__calc_=", on_equals)
js.window.set("__calc_C", on_clear)
js.window.set("__calc_CE", on_clear_entry)
js.window.set("__calc_NEG", on_negate)
js.window.set("__calc_DEL", on_delete)


_render()
_g("status").textContent = "Ready."
_g("status").classList.add("ok")
