import io
import base64
import hashlib
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch, Mock

from chrome_host import ChromeHost, ChromeLaunchError, chrome_command


class ChromeHostTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.host = ChromeHost(self.temp.name)
        self.owner = dict(pid=123, port=9233, executable=ChromeHost.executables()[0],
                          profile=str(self.host.profile), birth='birth')

    def test_normal_launch(self):
        command = chrome_command(self.owner['executable'], self.host.profile, 9233)
        for forbidden in ('--enable-automation', '--disable-sync', '--use-mock-keychain', '--password-store=basic'):
            self.assertNotIn(forbidden, command)
        self.assertIn('--remote-debugging-port=9233', command)
        with self.assertRaises(ValueError):
            chrome_command(self.owner['executable'], self.host.profile, 0)

    def test_graceful_close_sends_one_masked_fixed_command_after_endpoint_recheck(self):
        owner = dict(self.owner, browserPath='/devtools/browser/fixture')
        key = base64.b64encode(b'k' * 16).decode()
        accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
        header = b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + b'\r\n\r\n'
        connection = Mock()
        connection.recv.side_effect = [header, b'']
        context = Mock()
        context.__enter__ = Mock(return_value=connection)
        context.__exit__ = Mock(return_value=False)
        with patch('chrome_host.os.urandom', side_effect=[b'k' * 16, b'mask']), patch('chrome_host.socket.create_connection', return_value=context) as connect, \
             patch.object(self.host, 'matches', return_value=True), patch.object(self.host, 'owns_listener', return_value=True):
            self.host.graceful_close(owner)
        connect.assert_called_once_with(('127.0.0.1', owner['port']), timeout=2)
        self.assertEqual(connection.sendall.call_count, 2)
        frame = connection.sendall.call_args.args[0]
        self.assertEqual(frame[0], 0x81)
        self.assertEqual(frame[1] & 0x80, 0x80)
        mask, encoded = frame[2:6], frame[6:]
        self.assertEqual(json.loads(bytes(b ^ mask[i % 4] for i, b in enumerate(encoded))), {'id': 1, 'method': 'Browser.close'})

    def test_graceful_close_rejects_bad_handshake_before_command(self):
        connection = Mock()
        connection.recv.return_value = b'HTTP/1.1 200 OK\r\n\r\n'
        context = Mock()
        context.__enter__ = Mock(return_value=connection)
        context.__exit__ = Mock(return_value=False)
        with patch('chrome_host.socket.create_connection', return_value=context):
            with self.assertRaises(ChromeLaunchError):
                self.host.graceful_close(dict(self.owner, browserPath='/devtools/browser/fixture'))
        self.assertEqual(connection.sendall.call_count, 1)

    def test_regular_chrome_and_legacy_profile_are_never_adopted(self):
        legacy = dict(self.owner, executable='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome')
        self.assertFalse(self.host.matches(legacy))
        self.assertNotEqual(self.host.profile, self.host.root / 'profile')
        self.assertNotEqual(self.host.record, self.host.root / 'chrome-owner.json')
        self.assertTrue(all('Google Chrome for Testing.app' in p for p in self.host.executables()))

    def test_missing_testing_browser_does_not_fall_back_to_regular_chrome(self):
        with patch('chrome_host.os.access', return_value=False), patch('chrome_host.subprocess.Popen') as launch:
            with self.assertRaisesRegex(ChromeLaunchError, 'Chrome for Testing'):
                self.host.ensure()
        launch.assert_not_called()

    def test_process_identity_and_profile(self):
        command = ' '.join(chrome_command(self.owner['executable'], self.host.profile, 9233))
        with patch.object(self.host, 'process_field', side_effect=lambda pid, field: 'birth' if field == 'lstart' else command):
            self.assertTrue(self.host.matches(self.owner))
            self.assertFalse(self.host.matches(dict(self.owner, birth='reused pid')))
            self.assertFalse(self.host.matches(dict(self.owner, profile='/other/profile')))
            self.assertFalse(self.host.matches(dict(self.owner, executable='/other/chrome')))

    def test_listener_must_be_loopback_and_owned(self):
        with patch('chrome_host.subprocess.run') as run:
            for output, code, expected in [('p123\nn127.0.0.1:9233\n', 0, True),
                                           ('p123\nn*:9233\n', 0, False), ('', 1, False)]:
                run.return_value = Mock(stdout=output, returncode=code)
                self.assertEqual(self.host.owns_listener(123, 9233), expected)
            self.assertIn('123', run.call_args.args[0])

    def test_endpoint_identity(self):
        with patch.object(self.host, 'matches', return_value=True), patch.object(self.host, 'owns_listener', return_value=True):
            for endpoint, accepted in [('ws://127.0.0.1:9233/devtools/browser/one', True),
                                       ('ws://localhost:9233/devtools/browser/one', False),
                                       ('ws://127.0.0.1:9999/devtools/browser/one', False),
                                       ('ws://127.0.0.1:9233/devtools/browser/two', False)]:
                self.host.opener.open = Mock(return_value=io.BytesIO(json.dumps(dict(Browser='Chrome/1', webSocketDebuggerUrl=endpoint)).encode()))
                self.assertEqual(bool(self.host.endpoint(dict(self.owner, browserPath='/devtools/browser/one'))), accepted)

    def test_cancel_does_not_launch(self):
        event = threading.Event()
        event.set()
        with patch('chrome_host.subprocess.Popen') as launch, self.assertRaises(ChromeLaunchError):
            self.host.ensure(cancelled=event)
        launch.assert_not_called()

    def test_cookie_import_never_adopts_live_browser_or_retires_unknown_fence(self):
        self.host.persist(self.owner)
        fence = self.host.root / 'executor-in-flight.json'
        fence.write_text('{"state":"outcome_unknown"}')
        with patch.object(self.host, 'process_gone', return_value=False), patch.object(self.host, 'ensure') as launch:
            self.assertEqual(self.host.prepare_cookie_import(), {'code': 'destination_running'})
            launch.assert_not_called()
            self.assertTrue(fence.exists())
        self.host.record.unlink()
        with patch.object(self.host, 'ensure') as launch:
            self.assertEqual(self.host.prepare_cookie_import(), {'code': 'uncertain'})
            launch.assert_not_called()

    def test_cookie_import_retires_fence_only_after_confirmed_exit(self):
        self.host.persist(self.owner)
        fence = self.host.root / 'executor-in-flight.json'
        fence.write_text('{"state":"outcome_unknown"}')
        self.host.owner = dict(self.owner, browserPath='/devtools/browser/fixture')
        with patch.object(self.host, 'process_gone', return_value=True), patch.object(self.host, 'ensure', return_value='http://127.0.0.1:9233') as launch:
            self.assertEqual(self.host.prepare_cookie_import(), {'webSocketURL': 'ws://127.0.0.1:9233/devtools/browser/fixture'})
            self.assertEqual(launch.call_count, 1)
            self.assertFalse(fence.exists())

    def test_foreign_live_process_is_not_adopted(self):
        self.host.persist(self.owner)
        with patch.object(self.host, 'process_field', return_value='foreign'), patch('chrome_host.subprocess.Popen') as launch:
            with self.assertRaises(ChromeLaunchError):
                self.host.ensure()
            launch.assert_not_called()

    def test_reused_host_cannot_terminate_chrome(self):
        with patch('chrome_host.subprocess.Popen') as launch:
            self.host.close_created_for_test()
            launch.assert_not_called()

    def test_zombie_requires_same_birth_and_foreign_pid_is_preserved(self):
        with patch.object(self.host, 'process_field', side_effect=lambda pid, field: 'Z' if field == 'stat' else 'birth'):
            self.assertTrue(self.host.process_gone(self.owner))
            self.assertFalse(self.host.process_gone(dict(self.owner, birth='other')))
        with patch.object(self.host, 'process_field', return_value='S'):
            self.assertFalse(self.host.process_gone(self.owner))
        with patch.object(self.host, 'process_field', return_value=None):
            self.assertTrue(self.host.process_gone(self.owner))

    def test_zombie_record_allows_one_fresh_launch(self):
        self.host.persist(self.owner)
        child = Mock(pid=456)
        child.poll.return_value = None
        with patch.object(self.host, 'process_field', side_effect=lambda pid, field: 'Z' if field == 'stat' else 'birth'), \
             patch('chrome_host.os.access', return_value=True), \
             patch('chrome_host.verify_chrome'), \
             patch('chrome_host.subprocess.Popen', return_value=child) as launch, \
             patch.object(self.host, 'endpoint', return_value='http://127.0.0.1:9999'):
            self.assertEqual(self.host.ensure(), 'http://127.0.0.1:9999')
        self.assertEqual(launch.call_count, 1)
        self.assertEqual(self.host.owner['pid'], 456)
