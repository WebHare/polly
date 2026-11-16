#!/usr/bin/env python3
"""Run: python3 /absolute/path/to/polly/scripts/preview-web.py

Loopback-only development preview with API-shaped fixtures and a real DOM suite.
Never included in the production bundle. Ctrl-C stops the server in finally.
"""
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit
import argparse

ROOT = Path(__file__).resolve().parents[1]
PUBLIC = ROOT / "Packages/PollyWeb/Sources/PollyWeb/Public"


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(PUBLIC), **kwargs)

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/__test__/reference.html":
            import re
            source = (ROOT / "doc/design/polly-web/source/Polly Animations.dc.html").read_text()
            svg = re.findall(r'<svg viewBox="-24 -18 248 248".*?</svg>', source, re.S)
            css = re.search(r"<style>(.*?)</style>", source, re.S)[1]
            html = '<!doctype html><link rel="stylesheet" href="/fonts.css"><style>' + css + '</style>'
            html += '<h1>Original Polly animation export</h1><div style="display:flex">'
            for mood, pose in zip(["OK", "Warning", "Critical", "Unreachable"], svg):
                html += '<section style="width:25%;background:#14213D;color:white"><h2>' + mood + '</h2>' + pose + '</section>'
            return self.send_bytes((html + '</div>').encode(), "text/html", reference=True)
        if path == "/__test__/dom.html":
            html = (PUBLIC / "index.html").read_text().replace('<script type="module" src="/app.mjs"></script>', '<script type="module" src="/__test__/dom-suite.mjs"></script>')
            html = html.replace("<main", '<p id="test-results">Running DOM tests...</p><main', 1)
            return self.send_bytes(html.encode(), "text/html")
        if path in ["/__test__/fixtures.mjs", "/__test__/dom-suite.mjs", "/__test__/preview.mjs"]:
            return self.send_bytes((ROOT / "scripts/web" / path.split("/")[-1]).read_bytes(), "application/javascript")
        if path == "/":
            html = (PUBLIC / "index.html").read_text().replace('<script type="module" src="/app.mjs"></script>', '<script type="module" src="/__test__/preview.mjs"></script>')
            return self.send_bytes(html.encode(), "text/html")
        return super().do_GET()

    def send_bytes(self, data, mime, reference=False):
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Security-Policy", "default-src 'self'; object-src 'none'; base-uri 'none'" + ("; style-src 'self' 'unsafe-inline'" if reference else ""))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"Preview: http://127.0.0.1:{server.server_port}/", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
