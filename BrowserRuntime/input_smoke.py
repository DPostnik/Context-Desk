#!/usr/bin/env python3
"""Live screenshot and trusted-input check against a local fixture; no user data or external sites."""
import base64
import http.server
import json
import os
from pathlib import Path
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

PAGE = b'''<!doctype html><title>Input fixture</title>
<style>body{margin:0;font:16px sans-serif} #menu .item{display:none} #menu:hover .item{display:block}
#slider{position:relative;width:300px;height:20px;background:#ddd;margin:10px} #knob{position:absolute;left:0;top:0;width:20px;height:20px;background:#333}
#tall{height:3000px;background:linear-gradient(#fff,#ccf)} #bottom{font-size:40px}</style>
<canvas id="c" width="400" height="200" style="display:block"></canvas>
<p id="receipt">none</p>
<div id="menu" style="width:200px;background:#eee">Menu<div class="item" id="item" onclick="document.querySelector('#receipt').textContent='menu chosen'">Hidden item</div></div>
<div id="slider"><div id="knob"></div></div><p id="slid">0</p>
<form onsubmit="event.preventDefault();document.querySelector('#typed').textContent=document.querySelector('#field').value">
<input id="field" style="width:300px;height:30px"></form><p id="typed"></p>
<div id="tall"></div><p id="bottom">Bottom reached</p>
<script>
const g=document.querySelector('#c').getContext('2d');g.fillStyle='#e00';g.fillRect(250,60,100,80);
document.querySelector('#c').addEventListener('click',e=>{const r=e.target.getBoundingClientRect(),x=e.clientX-r.left,y=e.clientY-r.top;
 document.querySelector('#receipt').textContent=(x>=250&&x<=350&&y>=60&&y<=140&&e.isTrusted)?'canvas hit':'canvas miss '+Math.round(x)+','+Math.round(y)});
const knob=document.querySelector('#knob');let drag=false;
knob.addEventListener('mousedown',()=>drag=true);addEventListener('mouseup',()=>drag=false);
addEventListener('mousemove',e=>{if(!drag)return;const r=knob.parentElement.getBoundingClientRect();
 const x=Math.max(0,Math.min(280,e.clientX-r.left-10));knob.style.left=x+'px';document.querySelector('#slid').textContent=Math.round(x)});
</script>'''


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.end_headers()
        self.wfile.write(PAGE)

    def log_message(self, *_):
        pass


def main():
    fixture = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=fixture.serve_forever, daemon=True).start()
    url = 'http://127.0.0.1:' + str(fixture.server_port) + '/'
    with tempfile.TemporaryDirectory(prefix='context-input-smoke-') as temporary:
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

            def call(tool, **arguments):
                result = rpc.rpc('tools/call', {'name': tool, 'arguments': arguments}, str(next(sequence)), time.monotonic_ns() + 60_000_000_000)
                assert not result.get('isError'), result
                value = json.loads(result['content'][0]['text'])
                images = [b for b in result['content'] if b['type'] == 'image']
                return value, images

            def text(selector):
                with cdp.PageSession(host.owner['port'], target) as page:
                    return page.send('Runtime.evaluate', {'expression': 'document.querySelector(' + json.dumps(selector) + ').textContent',
                                                          'returnByValue': True})['result']['value']

            opened, _ = call('browser_open', url=url)
            session = opened['session']
            target = json.loads((root / 'records' / (session + '.json')).read_text())['targetId']
            started = time.monotonic()
            shot, images = call('browser_screenshot', session=session)
            screenshot_seconds = time.monotonic() - started
            assert len(images) == 1 and max(shot['width'], shot['height']) <= 1280, shot
            data = base64.b64decode(images[0]['data'])
            assert cdp.jpeg_size(data) == (shot['width'], shot['height'])
            Path(temporary, 'first.jpg').write_bytes(data)
            with cdp.PageSession(host.owner['port'], target) as page:
                css = page.send('Runtime.evaluate', {'expression': 'innerWidth', 'returnByValue': True})['result']['value']
            ratio = shot['width'] / css  # image pixels per CSS pixel

            def px(x, y):
                return {'x': x * ratio, 'y': y * ratio}
            call('browser_input', session=session, action='click', expectedURL=url, **px(300, 100))
            assert text('#receipt') == 'canvas hit', text('#receipt')
            call('browser_input', session=session, action='click', expectedURL=url, **px(20, 20))
            assert text('#receipt').startswith('canvas miss'), text('#receipt')
            # Hover reveals the menu item; the screenshot pixel mapping stays valid without scrolling.
            with cdp.PageSession(host.owner['port'], target) as page:
                box = page.send('Runtime.evaluate', {'expression': 'JSON.stringify(["#menu","#field"].map(s=>{const r=document.querySelector(s).getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2]}))',
                                                     'returnByValue': True})['result']['value']
            menu, field = json.loads(box)
            call('browser_input', session=session, action='hover', **px(menu[0], menu[1] - 5))
            call('browser_input', session=session, action='wait', seconds=0.2, screenshot=True)
            with cdp.PageSession(host.owner['port'], target) as page:
                item = json.loads(page.send('Runtime.evaluate', {'expression': 'JSON.stringify((r=>[r.x+r.width/2,r.y+r.height/2,r.height])(document.querySelector("#item").getBoundingClientRect()))',
                                                                  'returnByValue': True})['result']['value'])
            assert item[2] > 0, 'hover did not reveal the item'
            call('browser_input', session=session, action='click', expectedURL=url, **px(item[0], item[1]))
            assert text('#receipt') == 'menu chosen', text('#receipt')
            # Drag the slider knob. Move off the hover menu first so it collapses before measuring.
            call('browser_screenshot', session=session)
            call('browser_input', session=session, action='hover', **px(380, 10))
            call('browser_screenshot', session=session)
            with cdp.PageSession(host.owner['port'], target) as page:
                knob = json.loads(page.send('Runtime.evaluate', {'expression': 'JSON.stringify((r=>[r.x+r.width/2,r.y+r.height/2])(document.querySelector("#knob").getBoundingClientRect()))',
                                                                  'returnByValue': True})['result']['value'])
            start, end = px(*knob), px(knob[0] + 150, knob[1])
            call('browser_input', session=session, action='drag', expectedURL=url, x=start['x'], y=start['y'], toX=end['x'], toY=end['y'])
            assert 140 <= int(text('#slid')) <= 160, text('#slid')
            # Type and submit with Enter.
            call('browser_input', session=session, action='click', expectedURL=url, **px(*field))
            call('browser_input', session=session, action='type', expectedURL=url, text='Привет, agent')
            call('browser_input', session=session, action='key', expectedURL=url, key='Enter')
            assert text('#typed') == 'Привет, agent', text('#typed')
            # Wheel scrolling in a background, hidden tab.
            _, images = call('browser_input', session=session, action='scroll', deltaY=4000, screenshot=True)
            time.sleep(0.5)
            with cdp.PageSession(host.owner['port'], target) as page:
                offset = page.send('Runtime.evaluate', {'expression': 'scrollY', 'returnByValue': True})['result']['value']
            assert offset > 1000, offset
            assert len(images) == 1
            Path(temporary, 'scrolled.jpg').write_bytes(base64.b64decode(images[0]['data']))
            assert host.visibility(host.owner) is True, 'browser became visible'
            # A reused actionID never dispatches twice.
            call('browser_screenshot', session=session)
            call('browser_input', session=session, action='hover', actionID='smoke-hover-1', x=1, y=1)
            again = rpc.rpc('tools/call', {'name': 'browser_input', 'arguments': {'session': session, 'action': 'hover', 'actionID': 'smoke-hover-1', 'x': 1, 'y': 1}},
                            str(next(sequence)), time.monotonic_ns() + 30_000_000_000)
            assert again.get('isError') and 'do_not_replay' in again['content'][0]['text'], again
            call('browser_close', session=session)
            print(json.dumps({'result': 'passed', 'screenshotSeconds': round(screenshot_seconds, 3), 'image': [shot['width'], shot['height']],
                              'canvasHit': True, 'hoverMenu': True, 'drag': True, 'typeUnicodeAndEnter': True,
                              'wheelScrollHiddenTab': offset, 'browserStayedHidden': True, 'noReplay': True}))
        finally:
            if rpc:
                rpc.close()
            deadline = time.monotonic() + 8
            while endpoint(root).exists() and time.monotonic() < deadline:
                time.sleep(0.1)
            host.close_created_for_test()
            fixture.shutdown()


if __name__ == '__main__':
    main()
