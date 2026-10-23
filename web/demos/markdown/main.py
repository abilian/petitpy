"""Markdown editor — live preview via the ADR-006 js bridge.

Every textarea `input` event re-parses the source and writes the HTML
into the preview pane via `el.innerHTML = html`. Save / Load
round-trip the source through `js.window.localStorage`.
"""

import js

DEFAULT_TEXT = """# Markdown editor

A live preview powered by Python running in **WebAssembly**.

## Features

- Headers (one to three `#`)
- **Bold** and *italic* and `inline code`
- [Links](https://example.com) to anywhere
- Ordered and unordered lists
- Blockquotes and fenced code blocks

### Try editing

Every keystroke re-parses the source. Use *Save* to persist to
`localStorage`, then *Load* to restore later.

> "Programs must be written for people to read, and only incidentally
> for machines to execute."

1. Type in the left pane
2. Watch the right pane update
3. Click Save when you like it

```
def parse(source):
    return render(source)
```
"""


def escape_html(s):
    out = []
    for c in s:
        if c == "&":
            out.append("&amp;")
        elif c == "<":
            out.append("&lt;")
        elif c == ">":
            out.append("&gt;")
        elif c == '"':
            out.append("&quot;")
        else:
            out.append(c)
    return "".join(out)


def replace_pair(text, marker, open_tag, close_tag):
    """Alternate runs of `marker` become open/close tag pairs."""
    out, i, n, mlen, opn = [], 0, len(text), len(marker), True
    while i < n:
        if text[i : i + mlen] == marker:
            out.append(open_tag if opn else close_tag)
            opn = not opn
            i += mlen
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def parse_links(text):
    """[label](url) → <a href="url">label</a>. Inputs already escaped."""
    out, i, n = [], 0, len(text)
    while i < n:
        if text[i] == "[":
            close = text.find("]", i + 1)
            if close != -1 and close + 1 < n and text[close + 1] == "(":
                end = text.find(")", close + 2)
                if end != -1:
                    out.append(
                        '<a href="'
                        + text[close + 2 : end]
                        + '">'
                        + text[i + 1 : close]
                        + "</a>"
                    )
                    i = end + 1
                    continue
        out.append(text[i])
        i += 1
    return "".join(out)


def parse_inline(text):
    """Escape, then code-spans / bold / italic / links."""
    # Code spans first so their content isn't re-interpreted.
    spans, out, i, n = [], [], 0, len(text)
    while i < n:
        if text[i] == "`":
            end = text.find("`", i + 1)
            if end != -1:
                spans.append("<code>" + escape_html(text[i + 1 : end]) + "</code>")
                out.append("\x00" + str(len(spans) - 1) + "\x00")
                i = end + 1
                continue
        out.append(text[i])
        i += 1
    text = escape_html("".join(out))
    text = replace_pair(text, "**", "<strong>", "</strong>")
    text = replace_pair(text, "*", "<em>", "</em>")
    text = parse_links(text)
    for idx, html in enumerate(spans):
        text = text.replace("\x00" + str(idx) + "\x00", html)
    return text


def is_ordered(line):
    j = 0
    while j < len(line) and line[j].isdigit():
        j += 1
    return j > 0 and j + 1 < len(line) and line[j] == "." and line[j + 1] == " "


def strip_ordered(line):
    j = 0
    while j < len(line) and line[j].isdigit():
        j += 1
    return line[j + 2 :]


def render(source):
    lines = source.split("\n")
    out, i, n = [], 0, len(lines)
    while i < n:
        s = lines[i].lstrip()
        if s.startswith("```"):
            i += 1
            body = []
            while i < n and not lines[i].lstrip().startswith("```"):
                body.append(escape_html(lines[i]))
                i += 1
            i += 1
            out.append("<pre><code>" + "\n".join(body) + "</code></pre>")
        elif s.startswith("### "):
            out.append("<h3>" + parse_inline(s[4:]) + "</h3>")
            i += 1
        elif s.startswith("## "):
            out.append("<h2>" + parse_inline(s[3:]) + "</h2>")
            i += 1
        elif s.startswith("# "):
            out.append("<h1>" + parse_inline(s[2:]) + "</h1>")
            i += 1
        elif s.startswith(">"):
            body = []
            while i < n and lines[i].lstrip().startswith(">"):
                ln = lines[i].lstrip()[1:]
                if ln.startswith(" "):
                    ln = ln[1:]
                body.append(parse_inline(ln))
                i += 1
            out.append("<blockquote>" + " ".join(body) + "</blockquote>")
        elif s.startswith("- "):
            items = []
            while i < n and lines[i].lstrip().startswith("- "):
                items.append("<li>" + parse_inline(lines[i].lstrip()[2:]) + "</li>")
                i += 1
            out.append("<ul>" + "".join(items) + "</ul>")
        elif is_ordered(s):
            items = []
            while i < n and is_ordered(lines[i].lstrip()):
                items.append(
                    "<li>" + parse_inline(strip_ordered(lines[i].lstrip())) + "</li>"
                )
                i += 1
            out.append("<ol>" + "".join(items) + "</ol>")
        elif s == "":
            i += 1
        else:
            body = []
            while i < n:
                cs = lines[i].lstrip()
                if cs == "" or cs.startswith(("#", ">", "- ", "```")) or is_ordered(cs):
                    break
                body.append(parse_inline(lines[i]))
                i += 1
            out.append("<p>" + " ".join(body) + "</p>")
    return "\n".join(out)


# ---------------------------------------------------------------------------
# DOM wiring
# ---------------------------------------------------------------------------


def _g(idn):
    return js.document.getElementById(idn)


def set_status(text, kind=""):
    s = _g("status")
    s.textContent = text
    s.classList.remove("err")
    s.classList.remove("ok")
    if kind:
        s.classList.add(kind)


def update_preview(*_):
    src = _g("md-input").value.to_str()
    _g("md-preview").innerHTML = render(src)


def on_save(*_):
    js.window.localStorage.setItem("md", _g("md-input").value.to_str())
    set_status("Saved to localStorage.", "ok")


def on_load(*_):
    src = js.window.localStorage.getItem("md").to_str()
    if not src or src == "null":
        set_status("Nothing saved yet.", "err")
        return
    _g("md-input").value = src
    update_preview()
    set_status("Loaded from localStorage.", "ok")


_g("md-input").value = DEFAULT_TEXT
update_preview()

_g("md-input").addEventListener("input", update_preview)
_g("save-btn").addEventListener("click", on_save)
_g("load-btn").addEventListener("click", on_load)

_g("save-btn").disabled = False
_g("load-btn").disabled = False
set_status("Edit on the left; the preview updates on every keystroke.", "ok")
