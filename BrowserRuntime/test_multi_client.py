"""Exercise real MCP processes and leases with a deterministic browser backend.

BROWSER_RUNTIME_UNDER_TEST selects the signed app's resources for bundle checks.
No installed browser/profile or app session is touched.
"""
import fcntl
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import threading
import unittest
from unittest.mock import Mock

sys.dont_write_bytecode = True
RUNTIME = Path(os.environ.get('BROWSER_RUNTIME_UNDER_TEST', Path(__file__).parent)).resolve()
sys.path.insert(0, str(RUNTIME))
import server
from transport import StdioRPC


def serve_fake():
    original = server.LeasedBrowser.__init__

    def initialize(self, root, **kwargs):
        def rpc(name, arguments):
            with (Path(root) / 'dispatch.jsonl').open('a') as stream:
                stream.write(json.dumps({'pid': os.getpid(), 'name': name, 'args': arguments}) + '\n')
            if name == 'new_page':
                return {'content': [{'type': 'text', 'text': '7: ' + arguments['url']}]}
            if name == 'evaluate_script':
                return {'content': [{'type': 'text', 'text': '```json\n' + json.dumps({'url': 'https://example.test/', 'readyState': 'complete'}) + '\n```'}]}
            if name == 'click':
                if arguments.get('uid') == 'wait-for-disconnect':
                    self.stopped.wait(5)
                raise TimeoutError('injected lost response after dispatch')
            return {'content': [{'type': 'text', 'text': '## Pages\n1: about:blank'}]}
        original(self, root, rpc=rpc, **kwargs)
    server.LeasedBrowser.__init__ = initialize
    sys.argv = [str(RUNTIME / 'server.py'), *sys.argv[2:]]
    server.main()


class MultiClientTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.clients = []
        self.sequence = 0

    def tearDown(self):
        for client in self.clients:
            client.close()
        self.directory.cleanup()

    def client(self, language='en', fake=True):
        command = ([sys.executable, '-B', str(Path(__file__).resolve()), '--serve-fake'] if fake else
                   [sys.executable, '-B', str(RUNTIME / 'server.py')])
        client = StdioRPC(command + ['--root', str(self.root), '--language', language]).start()
        self.clients.append(client)
        info = client.initialize_mcp(expected_server_version=server.VERSION)
        self.assertEqual(len(info['tools']), 8)
        return client

    def call(self, client, tool, **arguments):
        self.sequence += 1
        return client.rpc('tools/call', {'name': tool, 'arguments': arguments}, str(self.sequence), time.monotonic_ns() + 3_000_000_000)

    def opened(self, client):
        result = self.call(client, 'browser_open', url='https://example.test/')
        self.assertFalse(result.get('isError'), result)
        return json.loads(result['content'][0]['text'])['session']

    def trace(self):
        return [json.loads(line) for line in (self.root / 'dispatch.jsonl').read_text().splitlines()]

    def test_real_catalog_available_to_two_clients_even_with_legacy_lock(self):
        with (self.root / 'executor.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            for language in ('ru', 'en'):
                client = self.client(language, fake=False)
                result = self.call(client, 'browser_open', url='https://example.test/')
                self.assertTrue(result['isError'])
                self.assertIn('Браузер занят' if language == 'ru' else 'browser is owned', result['content'][0]['text'])
                self.assertFalse((self.root / 'testing-profile').exists())

    def test_two_clients_close_handoff_and_token_isolation(self):
        a, b = self.client(), self.client()
        token = self.opened(a)
        count = len(self.trace())
        self.assertTrue(self.call(b, 'browser_open', url='https://example.test/')['isError'])
        self.assertTrue(self.call(b, 'browser_snapshot', session=token)['isError'])
        self.assertEqual(len(self.trace()), count)
        self.assertFalse(self.call(a, 'browser_close', session=token).get('isError'))
        new_token = self.opened(b)
        self.assertNotEqual(token, new_token)
        self.assertTrue(self.call(a, 'browser_snapshot', session=new_token)['isError'])

    def test_disconnect_releases_lease_without_closing_or_adopting_tab(self):
        a, b = self.client(), self.client()
        old = self.opened(a)
        a.close()
        self.assertIsNotNone(a.process.returncode)
        self.assertNotEqual(self.opened(b), old)
        self.assertFalse(any(row['name'] == 'close_page' for row in self.trace()))
        self.assertEqual(json.loads((self.root / 'records' / (old + '.json')).read_text())['state'], 'disconnected')

    def test_uncertain_action_never_replays_after_failure_or_handoff(self):
        a, b = self.client(), self.client()
        token = self.opened(a)
        arguments = dict(session=token, actionID='uncertain-action', expectedURL='https://example.test/', name='click', arguments={'uid': '1_1'})
        for _ in range(2):
            self.assertTrue(self.call(a, 'browser_action', **arguments)['isError'])
        self.assertTrue(self.call(b, 'browser_open', url='https://example.test/')['isError'])
        a.close()
        arguments['session'] = self.opened(b)
        self.assertTrue(self.call(b, 'browser_action', **arguments)['isError'])
        self.assertEqual(sum(row['name'] == 'click' for row in self.trace()), 1)
        record = json.loads((self.root / 'records/action-uncertain-action.json').read_text())
        self.assertEqual(record['state'], 'outcome_unknown')

    def disconnect_in_flight(self, cancel):
        a, b = self.client(), self.client()
        token = self.opened(a)
        errors = []
        def action():
            try:
                a.rpc('tools/call', {'name': 'browser_action', 'arguments': {
                    'session': token, 'actionID': 'disconnect-action',
                    'expectedURL': 'https://example.test/', 'name': 'click',
                    'arguments': {'uid': 'wait-for-disconnect'}}}, 'active',
                    time.monotonic_ns() + 8_000_000_000)
            except Exception as error:
                errors.append(error)
        worker = threading.Thread(target=action)
        worker.start()
        deadline = time.monotonic() + 3
        while not any(row['name'] == 'click' for row in self.trace()):
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.01)
        if cancel:
            a.notify('notifications/cancelled', {'requestId': 'active'})
            a.process.wait(timeout=3)
        else:
            a.close(grace_seconds=3)
        worker.join(timeout=3)
        self.assertFalse(worker.is_alive())
        self.assertTrue(errors)
        self.opened(b)
        self.assertEqual(sum(row['name'] == 'click' for row in self.trace()), 1)
        self.assertEqual(json.loads((self.root / 'records/action-disconnect-action.json').read_text())['state'], 'outcome_unknown')

    def test_eof_during_action_releases_without_replay(self):
        self.disconnect_in_flight(cancel=False)

    def test_active_cancellation_releases_without_replay(self):
        self.disconnect_in_flight(cancel=True)

    def test_release_waits_for_owned_transport_cleanup(self):
        a = server.LeasedBrowser(self.root)
        b = server.LeasedBrowser(self.root)
        a.acquire()
        transport = Mock()
        def close():
            with self.assertRaises(server.Rejected):
                b.acquire()
        transport.close.side_effect = close
        a.transport = transport
        a.disconnect()
        b.acquire()
        b.disconnect()
        self.assertIsNone(a.transport)
        self.assertIsNone(a.lease)


if __name__ == '__main__':
    if '--serve-fake' in sys.argv:
        serve_fake()
    else:
        unittest.main()
