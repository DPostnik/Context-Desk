"""C04 protocol doubles; direct execution never starts a native or browser process."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import platform
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from contract import Request, Target
from evidence import ROOT
import adapter as c04

TARGET = Target('run-7', 'generation-A', 'http://127.0.0.1:49152/run-7/A',
                'nonce-before-attach', 'selected-profile', 'AAAA0000BBBB1111CCCC2222DDDD3333')
IDENTITY = {'run': TARGET.run_id, 'generation': TARGET.generation, 'target': 'A',
            'url': TARGET.url, 'nonce': TARGET.nonce}


def response(data, *, valid=True):
    if not valid:
        return {}
    return {'isError': False, 'content': [{'type': 'text', 'text': 'controlled protocol double'}],
            'structuredContent': {'exitCode': 0, 'response': {'success': True, 'data': data}}}


def request(operation, args=None, *, target=TARGET, request_id='request-7'):
    return Request(request_id, target, operation, args or {}, time.monotonic_ns() + 30_000_000_000)


class Double:
    def __init__(self):
        self.calls = []
        self.tabs = [{'tabId': 't2', 'targetId': TARGET.target_id, 'url': TARGET.url, 'active': True}]
        self.identity = IDENTITY
        self.fail_tool = None
        self.malformed_tool = None
        self.hold_tool = None
        self.started = threading.Event()
        self.release = threading.Event()

    def __call__(self, method, params, request_id, deadline_ns):
        assert method == 'tools/call'
        tool = params['name']
        args = params['arguments']
        self.calls.append((tool, args, request_id))
        if tool == self.hold_tool:
            self.started.set()
            self.release.wait(3)
        if tool == self.fail_tool:
            raise TimeoutError('ambiguous transport result')
        if tool == self.malformed_tool:
            return response({}, valid=False)
        if tool == 'agent_browser_session_info':
            return response({'session': 'context-desk-research', 'namespace': 'context-desk-research',
                             'active': True, 'version': c04.VERSION,
                             'runtime': {'browserLaunched': True}})
        if tool == 'agent_browser_tab_list':
            return response({'tabs': self.tabs})
        if tool == 'agent_browser_eval' and args['script'] == c04.IDENTITY_JS:
            return response({'result': json.dumps(self.identity), 'origin': TARGET.url})
        return response({'ok': True})


class AdapterTests(unittest.TestCase):
    def setUp(self):
        ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.temp = tempfile.TemporaryDirectory(prefix='agent-browser-checks-', dir=ROOT)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.executable = self.root / 'candidate-data-only'
        self.executable.write_bytes(b'controlled binary identity double')
        self.hash = hashlib.sha256(self.executable.read_bytes()).hexdigest()
        self.pin_patch = patch.dict(c04.NATIVE_SHA256, {platform.machine(): self.hash})
        self.pin_patch.start()
        self.addCleanup(self.pin_patch.stop)
        self.upload = self.root / 'synthetic.pdf'
        self.upload.write_bytes(b'%PDF-1.4\nsynthetic fixture')
        self.download_root = self.root / 'outputs'
        self.download_root.mkdir()

    def subject(self, double, **kw):
        return c04.AgentBrowserAdapter(double, artifact_verified=True, executable_path=self.executable,
            executable_sha256=self.hash, selected_profile='selected-profile',
            endpoint='http://127.0.0.1:9222', namespace='context-desk-research',
            session='context-desk-research', prebound_pin_attested=True,
            connection_approved=True, allowed_upload_roots=(self.root,),
            allowed_download_root=self.download_root, **kw)

    def test_prerequisites_block_before_rpc(self):
        double = Double()
        subject = c04.AgentBrowserAdapter(double)
        self.assertEqual(subject.attach(request('attach')).status, 'blocked')
        self.assertEqual(double.calls, [])

    def test_attach_and_typed_mappings(self):
        double = Double()
        subject = self.subject(double)
        self.assertEqual(subject.attach(request('attach')).status, 'passed')
        cases = [
            ('observe', {'compact': True}, 'agent_browser_snapshot'),
            ('click', {'selector': '#next'}, 'agent_browser_click'),
            ('fill', {'selector': '#name', 'text': 'Ada'}, 'agent_browser_fill'),
            ('evaluate', {'script': '1 + 1'}, 'agent_browser_eval'),
            ('wait', {'ms': 25}, 'agent_browser_wait_ms'),
            ('upload', {'selector': '#cv', 'files': [str(self.upload)]}, 'agent_browser_upload'),
            ('download', {'selector': '#output', 'path': str(self.download_root / 'result.mp3')}, 'agent_browser_download'),
        ]
        for op, args, tool in cases:
            result = subject.execute(request(op, args))
            self.assertEqual(result.status, 'passed', result.error)
            self.assertEqual(double.calls[-1][0], tool)
            self.assertEqual(double.calls[-1][1]['namespace'], 'context-desk-research')
            self.assertEqual(double.calls[-1][1]['session'], 'context-desk-research')
        self.assertEqual(subject.detach().status, 'passed')
        self.assertFalse(any(c[0] in ('agent_browser_connect', 'agent_browser_close') for c in double.calls))

    def test_stale_target_generation_and_file_boundary(self):
        double = Double()
        subject = self.subject(double)
        self.assertEqual(subject.attach(request('attach')).status, 'passed')
        double.tabs[0]['active'] = False
        self.assertEqual(subject.execute(request('click', {'selector': '#next'})).status, 'failed')
        self.assertFalse(any(c[0] == 'agent_browser_click' for c in double.calls))
        self.assertEqual(subject.detach().status, 'blocked')

        other = Double()
        subject = self.subject(other)
        changed = Target(TARGET.run_id, 'stale', TARGET.url, TARGET.nonce, TARGET.profile, TARGET.target_id)
        self.assertEqual(subject.attach(request('attach', target=changed)).status, 'failed')
        self.assertFalse(any(c[0] == 'agent_browser_click' for c in other.calls))

        other = Double()
        subject = self.subject(other)
        self.assertEqual(subject.attach(request('attach')).status, 'passed')
        count = len(other.calls)
        self.assertEqual(subject.execute(request('upload', {'selector': '#cv', 'files': ['/etc/hosts']})).status, 'blocked')
        self.assertEqual(subject.execute(request('download', {'selector': '#output', 'path': '/tmp/out'})).status, 'blocked')
        dangling = self.download_root / 'redirect.mp3'
        dangling.symlink_to('/tmp/c04-never-created-by-test.mp3')
        self.assertEqual(subject.execute(request('download', {'selector': '#output', 'path': str(dangling)})).status, 'blocked')
        self.assertEqual(len(other.calls), count)

    def test_transport_ambiguity_and_malformed_result_latch(self):
        for kind in ('fail_tool', 'malformed_tool'):
            double = Double()
            subject = self.subject(double)
            self.assertEqual(subject.attach(request('attach')).status, 'passed')
            setattr(double, kind, 'agent_browser_click')
            result = subject.execute(request('click', {'selector': '#next'}))
            self.assertEqual(result.status, 'failed')
            self.assertTrue(result.uncertain)
            count = len(double.calls)
            self.assertEqual(subject.execute(request('click', {'selector': '#next'})).status, 'blocked')
            self.assertEqual(len(double.calls), count)
            self.assertEqual(subject.detach().status, 'blocked')

    def test_stop_while_guard_blocks_action_without_notification(self):
        double = Double()
        notices = []
        subject = self.subject(double, notify=lambda *args: notices.append(args))
        self.assertEqual(subject.attach(request('attach')).status, 'passed')
        double.hold_tool = 'agent_browser_tab_list'
        result = []
        thread = threading.Thread(target=lambda: result.append(subject.execute(request('click', {'selector': '#next'}, request_id='action-7'))))
        thread.start()
        self.assertTrue(double.started.wait(1))
        cancelled = subject.cancel('action-7')
        self.assertEqual(cancelled.status, 'not applicable')
        self.assertTrue(cancelled.uncertain)
        self.assertFalse(cancelled.details['notification_sent'])
        double.release.set()
        thread.join(3)
        self.assertFalse(thread.is_alive())
        self.assertEqual(result[0].status, 'failed')
        self.assertFalse(any(c[0] == 'agent_browser_click' for c in double.calls))
        self.assertEqual(notices, [])
        self.assertEqual(subject.detach().status, 'blocked')

    def test_late_action_reply_cannot_clear_stop(self):
        double = Double()
        subject = self.subject(double)
        self.assertEqual(subject.attach(request('attach')).status, 'passed')
        double.hold_tool = 'agent_browser_click'
        result = []
        thread = threading.Thread(target=lambda: result.append(subject.execute(request('click', {'selector': '#next'}, request_id='action-8'))))
        thread.start()
        self.assertTrue(double.started.wait(1))
        self.assertEqual(subject.cancel('action-8').status, 'not applicable')
        double.release.set()
        thread.join(3)
        self.assertFalse(thread.is_alive())
        self.assertEqual(result[0].status, 'failed')
        self.assertTrue(result[0].uncertain)
        self.assertEqual(subject.detach().status, 'blocked')


if __name__ == '__main__':
    unittest.main()
