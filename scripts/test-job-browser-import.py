"""Synthetic scheduler permission tests; never contact a running scheduler."""
import contextlib
import importlib.util
import io
from pathlib import Path
import unittest
from unittest.mock import patch

source = Path(__file__).resolve().parents[1] / 'Skills/schedule-control/scripts/browser-import.py'
spec = importlib.util.spec_from_file_location('browser_import_client', source)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ImportTests(unittest.TestCase):
    def setUp(self):
        self.job = {'id': 'B39B21BF-187C-4C45-8F94-F98F70F8643F', 'prompt': 'Do not send', 'enabled': True, 'model': 'fixture'}
        self.policy = {'site': 'linkedin.com', 'profile': 'Default'}
        self.args = ['client', '--job-id', self.job['id'], '--chrome-profile', 'Default', '--site', 'LinkedIn.COM']

    def test_permission_only_update_uses_observed_job(self):
        updated = {**self.job, 'browserSessionImport': self.policy}
        with patch('sys.argv', self.args), patch.object(module.client, 'send', side_effect=[{'jobs': [self.job]}, {'jobs': [updated]}]) as send, contextlib.redirect_stdout(io.StringIO()):
            module.main()
        self.assertEqual(send.call_args_list[1].args[0], {'operation': 'browser-import', 'expected': self.job, 'browserSessionImport': self.policy})

    def test_ignored_permission_and_changed_prompt_are_not_success(self):
        for updated in [self.job, {**self.job, 'browserSessionImport': self.policy, 'prompt': 'changed'}]:
            with patch('sys.argv', self.args), patch.object(module.client, 'send', side_effect=[{'jobs': [self.job]}, {'jobs': [updated]}]) as send:
                with self.assertRaises(RuntimeError):
                    module.main()
                self.assertEqual(send.call_count, 2)

    def test_disable_does_not_pause_job(self):
        job = {**self.job, 'browserSessionImport': self.policy}
        with patch('sys.argv', ['client', '--job-id', job['id'], '--disable']), patch.object(module.client, 'send', side_effect=[{'jobs': [job]}, {'jobs': [self.job]}]) as send, contextlib.redirect_stdout(io.StringIO()):
            module.main()
        self.assertEqual(send.call_args_list[1].args[0], {'operation': 'browser-import', 'expected': job, 'clearBrowserSessionImport': True})


if __name__ == '__main__':
    unittest.main()
