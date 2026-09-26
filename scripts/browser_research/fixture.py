#!/usr/bin/env python3
"""Synthetic loopback lab. Oracle controls exist only in the owning Python process."""
import argparse
import base64
import json
import os
from pathlib import Path
import signal
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

from evidence import ROOT, digest, private_json, revision
from media import MP4, MP3


def pdf(text):
    stream = f'BT /F1 12 Tf 30 100 Td ({text}) Tj ET'.encode()
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>',
               b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
               b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 150] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
               b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
               b'<< /Length ' + str(len(stream)).encode() + b' >>\nstream\n' + stream + b'\nendstream']
    data = b'%PDF-1.4\n'
    offsets = [0]
    for i, obj in enumerate(objects, 1):
        offsets.append(len(data))
        data += f'{i} 0 obj\n'.encode() + obj + b'\nendobj\n'
    start = len(data)
    data += b'xref\n0 6\n0000000000 65535 f \n'
    data += b''.join(f'{n:010d} 00000 n \n'.encode() for n in offsets[1:])
    return data + f'trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n'.encode()


class Rejected(Exception):
    pass


class Lab:
    def __init__(self, root=ROOT):
        self.run = uuid.uuid4().hex
        self.directory = Path(root) / self.run
        self.directory.mkdir(parents=True, mode=0o700)
        self.lock = threading.RLock()
        self.events = []
        self.artifacts = {'cv.pdf': pdf('Synthetic candidate for vacancy 7'),
                          'wrong.pdf': pdf('Synthetic candidate for vacancy 8'),
                          'input.mp4': MP4, 'output.mp3': MP3,
                          'transcript.txt': '[Synthetic silence — no speech]\n'.encode()}
        self.rows = [dict(id=i, title='Engineer' if i % 2 else 'Инженер',
                          city='Łódź' if i % 3 else '東京') for i in range(1, 41)]
        self.generation = {name: uuid.uuid4().hex for name in ('A', 'B', 'decoy')}
        self.steps = {}
        self.uploads = {}
        self.receipts = {}
        self.jobs = {}
        self.version = 1
        self.approvals = {}
        self.sent = set()
        self.timers = []
        self.servers = []
        self.threads = []
        self.closed = False
        for name, data in self.artifacts.items():
            path = self.directory / name
            path.write_bytes(data)
            path.chmod(0o600)
        private_json(self.directory / 'ground-truth.json', dict(
            run=self.run, rows=self.rows, generations=self.generation,
            hashes={k: digest(v) for k, v in self.artifacts.items()},
            media='Pregenerated black/silent MP4 and MP3; processing is mocked, no real-service claim'))
        self.emit('reset', {'reason': 'fresh run; no previous target reused'})

    def emit(self, kind, data):
        with self.lock:
            event = dict(sequence=len(self.events) + 1, monotonic_ns=time.monotonic_ns(),
                         run=self.run, kind=kind, data=data)
            path = self.directory / 'ledger.jsonl'
            with path.open('a', encoding='utf-8') as stream:
                os.chmod(path, 0o600)
                stream.write(json.dumps(event, ensure_ascii=False) + '\n')
                stream.flush()
                os.fsync(stream.fileno())
            self.events.append(event)
            return event

    def later(self, callback):
        def guarded():
            with self.lock:
                if not self.closed:
                    callback()
        timer = threading.Timer(0.35, guarded)
        self.timers.append(timer)
        timer.start()

    # Owner-only controls: never routed by HTTP.
    def approve(self, text, recipient='contact-7'):
        token = uuid.uuid4().hex
        self.approvals[token] = (self.version, recipient, text)
        self.emit('approval', dict(token=token, version=self.version, recipient=recipient, text=text))
        return token

    def incoming(self):
        self.version += 1
        self.emit('incoming', dict(version=self.version))

    def action(self, path, data):
        with self.lock:
            self.emit('attempt', dict(path=path, payload=data))
            try:
                return self._action(path, data)
            except (Rejected, KeyError, ValueError, TypeError) as error:
                self.emit('rejected', dict(path=path, reason=str(error)))
                raise Rejected(str(error)) from error

    def _action(self, path, d):
        if path == 'event':
            if d.get('target') not in self.generation or d.get('generation') != self.generation[d['target']]:
                raise Rejected('stale target')
            self.emit('page-event', d)
            return {'accepted': True}
        if path == 'step':
            if d.get('vacancy') != 7 or d.get('name') != 'Test Candidate' or d.get('email') != 'candidate@example.invalid' or d.get('role') != 'engineering' or d.get('consent') is not True:
                raise Rejected('invalid synthetic fields')
            ticket = uuid.uuid4().hex
            self.steps[ticket] = False
            self.later(lambda: (self.steps.__setitem__(ticket, True), self.emit('validated', {'ticket': ticket})))
            return {'ticket': ticket, 'state': 'validating'}
        if path == 'upload':
            content = base64.b64decode(d['base64'], validate=True)
            purpose = d['purpose']
            expected = {'cv': 'cv.pdf', 'media': 'input.mp4'}.get(purpose)
            if expected is None or d.get('item') != 7 or digest(content) != digest(self.artifacts[expected]):
                raise Rejected('wrong artifact or binding')
            key = uuid.uuid4().hex
            self.uploads[key] = dict(purpose=purpose, item=7, sha256=digest(content))
            self.emit('uploaded', dict(upload=key, **self.uploads[key]))
            return {'upload': key, **self.uploads[key]}
        if path == 'submit':
            attempt = d['attempt']
            if not isinstance(attempt, str) or not attempt:
                raise Rejected('missing attempt identity')
            if self.receipts or attempt in self.receipts:
                raise Rejected('duplicate vacancy submission')
            if not self.steps.get(d.get('ticket')) or self.uploads.get(d.get('upload'), {}).get('purpose') != 'cv' or d.get('vacancy') != 7:
                raise Rejected('not validated or wrong binding')
            receipt = dict(receipt=uuid.uuid4().hex, vacancy=7, attempt=attempt,
                           sha256=self.uploads[d['upload']]['sha256'], ticket=d['ticket'], upload=d['upload'])
            self.receipts[attempt] = receipt
            self.emit('submitted', receipt)
            return receipt
        if path == 'send':
            approval = self.approvals.get(d.get('approval'))
            if approval != (self.version, d.get('recipient'), d.get('text')) or d['approval'] in self.sent:
                raise Rejected('missing, stale, mismatched or consumed approval')
            self.sent.add(d['approval'])
            receipt = dict(version=self.version, recipient=d['recipient'], text=d['text'],
                           approval=d['approval'], receipt=uuid.uuid4().hex)
            self.emit('sent', receipt)
            return receipt
        if path == 'process':
            upload = d['upload']
            if self.uploads.get(upload, {}).get('purpose') != 'media' or upload in self.jobs:
                raise Rejected('wrong or repeated processing input')
            self.jobs[upload] = 'processing'
            def complete():
                self.jobs[upload] = 'failed' if d.get('fail') else 'complete'
                self.emit('processed', dict(upload=upload, state=self.jobs[upload]))
            self.later(complete)
            return {'job': upload, 'state': 'processing'}
        if path == 'site-delay':
            self.later(lambda: self.emit('site-response', {'cause': 'accepted site-delay'}))
            return {'accepted': True}
        raise Rejected('unknown action')

    def start(self):
        lab = self
        class Handler(BaseHTTPRequestHandler):
            def setup(self):
                super().setup()
                self.connection.settimeout(5)

            def log_message(self, *_):
                pass

            def reply(self, code, data, mime='application/json'):
                if not isinstance(data, bytes):
                    data = json.dumps(data, ensure_ascii=False).encode()
                self.send_response(code)
                self.send_header('Content-Type', mime)
                self.send_header('Content-Length', str(len(data)))
                self.send_header('Cache-Control', 'no-store')
                self.send_header('X-Content-Type-Options', 'nosniff')
                self.end_headers()
                self.wfile.write(data)

            def route(self):
                # Host validation prevents DNS-rebinding; CORS is deliberately absent.
                if self.headers.get('Host') != f'127.0.0.1:{self.server.server_port}':
                    raise Rejected('invalid host')
                url = urlsplit(self.path)
                prefix = '/' + lab.run + '/'
                if not url.path.startswith(prefix):
                    raise Rejected('unknown run')
                return url.path[len(prefix):], parse_qs(url.query)

            def do_GET(self):
                try:
                    path, q = self.route()
                    with lab.lock:
                        if path == 'search':
                            rows = [r for r in lab.rows if q.get('q', [''])[0].casefold() in r['title'].casefold()]
                            rows = sorted(rows, key=lambda r: r['id'], reverse=q.get('sort') == ['desc'])
                            page = int(q.get('page', ['0'])[0])
                            if page < 0:
                                raise Rejected('negative page')
                            result = dict(rows=rows[page*10:(page+1)*10], page=page,
                                          total=len(rows), exhausted=(page+1)*10 >= len(rows))
                            lab.emit('search-read', result)
                            self.reply(200, result)
                        elif path == 'state':
                            self.reply(200, dict(steps=lab.steps, jobs=lab.jobs, version=lab.version,
                                                messages=[{'id': 'message-7', 'source': 'original'},
                                                          {'id': 'notification-7', 'original': 'message-7'}],
                                                recipient='contact-7', relationship='connected', pending=False))
                        elif path.startswith('download/'):
                            name = path.split('/')[-1]
                            job = q.get('job', [''])[0]
                            if lab.jobs.get(job) != 'complete' or name not in ('output.mp3', 'transcript.txt'):
                                raise Rejected('output unavailable')
                            lab.emit('downloaded', dict(job=job, name=name, sha256=digest(lab.artifacts[name])))
                            self.reply(200, lab.artifacts[name], 'application/octet-stream')
                        elif path == 'lab.js':
                            self.reply(200, Path(__file__).with_name('lab.js').read_bytes(), 'text/javascript')
                        elif path in ('', 'A', 'B', 'decoy', 'frame', 'cross-frame'):
                            target = path if path in lab.generation else 'A'
                            config = dict(run=lab.run, target=target, generation=lab.generation[target],
                                          base=f'/{lab.run}/', peer=lab.origins[1] + '/' + lab.run + '/',
                                          frame=path in ('frame', 'cross-frame'))
                            html = Path(__file__).with_name('page.html').read_text().replace('__CONFIG__', json.dumps(config))
                            self.reply(200, html.encode(), 'text/html; charset=utf-8')
                        else:
                            self.reply(404, {'error': 'not found'})
                except (Rejected, ValueError) as error:
                    self.reply(400, {'error': str(error)})

            def do_POST(self):
                try:
                    path, _ = self.route()
                    origin = self.headers.get('Origin')
                    if origin and origin not in lab.origins:
                        raise Rejected('foreign origin')
                    size = int(self.headers.get('Content-Length', '0'))
                    if not 0 < size <= 1024 * 1024:
                        raise Rejected('body size')
                    if self.headers.get('Content-Type') != 'application/json':
                        raise Rejected('JSON required')
                    data = json.loads(self.rfile.read(size))
                    if not isinstance(data, dict):
                        raise Rejected('object required')
                    result = lab.action(path, data)
                    self.reply(200, result)
                except (Rejected, ValueError) as error:
                    self.reply(400, {'error': str(error)})
        for _ in range(2):
            server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
            server.daemon_threads = False
            self.servers.append(server)
        self.origins = [f'http://127.0.0.1:{s.server_port}' for s in self.servers]
        for server in self.servers:
            thread = threading.Thread(target=server.serve_forever)
            thread.start()
            self.threads.append(thread)
        private_json(self.directory / 'manifest.json', dict(schema_version=1, run=self.run,
            fixture_revision=revision(), pid=os.getpid(), origins=self.origins,
            targets={k: self.origins[0] + '/' + self.run + '/' + k for k in self.generation},
            generations=self.generation, ledger='ledger.jsonl', ground_truth='ground-truth.json'))
        return self

    def close(self):
        with self.lock:
            self.closed = True
        for timer in self.timers:
            timer.cancel()
            timer.join()
        for server in self.servers:
            server.shutdown()
            server.server_close()
        for thread in self.threads:
            thread.join()
        self.emit('cleanup', {'servers_closed': len(self.servers), 'timers_joined': len(self.timers),
                              'browser_cessation': 'not established by fixture shutdown'})


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    args = parser.parse_args()
    os.umask(0o077)
    lab = Lab(args.root).start()
    stop = threading.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stop.set())
    print(json.dumps({'directory': str(lab.directory), 'url': lab.origins[0] + '/' + lab.run + '/A'}), flush=True)
    try:
        stop.wait()
    finally:
        lab.close()
