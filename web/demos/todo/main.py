"""TodoMVC demo — Python-dominant, persistent wasm + js bridge.

main.py owns the todo list, the filter state, the localStorage round-trip,
and DOM rendering. JS owns only the wasm loader and a delegated click
handler on the <ul> that surfaces the clicked li's data-id and action
("toggle" / "delete") into Python via window globals (the standard
globals-stash workaround for the bridge's dropped-args caveat).

localStorage round-trip: the bridge does NOT marshal native Python dicts to
JS objects, so we hand-roll JSON for the todo list (list of {id, text,
done} dicts). We also hand-roll a tiny parser on load to avoid having to
walk a JsProxy chain.
"""

import js

STORAGE_KEY = "nanopython-todos"


# ---------------------------------------------------------------------------
# DOM helpers
# ---------------------------------------------------------------------------


def _g(idn):
    return js.document.getElementById(idn)


def _set_text(el, text):
    el.textContent = text


# ---------------------------------------------------------------------------
# JSON serialise / parse — hand-rolled because the bridge does not marshal
# native dicts to JS objects, and walking a JsProxy from js.JSON.parse is
# more code than a 25-line parser for this shape.
# ---------------------------------------------------------------------------


def _quote_str(s):
    """JSON-quote a Python string (escape \\ and ")."""
    esc = s.replace(chr(92), chr(92) + chr(92)).replace(chr(34), chr(92) + chr(34))
    return chr(34) + esc + chr(34)


def _todo_to_json(t):
    return (
        "{"
        + _quote_str("id")
        + ":"
        + str(t["id"])
        + ","
        + _quote_str("text")
        + ":"
        + _quote_str(t["text"])
        + ","
        + _quote_str("done")
        + ":"
        + ("true" if t["done"] else "false")
        + "}"
    )


def todos_to_json(todos):
    parts = []
    for t in todos:
        parts.append(_todo_to_json(t))
    return "[" + ",".join(parts) + "]"


def _parse_string(s, i):
    """Parse a JSON string starting at s[i]==chr(34). Returns (value, new_i)."""
    i += 1  # skip opening "
    out = []
    while i < len(s):
        c = s[i]
        if c == chr(92):  # backslash — only \" and \\ are emitted by us
            out.append(s[i + 1])
            i += 2
        elif c == chr(34):
            return "".join(out), i + 1
        else:
            out.append(c)
            i += 1
    return "".join(out), i


def _parse_int(s, i):
    start = i
    if s[i] == "-":
        i += 1
    while i < len(s) and s[i].isdigit():
        i += 1
    return int(s[start:i]), i


def _skip_ws(s, i):
    while i < len(s) and s[i] in " \t\n\r":
        i += 1
    return i


def parse_todos(s):
    """Parse the JSON we emit in todos_to_json. Tolerant of empty/garbage."""
    if not s:
        return []
    i = _skip_ws(s, 0)
    if i >= len(s) or s[i] != "[":
        return []
    i += 1
    out = []
    while True:
        i = _skip_ws(s, i)
        if i >= len(s):
            return []
        if s[i] == "]":
            return out
        # one object: {"id":N,"text":"...","done":true|false}
        if s[i] != "{":
            return []
        i += 1
        item = {"id": 0, "text": "", "done": False}
        while True:
            i = _skip_ws(s, i)
            if i >= len(s) or s[i] == "}":
                break
            key, i = _parse_string(s, i)
            i = _skip_ws(s, i)
            if i >= len(s) or s[i] != ":":
                return []
            i = _skip_ws(s, i + 1)
            if key == "text":
                val, i = _parse_string(s, i)
                item["text"] = val
            elif key == "id":
                val, i = _parse_int(s, i)
                item["id"] = val
            elif key == "done":
                if s[i : i + 4] == "true":
                    item["done"] = True
                    i += 4
                else:
                    item["done"] = False
                    i += 5  # "false"
            i = _skip_ws(s, i)
            if i < len(s) and s[i] == ",":
                i += 1
        if i >= len(s) or s[i] != "}":
            return []
        i += 1
        out.append(item)
        i = _skip_ws(s, i)
        if i < len(s) and s[i] == ",":
            i += 1


# ---------------------------------------------------------------------------
# TodoList — top-level container. Individual todos stay as plain dicts
# {id, text, done}.
# ---------------------------------------------------------------------------


class TodoList:
    def __init__(self):
        self.todos = []
        self.filter = "all"  # one of "all" / "active" / "completed"
        self.next_id = 1

    def add(self, text):
        text = text.strip()
        if not text:
            return
        self.todos.append({"id": self.next_id, "text": text, "done": False})
        self.next_id += 1
        self.save()

    def toggle(self, todo_id):
        for t in self.todos:
            if t["id"] == todo_id:
                t["done"] = not t["done"]
                break
        self.save()

    def delete(self, todo_id):
        self.todos = [t for t in self.todos if t["id"] != todo_id]
        self.save()

    def clear_completed(self):
        self.todos = [t for t in self.todos if not t["done"]]
        self.save()

    def set_filter(self, f):
        self.filter = f

    def visible(self):
        f = self.filter
        if f == "active":
            return [t for t in self.todos if not t["done"]]
        if f == "completed":
            return [t for t in self.todos if t["done"]]
        return self.todos

    def active_count(self):
        n = 0
        for t in self.todos:
            if not t["done"]:
                n += 1
        return n

    def has_completed(self):
        for t in self.todos:
            if t["done"]:
                return True
        return False

    def save(self):
        # todos_to_json is pure string work and the bridge does not raise
        # into Python, so there is nothing here to catch.
        store = js.window.localStorage
        if store._h == 0:
            return
        store.setItem(STORAGE_KEY, todos_to_json(self.todos))

    def load(self):
        store = js.window.localStorage
        if store._h == 0:
            return
        v = store.getItem(STORAGE_KEY).to_str()
        if not v or v in ("null", "undefined"):
            return
        try:
            todos = parse_todos(v)
        except (ValueError, IndexError):
            # Corrupt stored payload: _parse_int does int("") on a malformed
            # number and indexes past the end. Keep whatever is in memory.
            return
        self.todos = todos
        max_id = 0
        for t in todos:
            if t["id"] > max_id:
                max_id = t["id"]
        self.next_id = max_id + 1


TODOS = TodoList()


# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------


def render():
    ul = _g("list")
    ul.innerHTML = ""
    visible = TODOS.visible()
    if not visible:
        li = js.document.createElement("li")
        li.className = "empty-msg"
        msg = "No todos yet. Add one above."
        if TODOS.filter == "active":
            msg = "Nothing active. Nice."
        elif TODOS.filter == "completed":
            msg = "Nothing completed yet."
        _set_text(li, msg)
        ul.appendChild(li)
    else:
        for t in visible:
            li = js.document.createElement("li")
            li.dataset.id = str(t["id"])
            if t["done"]:
                li.className = "done"
            cb = js.document.createElement("input")
            cb.type = "checkbox"
            cb.checked = t["done"]
            span = js.document.createElement("span")
            span.className = "label"
            _set_text(span, t["text"])
            btn = js.document.createElement("button")
            btn.type = "button"
            btn.className = "delete"
            _set_text(btn, "Delete")
            li.appendChild(cb)
            li.appendChild(span)
            li.appendChild(btn)
            ul.appendChild(li)

    # Counter: number of active (not-done) todos.
    active = TODOS.active_count()
    label = "1 item left" if active == 1 else (str(active) + " items left")
    _set_text(_g("count"), label)

    # Filter button active class.
    for name in ("all", "active", "completed"):
        btn = js.document.querySelector(
            ".filter-btn[data-filter=" + chr(34) + name + chr(34) + "]"
        )
        if TODOS.filter == name:
            btn.classList.add("active")
        else:
            btn.classList.remove("active")


# ---------------------------------------------------------------------------
# Handlers
# ---------------------------------------------------------------------------


def on_add(*_):
    inp = _g("new-todo")
    TODOS.add(inp.value.to_str())
    inp.value = ""
    render()


def on_action():
    """Invoked by app.js after stashing the row's data-id and action on
    window — see app.js for the delegated click handler."""
    tid = int(js.window._todoId.to_str())
    action = js.window._todoAction.to_str()
    if action == "toggle":
        TODOS.toggle(tid)
    elif action == "delete":
        TODOS.delete(tid)
    render()


def make_filter_handler(name):
    def handler(*_):
        TODOS.set_filter(name)
        render()

    return handler


def on_clear_completed(*_):
    TODOS.clear_completed()
    render()


# ---------------------------------------------------------------------------
# Wire-up
# ---------------------------------------------------------------------------

TODOS.load()
render()

_g("add-btn").addEventListener("click", on_add)
_g("clear-completed").addEventListener("click", on_clear_completed)

for name in ("all", "active", "completed"):
    sel = ".filter-btn[data-filter=" + chr(34) + name + chr(34) + "]"
    js.document.querySelector(sel).addEventListener("click", make_filter_handler(name))

# Globals-stash callback for the delegated click handler in app.js.
js.window.set("_py_action", on_action)

# Enable input + add button now that handlers are wired.
_g("new-todo").disabled = False
_g("add-btn").disabled = False

status = _g("status")
_set_text(status, "Ready. Type a todo and press Add.")
status.classList.add("ok")
