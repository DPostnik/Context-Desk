#!/usr/bin/env python3
"""Live check of cross-origin frames, uploads, JavaScript evaluation and logs; local fixtures only."""
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

TOP = '''<!doctype html><title>Checkout</title><h1>Checkout</h1><p id="receipt">none</p>
<div style="height:1200px"></div>
<iframe src="FRAME/pay" title="Payment widget" style="width:420px;height:260px;border:4px solid #333;padding:6px"></iframe>
<script>addEventListener('message',e=>{document.querySelector('#receipt').textContent=e.data});
console.error('fixture console error');fetch('/api/ping');</script>'''
PAY = '''<!doctype html><title>Pay</title><form onsubmit="event.preventDefault();parent.postMessage('paid '+this.card.value+' '+this.plan.value+' '+(this.doc.files[0]||{}).name,'*')">
<label>Card holder <input name="card"></label>
<select name="plan" aria-label="Plan"><option>Basic</option><option>Pro</option></select>
<label>Document <input type="file" name="doc"></label>
<button type="button" onclick="parent.postMessage(confirm('Remove card?')?'removed':'kept','*')">Remove card</button>
<button>Pay now</button></form>'''


def handler(frame_origin):
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = PAY if self.path == '/pay' else ('{"ok":true}' if self.path == '/api/ping' else TOP.replace('FRAME', frame_origin))
            self.send_response(200)
            self.send_header('Content-Type', 'application/json' if self.path == '/api/ping' else 'text/html; charset=utf-8')
            self.end_headers()
            self.wfile.write(body.encode())

        def log_message(self, *_):
            pass
    return Handler


def main():
    partner = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler(''))
    threading.Thread(target=partner.serve_forever, daemon=True).start()
    # localhost vs 127.0.0.1: different sites, so Chrome runs the frame out of process.
    fixture = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler('http://localhost:' + str(partner.server_port)))
    threading.Thread(target=fixture.serve_forever, daemon=True).start()
    url = 'http://127.0.0.1:' + str(fixture.server_port) + '/'
    with tempfile.TemporaryDirectory(prefix='context-frame-smoke-') as temporary, \
            tempfile.TemporaryDirectory(prefix='context-frame-project-') as project:
        root = Path(temporary)
        (root / 'runtime.json').write_bytes((ROOT / 'runtime.json').read_bytes())
        (root / ('chrome-devtools-' + LOCK['version'])).symlink_to(ROOT / ('chrome-devtools-' + LOCK['version']))
        Path(project, 'passport.pdf').write_bytes(b'%PDF-1.4 fixture')
        outside = root / 'secret.txt'
        outside.write_text('not for upload')
        host = ChromeHost(root)
        rpc = None
        sequence = iter(range(1000))
        try:
            host.ensure(seconds=30)
            host.visibility(host.owner, hide=True)
            rpc = StdioRPC([sys.executable, '-B', str(RUNTIME / 'server.py'), '--root', str(root)], cwd=project).start()
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
            time.sleep(0.8)
            tree = call('browser_read', session=session, filter='interactive')['tree']

            def ref(pattern):
                match = re.search(pattern + r'.*?\[(ref_\d+)\]', tree)
                assert match, (pattern, tree)
                return match.group(1)
            # The cross-origin frame's controls nest under its iframe line.
            assert re.search(r'- iframe "Payment widget" \[ref_\d+\]\n  - textbox "Card holder"', tree), tree
            assert 'cross-origin' not in tree, tree
            numbers = [int(n) for n in re.findall(r'ref_(\d+)', tree)]
            assert len(numbers) == len(set(numbers)), tree  # Frame refs never collide with top refs.
            # Type, select and upload inside the frame; the frame is below the fold.
            call('browser_input', session=session, action='type', ref=ref(r'textbox "Card holder"'), text='Ада Лавлейс')
            call('browser_input', session=session, action='select', ref=ref(r'combobox "Plan"'), value='Pro')
            assert 'project directory' in refused('browser_input', session=session, action='upload', expectedURL=url,
                                                  ref=ref(r'button "Document"'), files=[str(outside)])
            call('browser_input', session=session, action='upload', expectedURL=url, ref=ref(r'button "Document"'), files=['passport.pdf'])
            # Natural-language lookup finds the frame's pay button.
            found = call('browser_find', session=session, query='pay button')
            assert found['matches'][0]['ref'] == ref(r'button "Pay now"'), found
            # A confirm dialog inside the cross-origin frame: reported, blocks reads, answered in the frame.
            asked = call('browser_input', session=session, action='click', ref=ref(r'button "Remove card"'))
            # Chrome reports frame dialogs through the tab (they are tab-modal); the URL names the frame.
            assert asked['dialog']['message'] == 'Remove card?' and '/pay' in asked['dialog']['url'], asked
            assert 'dialog' in refused('browser_read', session=session)
            call('browser_input', session=session, action='dialog', expectedURL=asked['dialog']['url'], value='accept')
            assert 'removed' in call('browser_read', session=session, mode='text')['text']
            # A coordinate click on the frame's submit button is classified inside the frame.
            call('browser_input', session=session, action='scroll_to', ref=ref(r'button "Pay now"'))
            shot = call('browser_screenshot', session=session)
            frame_target = next(t for t in json.loads(__import__('urllib.request').request.urlopen(
                'http://127.0.0.1:%d/json/list' % host.owner['port']).read()) if t['type'] == 'iframe')['id']
            with cdp.PageSession(host.owner['port'], frame_target) as frame_page:
                inner = frame_page.send('Runtime.evaluate', {'returnByValue': True, 'expression':
                    'JSON.stringify((r=>[r.x+r.width/2,r.y+r.height/2])([...document.querySelectorAll("button")].find(b=>b.textContent=="Pay now").getBoundingClientRect()))'})
            inner = json.loads(inner['result']['value'])
            outer = call('browser_eval', session=session, expectedURL=url, expression=
                '(f=>{const r=f.getBoundingClientRect(),s=getComputedStyle(f);return [r.x+parseFloat(s.borderLeftWidth)+parseFloat(s.paddingLeft),r.y+parseFloat(s.borderTopWidth)+parseFloat(s.paddingTop),innerWidth]})(document.querySelector("iframe"))')['value']
            scale = shot['width'] / outer[2]
            point = {'x': (outer[0] + inner[0]) * scale, 'y': (outer[1] + inner[1]) * scale}
            call('browser_screenshot', session=session)
            message = refused('browser_input', session=session, action='click', **point)
            assert 'expectedURL' in message, message
            paid = call('browser_input', session=session, action='click', expectedURL=url, **point)
            assert paid['risk'] == 'submit', paid
            receipt = call('browser_read', session=session, mode='text')['text']
            assert 'paid Ада Лавлейс Pro passport.pdf' in receipt, receipt
            # JavaScript evaluation: value of the last expression, await allowed, journaled once.
            evaluated = call('browser_eval', session=session, expectedURL=url, actionID='eval-fixture-1',
                             expression='const r = await fetch("/api/ping"); ({status: r.status, title: document.title})')
            assert evaluated['value'] == {'status': 200, 'title': 'Checkout'}, evaluated
            assert 'do_not_replay' in refused('browser_eval', session=session, expectedURL=url, actionID='eval-fixture-1', expression='1')
            thrown = call('browser_eval', session=session, expectedURL=url, expression='throw new Error("boom")')
            assert 'boom' in thrown['error'], thrown
            assert 'expectedURL' in refused('browser_eval', session=session, expectedURL='', expression='1')
            # Console and network summaries come from Chrome DevTools' own collection.
            console = call('browser_logs', session=session, kind='console', problems=True)
            assert 'fixture console error' in console['text'], console
            network = call('browser_logs', session=session, kind='network')
            assert '/api/ping' in network['text'], network
            assert host.visibility(host.owner) is True, 'browser became visible'
            call('browser_close', session=session)
            print(json.dumps({'result': 'passed', 'frameTreeNested': True, 'frameRefsUnique': True, 'typeSelectInFrame': True,
                              'uploadFromProjectOnly': True, 'submitInFrame': True, 'evalAwaitJournaled': True,
                              'evalException': True, 'findInFrame': True, 'frameDialog': True, 'frameCoordinateRisk': True, 'consoleProblems': True, 'networkLog': True, 'browserStayedHidden': True}))
        finally:
            if rpc:
                rpc.close()
            deadline = time.monotonic() + 8
            while endpoint(root).exists() and time.monotonic() < deadline:
                time.sleep(0.1)
            host.close_created_for_test()
            fixture.shutdown()
            partner.shutdown()


if __name__ == '__main__':
    main()
