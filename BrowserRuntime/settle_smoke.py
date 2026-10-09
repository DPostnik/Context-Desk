#!/usr/bin/env python3
"""Live check of post-action settling, change reports, risk classes and dialogs; local fixtures only."""
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

APP = '''<!doctype html><title>Shop</title>
<nav><a href="/app" id="home">Shop home</a> <a href="/app/orders" onclick="event.preventDefault();go()">Orders</a>
<a href="OTHER/" >Partner site</a> <a href="/help" target="_blank">Help</a></nav>
<main id="view"><button onclick="add()">Add to cart</button><span id="cart">Cart (0)</span>
<button onclick="if(confirm('Empty the cart?'))empty()">Empty cart</button>
<form action="/done" method="get"><input name="q" aria-label="Note"><button>Place order</button></form></main>
<script>
let n=0;function add(){n++;document.querySelector('#cart').textContent='Cart ('+n+')';
 if(n===1){const c=document.createElement('input');c.setAttribute('aria-label','Coupon');document.querySelector('#view').append(c)}}
function empty(){n=0;document.querySelector('#cart').textContent='Cart (0)'}
async function go(){await fetch('/slow');history.pushState({},'','/app/orders');document.title='Orders';
 document.querySelector('#view').innerHTML='<h1>Orders</h1><a href="/app/orders/1">Order 1</a>'}
</script>'''
DONE = '<!doctype html><title>Done</title><h1>Order placed</h1><a href="/app">Back</a>'


def handler(other):
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == '/slow':
                time.sleep(0.9)
                body = 'ok'
            elif self.path.startswith('/done'):
                time.sleep(0.3)
                body = DONE
            else:
                body = APP.replace('OTHER', other)
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.end_headers()
            self.wfile.write(body.encode())

        def log_message(self, *_):
            pass
    return Handler


def main():
    partner = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler(''))
    threading.Thread(target=partner.serve_forever, daemon=True).start()
    fixture = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler('http://localhost:' + str(partner.server_port)))
    threading.Thread(target=fixture.serve_forever, daemon=True).start()
    base = 'http://127.0.0.1:' + str(fixture.server_port)
    url = base + '/app'
    with tempfile.TemporaryDirectory(prefix='context-settle-smoke-') as temporary:
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
            tree = call('browser_read', session=session, filter='interactive')['tree']

            def ref(pattern, source=None):
                match = re.search(pattern + r'.*?\[(ref_\d+)\]', source or tree)
                assert match, (pattern, source or tree)
                return match.group(1)
            # Same-page change report: counter changed, coupon field added; no URL needed for a plain click.
            added = call('browser_input', session=session, action='click', ref=ref(r'button "Add to cart"'))
            changes = added['changes']
            assert added['settled'] and changes['kind'] == 'same_page' and changes['added'] == 1, added
            assert '+ textbox "Coupon"' in changes['diff'], changes
            # Client-side navigation after a slow fetch: the result already shows the new route.
            started = time.monotonic()
            orders = call('browser_input', session=session, action='click', ref=ref(r'link "Orders"'))
            spa_seconds = time.monotonic() - started
            assert orders['url'] == base + '/app/orders' and orders['title'] == 'Orders', orders
            assert orders['changes']['kind'] == 'new_page' and 'Order 1' in orders['changes']['tree'], orders
            assert orders['navigated'] and orders['settled'], orders
            # Back to the app with a full navigation; refs from the old document must be stale, never reused.
            home_ref = ref(r'link "Shop home"')
            home = call('browser_input', session=session, action='click', ref=home_ref)
            assert home['url'] == url and home['changes']['kind'] == 'new_page', home
            new_tree = home['changes']['tree']
            old_numbers = {int(r) for r in re.findall(r'ref_(\d+)', tree)}
            new_numbers = {int(r) for r in re.findall(r'ref_(\d+)', new_tree)}
            assert new_numbers and min(new_numbers) > max(old_numbers), (old_numbers, new_numbers)
            assert 'Stale ref' in refused('browser_input', session=session, action='click', ref=ref(r'button "Add to cart"'))
            tree = new_tree
            # Leaving the site and submitting a form are risky: expectedURL required.
            message = refused('browser_input', session=session, action='click', ref=ref(r'link "Partner site"'))
            assert 'expectedURL' in message, message
            help_link = call('browser_input', session=session, action='hover', ref=ref(r'link "Help"'))
            assert help_link['action'] == 'hover'
            opened = call('browser_input', session=session, action='click', ref=ref(r'link "Help"'), observe='none')
            assert opened['newTabs'] == [base + '/help'], opened
            call('browser_input', session=session, action='type', ref=ref(r'textbox "Note"'), text='ring twice')
            assert 'expectedURL' in refused('browser_input', session=session, action='key', key='Enter')
            assert 'expectedURL' in refused('browser_input', session=session, action='click', ref=ref(r'button "Place order"'))
            placed = call('browser_input', session=session, action='click', expectedURL=url, ref=ref(r'button "Place order"'))
            assert placed['risk'] == 'submit' and placed['url'].startswith(base + '/done?q=ring+twice'), placed
            assert 'Order placed' in placed['changes']['tree'] and placed['settled'], placed
            # Confirm dialog: reported, blocks reads, answered once.
            call('browser_input', session=session, action='click', expectedURL=placed['url'], ref=ref(r'link "Back"', placed['changes']['tree']))
            tree = call('browser_read', session=session, filter='interactive')['tree']
            call('browser_input', session=session, action='click', ref=ref(r'button "Add to cart"'))
            asked = call('browser_input', session=session, action='click', ref=ref(r'button "Empty cart"'))
            assert asked['dialog']['type'] == 'confirm' and asked['dialog']['message'] == 'Empty the cart?', asked
            blocked = refused('browser_read', session=session)
            assert 'dialog' in blocked, blocked
            assert 'expectedURL' in refused('browser_input', session=session, action='dialog', value='accept')
            answered = call('browser_input', session=session, action='dialog', expectedURL=url, value='accept')
            assert answered['risk'] == 'dialog' and 'dialog' not in answered, answered
            cart = call('browser_read', session=session, filter='interactive')
            assert 'Cart (0)' in call('browser_read', session=session, mode='text')['text'], cart
            assert host.visibility(host.owner) is True, 'browser became visible'
            call('browser_close', session=session)
            print(json.dumps({'result': 'passed', 'spaNavigationSeconds': round(spa_seconds, 3), 'samePageDiff': True,
                              'spaRouteObserved': True, 'refsNeverReused': True, 'riskNavigationAndSubmit': True,
                              'newTabFlagged': True, 'dialogReportedAndAnswered': True, 'browserStayedHidden': True}))
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
