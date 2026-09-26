"""Protocol doubles only: these checks never start a browser or MCP server."""
from __future__ import annotations

from pathlib import Path
import sys
import shutil
import tempfile
import threading
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from contract import Request, Target
from evidence import ROOT
from adapter import PlaywrightAdapter


TARGET = Target('run-7', 'generation-A', 'http://127.0.0.1:49152/run-7/A',
                'nonce-A-before-attach', 'explicit-profile', 'index:0')
IDENTITY = '{"run":"run-7","generation":"generation-A","target":"A","url":"http://127.0.0.1:49152/run-7/A","nonce":"nonce-A-before-attach"}'
TEST_ROOT = None


def result(text):
    return {'content': [{'type': 'text', 'text': '### Result\n' + text + '\n'}]}


def req(op, *, target=TARGET, args=None, rid='request-1'):
    return Request(rid, target, op, args or {}, time.monotonic_ns() + 30_000_000_000)


class Double:
    def __init__(self):
        self.calls = []
        self.tabs = '- 0: (current) [Synthetic browser research](http://127.0.0.1:49152/run-7/A)'
        self.identity = IDENTITY
        self.fail_tool = None
        self.malformed_tool = None
        self.action_started = threading.Event()
        self.release_action = threading.Event()
        self.hold_action = False

    def __call__(self, method, params, request_id, deadline_ns):
        assert method == 'tools/call'
        self.calls.append((params['name'], params['arguments'], request_id))
        tool = params['name']
        if tool == self.fail_tool:
            raise TimeoutError('transport result ambiguous')
        if tool == self.malformed_tool:
            return {}
        if tool == 'browser_tabs':
            return result(self.tabs)
        if tool == 'browser_evaluate' and params['arguments']['function'].startswith('() => ({run:'):
            return result(self.identity)
        if self.hold_action:
            self.action_started.set()
            self.release_action.wait(3)
        return result('ok')


def adapter(double, **kw):
    return PlaywrightAdapter(double, artifact_verified=True, extension_version='0.4.0',
                             extension_artifact_sha256='a' * 64,
                             selected_profile='explicit-profile', connection_approved=True,
                             allowed_upload_roots=(TEST_ROOT,), **kw)


class AdapterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        global TEST_ROOT
        ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
        TEST_ROOT = Path(tempfile.mkdtemp(prefix='playwright-checks-', dir=ROOT))
        sample = TEST_ROOT / 'synthetic.txt'
        sample.write_text('Synthetic upload fixture\n')
        sample.chmod(0o600)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(TEST_ROOT)

    def test_missing_consent_does_not_dispatch(self):
        double = Double()
        subject = PlaywrightAdapter(double)
        self.assertEqual(subject.attach(req('attach')).status, 'blocked')
        self.assertEqual(double.calls, [])

    def test_attach_identity_and_native_mapping(self):
        double = Double()
        subject = adapter(double)
        self.assertEqual(subject.attach(req('attach')).status, 'passed')
        operations = [
            ('observe', {}, 'browser_snapshot'),
            ('click', {'target': '#next'}, 'browser_click'),
            ('fill', {'fields': [{'name': 'Name', 'type': 'textbox', 'target': '#name', 'value': 'Ada'}]}, 'browser_fill_form'),
            ('evaluate', {'function': '() => 2'}, 'browser_evaluate'),
            ('wait', {'time': 0.1}, 'browser_wait_for'),
            ('upload', {'paths': [str(TEST_ROOT / 'synthetic.txt')]}, 'browser_file_upload'),
        ]
        for operation, args, tool in operations:
            response = subject.execute(req(operation, args=args))
            self.assertEqual(response.status, 'passed', response.error)
            self.assertEqual(double.calls[-1][0], tool)
        self.assertEqual(subject.detach().status, 'passed')
        self.assertEqual(double.calls[-1][0], 'browser_file_upload')

    def test_wrong_index_nonce_generation_and_stale_current_denied(self):
        for changed in ('index', 'nonce', 'generation'):
            double = Double()
            subject = adapter(double)
            target = TARGET
            if changed == 'index':
                target = Target(TARGET.run_id, TARGET.generation, TARGET.url, TARGET.nonce, TARGET.profile, 'index:1')
            elif changed == 'nonce':
                target = Target(TARGET.run_id, TARGET.generation, TARGET.url, 'wrong', TARGET.profile, TARGET.target_id)
            else:
                target = Target(TARGET.run_id, 'wrong', TARGET.url, TARGET.nonce, TARGET.profile, TARGET.target_id)
            self.assertEqual(subject.attach(req('attach', target=target)).status, 'blocked')
            self.assertFalse(any(c[0] == 'browser_click' for c in double.calls))
        double = Double()
        subject = adapter(double)
        self.assertEqual(subject.attach(req('attach')).status, 'passed')
        double.tabs = '- 0: [Synthetic browser research](http://127.0.0.1:49152/run-7/A)'
        self.assertEqual(subject.execute(req('click', args={'target': '#next'})).status, 'blocked')
        self.assertFalse(any(c[0] == 'browser_click' for c in double.calls))

    def test_unsupported_and_bad_fields_never_dispatch(self):
        double = Double()
        subject = adapter(double)
        self.assertEqual(subject.attach(req('attach')).status, 'passed')
        count = len(double.calls)
        self.assertEqual(subject.execute(req('download')).status, 'not applicable')
        self.assertEqual(subject.execute(req('click', args={'target': '#next', 'url': 'https://elsewhere'})).status, 'blocked')
        self.assertEqual(subject.execute(req('upload', args={'paths': ['/etc/hosts']})).status, 'blocked')
        self.assertEqual(len(double.calls), count)

    def test_upload_roots_outside_app_owned_storage_are_rejected(self):
        double = Double()
        subject = adapter(double)
        subject.allowed_upload_roots = (Path(__file__).resolve().parents[2],)
        self.assertEqual(subject.attach(req('attach')).status, 'passed')
        count = len(double.calls)
        result = subject.execute(req('upload', args={'paths': [str(Path(__file__).resolve())]}))
        self.assertEqual(result.status, 'blocked')
        self.assertEqual(len(double.calls), count)

    def test_timeout_latches_uncertainty_without_replay(self):
        double = Double()
        subject = adapter(double)
        self.assertEqual(subject.attach(req('attach')).status, 'passed')
        double.fail_tool = 'browser_click'
        response = subject.execute(req('click', args={'target': '#next'}))
        self.assertEqual(response.status, 'failed')
        self.assertTrue(response.uncertain)
        count = len(double.calls)
        self.assertEqual(subject.execute(req('click', args={'target': '#next'})).status, 'blocked')
        self.assertEqual(len(double.calls), count)
        self.assertEqual(subject.detach().status, 'blocked')
        self.assertEqual(subject.inspect_state()['target']['nonce'], TARGET.nonce)

    def test_malformed_action_envelope_is_uncertain(self):
        double = Double()
        subject = adapter(double)
        self.assertEqual(subject.attach(req('attach')).status, 'passed')
        double.malformed_tool = 'browser_click'
        response = subject.execute(req('click', args={'target': '#next'}))
        self.assertEqual(response.status, 'failed')
        self.assertTrue(response.uncertain)
        self.assertEqual(subject.detach().status, 'blocked')

    def test_stop_latches_and_late_reply_cannot_clear(self):
        double = Double()
        notices = []
        subject = adapter(double, notify=lambda method, params: notices.append((method, params)))
        self.assertEqual(subject.attach(req('attach')).status, 'passed')
        double.hold_action = True
        outcome = []
        thread = threading.Thread(target=lambda: outcome.append(subject.execute(req('click', args={'target': '#next'}, rid='action-7'))))
        thread.start()
        self.assertTrue(double.action_started.wait(1))
        cancel = subject.cancel('action-7')
        self.assertEqual(cancel.status, 'blocked')
        self.assertTrue(cancel.uncertain)
        self.assertEqual(cancel.details, {'notification_sent': True, 'cancel_ack': None, 'cessation_verified': False})
        self.assertEqual(notices, [('notifications/cancelled', {'requestId': 'action-7', 'reason': 'host Stop'})])
        double.release_action.set()
        thread.join(3)
        self.assertFalse(thread.is_alive())
        self.assertEqual(outcome[0].status, 'failed')
        self.assertTrue(subject.inspect_state()['uncertain'])
        count = len(double.calls)
        self.assertEqual(subject.execute(req('observe')).status, 'blocked')
        self.assertEqual(len(double.calls), count)

    def test_stop_during_guard_prevents_action_dispatch(self):
        class GuardDouble(Double):
            def __init__(self):
                super().__init__()
                self.pause_guard = False
                self.guard_started = threading.Event()
                self.release_guard = threading.Event()

            def __call__(self, method, params, request_id, deadline_ns):
                if self.pause_guard and request_id.endswith(':identity'):
                    self.guard_started.set()
                    self.release_guard.wait(3)
                return super().__call__(method, params, request_id, deadline_ns)

        double = GuardDouble()
        notices = []
        subject = adapter(double, notify=lambda method, params: notices.append((method, params)))
        self.assertEqual(subject.attach(req('attach')).status, 'passed')
        double.pause_guard = True
        outcome = []
        thread = threading.Thread(target=lambda: outcome.append(subject.execute(req('click', args={'target': '#next'}, rid='guard-7'))))
        thread.start()
        self.assertTrue(double.guard_started.wait(1))
        subject.cancel('guard-7')
        double.release_guard.set()
        thread.join(3)
        self.assertFalse(thread.is_alive())
        self.assertEqual(outcome[0].status, 'failed')
        self.assertFalse(any(call[0] == 'browser_click' for call in double.calls))
        self.assertEqual(notices[0][1]['requestId'], 'guard-7:identity')


if __name__ == '__main__':
    unittest.main()
