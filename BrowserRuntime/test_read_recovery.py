"""Operator-approved recovery cannot clear a different or mutating operation."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
RUNTIME = Path(os.environ.get('BROWSER_RUNTIME_UNDER_TEST', Path(__file__).parent)).resolve()
sys.path.insert(0, str(RUNTIME))
from broker import Executor


class ReadRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.executor = Executor(self.root)
        self.fence = self.executor.fence
        self.fence.write_text('{"client":7,"request":2,"state":"outcome_unknown"}')
        self.approval_path = self.root / 'approved-read-recovery.json'
        self.approval = {'schema': 1, 'confirmedTool': 'browser_snapshot',
            'reason': 'operator_confirmed_read_failure',
            'fenceSHA256': hashlib.sha256(self.fence.read_bytes()).hexdigest(),
            'fenceModifiedNS': self.fence.stat().st_mtime_ns}
        self.approval_path.write_text(json.dumps(self.approval))

    def tearDown(self):
        self.temporary.cleanup()

    def test_exact_approval_archives_evidence_without_browser_calls_or_action_edits(self):
        records = self.root / 'records'
        records.mkdir()
        action = records / 'action-original.json'
        action.write_text('{"state":"outcome_unknown"}')
        with patch('server.Browser.native', side_effect=AssertionError('must not dispatch')):
            self.assertTrue(self.executor.apply_approved_read_recovery())
        self.assertFalse(self.fence.exists())
        self.assertFalse(self.approval_path.exists())
        evidence = list(records.glob('read-recovery-*.json'))
        self.assertEqual(len(evidence), 1)
        self.assertFalse(json.loads(evidence[0].read_text())['replayed'])
        self.assertEqual(action.read_text(), '{"state":"outcome_unknown"}')
        self.assertFalse(self.executor.apply_approved_read_recovery())

    def test_old_executor_lock_prevents_consuming_approval(self):
        with (self.root / 'executor.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):
                self.executor.run()
        self.assertTrue(self.fence.exists())
        self.assertTrue(self.approval_path.exists())

    def test_changed_bytes_or_mtime_do_not_consume_approval(self):
        original = self.fence.read_bytes()
        self.fence.write_bytes(original + b' ')
        self.assertFalse(self.executor.apply_approved_read_recovery())
        self.fence.write_bytes(original)
        os.utime(self.fence, ns=(self.approval['fenceModifiedNS'] + 10000,) * 2)
        self.assertFalse(self.executor.apply_approved_read_recovery())
        self.assertTrue(self.approval_path.exists())

    def test_known_mutation_or_unapproved_read_stays_fenced(self):
        for tool in ('browser_action', 'browser_open', 'browser_next', 'browser_close'):
            self.fence.write_text(json.dumps({'state': 'outcome_unknown', 'tool': tool}))
            self.approval.update(fenceSHA256=hashlib.sha256(self.fence.read_bytes()).hexdigest(),
                                 fenceModifiedNS=self.fence.stat().st_mtime_ns)
            self.approval_path.write_text(json.dumps(self.approval))
            self.assertFalse(self.executor.apply_approved_read_recovery())
        self.approval_path.unlink()
        self.assertFalse(self.executor.apply_approved_read_recovery())

    def test_evidence_save_failure_preserves_fence_and_approval(self):
        with patch('server.save', side_effect=OSError('fixture disk failure')):
            with self.assertRaises(OSError):
                self.executor.apply_approved_read_recovery()
        self.assertTrue(self.fence.exists())
        self.assertTrue(self.approval_path.exists())


if __name__ == '__main__':
    unittest.main()
