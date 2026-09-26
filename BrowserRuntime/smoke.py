#!/usr/bin/env python3
"""Real Chrome acceptance test against an ephemeral loopback fixture only."""
import http.server
import json
from pathlib import Path
import re
import tempfile
import threading

from install import ROOT, LOCK
from server import Browser, Rejected

HTML = '''<!doctype html><title>Context Desk browser fixture</title>
<style>#list{height:200px;overflow:auto}.card{height:80px}body{margin:20px}</style>
<div id="loading">Loading</div><div id="list"></div>
<button id="next">Next fixture page</button><button id="noop">No-op fixture</button>
<button id="send">Submit fixture only</button><p id="receipt"></p>
<script>
let page=1, sends=0;const list=document.querySelector('#list');
function render(){list.innerHTML='';document.querySelector('#loading').hidden=false;
 for(let i=0;i<12;i++){let n=document.createElement('div');n.className='card';n.dataset.key=page+'-'+i;list.append(n)}
 setTimeout(()=>{document.querySelector('#loading').remove();hydrate()},350)}
function hydrate(){[...list.children].forEach((n,i)=>{if(n.offsetTop<list.scrollTop+list.clientHeight+120)n.innerHTML='<a href="/job/'+n.dataset.key+'">Card '+n.dataset.key+'</a><span class="company">Example</span>'})}
list.addEventListener('scroll',()=>setTimeout(hydrate,80));
document.querySelector('#next').onclick=()=>{page++;history.pushState({},'', '?page='+page);list.scrollTop=0;
 const loading=document.createElement('div');loading.id='loading';document.body.prepend(loading);render()};
document.querySelector('#send').onclick=()=>document.querySelector('#receipt').innerText='Fixture received '+(++sends);
render();</script>'''


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.end_headers()
        self.wfile.write(HTML.encode())

    def log_message(self, *_):
        pass


def main():
    fixture = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=fixture.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix='context-desk-browser-check-') as temporary:
        root = Path(temporary)
        (root / 'runtime.json').write_bytes((ROOT / 'runtime.json').read_bytes())
        (root / ('chrome-devtools-' + LOCK['version'])).symlink_to(ROOT / ('chrome-devtools-' + LOCK['version']))
        browser = Browser(root)
        try:
            url = 'http://127.0.0.1:' + str(fixture.server_port) + '/'
            opened = browser.open(url)
            token = opened['session']
            config = {'card': '.card', 'title': 'a', 'link': 'a', 'idAttribute': 'data-key',
                      'company': '.company', 'scroll': '#list', 'next': '#next', 'loading': '#loading'}
            first = browser.cards(token, config)
            assert first['complete'] and len(first['cards']) == 12, first

            def uid(label):
                snapshot = browser.text(browser.native('take_snapshot', {'pageId': browser.page}))
                match = re.search(r'uid=(\S+) button "' + re.escape(label) + '"', snapshot)
                assert match, snapshot
                return match.group(1)

            noop = browser.next(token, 'fixture-noop-01', url, uid('No-op fixture'), config, 1)
            assert not noop['complete'] and noop['reason'] == 'page_transition_not_observed', noop
            browser.cards(token, config)
            second = browser.next(token, 'fixture-next-01', url, uid('Next fixture page'), config)
            assert second['complete'] and len(second['cards']) == 12 and all(c['id'].startswith('2-') for c in second['cards']), second
            browser.action(token, 'fixture-send-01', second['url'], 'click', {'uid': uid('Submit fixture only')})
            assert browser.verify_result(token, '#receipt', text='Fixture received 1')['verified']
            try:
                browser.action(token, 'fixture-send-01', second['url'], 'click', {'uid': uid('Submit fixture only')})
                raise AssertionError('Repeated action accepted')
            except Rejected:
                pass
            assert browser.verify_result(token, '#receipt', text='Fixture received 1')['verified']
            metrics = dict(browser.metrics)
            browser.close_session(token)
            print(json.dumps({'result': 'passed', 'pages': 2, 'cardsPerPage': 12, 'noOpDetected': True,
                              'submissionCount': 1, 'metrics': metrics}, indent=2))
        finally:
            browser.stop()
            fixture.shutdown()


if __name__ == '__main__':
    main()
