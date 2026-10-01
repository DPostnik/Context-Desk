#!/usr/bin/env python3
"""Read a local profile while a cross-site iframe is busy; no user data is used."""
import argparse
import http.server
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import threading
import time

sys.dont_write_bytecode = True
RUNTIME = Path(os.environ.get('BROWSER_RUNTIME_UNDER_TEST', Path(__file__).parent)).resolve()
sys.path.insert(0, str(RUNTIME))
from install import ROOT, LOCK
from chrome_host import ChromeHost
from transport import StdioRPC
from broker import endpoint
import server

busy = threading.Event()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/busy':
            busy.set()
            body = b'ok'
        elif self.path == '/frame':
            body = b'''<p>Third-party frame</p><script>
setTimeout(async()=>{await fetch('/busy');setTimeout(()=>{const end=performance.now()+35000;
while(performance.now()<end){}},200)},1000)</script>'''
        elif self.path == '/interactive':
            body = b'''<button onclick="document.querySelector('#receipt').textContent='Marked once'">Mark fixture</button><p id="receipt"></p>'''
        else:
            body = ('''<!doctype html><title>Local profile</title>
<h1>Fixture profile</h1><main id="profile"><p>Visible biography</p><a href="/details">Profile details</a></main>
<div hidden>SECRET_HIDDEN</div><input type="password" value="SECRET_PASSWORD">
<div id="shadow"></div><div id="huge"></div><div id="unicode"></div>
<iframe src="http://localhost:''' + str(self.server.server_port) + '''/frame"></iframe>
<script>
const shadow=document.querySelector('#shadow').attachShadow({mode:'open'});
shadow.innerHTML='<p>Visible shadow biography</p>';
document.querySelector('#huge').textContent='x'.repeat(100000);
document.querySelector('#unicode').textContent='x'.repeat(23999)+String.fromCodePoint(0x1f600);
setInterval(()=>document.body.dataset.tick=Date.now(),10);
</script>''').encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--reproduce-legacy', action='store_true')
    args = parser.parse_args()
    fixture = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=fixture.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix='context-snapshot-smoke-') as temporary:
        root = Path(temporary)
        (root / 'runtime.json').write_bytes((ROOT / 'runtime.json').read_bytes())
        (root / ('chrome-devtools-' + LOCK['version'])).symlink_to(ROOT / ('chrome-devtools-' + LOCK['version']))
        host, clients = ChromeHost(root), []
        sequence = iter(range(100))
        try:
            host.ensure(seconds=30)
            def client():
                rpc = StdioRPC([sys.executable, '-B', str(RUNTIME / 'server.py'), '--root', str(root)]).start()
                clients.append(rpc)
                rpc.initialize_mcp(expected_server_version=server.VERSION)
                return rpc
            def call(rpc, tool, **arguments):
                result = rpc.rpc('tools/call', {'name': tool, 'arguments': arguments}, str(next(sequence)), time.monotonic_ns() + 80_000_000_000)
                assert not result.get('isError'), result
                return json.loads(result['content'][0]['text'])
            rpc = client()
            url = 'http://127.0.0.1:' + str(fixture.server_port)
            owned = call(rpc, 'browser_open', url=url + '/')
            assert busy.wait(5)
            time.sleep(0.4)
            started = time.monotonic()
            read = call(rpc, 'browser_snapshot', session=owned['session'], selector='#profile')
            elapsed = time.monotonic() - started
            assert elapsed < 5, elapsed
            assert 'Visible biography' in read['text'], read
            assert not read['complete'] and not read['interactiveUIDs'], read
            assert 'uid' not in json.dumps(read), read
            full = call(rpc, 'browser_snapshot', session=owned['session'])
            assert full['truncated'] and len(full['text']) <= 24000, full
            assert 'Visible shadow biography' in full['text'], full
            assert 'SECRET_' not in json.dumps(full), full
            assert full['visitedNodes'] <= 4000, full
            unicode_read = call(rpc, 'browser_snapshot', session=owned['session'], selector='#unicode')
            assert len(unicode_read['text']) == 24000 and unicode_read['text'].endswith('\ufffd')
            if args.reproduce_legacy:
                started = time.monotonic()
                result = rpc.rpc('tools/call', {'name': 'browser_snapshot', 'arguments': {
                    'session': owned['session'], 'mode': 'interactive'}}, str(next(sequence)), time.monotonic_ns() + 40_000_000_000)
                legacy_seconds = time.monotonic() - started
                assert result.get('isError') and 'deadline' in result['content'][0]['text'], result
                assert 24 <= legacy_seconds < 32, legacy_seconds
                print(json.dumps({'boundedReadSeconds': round(elapsed, 3), 'legacyTimeoutSeconds': round(legacy_seconds, 3), 'result': 'reproduced'}))
            else:
                other = client()
                action_url = url + '/interactive'
                second = call(other, 'browser_open', url=action_url)
                snapshot = call(other, 'browser_snapshot', session=second['session'], mode='interactive')
                uid = re.search(r'uid=(\S+) button "Mark fixture"', server.Browser.text(snapshot))
                assert uid, snapshot
                call(other, 'browser_action', session=second['session'], actionID='local-mark-once',
                     expectedURL=action_url, name='click', arguments={'uid': uid.group(1)})
                assert call(other, 'browser_verify', session=second['session'], selector='#receipt', text='Marked once')['verified']
                call(other, 'browser_close', session=second['session'])
                # The slow frame never fences the other client during bounded reads.
                again = call(rpc, 'browser_snapshot', session=owned['session'], selector='#profile')
                assert 'Visible biography' in again['text']
                assert not (root / 'executor-in-flight.json').exists()
                print(json.dumps({'result': 'passed', 'boundedReadSeconds': round(elapsed, 3),
                    'busyCrossSiteFrame': True, 'changingDOM': True, 'truncation': True,
                    'unicodeBoundary': True, 'shadowDOM': True, 'hiddenAndPasswordExcluded': True, 'explicitUIDAction': True,
                    'otherClientContinued': True, 'externalSitesOrMessages': False}))
        finally:
            for rpc in clients:
                rpc.close()
            deadline = time.monotonic() + 8
            while endpoint(root).exists() and time.monotonic() < deadline:
                time.sleep(0.1)
            host.close_created_for_test()
            fixture.shutdown()


if __name__ == '__main__':
    main()
