#!/usr/bin/env python3
"""Real bundled MCP, shared executor, isolated Chrome/profile, loopback pages only."""
import concurrent.futures
import http.server
import json
import os
from pathlib import Path
import sys
import subprocess
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


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = ('<!doctype html><title>Isolated client fixture</title><p id="owner">' + self.path.strip('/') + '</p>').encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def main():
    fixture = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=fixture.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix='context-browser-shared-smoke-') as temporary:
        root = Path(temporary)
        (root / 'runtime.json').write_bytes((ROOT / 'runtime.json').read_bytes())
        (root / ('chrome-devtools-' + LOCK['version'])).symlink_to(ROOT / ('chrome-devtools-' + LOCK['version']))
        host = ChromeHost(root)
        clients = []
        sequence = iter(range(100))
        try:
            host.ensure()
            def client():
                result = StdioRPC([sys.executable, '-B', str(RUNTIME / 'server.py'), '--root', str(root)]).start()
                clients.append(result)
                result.initialize_mcp(expected_server_version=server.VERSION)
                return result
            def call(c, name, **arguments):
                response = c.rpc('tools/call', {'name': name, 'arguments': arguments}, str(next(sequence)), time.monotonic_ns() + 85_000_000_000)
                assert not response.get('isError'), response
                return json.loads(response['content'][0]['text'])
            a, b = client(), client()
            url = 'http://127.0.0.1:' + str(fixture.server_port)
            first = call(a, 'browser_open', url=url + '/client-a')
            second = call(b, 'browser_open', url=url + '/client-b')
            assert first['session'] != second['session']
            # Upstream page IDs are client-local: verify actual page content,
            # rather than assuming that numeric IDs differ across transports.
            def verify(c, owned, label):
                result = call(c, 'browser_verify', session=owned['session'], selector='#owner', text=label)
                assert result['verified'], result
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                futures = [pool.submit(verify, a, first, 'client-a'), pool.submit(verify, b, second, 'client-b')]
                for future in futures:
                    future.result()
            call(a, 'browser_close', session=first['session'])
            verify(b, second, 'client-b')
            a.close()
            verify(b, second, 'client-b')
            call(b, 'browser_close', session=second['session'])
            b.close()
            deadline = time.monotonic() + 8
            while endpoint(root).exists():
                assert time.monotonic() < deadline, 'executor did not stop after disconnect'
                time.sleep(0.1)
            assert not (root / 'executor-in-flight.json').exists()
            processes = subprocess.check_output(['/bin/ps', '-Ao', 'pid=,args='], text=True)
            assert not any(str(root) in line and 'chrome-devtools-mcp.js' in line
                           for line in processes.splitlines()), 'owned upstream child was not reaped'
            print(json.dumps({'result': 'passed', 'clients': 2, 'simultaneousOwnedTabs': 2,
                'concurrentReads': 'serialized', 'closeAndDisconnectIsolation': True,
                'executorReleased': True, 'upstreamChildrenReaped': True, 'externalSitesOrSubmissions': False}))
        finally:
            for c in clients:
                c.close()
            host.close_created_for_test()
            fixture.shutdown()


if __name__ == '__main__':
    main()
