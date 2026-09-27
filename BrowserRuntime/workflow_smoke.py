#!/usr/bin/env python3
"""Matched local-fixture traversal: generic + snapshots versus compact static path."""
import http.server
import json
from pathlib import Path
import re
import sys
import tempfile
import threading
import time
from urllib.parse import parse_qs, urlparse

sys.dont_write_bytecode = True
from install import ROOT, LOCK
from server import Browser, Rejected


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        page = int(parse_qs(urlparse(self.path).query).get('page', ['1'])[0])
        cards = ''.join(f'''<article class="card" id="job-{page}-{i}">
            <a href="/job/{page}-{i}?signed={'x' * 2200}">Engineer {page}-{i}</a>
            <span class="company">Example</span><span class="location">Warsaw</span>
            <time>2026-09-27</time><p class="excerpt">React and TypeScript. Fixture data.</p></article>'''
            for i in range(20))
        html = f'''<!doctype html><title>Static workflow fixture</title>
            <style>.card{{height:240px}}</style>{cards}
            <a id="next" href="?page={page + 1}">Next fixture page</a>'''
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.end_headers()
        self.wfile.write(html.encode())

    def log_message(self, *_):
        pass


def main():
    fixture = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=fixture.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix='context-desk-workflow-check-') as temporary:
        root = Path(temporary)
        (root / 'runtime.json').write_bytes((ROOT / 'runtime.json').read_bytes())
        (root / ('chrome-devtools-' + LOCK['version'])).symlink_to(ROOT / ('chrome-devtools-' + LOCK['version']))
        browser = Browser(root)
        config = {'card': '.card', 'title': 'a', 'link': 'a', 'idAttribute': 'id',
                  'company': '.company', 'location': '.location', 'date': 'time',
                  'excerpt': '.excerpt', 'next': '#next'}
        runs = []
        try:
            url = f'http://127.0.0.1:{fixture.server_port}/'
            # Equal stable fixture content, alternating order; browser launch excluded.
            for iteration, fast in enumerate((False, True, True, False)):
                token = browser.open(url)['session']
                start = time.monotonic()
                initial_calls = browser.metrics['calls']
                first = browser.cards(token, config, expected_cards=20 if fast else None)
                response_bytes = len(json.dumps(first).encode())
                if fast:
                    second = browser.next(token, f'fixture-link-{iteration}', url, None, config,
                                          next_token=first['nextToken'])
                else:
                    snapshot = browser.native('take_snapshot', {'pageId': browser.page})
                    response_bytes += len(json.dumps(snapshot).encode())
                    uid = re.search(r'uid=(\S+) link "Next fixture page"', browser.text(snapshot)).group(1)
                    second = browser.next(token, f'fixture-link-{iteration}', url, uid, config)
                response_bytes += len(json.dumps(second).encode())
                seconds = time.monotonic() - start
                assert all(r['complete'] and not r['truncated'] and len(r['cards']) == 20 for r in (first, second))
                assert all(c['company'] == 'Example' and c['location'] == 'Warsaw'
                           and c['date'] == '2026-09-27' and c['excerpt'] == 'React and TypeScript. Fixture data.'
                           and c['url'].endswith('x' * 2200) for r in (first, second) for c in r['cards'])
                assert [c['id'] for c in second['cards']] == [f'job-2-{i}' for i in range(20)]
                if fast:
                    assert first['reason'] == second['reason'] == 'stable_expected_cards'
                rows = [first['cards'], second['cards']]
                if runs:
                    assert rows == runs[0]['cards'], 'Traversal changed card content or order'
                runs.append({'fast': fast, 'seconds': seconds, 'responseBytes': response_bytes,
                             'upstreamCalls': browser.metrics['calls'] - initial_calls, 'cards': rows})
                browser.close_session(token)

            token = browser.open(url)['session']
            first = browser.cards(token, config, expected_cards=20)
            browser.evaluate("() => {document.querySelector('#next').href='?page=9'; return true;}")
            try:
                browser.next(token, 'changed-link-01', url, None, config, next_token=first['nextToken'])
                raise AssertionError('Changed next link accepted')
            except Rejected as error:
                assert str(error) == 'pagination_link_changed'
            assert browser.evaluate('() => location.href') == url
            # Unsafe, ambiguous and disabled controls never receive a compact navigation token.
            for mutation in [
                "n.href='https://example.org/next'",
                "n.href='javascript:void(0)'",
                "n.href='?page=2';n.setAttribute('aria-disabled','true')",
                "n.removeAttribute('aria-disabled');n.after(n.cloneNode(true));n.nextElementSibling.href='?page=3'",
            ]:
                browser.evaluate("() => {const n=document.querySelector('#next');" + mutation + ";return true;}")
                assert browser.read(config)['nextLink'] is None
            browser.evaluate("() => {document.querySelectorAll('#next').forEach(n => n.href='?page=2');return true;}")
            assert browser.read(config)['nextLink']['url'] == url + '?page=2'
            browser.close_session(token)
            print(json.dumps({'result': 'passed', 'equalCards': 40, 'runs': [
                {k: v for k, v in r.items() if k != 'cards'} for r in runs],
                'limits': 'Local static fixture; no live site, agent tokens or end-to-end job speedup.'}, indent=2))
        finally:
            browser.stop()
            if browser.chrome:
                browser.chrome.close_created_for_test()
            fixture.shutdown()


if __name__ == '__main__':
    main()
