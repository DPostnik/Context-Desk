"""Independent negative checks for nonce, lifecycle and media-binding assertions."""
import copy
from pathlib import Path
import sys
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from fixture import Lab
from oracle import Oracle


class IndependentOracleChecks(unittest.TestCase):
    def setUp(self):
        self.lab = Lab()

    def tearDown(self):
        self.lab.close()

    def event(self, target='A', nonce='before-attach', top_level=True):
        self.lab.action('event', dict(target=target, generation=self.lab.generation[target],
                                     top_level=top_level, kind='loaded', detail={'nonce': nonce}))

    def test_nonce_must_precede_attachment_and_match_generation(self):
        before = time.monotonic_ns()
        self.event()
        after = time.monotonic_ns()
        oracle = Oracle(self.lab.directory)
        self.assertIsNone(oracle.loaded_nonce('A', before))
        self.assertEqual(oracle.loaded_nonce('A', after), 'before-attach')
        self.assertIsNone(oracle.loaded_nonce('decoy', after))
        oracle.events[-1]['data']['generation'] = 'stale'
        self.assertIsNone(oracle.loaded_nonce('A', after))

    def test_multiple_nonce_generations_require_reconciliation(self):
        self.event()
        self.event(nonce='different-session')
        self.assertIsNone(Oracle(self.lab.directory).loaded_nonce('A', time.monotonic_ns()))

    def test_cross_origin_frame_nonce_is_not_top_level_identity(self):
        self.event()
        self.event(nonce='cross-origin-frame', top_level=False)
        self.assertEqual(Oracle(self.lab.directory).loaded_nonce('A', time.monotonic_ns()),
                         'before-attach')

    def test_quiet_or_busy_ledger_does_not_prove_cessation(self):
        start = time.monotonic_ns()
        self.event()
        self.event('decoy')
        self.lab.emit('site-response', {'cause': 'accepted site-delay'})
        readback = Oracle(self.lab.directory).lifecycle_readback('A', start)
        self.assertEqual(len(readback['page_events']), 1)
        self.assertEqual(len(readback['decoy_events']), 1)
        self.assertEqual(len(readback['site_responses']), 1)
        self.assertFalse(readback['cessation_verified'])
        quiet = Oracle(self.lab.directory).lifecycle_readback('A', time.monotonic_ns())
        self.assertIsNone(quiet['last_page_receive_ns'])
        self.assertFalse(quiet['cessation_verified'])

    def test_media_outputs_require_uploaded_item_and_hash(self):
        job = 'synthetic-job'
        self.lab.emit('uploaded', dict(upload=job, purpose='media', item=7,
                                      sha256=Oracle(self.lab.directory).truth['hashes']['input.mp4']))
        self.lab.emit('processed', dict(upload=job, state='complete'))
        for name in ('output.mp3', 'transcript.txt'):
            self.lab.emit('downloaded', dict(job=job, name=name,
                                            sha256=Oracle(self.lab.directory).truth['hashes'][name]))
        oracle = Oracle(self.lab.directory)
        self.assertTrue(oracle.outputs(job, self.lab.directory))
        saved = copy.deepcopy(oracle.events)
        for key, value in [('item', 8), ('sha256', 'wrong'), ('purpose', 'cv')]:
            oracle.events = copy.deepcopy(saved)
            next(e for e in oracle.events if e['kind'] == 'uploaded')['data'][key] = value
            self.assertFalse(oracle.outputs(job, self.lab.directory))
        oracle.events = [e for e in saved if e['kind'] != 'uploaded']
        self.assertFalse(oracle.outputs(job, self.lab.directory))


if __name__ == '__main__':
    unittest.main(verbosity=2)
