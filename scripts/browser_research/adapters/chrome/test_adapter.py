"""C01 protocol-double checks. Never connects to a browser or starts a driver."""

import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from adapters.chrome import ChromeAdapter
from contract import Request, Target
from evidence import ROOT


def mcp(value):
    return {'content': [{'type': 'text', 'text': 'Script ran on page and returned:\n```json\n' +
                                               json.dumps(value) + '\n```'}]}


class Double:
    def __init__(self, observed):
        self.observed = observed
        self.calls = []
        self.fail_action = False
        self.action_started = threading.Event()
        self.action_continue = threading.Event()
        self.hold_action = False
        self.guard_started = threading.Event()
        self.guard_continue = threading.Event()
        self.hold_guard = False

    def __call__(self, method, params, request_id, deadline_ns):
        self.calls.append((method, params, request_id, deadline_ns))
        if params['name'] == 'evaluate_script' and request_id.endswith((':attach', ':guard')):
            self.guard_started.set()
            if self.hold_guard:
                self.guard_continue.wait(2)
            return mcp(self.observed)
        self.action_started.set()
        if self.hold_action:
            self.action_continue.wait(2)
        if self.fail_action:
            raise ConnectionError('simulated transport loss')
        return {'content': [{'type': 'text', 'text': 'controlled response'}]}


class ChromeAdapterTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
        cls.check_root = Path(tempfile.mkdtemp(prefix='chrome-checks-', dir=ROOT))
        os.chmod(cls.check_root, 0o700)
        cls.target = Target('run-1', 'generation-1', 'http://127.0.0.1:34981/run-1/A',
                            'nonce-1', 'selected-profile', '7')
        cls.observed = {'run_id': 'run-1', 'generation': 'generation-1',
                        'target': 'A', 'url': cls.target.url, 'nonce': 'nonce-1',
                        'stored_nonce': 'nonce-1'}

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.check_root)

    def setUp(self):
        self.driver = Double(dict(self.observed))
        self.adapter = ChromeAdapter(self.driver, browser_consent=True,
                                     current_profile='selected-profile', runtime_binding_verified=True,
                                     allowed_upload_roots=(self.check_root,))
        self.assertEqual(self.adapter.preflight().status, 'passed')

    def request(self, operation, arguments=None, target=None, request_id='request-1'):
        return Request(request_id, target or self.target, operation, arguments or {},
                       time.monotonic_ns() + 5_000_000_000)

    def attach(self):
        result = self.adapter.attach(self.request('attach'))
        self.assertEqual(result.status, 'passed', result.error)
        return result

    def test_e00_artifact_is_read_only_and_preflight_does_not_call_rpc(self):
        self.assertEqual(len(self.driver.calls), 0)
        self.assertEqual(self.adapter.preflight().value['files'], 359)
        self.assertEqual(len(self.driver.calls), 0)

    def test_e01_denied_consent_and_exact_identity(self):
        denied = ChromeAdapter(self.driver, browser_consent=False,
                               current_profile='selected-profile', runtime_binding_verified=True)
        denied.preflight()
        self.assertEqual(denied.attach(self.request('attach')).status, 'blocked')
        self.assertEqual(self.driver.calls, [])
        self.attach()
        self.assertEqual(self.driver.calls[0][1]['arguments']['pageId'], 7)

    def test_e02_decoy_stale_and_profile_denied(self):
        self.driver.observed['target'] = 'decoy'
        result = self.adapter.attach(self.request('attach'))
        self.assertEqual(result.status, 'blocked')
        self.assertIsNone(self.adapter.inspect_state()['attached_target'])
        self.driver.observed = dict(self.observed)
        self.attach()
        wrong = Target(self.target.run_id, self.target.generation, self.target.url,
                       self.target.nonce, self.target.profile, '8')
        calls = len(self.driver.calls)
        self.assertEqual(self.adapter.execute(self.request('click', {'uid': 'x'}, wrong)).status, 'blocked')
        self.assertEqual(len(self.driver.calls), calls)
        self.driver.observed['generation'] = 'new-generation'
        result = self.adapter.execute(self.request('click', {'uid': 'x'}))
        self.assertEqual(result.status, 'blocked')
        self.assertEqual(self.driver.calls[-1][1]['name'], 'evaluate_script')

    def test_e03_e06_operation_mapping_and_rejections(self):
        self.attach()
        mappings = [('observe', {}, 'take_snapshot'),
                    ('click', {'uid': '12'}, 'click'),
                    ('fill', {'uid': '13', 'value': 'synthetic'}, 'fill'),
                    ('evaluate', {'function': '() => 1'}, 'evaluate_script'),
                    ('wait', {'text': ['Ready']}, 'wait_for')]
        for operation, arguments, tool in mappings:
            result = self.adapter.execute(self.request(operation, arguments, request_id=operation))
            self.assertEqual(result.status, 'passed', result.error)
            self.assertEqual(self.driver.calls[-1][1]['name'], tool)
            self.assertEqual(self.driver.calls[-1][1]['arguments']['pageId'], 7)
        pdf = self.check_root / 'synthetic.pdf'
        pdf.write_bytes(b'%PDF-synthetic')
        result = self.adapter.execute(self.request('upload', {'uid': '15', 'filePaths': [str(pdf)]}))
        self.assertEqual(result.status, 'passed')
        calls = len(self.driver.calls)
        self.assertEqual(self.adapter.execute(self.request('download')).status, 'not applicable')
        self.assertEqual(self.adapter.execute(self.request('click', {'uid': '1', 'pageId': 8})).status, 'blocked')
        self.assertEqual(self.adapter.execute(self.request('upload', {'uid': '1', 'filePaths': ['/etc/hosts']})).status, 'blocked')
        self.assertEqual(len(self.driver.calls), calls)

    def test_e07_cancel_notification_is_not_ack_or_cessation(self):
        notices = []
        self.adapter._notify = lambda method, params: notices.append((method, params))
        self.attach()
        self.driver.hold_action = True
        results = []
        worker = threading.Thread(target=lambda: results.append(self.adapter.execute(
            self.request('click', {'uid': '16'}, request_id='in-flight'))))
        worker.start()
        self.assertTrue(self.driver.action_started.wait(2))
        cancel = self.adapter.cancel('in-flight')
        self.assertEqual(cancel.status, 'not applicable')
        self.assertTrue(cancel.uncertain)
        self.assertIsNone(cancel.details['cancel_ack'])
        self.assertEqual(notices, [('notifications/cancelled', {'requestId': 'in-flight', 'reason': 'research Stop'})])
        self.driver.action_continue.set()
        worker.join(3)
        self.assertFalse(worker.is_alive())
        self.assertEqual(results[0].status, 'failed')
        self.assertTrue(results[0].uncertain)
        self.assertEqual(self.adapter.detach().status, 'blocked')

    def test_e07_unsupported_cancellation(self):
        self.attach()
        self.driver.hold_action = True
        results = []
        worker = threading.Thread(target=lambda: results.append(self.adapter.execute(
            self.request('click', {'uid': '16'}, request_id='in-flight'))))
        worker.start()
        self.assertTrue(self.driver.action_started.wait(2))
        cancel = self.adapter.cancel('in-flight')
        self.assertEqual(cancel.status, 'not applicable')
        self.assertTrue(cancel.uncertain)
        self.driver.action_continue.set()
        worker.join(3)
        self.assertEqual(results[0].status, 'failed')

    def test_e07_stop_during_guard_withholds_action_and_attach(self):
        notices = []
        self.adapter._notify = lambda method, params: notices.append((method, params))
        self.driver.hold_guard = True
        results = []
        worker = threading.Thread(target=lambda: results.append(self.adapter.attach(
            self.request('attach', request_id='attach-stop'))))
        worker.start()
        self.assertTrue(self.driver.guard_started.wait(2))
        cancel = self.adapter.cancel('attach-stop')
        self.assertEqual(cancel.details['cancelled_rpc_id'], 'attach-stop:attach')
        self.driver.guard_continue.set()
        worker.join(3)
        self.assertFalse(worker.is_alive())
        self.assertEqual(results[0].status, 'blocked')
        self.assertIsNone(self.adapter.inspect_state()['attached_target'])
        self.assertEqual(len(self.driver.calls), 1)

        other = ChromeAdapter(self.driver, browser_consent=True, current_profile='selected-profile',
                              runtime_binding_verified=True, notify=lambda m, p: notices.append((m, p)))
        other.preflight()
        self.driver.hold_guard = False
        self.assertEqual(other.attach(self.request('attach')).status, 'passed')
        self.driver.guard_started.clear()
        self.driver.guard_continue.clear()
        self.driver.hold_guard = True
        calls = len(self.driver.calls)
        worker = threading.Thread(target=lambda: results.append(other.execute(
            self.request('click', {'uid': '16'}, request_id='guard-stop'))))
        worker.start()
        self.assertTrue(self.driver.guard_started.wait(2))
        cancel = other.cancel('guard-stop')
        self.assertEqual(cancel.details['cancelled_rpc_id'], 'guard-stop:guard')
        self.driver.guard_continue.set()
        worker.join(3)
        self.assertFalse(worker.is_alive())
        self.assertEqual(results[-1].status, 'blocked')
        self.assertEqual(len(self.driver.calls), calls + 1)
        self.assertEqual(self.driver.calls[-1][1]['name'], 'evaluate_script')
        self.assertEqual(notices[0][1]['requestId'], 'attach-stop:attach')
        self.assertEqual(notices[1][1]['requestId'], 'guard-stop:guard')

    def test_e08_e09_transport_loss_and_owned_detach(self):
        self.attach()
        self.driver.fail_action = True
        result = self.adapter.execute(self.request('fill', {'uid': '20', 'value': 'x'}))
        self.assertEqual(result.status, 'failed')
        self.assertTrue(result.uncertain)
        self.assertEqual(self.adapter.execute(self.request('observe')).status, 'blocked')
        self.assertEqual(self.adapter.detach().status, 'blocked')
        closed = []
        other = ChromeAdapter(self.driver, browser_consent=True, current_profile='selected-profile',
                              runtime_binding_verified=True,
                              close_owned_transport=lambda: closed.append('owned child only'))
        other.preflight()
        self.driver.fail_action = False
        self.assertEqual(other.attach(self.request('attach')).status, 'passed')
        self.assertEqual(other.detach().status, 'passed')
        self.assertEqual(closed, ['owned child only'])


if __name__ == '__main__':
    unittest.main()
