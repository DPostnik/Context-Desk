"""Lead-owned counterexamples: tool return is neither cessation nor cancel ACK."""
from pathlib import Path
import sys
import threading
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from contract import Result, Target
from runner.core import DirectRunner


class FiniteDelayedAdapter:
    candidate_id = 'double'
    candidate_version = '1'

    def __init__(self):
        self.release = threading.Event()
        self.effect = threading.Event()
        self.started = threading.Event()
        self.threads = []

    def preflight(self):
        return Result('passed')

    def attach(self, request):
        return Result('passed')

    def execute(self, request):
        self.started.set()
        if request.operation == 'wait':
            self.release.wait(1)
        else:
            def delayed():
                if self.release.wait(1):
                    self.effect.set()
            thread = threading.Thread(target=delayed)
            self.threads.append(thread)
            thread.start()
        return Result('passed', dispatched=True)

    def cancel(self, request_id):
        return Result('not applicable', error='No cancellation primitive')

    def inspect_state(self):
        return {}

    def detach(self):
        return Result('passed')

    def finish(self):
        self.release.set()
        for thread in self.threads:
            thread.join(2)
            assert not thread.is_alive()


class HostBoundaryChecks(unittest.TestCase):
    def setUp(self):
        self.adapter = FiniteDelayedAdapter()
        self.target = Target('run', 'generation', 'http://127.0.0.1:1234/run/A',
                             'nonce', 'explicit-profile', '1')
        self.runner = DirectRunner(self.adapter, self.target)
        self.assertEqual(self.runner.preflight().status, 'passed')
        self.assertEqual(self.runner.attach().status, 'passed')

    def tearDown(self):
        self.adapter.finish()
        self.runner.close()

    def test_completed_script_can_still_have_a_future_effect(self):
        self.assertEqual(self.runner.dispatch('evaluate', {'script': 'finite timer'}).status, 'passed')
        self.runner.stop()
        self.assertTrue(self.runner.uncertain, 'completed RPC cannot release page-side work')
        self.assertEqual(self.runner.dispatch('click').status, 'blocked')
        self.adapter.release.set()
        self.assertTrue(self.adapter.effect.wait(1))
        self.assertIsNone(self.runner.timestamps['cessation_verified'])

    def test_unsupported_cancel_is_not_an_acknowledgment(self):
        call = threading.Thread(target=lambda: self.runner.dispatch('wait'))
        call.start()
        try:
            self.assertTrue(self.adapter.started.wait(1))
            self.runner.stop()
            self.assertIsNone(self.runner.timestamps['cancel_ack'])
            self.assertTrue(self.runner.uncertain)
        finally:
            self.adapter.release.set()
            call.join(2)
            self.assertFalse(call.is_alive())

    def test_runtime_label_can_be_supplied_explicitly(self):
        value = self.runner.evidence('E00', 'label-only', 'blocked', evidence_level='runtime')
        self.assertEqual(value['evidence_level'], 'runtime')
        # This checks serialization only; this test is not runtime browser evidence.


if __name__ == '__main__':
    unittest.main(verbosity=2)
