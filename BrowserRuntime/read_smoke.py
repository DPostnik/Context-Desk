#!/usr/bin/env python3
"""Live check of browser_read refs and ref-targeted input on local fixtures; no user data or external sites."""
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
import cdp
import server

PAGE = '''<!doctype html><title>Read fixture</title>
<style>body{margin:0;font:16px sans-serif} #overlay{position:fixed;left:0;top:0;width:300px;height:120px;background:rgba(0,0,0,.4)}</style>
<header><nav><a href="/home">Home</a> <a href="/about">About us</a></nav></header>
<main><h1>Fixture shop</h1><p>Welcome to the <b>fixture</b> shop.</p>
<button id="covered" style="position:absolute;left:20px;top:40px" onclick="r('covered clicked')">Under overlay</button>
<form onsubmit="event.preventDefault();r('sent '+this.q.value+' / '+this.size.value)">
<label for="q">Query</label><input id="q" name="q" value="initial">
<input type="password" value="SECRET_PASSWORD" aria-label="Password">
<input autocomplete="cc-number" value="4111111111111111" aria-label="Card">
<select name="size" aria-label="Size"><option>Small</option><option>Medium</option><option value="xl">Extra large</option></select>
<label><input type="checkbox" id="agree"> I agree</label>
<button type="submit">Send</button></form>
<div hidden><button>Invisible</button></div>
<div id="host"></div>
<ul id="list"></ul><button id="rerender" onclick="draw()">Re-render list</button>
<iframe id="same" src="/frame" style="width:300px;height:80px"></iframe>
<iframe id="cross" src="CROSS/frame" title="Partner widget" style="width:300px;height:80px"></iframe>
<div style="height:2500px"></div><button id="far" onclick="r('far clicked')">Far below</button></main>
<p id="receipt">none</p><div id="overlay"></div>
<script>
function r(t){document.querySelector('#receipt').textContent=t}
const s=document.querySelector('#host').attachShadow({mode:'open'});
s.innerHTML='<button id="inner">Shadow action</button>';s.querySelector('#inner').onclick=()=>r('shadow clicked');
let n=0;function draw(){n++;document.querySelector('#list').innerHTML=['Alpha','Beta'].map(x=>'<li><a href="#'+x+'">'+x+' '+n+'</a></li>').join('')}
draw();
</script>'''
FRAME = b'<!doctype html><button onclick="parent.r(\'frame clicked\')">Frame button</button>'


def handler(cross):
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = FRAME if self.path == '/frame' else PAGE.replace('CROSS', cross).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass
    return Handler


def main():
    other = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler(''))
    threading.Thread(target=other.serve_forever, daemon=True).start()
    # localhost vs 127.0.0.1 makes the second frame cross-origin.
    fixture = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler('http://localhost:' + str(other.server_port)))
    threading.Thread(target=fixture.serve_forever, daemon=True).start()
    url = 'http://127.0.0.1:' + str(fixture.server_port) + '/'
    with tempfile.TemporaryDirectory(prefix='context-read-smoke-') as temporary:
        root = Path(temporary)
        (root / 'runtime.json').write_bytes((ROOT / 'runtime.json').read_bytes())
        (root / ('chrome-devtools-' + LOCK['version'])).symlink_to(ROOT / ('chrome-devtools-' + LOCK['version']))
        host = ChromeHost(root)
        rpc = None
        sequence = iter(range(1000))
        try:
            host.ensure(seconds=30)
            host.visibility(host.owner, hide=True)
            rpc = StdioRPC([sys.executable, '-B', str(RUNTIME / 'server.py'), '--root', str(root)]).start()
            rpc.initialize_mcp(expected_server_version=server.VERSION)

            def raw(tool, **arguments):
                return rpc.rpc('tools/call', {'name': tool, 'arguments': arguments}, str(next(sequence)), time.monotonic_ns() + 60_000_000_000)

            def call(tool, **arguments):
                result = raw(tool, **arguments)
                assert not result.get('isError'), result
                return json.loads(result['content'][0]['text'])

            def refused(tool, **arguments):
                result = raw(tool, **arguments)
                assert result.get('isError'), result
                return result['content'][0]['text']

            session = call('browser_open', url=url)['session']
            target = json.loads((root / 'records' / (session + '.json')).read_text())['targetId']

            def receipt():
                with cdp.PageSession(host.owner['port'], target) as page:
                    return page.send('Runtime.evaluate', {'expression': 'document.querySelector("#receipt").textContent',
                                                          'returnByValue': True})['result']['value']
            time.sleep(0.5)
            started = time.monotonic()
            tree = call('browser_read', session=session)
            read_seconds = time.monotonic() - started
            text = tree['tree']

            def ref(pattern):
                match = re.search(pattern + r'.*?\[(ref_\d+)\]', text)
                assert match, (pattern, text)
                return match.group(1)
            assert 'heading "Fixture shop" [ref_' in text and 'level=1' in text, text
            assert 'SECRET_PASSWORD' not in text and '4111' not in text and '[redacted]' in text, text
            assert 'Invisible' not in text, text
            assert 'Shadow action' in text and 'Frame button' in text, text
            assert re.search(r'iframe "Partner widget" \[ref_\d+\]\n\s+- button "Frame button"', text), text  # Cross-origin frame nested.
            assert 'textbox "Query"' in text and 'value="initial"' in text, text
            assert 'combobox "Size"' in text and 'value="Small"' in text, text
            interactive = call('browser_read', session=session, filter='interactive')
            assert 'heading' not in interactive['tree'] and 'button "Send"' in interactive['tree'], interactive
            page_text = call('browser_read', session=session, mode='text')
            assert page_text['source'] == 'main' and 'Welcome to the fixture shop.' in page_text['text'], page_text
            # Refs are stable across reads, and a re-rendered element gets a new ref; the old one is stale.
            again = call('browser_read', session=session)['tree']
            assert ref(r'button "Send"') in again and ref(r'link "Alpha 1"') in again
            alpha = ref(r'link "Alpha 1"')
            call('browser_input', session=session, action='click', expectedURL=url, ref=ref(r'button "Re-render list"'))
            stale = refused('browser_input', session=session, action='hover', ref=alpha)
            assert 'Stale ref' in stale, stale
            # Covered element is refused, not clicked through the overlay.
            covered = refused('browser_input', session=session, action='click', expectedURL=url, ref=ref(r'button "Under overlay"'))
            assert 'covered' in covered, covered
            assert receipt() == 'none'
            # Shadow DOM and same-origin iframe buttons by ref.
            call('browser_input', session=session, action='click', expectedURL=url, ref=ref(r'button "Shadow action"'))
            assert receipt() == 'shadow clicked', receipt()
            call('browser_input', session=session, action='click', expectedURL=url, ref=ref(r'button "Frame button"'))
            assert receipt() == 'frame clicked', receipt()
            # Off-screen element is scrolled into view, then clicked.
            call('browser_input', session=session, action='click', expectedURL=url, ref=ref(r'button "Far below"'))
            assert receipt() == 'far clicked', receipt()
            # Form: focus+type by ref, select by label, checkbox, submit.
            query = ref(r'textbox "Query"')
            call('browser_input', session=session, action='click', expectedURL=url, ref=query)
            call('browser_input', session=session, action='key', expectedURL=url, key='cmd+a')
            call('browser_input', session=session, action='type', expectedURL=url, ref=query, text='лампа')
            call('browser_input', session=session, action='select', expectedURL=url, ref=ref(r'combobox "Size"'), value='Extra large')
            bad = refused('browser_input', session=session, action='select', expectedURL=url, ref=ref(r'combobox "Size"'), value='Huge')
            assert 'option_not_found' in bad and 'Medium' in bad, bad
            call('browser_input', session=session, action='click', expectedURL=url, ref=ref(r'checkbox'))
            call('browser_input', session=session, action='click', expectedURL=url, ref=ref(r'button "Send"'))
            assert receipt() == 'sent лампа / xl', receipt()
            after = call('browser_read', session=session, filter='interactive')['tree']
            assert re.search(r'checkbox[^\n]* checked', after) and 'value="Extra large"' in after, after
            # Focused subtree and truncation.
            nav = call('browser_read', session=session, ref=ref(r'navigation'))['tree']
            assert 'About us' in nav and 'Fixture shop' not in nav, nav
            small = call('browser_read', session=session, maxChars=1000)
            assert small['truncated'] and len(small['tree']) <= 1000 and small['hint'], small
            assert host.visibility(host.owner) is True, 'browser became visible'
            call('browser_close', session=session)
            print(json.dumps({'result': 'passed', 'readSeconds': round(read_seconds, 3), 'treeChars': len(text), 'refs': tree['refs'],
                              'redaction': True, 'shadowDOM': True, 'sameOriginFrame': True, 'crossOriginNested': True,
                              'staleRefRefused': True, 'coveredRefused': True, 'scrollIntoView': True, 'formBySelectTypeRef': True,
                              'textMode': True, 'subtree': True, 'truncation': True, 'browserStayedHidden': True}))
        finally:
            if rpc:
                rpc.close()
            deadline = time.monotonic() + 8
            while endpoint(root).exists() and time.monotonic() < deadline:
                time.sleep(0.1)
            host.close_created_for_test()
            fixture.shutdown()
            other.shutdown()


if __name__ == '__main__':
    main()
