"""Client checks use an isolated mailbox, never the user's running app."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / 'Skills/schedule-control/scripts/schedule-control.py'
spec = importlib.util.spec_from_file_location('schedule_client', SOURCE)
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)


class ScheduleClientTests(unittest.TestCase):
    def test_edit_uses_observed_snapshot_and_literal_prompt(self):
        with tempfile.TemporaryDirectory() as tmp:
            prompt = Path(tmp) / 'prompt.txt'
            prompt.write_text('Не отправлять заявки. $(do-not-run) `literal`\nNext line')
            job = {'id': 'B39B21BF-187C-4C45-8F94-F98F70F8643F', 'prompt': 'old', 'enabled': False}
            argv = ['client', 'update', '--job-id', job['id'], '--prompt-file', str(prompt), '--enable', '--confirm-source-disabled']
            with patch('sys.argv', argv), patch.object(client, 'send', side_effect=[{'jobs': [job]}, {'jobs': []}]) as send, contextlib.redirect_stdout(io.StringIO()):
                client.main()
            update = send.call_args_list[1].args[0]
            self.assertEqual(update['expected'], job)
            self.assertEqual(update['prompt'], prompt.read_text())
            self.assertTrue(update['enabled'] and update['confirmSourceDisabled'])

    def test_timeout_keeps_one_receipt_and_status_never_resends(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(client, 'ROOT', Path(tmp)), contextlib.redirect_stderr(io.StringIO()):
            with patch.object(client.time, 'monotonic', side_effect=[0, 41]):
                with self.assertRaisesRegex(RuntimeError, 'Do not repeat'):
                    client.send({'operation': 'list'})
            files = list(Path(tmp).iterdir())
            self.assertEqual(len(files), 1)
            self.assertEqual(files[0].stat().st_mode & 0o777, 0o600)
            request = json.loads(files[0].read_text())
            output = io.StringIO()
            with patch('sys.argv', ['client', 'status', request['id']]), contextlib.redirect_stdout(output):
                client.main()
            self.assertEqual(json.loads(output.getvalue())['status'], 'pending-or-expired')
            self.assertEqual(list(Path(tmp).iterdir()), files)

    def test_oversize_request_never_enters_mailbox(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(client, 'ROOT', Path(tmp)):
            with self.assertRaisesRegex(ValueError, 'too large'):
                client.send({'operation': 'update', 'prompt': 'я' * 1_100_000})
            self.assertEqual(list(Path(tmp).iterdir()), [])


if __name__ == '__main__':
    unittest.main()
