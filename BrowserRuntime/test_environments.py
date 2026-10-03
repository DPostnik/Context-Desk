"""Environment boundaries and admission, without launching a real browser."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from chrome_host import ChromeHost, ChromeLaunchError
from broker import Executor, endpoint
from server import Browser


class EnvironmentTests(unittest.TestCase):
    def test_fence_and_endpoint_are_environment_local(self):
        with tempfile.TemporaryDirectory() as tmp:
            a, b = [Path(tmp) / 'environments' / name for name in ('a', 'b')]
            for path in (a, b):
                path.mkdir(parents=True)
            first, second = Executor(a), Executor(b)
            first.fence.write_text('{}')
            self.assertTrue(first.quarantine())
            self.assertFalse(second.quarantine())
            self.assertNotEqual(endpoint(a), endpoint(b))
            self.assertNotEqual(ChromeHost(a).profile, ChromeHost(b).profile)
            browser = Browser(a, installation_root=tmp, workspace=b)
            self.assertEqual(browser.installation_root, Path(tmp))
            self.assertEqual(browser.root, a)
            self.assertEqual(browser.workspace, b.resolve())

    def test_limit_does_not_evict_and_allows_existing_browser(self):
        with tempfile.TemporaryDirectory() as tmp:
            roots = [Path(tmp) / 'environments' / name for name in ('a', 'b', 'c')]
            for root in roots:
                root.mkdir(parents=True)
            for i, root in enumerate(roots[:2]):
                (root / 'testing-chrome-owner.json').write_text(json.dumps({'pid': i + 100}))
            with patch.object(ChromeHost, 'process_gone', return_value=False), patch.object(ChromeHost, 'ensure_owned', return_value='existing') as launch:
                for language in ('ru', 'en'):
                    with self.assertRaisesRegex(ChromeLaunchError, 'Cmd\\+Q'):
                        ChromeHost(roots[2], language=language).ensure()
                launch.assert_not_called()
                self.assertEqual(ChromeHost(roots[0]).ensure(), 'existing')
            with patch.object(ChromeHost, 'process_gone', return_value=True), patch.object(ChromeHost, 'ensure_owned', return_value='new'):
                self.assertEqual(ChromeHost(roots[2]).ensure(), 'new')

    def test_close_uncertainty_is_durable_and_never_resends(self):
        with tempfile.TemporaryDirectory() as tmp:
            host = ChromeHost(tmp)
            host.record.write_text(json.dumps({'pid': 123, 'birth': 'fixture'}))
            with patch.object(host, 'process_gone', return_value=False), patch.object(host, 'endpoint', return_value='verified'), patch.object(host, 'matches', return_value=True), patch.object(host, 'graceful_close') as kill:
                with patch('chrome_host.time.monotonic', side_effect=[0, 9]):
                    with self.assertRaisesRegex(ChromeLaunchError, 'not confirmed'):
                        host.control(close=True)
                kill.assert_called_once()
                with self.assertRaisesRegex(ChromeLaunchError, 'already requested'):
                    host.control(close=True)
                kill.assert_called_once()

    def test_close_refuses_unverified_process_and_pending_action(self):
        with tempfile.TemporaryDirectory() as tmp:
            host = ChromeHost(tmp)
            host.record.write_text(json.dumps({'pid': 123}))
            with patch.object(host, 'process_gone', return_value=False), patch('chrome_host.os.kill') as kill:
                with patch.object(host, 'endpoint', return_value=None):
                    with self.assertRaisesRegex(ChromeLaunchError, 'ownership'):
                        host.control(close=True)
                (Path(tmp) / 'executor-in-flight.json').write_text('{}')
                with patch.object(host, 'endpoint', return_value='verified'):
                    with self.assertRaisesRegex(ChromeLaunchError, 'unfinished'):
                        host.control(close=True)
                kill.assert_not_called()

    def test_close_cannot_race_with_dispatch(self):
        import fcntl
        with tempfile.TemporaryDirectory() as tmp:
            host = ChromeHost(tmp)
            host.record.write_text(json.dumps({'pid': 123}))
            with (Path(tmp) / 'operation.lock').open('a') as lock, patch('chrome_host.os.kill') as kill:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with self.assertRaisesRegex(ChromeLaunchError, 'performing an operation'):
                    host.control(close=True)
                kill.assert_not_called()
