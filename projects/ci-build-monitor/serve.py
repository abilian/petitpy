#!/usr/bin/env python3
"""Static file server + CORS proxy for standalone web-app mode.

In a real browser extension, `manifest.host_permissions` bypasses CORS so
fetches to builds.sr.ht / api.github.com / gitlab.com just work. But when
the extension pages are served from http://localhost:PORT/ as a plain
web-app (for local development and the browser-smoke harness), those
upstreams do not send Access-Control-Allow-Origin, so the browser blocks
the fetch with a TypeError / NetworkError.

This server is a drop-in replacement for `python3 -m http.server`:

  * Static files are served from the cwd, exactly like http.server.
  * Any GET to /proxy/<full-original-url> is fetched server-side via
    urllib and the response is mirrored back with
    `Access-Control-Allow-Origin: *` so the page-side fetch succeeds.

The provider modules (and the Test Connection button) detect that the
page origin is localhost and prepend "/proxy/" to the upstream URL.

Usage:
    python3 serve.py [PORT]      # defaults to 8000
"""

from __future__ import annotations

import http.server
import socketserver
import sys
import urllib.error
import urllib.request

PROXY_PREFIX = "/proxy/"


class CorsProxyHandler(http.server.SimpleHTTPRequestHandler):
    """SimpleHTTPRequestHandler + /proxy/<url> CORS-bypass passthrough."""

    def do_GET(self):
        if self.path.startswith(PROXY_PREFIX):
            self._do_proxy()
            return
        super().do_GET()

    def _do_proxy(self) -> None:
        # Everything after /proxy/ is the original URL. We keep it verbatim
        # (callers are expected to pass an already-valid URL) — quoting is
        # the caller's job.
        original = self.path[len(PROXY_PREFIX) :]
        if not original.startswith(("http://", "https://")):
            self.send_error(400, "proxy target must be http(s)")
            return

        try:
            with urllib.request.urlopen(original, timeout=15) as upstream:
                body = upstream.read()
                content_type = upstream.headers.get(
                    "Content-Type", "application/octet-stream"
                )
                status = upstream.status
        except urllib.error.HTTPError as exc:
            body = exc.read() if exc.fp is not None else b""
            content_type = (
                exc.headers.get("Content-Type", "text/plain")
                if exc.headers
                else "text/plain"
            )
            status = exc.code
        except urllib.error.URLError as exc:
            self.send_error(502, f"proxy fetch failed: {exc.reason}")
            return
        except Exception as exc:  # noqa: BLE001 — defensive
            self.send_error(502, f"proxy fetch failed: {exc}")
            return

        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.end_headers()


def main(argv: list[str]) -> int:
    port = int(argv[1]) if len(argv) > 1 else 8000
    with socketserver.ThreadingTCPServer(("", port), CorsProxyHandler) as httpd:
        httpd.allow_reuse_address = True
        print(f"serving on http://localhost:{port}/ (proxy at /proxy/<url>)")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
