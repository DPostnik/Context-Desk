"""Cross-package checks with real Lab/oracle and controlled candidate RPC doubles."""
import json
from pathlib import Path
import sys
import threading
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from adapters.chrome import ChromeAdapter
from adapters.playwright.adapter import PlaywrightAdapter
from contract import Request, Target
from fixture import Lab
from oracle import Oracle
from runner.core import DirectRunner


class CandidateDouble:
    def __init__(self, candidate, target):
        self.candidate, self.target = candidate, target
        self.calls = []
        self.pause = False
        self.guard_started = threading.Event()
        self.release = threading.Event()

    def __call__(self, method, params, request_id, deadline_ns):
        self.calls.append((params['name'], request_id))
        tool = params['name']
        if tool == 'browser_tabs':
            text = '### Result\n- 0: (current) [Synthetic browser research](' + self.target.url + ')\n'
        elif tool in ('evaluate_script', 'browser_evaluate'):
            if self.pause:
                self.guard_started.set()
                if not self.release.wait(2):
                    raise TimeoutError('finite double guard deadline')
            t = self.target
            identity = dict(generation=t.generation, target='A', url=t.url, nonce=t.nonce)
            if self.candidate == 'C01':
                identity.update(run_id=t.run_id, stored_nonce=t.nonce)
                text = 'Script ran on page and returned:\n```json\n' + json.dumps(identity) + '\n```'
            else:
                identity['run'] = t.run_id
                text = '### Result\n' + json.dumps(identity) + '\n'
        else:
            text = '### Result\nok\n'
        return {'content': [{'type': 'text', 'text': text}]}


class CrossPackageChecks(unittest.TestCase):
    def test_malformed_chrome_identity_retains_uncertainty(self):
        target = Target('run', 'generation', 'http://127.0.0.1:12345/run/A',
                        'nonce', 'synthetic-profile', '1')
        adapter = ChromeAdapter(lambda *args: [], browser_consent=True,
                                current_profile=target.profile, runtime_binding_verified=True)
        self.assertEqual(adapter.preflight().status, 'passed')
        result = adapter.attach(Request('malformed', target, 'attach', {},
                                       time.monotonic_ns() + 1_000_000_000))
        self.assertEqual(result.status, 'failed')
        self.assertTrue(result.uncertain)
        self.assertEqual(adapter.detach().status, 'blocked')

    def exercise(self, candidate):
        lab = Lab()
        runner = None
        worker = None
        try:
            lab.action('event', dict(target='A', generation=lab.generation['A'],
                       top_level=True, kind='loaded', detail={'nonce': 'protocol-double-nonce'}))
            nonce = Oracle(lab.directory).loaded_nonce('A', time.monotonic_ns())
            target = Target(lab.run, lab.generation['A'], 'http://127.0.0.1:12345/' + lab.run + '/A',
                            nonce, 'synthetic-profile', '1' if candidate == 'C01' else 'index:0')
            rpc = CandidateDouble(candidate, target)
            if candidate == 'C01':
                adapter = ChromeAdapter(rpc, browser_consent=True, current_profile=target.profile,
                                        runtime_binding_verified=True)
                arguments = {'uid': 'fixture-button'}
                action_tool = 'click'
            else:
                adapter = PlaywrightAdapter(rpc, artifact_verified=True, extension_version='0.4.0',
                       extension_artifact_sha256='a' * 64, selected_profile=target.profile,
                       connection_approved=True)
                arguments = {'target': '#next'}
                action_tool = 'browser_click'
            runner = DirectRunner(adapter, target)
            self.assertEqual(runner.preflight().status, 'passed')
            self.assertEqual(runner.attach().status, 'passed')
            json.dumps(adapter.inspect_state())
            rpc.pause = True
            results = []
            worker = threading.Thread(target=lambda: results.append(runner.dispatch('click', arguments)))
            worker.start()
            self.assertTrue(rpc.guard_started.wait(1))
            runner.stop()
            rpc.release.set()
            worker.join(3)
            self.assertFalse(worker.is_alive())
            self.assertTrue(runner.uncertain)
            self.assertFalse(any(tool == action_tool for tool, _ in rpc.calls))
            before = len(rpc.calls)
            self.assertEqual(runner.dispatch('click', arguments).status, 'blocked')
            self.assertEqual(len(rpc.calls), before)
            self.assertIsNone(runner.timestamps['cancel_ack'])
            value = runner.evidence('E07', 'integrated-guard-double', 'blocked',
                       adapter_state=adapter.inspect_state(), oracle_evidence=[str(lab.directory)])
            self.assertEqual(value['evidence_level'], 'protocol double')
            json.dumps(value)
        finally:
            if 'rpc' in locals():
                rpc.release.set()
            if worker:
                worker.join(3)
            if runner:
                runner.close()
            lab.close()

    def test_chrome_runner_oracle_contract(self):
        self.exercise('C01')

    def test_playwright_runner_oracle_contract(self):
        self.exercise('C02')


if __name__ == '__main__':
    unittest.main(verbosity=2)
