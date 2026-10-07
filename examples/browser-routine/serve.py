#!/usr/bin/env python3
"""Serve only the synthetic catalog on loopback; never serves local files."""
import argparse
import html
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

DATA = json.loads(Path(__file__).with_name("data.json").read_text())


def page_html(snapshot, page):
    cards = []
    for row in DATA[snapshot][(page - 1) * 2:page * 2]:
        safe = {k: html.escape(v) for k, v in row.items()}
        cards.append(f'''<article class="card" data-id="{safe['id']}">
<span class="identifier">{safe['id']}</span>
<h2><a href="/?snapshot={snapshot}&amp;page={page}#{safe['id']}">{safe['title']}</a></h2>
<p class="company">{safe['track']}</p><span class="badge">{safe['status']}</span></article>''')
    next_link = f'<a id="next" href="/?snapshot={snapshot}&amp;page=2">Next page →</a>' if page == 1 else '<p id="end">End of catalog</p>'
    return f'''<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Workshop Watch — Context Desk demo</title>
<style>body{{font:18px system-ui;max-width:780px;margin:60px auto;padding:0 24px;color:#242a32;background:#f5f6f8}}h1{{font-size:42px;letter-spacing:-1.5px}}.eyebrow,.identifier{{font-size:13px;color:#606978}}.card{{background:white;border:1px solid #e1e4e8;border-radius:14px;padding:24px;margin:16px 0}}h2{{margin:10px 0;font-size:24px}}a{{color:#244fba;text-decoration:none}}.badge{{background:#edf1fa;border-radius:6px;padding:4px 9px;font-size:14px}}footer{{margin-top:28px;color:#606978;font-size:14px}}</style>
<div class="eyebrow">CONTEXT DESK · SYNTHETIC DEMO</div><h1>Workshop Watch</h1>
<p>Snapshot {snapshot} · Page {page} of 2 · 4 fictional workshops</p>
<main>{''.join(cards)}</main><nav>{next_link}</nav>
<footer>Local fixture. No accounts, bookings, tracking, or external requests.</footer></html>'''


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlsplit(self.path)
        values = parse_qs(parsed.query)
        snapshot = values.get("snapshot", ["1"])[0]
        page = values.get("page", ["1"])[0]
        if parsed.path != "/" or snapshot not in DATA or page not in ("1", "2"):
            self.send_error(404)
            return
        body = page_html(snapshot, int(page)).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"Workshop Watch: http://127.0.0.1:{server.server_port}/?snapshot=1", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
