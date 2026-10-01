#!/usr/bin/env python3
"""Two owned Chrome processes, real MCP, local pages only; no model calls."""
import concurrent.futures
import http.server
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import threading
import time
import uuid

sys.dont_write_bytecode = True
RUNTIME = Path(os.environ.get('BROWSER_RUNTIME_UNDER_TEST', Path(__file__).parent)).resolve()
sys.path.insert(0, str(RUNTIME))
from install import ROOT, LOCK
from chrome_host import ChromeHost
from transport import StdioRPC
from broker import endpoint
import server

entered = threading.Event()
release = threading.Event()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('/slow'):
            entered.set()
            release.wait(15)
        label = 'A' if self.path.startswith('/a') else 'B'
        body = ('''<!doctype html><title>Parallel fixture</title>
<label>Value<input aria-label="Value" oninput="document.querySelector('#value').textContent=this.value"></label>
<p id="value"></p><p id="cookie"></p><p id="owner">''' + label + '''</p>
<script>const old=document.cookie; document.querySelector('#cookie').textContent=old||'empty';
document.cookie='owner=' + document.querySelector('#owner').textContent + ';path=/';</script>''').encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def main():
    fixture = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=fixture.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix='context-browser-parallel-') as temp:
        root = Path(temp)
        (root / 'runtime.json').write_bytes((ROOT / 'runtime.json').read_bytes())
        (root / ('chrome-devtools-' + LOCK['version'])).symlink_to(ROOT / ('chrome-devtools-' + LOCK['version']))
        ids = [str(uuid.uuid4()), str(uuid.uuid4())]
        roots = [root / 'environments' / value for value in ids]
        hosts, clients = [], []
        for path in roots:
            path.mkdir(parents=True)
        def client(index):
            c = StdioRPC([sys.executable, '-B', str(RUNTIME / 'server.py'), '--root', str(root),
                          '--environment', ids[index]], cwd=str(root)).start()
            clients.append(c)
            c.initialize_mcp(expected_server_version=server.VERSION)
            return c
        def raw(c, tool, **args):
            return c.rpc('tools/call', {'name': tool, 'arguments': args}, uuid.uuid4().hex,
                         time.monotonic_ns() + 80_000_000_000)
        def call(c, tool, **args):
            result = raw(c, tool, **args)
            assert not result.get('isError'), result
            return json.loads(result['content'][0]['text'])
        def verify(c, token, selector, text):
            assert call(c, 'browser_verify', session=token, selector=selector, text=text)['verified']
        try:
            # Own the parent process handles so cleanup cannot terminate a user browser.
            for path in roots:
                host = ChromeHost(path)
                hosts.append(host)
                host.ensure(seconds=25)
            assert hosts[0].owner['pid'] != hosts[1].owner['pid']
            assert hosts[0].owner['port'] != hosts[1].owner['port']
            a, b = client(0), client(1)
            base = 'http://127.0.0.1:' + str(fixture.server_port)
            one = call(a, 'browser_open', url=base + '/a')
            two = call(b, 'browser_open', url=base + '/b')
            verify(a, one['session'], '#cookie', 'empty')
            verify(b, two['session'], '#cookie', 'empty')
            assert raw(b, 'browser_snapshot', session=one['session'])['isError']
            def fill(c, opened, label):
                snap = call(c, 'browser_snapshot', session=opened['session'], mode='interactive')
                match = re.search(r'uid=(\S+) textbox "Value"', server.Browser.text(snap))
                assert match, snap
                call(c, 'browser_action', session=opened['session'], actionID='fill-' + label + '-once',
                     expectedURL=opened['url'], name='fill', arguments={'uid': match[1], 'value': label})
                verify(c, opened['session'], '#value', label)
            with concurrent.futures.ThreadPoolExecutor(2) as pool:
                futures = [pool.submit(fill, a, one, 'alpha'), pool.submit(fill, b, two, 'beta')]
                for future in futures:
                    future.result()
                slow = pool.submit(call, a, 'browser_action', session=one['session'], actionID='navigate-slow-once',
                                   expectedURL=one['url'], name='navigate_page', arguments={'type': 'url', 'url': base + '/slow'})
                assert entered.wait(10), 'First browser did not enter the slow navigation'
                try:
                    start = time.monotonic()
                    verify(b, two['session'], '#value', 'beta')
                    assert not slow.done(), 'Second browser waited for the first navigation'
                    parallel_seconds = time.monotonic() - start
                finally:
                    release.set()
                slow.result()
            # Disconnect A while an operation is pending: quarantine only A.
            with concurrent.futures.ThreadPoolExecutor(1) as pool:
                pending = pool.submit(raw, a, 'browser_verify', session=one['session'], selector='#absent', text='never', timeout=20)
                deadline = time.monotonic() + 5
                while not (roots[0] / 'executor-in-flight.json').exists():
                    assert time.monotonic() < deadline
                    time.sleep(.02)
                a.close()
                try:
                    pending.result()
                except Exception:
                    pass
            verify(b, two['session'], '#value', 'beta')
            assert (roots[0] / 'executor-in-flight.json').exists()
            assert not (roots[1] / 'executor-in-flight.json').exists()
            # B reconnects to the same profile; the old token is not transferred.
            b.close()
            b2 = client(1)
            assert raw(b2, 'browser_snapshot', session=two['session'])['isError']
            reopened = call(b2, 'browser_open', url=base + '/b')
            verify(b2, reopened['session'], '#cookie', 'owner=B')
            assert hosts[1].control()['running']
            assert not hosts[1].control(close=True)['running']
            assert hosts[0].child.poll() is None, 'Closing B terminated A'
            print(json.dumps({'result': 'passed', 'separateChromeProcesses': 2, 'concurrentFill': True,
                              'cookieIsolation': True, 'secondBrowserDuringBlockedNavigationSeconds': round(parallel_seconds, 3),
                              'disconnectFenceIsolation': True, 'profileRetained': True,
                              'explicitCloseIsolation': True, 'modelCalls': 0}))
        finally:
            release.set()
            for c in clients:
                c.close()
            for host in hosts:
                host.close_created_for_test()
            deadline = time.monotonic() + 8
            while any(endpoint(path).exists() for path in roots):
                assert time.monotonic() < deadline, 'Executor did not exit'
                time.sleep(.1)
            fixture.shutdown()


if __name__ == '__main__':
    main()
