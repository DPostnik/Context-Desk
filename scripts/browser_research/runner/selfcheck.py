#!/usr/bin/env python3
"""Offline protocol-double and loopback-Lab runner checks; no browser calls."""
from dataclasses import replace
import json
import os
from pathlib import Path
import sys
import threading
import time
import unittest
import uuid

from contract import Result, Target
from evidence import ROOT
from fixture import Lab
from oracle import Oracle
from runner import DirectRunner, RunnerError, StdioRPC, TransportError, WireGate, WireRejected


class DoubleAdapter:
    candidate_id = 'DOUBLE'
    candidate_version = '0'

    def __init__(self, lab=None, *, delay=0, cancel_result=None):
        self.lab = lab
        self.delay = delay
        self.cancel_result = cancel_result or Result('not applicable', error='cancel unsupported')
        self.calls = []

    def preflight(self):
        self.calls.append('preflight')
        return Result('passed')

    def attach(self, request):
        self.calls.append(('attach', request))
        return Result('passed', value={'target': request.target.target_id})

    def execute(self, request):
        self.calls.append(('execute', request))
        if self.delay:
            time.sleep(self.delay)
        if self.lab and request.operation == 'click':
            self.lab.action('event', {'target': 'A', 'generation': self.lab.generation['A'],
                                      'kind': 'input', 'detail': {'request_id': request.request_id}})
        if self.lab and request.operation == 'evaluate':
            self.lab.action('site-delay', {})
        return Result('passed', value={'request_id': request.request_id}, dispatched=True)

    def cancel(self, request_id):
        self.calls.append(('cancel', request_id))
        return self.cancel_result

    def inspect_state(self):
        return {'double': True}

    def detach(self):
        self.calls.append('detach')
        return Result('passed')


class RunnerChecks(unittest.TestCase):
    root = None

    def setUp(self):
        self.lab = Lab(self.root).start()
        self.target = Target(self.lab.run, self.lab.generation['A'],
            self.lab.origins[0] + '/' + self.lab.run + '/A', 'preloaded-nonce',
            'synthetic-profile', 'synthetic-target-A')

    def tearDown(self):
        self.lab.close()
        self.assertTrue(all(not t.is_alive() for t in self.lab.threads + self.lab.timers))

    def ready(self, adapter=None, *, case_seconds=1, watchdog_seconds=4):
        adapter = adapter or DoubleAdapter(self.lab)
        runner = DirectRunner(adapter, self.target, case_seconds=case_seconds,
                              watchdog_seconds=watchdog_seconds)
        self.assertEqual(runner.preflight().status, 'passed')
        self.assertEqual(runner.attach().status, 'passed')
        return runner, adapter

    def test_rejected_dispatch_never_reaches_double_or_lab(self):
        runner, adapter = self.ready()
        stale = replace(self.target, generation='stale')
        self.assertFalse(runner.dispatch('click', target=stale).dispatched)
        self.assertFalse(runner.dispatch('arbitrary').dispatched)
        self.assertEqual([c for c in adapter.calls if isinstance(c, tuple) and c[0] == 'execute'], [])
        self.assertEqual(Oracle(self.lab.directory).of('page-event'), [])
        runner.stop()
        self.assertFalse(runner.dispatch('click').dispatched)
        runner.close()

    def test_stop_during_call_latches_and_late_completion_is_ignored(self):
        runner, adapter = self.ready(DoubleAdapter(self.lab, delay=0.2), case_seconds=0.1)
        result = runner.dispatch('click')
        self.assertEqual(result.status, 'failed')
        self.assertTrue(result.uncertain)
        self.assertIsNone(runner.timestamps['cancel_ack'])
        self.assertFalse(runner.dispatch('click').dispatched)
        time.sleep(0.25)
        self.assertEqual(len(Oracle(self.lab.directory).of('page-event')), 1)
        self.assertTrue(any(e['kind'] == 'late_adapter_completion' for e in runner.audit))
        with self.assertRaises(RunnerError):
            runner.evidence('E07', 'double', 'passed')
        runner.close()

    def test_stop_after_completed_effect_retains_uncertainty_and_observes_site_effect(self):
        runner, _ = self.ready()
        self.assertEqual(runner.dispatch('evaluate').status, 'passed')
        runner.stop()
        self.assertTrue(runner.uncertain)
        self.assertIsNone(runner.timestamps['cancel_ack'])
        since = runner.timestamps['stop_received']
        with self.assertRaises(ValueError):
            runner.observe_after_cancel(lambda: {}, seconds=0.1)
        readback = runner.observe_after_cancel(
            lambda: Oracle(self.lab.directory).lifecycle_readback('A', since),
            seconds=0.5, protocol_double=True)
        self.assertEqual(len(readback['second']['site_responses']), 1)
        self.assertFalse(readback['second']['cessation_verified'])
        with self.assertRaises(RunnerError):
            runner.reconcile(observer='fixture-ledger', evidence={'executor_drained': True},
                             cessation_condition='quiet ledger', observed_at_ns=time.monotonic_ns())
        evidence = runner.evidence('E07', 'double-site-delay', 'failed',
                                   evidence_level='protocol double')
        self.assertTrue(evidence['outcome_uncertain'])
        runner.close()

    def test_url_identity_validation(self):
        adapter = DoubleAdapter()
        for url in ('http://127.0.0.1:123@external.example/x/A',
                    'http://127.0.0.1:123/' + self.lab.run + '/A?fallback=1',
                    'https://127.0.0.1:123/' + self.lab.run + '/A'):
            with self.assertRaises(ValueError):
                DirectRunner(adapter, replace(self.target, url=url))

    def test_observer_timeout_keeps_uncertainty_and_audit(self):
        runner, _ = self.ready(case_seconds=0.1, watchdog_seconds=0.3)
        self.assertEqual(runner.dispatch('click').status, 'passed')
        runner.stop()
        release = threading.Event()
        try:
            with self.assertRaises(RunnerError):
                runner.observe_after_cancel(lambda: release.wait(1),
                                            seconds=0.01, protocol_double=True)
            self.assertTrue(runner.uncertain)
            self.assertTrue(any(e['kind'] == 'observer_timeout' and e['outstanding_reader']
                                for e in runner.audit))
        finally:
            release.set()
            runner.close()


class StdioChecks(unittest.TestCase):
    root = None

    def peer(self, mode):
        return StdioRPC([sys.executable, str(Path(__file__).with_name('protocol_double.py')), mode],
                        stderr_path=self.root / ('stderr-' + uuid.uuid4().hex + '.log')).start()

    def test_rpc_single_id_and_owned_cleanup(self):
        peer = self.peer('echo')
        try:
            result = peer.rpc('tools/list', {}, 'r1', time.monotonic_ns() + 1_000_000_000)
            self.assertEqual(result['method'], 'tools/list')
            with self.assertRaises(TransportError):
                peer.rpc('tools/list', {}, 'r1', time.monotonic_ns() + 1_000_000_000)
        finally:
            peer.close()
        self.assertIsNotNone(peer.process.returncode)
        self.assertEqual(peer.cleanup[-1]['scope'], 'direct owned child only')

    def test_browser_free_mcp_handshake_checks_exact_server_version(self):
        peer = self.peer('mcp-handshake')
        try:
            manifest = peer.initialize_mcp(expected_server_version='0.double')
            self.assertEqual(manifest['tools'], ['double_tool'])
        finally:
            peer.close()
        mismatch = self.peer('mcp-handshake')
        with self.assertRaises(TransportError):
            mismatch.initialize_mcp(expected_server_version='wrong')
        self.assertIsNotNone(mismatch.process.returncode)

    def test_late_response_does_not_satisfy_new_id(self):
        peer = self.peer('late')
        try:
            with self.assertRaises(TimeoutError):
                peer.rpc('slow', {}, 'old', time.monotonic_ns() + 30_000_000)
            time.sleep(0.25)
            self.assertEqual([x['id'] for x in peer.late_responses], ['old'])
            result = peer.rpc('fresh', {}, 'new', time.monotonic_ns() + 1_000_000_000)
            self.assertEqual(result['method'], 'fresh')
        finally:
            peer.close()

    def test_unknown_server_request_denied_and_transport_failed(self):
        peer = self.peer('server-request')
        try:
            with self.assertRaises(TransportError):
                peer.rpc('initialize', {}, 'client', time.monotonic_ns() + 1_000_000_000)
            self.assertEqual(peer.denied_server_messages[0]['method'], 'roots/list')
        finally:
            peer.close()

    def test_unknown_server_notification_fails_closed(self):
        peer = self.peer('server-notification')
        try:
            with self.assertRaises(TransportError):
                peer.rpc('initialize', {}, 'client', time.monotonic_ns() + 1_000_000_000)
            self.assertEqual(peer.denied_server_messages[0]['method'], 'unexpected/notice')
        finally:
            peer.close()

    def test_eof_is_not_a_successful_response(self):
        peer = self.peer('eof')
        try:
            with self.assertRaises(TransportError):
                peer.rpc('tools/call', {}, 'closed', time.monotonic_ns() + 1_000_000_000)
        finally:
            peer.close()

    def test_child_not_reading_large_write_is_bounded(self):
        peer = self.peer('noread')
        start = time.monotonic()
        try:
            with self.assertRaises(TimeoutError):
                peer.rpc('large', {'blob': 'x' * 2_000_000}, 'blocked',
                         time.monotonic_ns() + 100_000_000)
            self.assertLess(time.monotonic()-start, 0.8)
            with self.assertRaises(TransportError):
                peer.rpc('next', {}, 'next', time.monotonic_ns() + 1_000_000_000)
        finally:
            peer.close(grace_seconds=0.1)

    def test_wire_gate_blocks_second_action_after_stop_during_guard(self):
        peer = self.peer('late')
        target = Target('synthetic-run', 'generation-A',
            'http://127.0.0.1:12345/synthetic-run/A', 'nonce', 'profile', 'target')
        gate = WireGate(peer, target)
        class GuardThenAction(DoubleAdapter):
            def attach(self, request):
                gate.rpc('tools/call', {'name': 'identity', 'arguments': {}},
                         request.request_id + ':attach', request.deadline_ns)
                return Result('passed', dispatched=True)
            def execute(self, request):
                gate.rpc('tools/call', {'name': 'guard', 'arguments': {}},
                         request.request_id + ':guard', request.deadline_ns)
                gate.rpc('tools/call', {'name': 'action', 'arguments': {}},
                         request.request_id, request.deadline_ns)
                return Result('passed', dispatched=True)
        adapter = GuardThenAction()
        runner = DirectRunner(adapter, target, wire_gate=gate, owned_transports=[peer],
                              case_seconds=0.6, watchdog_seconds=2)
        try:
            self.assertEqual(runner.preflight().status, 'passed')
            self.assertEqual(runner.attach().status, 'passed')
            box = []
            thread = threading.Thread(target=lambda: box.append(runner.dispatch('click')))
            thread.start()
            limit = time.monotonic()+1
            while not any(e['kind'] == 'wire_written' and e.get('tool') == 'guard'
                          for e in gate.audit) and time.monotonic() < limit:
                time.sleep(0.005)
            runner.stop()
            thread.join(timeout=1)
            self.assertFalse(thread.is_alive())
            self.assertTrue(box[0].uncertain)
            self.assertFalse(any(e['kind'] == 'wire_admitted' and e.get('tool') == 'action'
                                 for e in gate.audit))
            self.assertTrue(any(e['kind'] == 'wire_rejected' for e in gate.audit))
            self.assertFalse(runner.dispatch('click').dispatched)
        finally:
            runner.close()

    def test_wire_gate_rejects_unbound_rpc_before_write(self):
        peer = self.peer('echo')
        target = Target('synthetic-run', 'generation-A',
            'http://127.0.0.1:12345/synthetic-run/A', 'nonce', 'profile', 'target')
        gate = WireGate(peer, target)
        try:
            with self.assertRaises(WireRejected):
                gate.rpc('tools/call', {'name': 'action', 'arguments': {}}, 'unbound',
                         time.monotonic_ns() + 1_000_000_000)
            self.assertFalse(any(e['kind'] == 'wire_written' for e in gate.audit))
        finally:
            peer.close()

    def test_stop_intent_is_immediate_during_bounded_partial_write(self):
        peer = self.peer('noread')
        target = Target('synthetic-run', 'generation-A',
            'http://127.0.0.1:12345/synthetic-run/A', 'nonce', 'profile', 'target')
        gate = WireGate(peer, target)
        class BlockedAction(DoubleAdapter):
            def execute(self, request):
                gate.rpc('tools/call', {'name': 'action', 'arguments': {'blob': 'x' * 2_000_000}},
                         request.request_id, request.deadline_ns)
                return Result('passed', dispatched=True)
        runner = DirectRunner(BlockedAction(), target, wire_gate=gate,
                              owned_transports=[peer], case_seconds=0.3,
                              watchdog_seconds=1)
        try:
            self.assertEqual(runner.preflight().status, 'passed')
            self.assertEqual(runner.attach().status, 'passed')
            box = []
            thread = threading.Thread(target=lambda: box.append(runner.dispatch('click')))
            thread.start()
            limit = time.monotonic()+0.2
            while not any(e['kind'] == 'wire_admitted' for e in gate.audit) and time.monotonic() < limit:
                time.sleep(0.002)
            started = time.monotonic()
            runner.stop()
            self.assertLess(time.monotonic()-started, 0.1)
            thread.join(timeout=0.6)
            self.assertFalse(thread.is_alive())
            self.assertTrue(box[0].uncertain)
            self.assertFalse(runner.dispatch('click').dispatched)
            self.assertTrue(any(e['kind'] == 'wire_write_failed_or_partial' for e in gate.audit))
        finally:
            runner.close()


def main():
    os.umask(0o077)
    root = ROOT / ('runner-checks-' + uuid.uuid4().hex)
    root.mkdir(parents=True, mode=0o700)
    RunnerChecks.root = root
    StdioChecks.root = root
    suite = unittest.TestSuite((unittest.defaultTestLoader.loadTestsFromTestCase(RunnerChecks),
                                unittest.defaultTestLoader.loadTestsFromTestCase(StdioChecks)))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    summary = {'kind': 'protocol-double-and-loopback', 'tests': result.testsRun,
               'passed': result.wasSuccessful(), 'errors': [str(e) for _, e in result.errors],
               'failures': [str(e) for _, e in result.failures],
               'browser_attached': False, 'model_called': False,
               'interpretation': 'Doubles test host behavior; they do not prove real browser cessation'}
    path = root / 'summary.json'
    path.write_text(json.dumps(summary, indent=2) + '\n')
    path.chmod(0o600)
    print(path)
    return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    raise SystemExit(main())
