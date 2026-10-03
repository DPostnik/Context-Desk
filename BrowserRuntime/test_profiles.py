"""Profile leases across actual MCP/executor processes, with synthetic websites."""
import fcntl
import json
import os
from pathlib import Path
import threading
import time
import unittest
import uuid
import test_multi_client as multi
from profiles import validate, idle
from server import Rejected
from chrome_host import ChromeHost
from unittest.mock import patch


class ProfileTests(unittest.TestCase):
    start_executor = multi.MultiClientTests.start_executor
    client = multi.MultiClientTests.client
    call = multi.MultiClientTests.call
    opened = multi.MultiClientTests.opened
    trace = multi.MultiClientTests.trace
    tearDown = multi.MultiClientTests.tearDown

    def setUp(self):
        multi.MultiClientTests.setUp(self)
        self.catalog = self.root / 'profiles.json'
        self.root = self.root / 'environments' / str(uuid.uuid4())
        self.root.mkdir(parents=True)
        self.lease = str(uuid.uuid4())
        self.project = self.root / 'project'
        self.project.mkdir()
        self.write_catalog()

    def write_catalog(self, state='active', lease=None):
        value = {'schema': 1, 'profiles': {self.root.name: {
            'id': self.root.name.upper(), 'generation': (lease or self.lease).upper(),
            'state': state, 'owner': 'native-session-key', 'project': str(self.project.resolve())}}}
        temporary = self.catalog.with_suffix('.tmp')
        temporary.write_text(json.dumps(value))
        os.replace(temporary, self.catalog)

    def test_old_connected_client_and_legacy_client_cannot_dispatch_after_handoff(self):
        self.start_executor()
        a = self.client(workspace=self.project, lease=self.lease)
        self.opened(a)
        old_count = len(self.trace())
        next_lease = str(uuid.uuid4())
        with (self.root / 'operation.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.write_catalog(lease=next_lease)
        for client in (a, self.client(workspace=self.project)):
            result = self.call(client, 'browser_open', url='https://example.test/')
            self.assertTrue(result['isError'])
            self.assertIn('No action was sent', result['content'][0]['text'])
        self.assertEqual(len(self.trace()), old_count)
        self.opened(self.client(workspace=self.project, lease=next_lease))

    def test_queued_request_rechecks_lease_after_acquiring_operation_lock(self):
        self.start_executor()
        client = self.client(workspace=self.project, lease=self.lease)
        self.opened(client)
        answers = []
        count = len(self.trace())
        with (self.root / 'operation.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            thread = threading.Thread(target=lambda: answers.append(self.call(client, 'browser_open', url='https://example.test/queued')))
            thread.start()
            time.sleep(0.2)
            self.write_catalog(lease=str(uuid.uuid4()))
        thread.join(5)
        self.assertFalse(thread.is_alive())
        self.assertTrue(answers[0]['isError'])
        self.assertEqual(len(self.trace()), count)

    def test_wrong_project_and_pending_human_unknown_states_fail_closed(self):
        for state in ('pending', 'configuring', 'human', 'available', 'future-state'):
            self.write_catalog(state=state)
            with self.assertRaises(Rejected):
                validate(self.root, self.lease, self.project)
        self.write_catalog()
        with self.assertRaises(Rejected):
            validate(self.root, self.lease, self.root)
        validate(self.root, self.lease, self.project)
        self.write_catalog(state='human')
        validate(self.root, self.lease, allow_human=True)
        with self.assertRaises(Rejected):
            validate(self.root, str(uuid.uuid4()), allow_human=True)

    def test_corruption_and_missing_catalog_never_downgrade_a_leased_client(self):
        for value in ('{bad}', '{}', '{"schema":2,"profiles":{}}'):
            self.catalog.write_text(value)
            for lease in (None, self.lease):
                with self.assertRaises(Rejected):
                    validate(self.root, lease, self.project)
        self.catalog.unlink()
        with self.assertRaises(Rejected):
            validate(self.root, self.lease, self.project)
        validate(self.root, None, self.project)
        (self.catalog.parent / 'profiles-required').write_text('1')
        with self.assertRaises(Rejected):
            validate(self.root, None, self.project)

    def test_native_idle_check_never_signals_or_launches_and_requires_known_exit(self):
        host = ChromeHost(self.root)
        host.record.write_text('{"pid":123,"birth":"fixture"}')
        with patch.object(host, 'process_gone', return_value=False), patch('chrome_host.os.kill') as signal:
            with self.assertRaises(Rejected): idle(host)
            signal.assert_not_called()
        with patch.object(host, 'process_gone', return_value=True):
            idle(host)
        host.record.unlink()
        (self.root / 'executor-in-flight.json').write_text('{}')
        with self.assertRaises(Rejected): idle(host)


if __name__ == '__main__':
    unittest.main()
