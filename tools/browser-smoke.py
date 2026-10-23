#!/usr/bin/env python3
"""Headless-Chromium browser smoke harness for petitpy demos.

Launches a page in headless Chromium, captures every console message
(log / warn / error / info / debug) plus uncaught page errors, and
exits non-zero if anything was logged at error level. Intended as a
greppable CI smoke for the web/ demos and projects/ci-build-monitor.

Two ways to point at a page:

  # 1. direct URL (you already serve it somewhere)
  python3 tools/browser-smoke.py http://localhost:8000/popup.html

  # 2. spin up an ephemeral http.server on a free port
  python3 tools/browser-smoke.py --serve web --page validation/
  python3 tools/browser-smoke.py --serve projects/ci-build-monitor --page popup.html

Static knobs:
  --wait MS                Idle settle after all steps run, before
                           --assert-text / --assert-no-text (default 3000).
  --wait-for TEXT          Block until TEXT appears in document.body.innerText
                           BEFORE any steps run (uses --wait as ceiling).
  --step-timeout MS        Per-step timeout (default 5000).
  --assert-text TEXT       Fail (exit 1) if TEXT is NOT in document.body.innerText.
  --assert-no-text TEXT    Fail (exit 1) if TEXT IS in document.body.innerText
                           (catches stuck "Loading" spinners).
  --screenshot PATH        Save a full-page screenshot to PATH.

Step primitives — executed in argv order, each repeatable:
  --click SEL              Click first element matching CSS selector SEL.
  --type SEL=TEXT          Type TEXT into the input matched by SEL.
  --select SEL=VALUE       Set <select> SEL to VALUE.
  --wait-for-text TEXT     Block until TEXT appears in body innerText.
  --wait-for-selector SEL  Block until CSS selector SEL is in the DOM.
  --eval JS                Evaluate JS in the page, print result as [eval] line.
  --sleep MS               Sleep MS milliseconds (between actions).

Output format (one event per line, greppable):
  [log]    hello from the page
  [error]  TypeError: foo is not a function
  [pageerror]  Uncaught ReferenceError: bar is not defined
  [step 1/4] click #settings-btn
  [eval]   {"foo":1}
  [body]   <document.body.innerText, after wait>
  [assert] missing text: 'Repositories'
  [assert] forbidden text present: 'Loading'

Exit codes:
  0  no [error] / [pageerror] events and all asserts passed
  1  at least one error captured or an assertion failed
  2  CLI / launch failure / step failure
"""

from __future__ import annotations

import argparse
import http.server
import socket
import socketserver
import subprocess
import sys
import threading
import time
from pathlib import Path

# Step flag names — used by both the argparse declarations and the
# second-pass argv walk that recovers cross-option order.
STEP_FLAGS = {
    "--click",
    "--type",
    "--select",
    "--wait-for-text",
    "--wait-for-selector",
    "--eval",
    "--sleep",
}


def _pick_free_port() -> int:
    """Ask the kernel for an unused TCP port and release it immediately."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _start_server(
    directory: Path,
) -> tuple[socketserver.TCPServer, int, threading.Thread]:
    """Spin up a ThreadingHTTPServer rooted at `directory` on a free port."""
    port = _pick_free_port()
    root = str(directory)

    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            super().__init__(*a, directory=root, **kw)

    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    return httpd, port, thread


def _start_serve_py(directory: Path) -> tuple[subprocess.Popen, int]:
    """Spawn `python3 serve.py PORT` from `directory` and wait until it binds.

    When the served dir ships its own serve.py (e.g. projects/ci-build-monitor
    which needs CORS-proxy support), use it instead of the inline http.server
    so localhost fetches to api.github.com / builds.sr.ht / gitlab.com can
    tunnel through the proxy.
    """
    port = _pick_free_port()
    proc = subprocess.Popen(
        [sys.executable, "serve.py", str(port)],
        cwd=str(directory),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    # Spin until the port accepts a connection or we give up.
    deadline = time.time() + 5.0
    while time.time() < deadline:
        if proc.poll() is not None:
            break  # server died — let downstream goto() report it
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return proc, port
        except OSError:
            time.sleep(0.1)
    return proc, port


def _collect_steps(argv: list[str]) -> list[tuple[str, str]]:
    """Walk argv preserving order; return [(flag, value), ...] for step flags.

    argparse loses cross-option order, so we recover it by re-scanning argv.
    Supports both '--flag value' and '--flag=value' forms.
    """
    steps: list[tuple[str, str]] = []
    i = 0
    while i < len(argv):
        tok = argv[i]
        if tok in STEP_FLAGS:
            if i + 1 >= len(argv):
                # argparse already errored on this; defensive guard.
                break
            steps.append((tok, argv[i + 1]))
            i += 2
            continue
        # --flag=value form
        eq = tok.find("=")
        if tok.startswith("--") and eq > 0 and tok[:eq] in STEP_FLAGS:
            steps.append((tok[:eq], tok[eq + 1 :]))
            i += 1
            continue
        i += 1
    return steps


def _split_kv(arg: str, flag: str) -> tuple[str, str]:
    """Split 'SELECTOR=VALUE' into (selector, value); error on missing '='."""
    eq = arg.find("=")
    if eq < 0:
        raise ValueError(f"{flag} expects SELECTOR=VALUE, got {arg!r}")
    return arg[:eq], arg[eq + 1 :]


def _describe(flag: str, value: str) -> str:
    """Short human description of a step for [step N/M] log line."""
    name = flag.lstrip("-")
    return f"{name} {value}"


def _run_step(page, flag: str, value: str, step_timeout: int) -> None:
    """Execute one step. Raises on failure; caller logs."""
    if flag == "--click":
        page.click(value, timeout=step_timeout)
    elif flag == "--type":
        sel, text = _split_kv(value, flag)
        page.fill(sel, text, timeout=step_timeout)
    elif flag == "--select":
        sel, val = _split_kv(value, flag)
        page.select_option(sel, value=val, timeout=step_timeout)
    elif flag == "--wait-for-text":
        page.wait_for_function(
            "needle => document.body && document.body.innerText.includes(needle)",
            arg=value,
            timeout=step_timeout,
        )
    elif flag == "--wait-for-selector":
        page.wait_for_selector(value, timeout=step_timeout)
    elif flag == "--eval":
        result = page.evaluate(value)
        # Flatten embedded newlines so `[eval]  ...` lives on a single
        # line — consumers (smoke tests) parse via `grep ^\[eval\]` and
        # multi-line results would only surface the leading whitespace.
        result_s = (
            "" if result is None else str(result).replace("\n", " ").replace("\r", " ")
        )
        print(f"[eval]  {result_s}")
    elif flag == "--sleep":
        page.wait_for_timeout(int(value))
    else:  # pragma: no cover — STEP_FLAGS gate prevents this
        raise ValueError(f"unknown step flag: {flag}")


def _run(
    url: str,
    wait_ms: int,
    wait_for: str | None,
    steps: list[tuple[str, str]],
    step_timeout: int,
    assert_text: list[str],
    assert_no_text: list[str],
    screenshot: str | None,
) -> int:
    """Drive headless Chromium, return exit code (0 clean, 1 errors/assert, 2 step)."""
    try:
        from playwright.sync_api import Error as PlaywrightError
        from playwright.sync_api import sync_playwright
    except ImportError:
        print(
            "[stderr] playwright not installed — run `make smoke-setup`",
            file=sys.stderr,
        )
        return 2

    errors: list[str] = []

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        try:
            page = browser.new_page()

            def on_console(msg):
                line = f"[{msg.type}]  {msg.text}"
                print(line)
                if msg.type == "error":
                    errors.append(line)

            def on_pageerror(exc):
                line = f"[pageerror]  {exc}"
                print(line)
                errors.append(line)

            page.on("console", on_console)
            page.on("pageerror", on_pageerror)

            page.goto(url, wait_until="load", timeout=max(wait_ms, 5000))

            if wait_for:
                # Initial pre-step gate — poll for literal text.
                page.wait_for_function(
                    "needle => document.body && document.body.innerText.includes(needle)",
                    arg=wait_for,
                    timeout=wait_ms,
                )

            total = len(steps)
            for idx, (flag, value) in enumerate(steps, 1):
                desc = _describe(flag, value)
                print(f"[step {idx}/{total}] {desc}")
                try:
                    _run_step(page, flag, value, step_timeout)
                except PlaywrightError as exc:
                    print(f"[step] FAILED at step {idx}: {desc}: {exc}")
                    return 2

            # Final settle before asserts.
            page.wait_for_timeout(wait_ms)

            # Dump rendered text so stuck-spinner / wrong-state pages are visible.
            body_text = page.evaluate("document.body ? document.body.innerText : ''")
            for ln in body_text.splitlines():
                print(f"[body]  {ln}")

            for needle in assert_text:
                if needle not in body_text:
                    line = f"[assert]  missing text: {needle!r}"
                    print(line)
                    errors.append(line)

            for needle in assert_no_text:
                if needle in body_text:
                    line = f"[assert]  forbidden text present: {needle!r}"
                    print(line)
                    errors.append(line)

            if screenshot:
                out = Path(screenshot).resolve()
                out.parent.mkdir(parents=True, exist_ok=True)
                page.screenshot(path=str(out), full_page=True)
                print(f"[stderr] screenshot saved: {out}", file=sys.stderr)
        finally:
            browser.close()

    return 1 if errors else 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(
        description="Headless Chromium smoke harness — captures console + page errors.",
    )
    ap.add_argument(
        "url",
        nargs="?",
        help="URL to load (omit if you use --serve).",
    )
    ap.add_argument(
        "--serve",
        metavar="DIR",
        help="Serve DIR over an ephemeral http.server, then target --page on it.",
    )
    ap.add_argument(
        "--page",
        metavar="PATH",
        help="Path under --serve to open (e.g. popup.html, validation/).",
    )
    ap.add_argument(
        "--wait",
        type=int,
        default=3000,
        metavar="MS",
        help="Idle settle after all steps run, before --assert-* (default 3000).",
    )
    ap.add_argument(
        "--wait-for",
        metavar="TEXT",
        help="Pre-step gate: block until TEXT appears in body innerText.",
    )
    ap.add_argument(
        "--step-timeout",
        type=int,
        default=5000,
        metavar="MS",
        help="Per-step timeout in milliseconds (default 5000).",
    )
    # Step flags — repeatable, executed in argv order. argparse stores them
    # but only _collect_steps() preserves cross-option ordering.
    ap.add_argument(
        "--click",
        metavar="SEL",
        action="append",
        default=[],
        help="Click CSS SEL (repeatable, ordered).",
    )
    ap.add_argument(
        "--type",
        metavar="SEL=TEXT",
        action="append",
        default=[],
        help="Type TEXT into input SEL (repeatable, ordered).",
    )
    ap.add_argument(
        "--select",
        metavar="SEL=VALUE",
        action="append",
        default=[],
        help="Set <select> SEL to VALUE (repeatable, ordered).",
    )
    ap.add_argument(
        "--wait-for-text",
        metavar="TEXT",
        action="append",
        default=[],
        help="Block until TEXT appears in body (repeatable, ordered).",
    )
    ap.add_argument(
        "--wait-for-selector",
        metavar="SEL",
        action="append",
        default=[],
        help="Block until SEL is in DOM (repeatable, ordered).",
    )
    ap.add_argument(
        "--eval",
        metavar="JS",
        action="append",
        default=[],
        help="Evaluate JS, print result as [eval] (repeatable, ordered).",
    )
    ap.add_argument(
        "--sleep",
        metavar="MS",
        action="append",
        default=[],
        help="Sleep MS milliseconds (repeatable, ordered).",
    )
    ap.add_argument(
        "--assert-text",
        metavar="TEXT",
        action="append",
        default=[],
        help="Fail unless TEXT appears in document.body.innerText (repeatable).",
    )
    ap.add_argument(
        "--assert-no-text",
        metavar="TEXT",
        action="append",
        default=[],
        help="Fail if TEXT appears in document.body.innerText (repeatable).",
    )
    ap.add_argument(
        "--screenshot",
        metavar="PATH",
        help="Save a full-page screenshot to PATH after the wait.",
    )
    args = ap.parse_args(argv)

    # Recover cross-option order for step flags by re-walking argv.
    steps = _collect_steps(argv)

    # Validate kv-shaped steps up front so we fail fast on CLI errors.
    for flag, value in steps:
        if flag in ("--type", "--select") and "=" not in value:
            ap.error(f"{flag} expects SELECTOR=VALUE, got {value!r}")
        if flag == "--sleep":
            try:
                int(value)
            except ValueError:
                ap.error(f"--sleep expects integer MS, got {value!r}")

    httpd = None
    serve_proc: subprocess.Popen | None = None
    try:
        if args.serve:
            if not args.page:
                ap.error("--serve requires --page")
            directory = Path(args.serve).resolve()
            if not directory.is_dir():
                print(f"[stderr] --serve dir not found: {directory}", file=sys.stderr)
                return 2
            # If the served dir ships a serve.py (CORS proxy / custom static
            # server), use it as a subprocess instead of the inline
            # http.server — extension pages that hit cross-origin APIs need
            # the proxy.
            serve_py = directory / "serve.py"
            if serve_py.is_file():
                serve_proc, port = _start_serve_py(directory)
                url = f"http://127.0.0.1:{port}/{args.page.lstrip('/')}"
                print(
                    f"[stderr] serving {directory} via serve.py on :{port} — targeting {url}",
                    file=sys.stderr,
                )
            else:
                httpd, port, _ = _start_server(directory)
                url = f"http://127.0.0.1:{port}/{args.page.lstrip('/')}"
                print(
                    f"[stderr] serving {directory} on :{port} — targeting {url}",
                    file=sys.stderr,
                )
        elif args.url:
            url = args.url
        else:
            ap.error("either URL or --serve/--page is required")

        return _run(
            url,
            args.wait,
            args.wait_for,
            steps,
            args.step_timeout,
            args.assert_text,
            args.assert_no_text,
            args.screenshot,
        )
    finally:
        if httpd is not None:
            httpd.shutdown()
            httpd.server_close()
        if serve_proc is not None:
            serve_proc.terminate()
            try:
                serve_proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                serve_proc.kill()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
