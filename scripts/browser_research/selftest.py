#!/usr/bin/env python3
"""Candidate-free positive/negative HTTP and durable-oracle validation."""
import base64
import copy
import json
import os
from pathlib import Path
import time
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from evidence import ROOT, private_json, record
from fixture import Lab
from oracle import Oracle


class Fixtures(unittest.TestCase):
    evidence_paths = []

    def setUp(self):
        self.lab = Lab().start()
        self.base = self.lab.origins[0] + '/' + self.lab.run + '/'
        self.evidence_paths.append(str(self.lab.directory))

    def tearDown(self):
        self.lab.close()
        self.assertTrue(all(not t.is_alive() for t in self.lab.threads + self.lab.timers))
        Oracle(self.lab.directory)  # Durable sequence/time/run invariant.

    def request(self, path, data=None, expected=200, origin=None):
        headers = {'Content-Type': 'application/json'}
        if origin:
            headers['Origin'] = origin
        request = Request(self.base + path, data=None if data is None else json.dumps(data).encode(), headers=headers)
        try:
            response = urlopen(request, timeout=3)
        except HTTPError as error:
            response = error
        with response:
            self.assertEqual(response.status, expected)
            raw = response.read()
            return json.loads(raw) if response.headers['Content-Type'] == 'application/json' else raw

    def upload(self, purpose='cv', name='cv.pdf', item=7, expected=200):
        return self.request('upload', dict(purpose=purpose, item=item,
            base64=base64.b64encode(self.lab.artifacts[name]).decode()), expected)

    def await_state(self, predicate):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            state = self.request('state')
            if predicate(state):
                return state
            time.sleep(0.02)
        self.fail('bounded state deadline')

    def test_search_coverage_rejects_partial_duplicate_and_wrong_values(self):
        collected = []
        for page in range(4):
            result = self.request(f'search?page={page}')
            collected.extend(result['rows'])
        oracle = Oracle(self.lab.directory)
        self.assertTrue(oracle.coverage(collected, result['exhausted']))
        self.assertFalse(oracle.coverage(collected[:10], True))
        self.assertFalse(oracle.coverage(collected, False))
        self.assertFalse(oracle.coverage(collected + collected[:1], True))
        wrong = [dict(row) for row in collected]; wrong[0]['city'] = 'wrong'
        self.assertFalse(oracle.coverage(wrong, True))
        self.assertEqual(self.request('search?q=missing')['rows'], [])
        self.assertEqual(self.request('search?sort=desc')['rows'][0]['id'], 40)
        self.assertEqual(self.request('search?q=%D0%98%D0%BD%D0%B6%D0%B5%D0%BD%D0%B5%D1%80')['total'], 20)
        self.request('search?page=-1', expected=400)

    def test_w01_invalid_async_valid_artifact_receipt_duplicate(self):
        self.request('step', {'vacancy': 7}, 400)
        self.upload(name='wrong.pdf', expected=400)
        self.upload(item=8, expected=400)
        upload = self.upload()['upload']
        step = self.request('step', dict(vacancy=7, name='Test Candidate',
            email='candidate@example.invalid', role='engineering', consent=True))
        payload = dict(vacancy=7, ticket=step['ticket'], upload=upload, attempt='attempt-1')
        self.request('submit', payload, 400)
        self.await_state(lambda s: s['steps'][step['ticket']])
        receipt = self.request('submit', payload)
        self.request('submit', payload, 400)
        self.request('submit', {**payload, 'attempt': 'attempt-2'}, 400)
        oracle = Oracle(self.lab.directory)
        self.assertTrue(oracle.application(receipt))
        self.assertFalse(oracle.application({**receipt, 'sha256': 'wrong'}))
        self.assertEqual(len(oracle.of('rejected')), 6)

    def test_w03_requires_current_exact_one_time_approval(self):
        draft = dict(approval='none', recipient='contact-7', text='Synthetic reply')
        self.request('send', draft, 400)
        draft['approval'] = self.lab.approve(draft['text'])
        self.lab.incoming()
        self.request('send', draft, 400)
        draft['approval'] = self.lab.approve(draft['text'])
        self.request('send', {**draft, 'recipient': 'contact-8'}, 400)
        self.request('send', {**draft, 'text': 'Altered reply'}, 400)
        result = self.request('send', draft)
        self.assertEqual(result['version'], 2)
        self.request('send', draft, 400)
        oracle = Oracle(self.lab.directory)
        self.assertTrue(oracle.replies())
        self.assertEqual(len(oracle.of('sent')), 1)
        original = copy.deepcopy(oracle.events)
        sent_event = next(e for e in oracle.events if e['kind'] == 'sent')
        sent_event['data']['version'] = 1
        self.assertFalse(oracle.replies())
        oracle.events = original + [copy.deepcopy(next(e for e in original if e['kind'] == 'sent'))]
        self.assertFalse(oracle.replies())
        state = self.request('state')
        self.assertEqual(state['messages'][1]['original'], state['messages'][0]['id'])

    def test_w06_processing_resume_download_identity_and_destination(self):
        self.upload('media', 'wrong.pdf', expected=400)
        upload = self.upload('media', 'input.mp4')['upload']
        job = self.request('process', {'upload': upload})['job']
        self.request(f'download/output.mp3?job={job}', expected=400)
        self.request('process', {'upload': upload}, 400)
        self.await_state(lambda s: s['jobs'][job] == 'complete')
        self.assertEqual(self.request('state')['jobs'][job], 'complete')  # Lost result: read, no repeat.
        destination = self.lab.directory / 'downloads'; destination.mkdir(mode=0o700)
        for name in ('output.mp3', 'transcript.txt'):
            path = destination / name
            path.write_bytes(self.request(f'download/{name}?job={job}')); path.chmod(0o600)
        oracle = Oracle(self.lab.directory)
        self.assertTrue(oracle.outputs(job, destination))
        self.assertFalse(oracle.outputs(job, destination / 'wrong-destination'))
        (destination / 'output.mp3').write_bytes(b'corrupt')
        self.assertFalse(oracle.outputs(job, destination))

    def test_failed_processing_never_exposes_outputs(self):
        upload = self.upload('media', 'input.mp4')['upload']
        self.request('process', {'upload': upload, 'fail': True})
        self.await_state(lambda s: s['jobs'][upload] == 'failed')
        self.request(f'download/transcript.txt?job={upload}', expected=400)

    def test_target_generation_and_finite_lifecycle_attribution(self):
        self.request('event', dict(target='A', generation='stale', kind='input'), 400)
        for index in range(3):
            self.request('event', dict(target='A', generation=self.lab.generation['A'], kind='input', detail={'index': index}))
        self.request('site-delay', {})
        deadline = time.monotonic() + 3
        while not Oracle(self.lab.directory).of('site-response') and time.monotonic() < deadline:
            time.sleep(0.02)
        oracle = Oracle(self.lab.directory)
        self.assertEqual(len(oracle.of('page-event')), 3)
        self.assertEqual(len(oracle.of('site-response')), 1)
        self.assertFalse(any(e['target'] == 'decoy' for e in oracle.of('page-event')))

    def test_two_origins_pages_and_no_http_oracle_controls(self):
        self.assertNotEqual(*self.lab.origins)
        for route in ('A', 'B', 'decoy', 'frame', 'cross-frame'):
            page = self.request(route).decode()
            self.assertIn(self.lab.run, page)
            self.assertNotIn('__CONFIG__', page)
        self.assertIn(b'fixtureEvent', self.request('lab.js'))
        self.base = self.lab.origins[1] + '/' + self.lab.run + '/'
        self.assertIn(self.lab.run.encode(), self.request('cross-frame'))
        for route in ('approve', 'reset', 'incoming', 'ledger.jsonl', 'ground-truth.json'):
            self.request(route, expected=404)
            self.request(route, {}, 400)
        self.request('site-delay', {}, 400, origin='https://foreign.invalid')

    def test_evidence_is_private_and_new_run_is_distinct(self):
        other = Lab()
        try:
            self.assertNotEqual(self.lab.run, other.run)
            self.assertNotEqual(self.lab.generation, other.generation)
            for path in self.lab.directory.iterdir():
                self.assertEqual(path.stat().st_mode & 0o077, 0)
        finally:
            other.close()


if __name__ == '__main__':
    os.umask(0o077)
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(Fixtures)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    value = record('fixture', 'candidate-free-http-oracles', 'passed' if result.wasSuccessful() else 'failed',
        hypothesis='Reject incorrect workflow claims using durable synthetic evidence',
        oracle_evidence=Fixtures.evidence_paths,
        steps=[{'command': 'python3 scripts/browser_research/selftest.py', 'tests': result.testsRun}],
        errors=[str(error) for _, error in result.failures + result.errors],
        owned_process_cleanup=['All test-owned HTTP threads and timers joined in tearDown'],
        interpretation_limits=['No browser, candidate, model, DOM interaction or real codec tested',
                               'Page event reports cannot establish absence of future browser work'])
    path = ROOT / ('selftest-' + value['run_id'] + '.json')
    private_json(path, value)
    print(path)
    raise SystemExit(0 if result.wasSuccessful() else 1)
