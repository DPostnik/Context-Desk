import json
import os
from pathlib import Path
import tempfile
import unittest

from history import build, match, manifest, require_fresh, url_key, write_new, bank_url_keys


class HistoryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        self.base = self.root / 'wiki/job-search'
        for directory in ('companies', 'sourcing-runs', 'runtime'):
            (self.base / directory).mkdir(parents=True, exist_ok=True)
        (self.base / 'vacancy-bank.md').write_text('''| ID | Vacancy | Source URL | Status |
|---|---|---|---|
| V-0001 | Example — Senior React | https://jobs.test/example/req-1?utm_source=board | submitted |
| V-0002 | Example — Senior React | https://jobs.test/example/req-2 | skipped |
''')
        (self.base / 'pipeline.md').write_text('Example V-0001 applied\n')
        (self.base / 'runtime/job-board-memory.md').write_text('Earlier: Another Employer, frontend.\n')
        (self.base / 'companies/example.md').write_text('# Example\nV-0002 rejected; see current reason.\n')
        (self.base / 'sourcing-runs/old.json').write_text(json.dumps([
            {'company': 'Other Company', 'url': 'https://board.test/123', 'title': 'Senior Frontend'}]))

    def tearDown(self):
        self.tmp.cleanup()

    def lookup(self, card, index=None):
        return match(index or build(self.root), self.root, [dict(id='card-1', **card)])['matches'][0]

    def test_exact_url_is_evidence_not_an_automatic_decision(self):
        row = self.lookup({'url': 'https://jobs.test/example/req-1', 'company': 'Example', 'title': 'Senior React'})
        self.assertEqual(row['classification'], 'known_source_url')
        self.assertTrue(row['reviewRequired'])
        self.assertEqual({x['vacancyID']: x['matchKind'] for x in row['bankMatches']},
                         {'V-0001': 'source_url', 'V-0002': 'company_title'})
        self.assertIn('wiki/job-search/companies/example.md', [x['path'] for x in row['evidence']])

    def test_same_company_title_new_requisition_remains_ambiguous(self):
        row = self.lookup({'url': 'https://jobs.test/example/req-3', 'company': 'Example', 'title': 'Senior React'})
        self.assertEqual(row['classification'], 'possible_role_match')
        self.assertEqual(row['bankMatchCount'], 2)
        self.assertTrue(row['reviewRequired'])
        other = self.lookup({'company': 'Example', 'title': 'Vue Developer'})
        self.assertEqual(other['classification'], 'company_history')

    def test_identity_query_and_fragment_are_preserved(self):
        self.assertNotEqual(url_key('https://jobs.test/?id=1'), url_key('https://jobs.test/?id=2'))
        self.assertNotEqual(url_key('https://jobs.test/#/1'), url_key('https://jobs.test/#/2'))
        self.assertNotEqual(url_key('https://jobs.test/?sourceId=1'), url_key('https://jobs.test/?sourceId=2'))
        self.assertNotEqual(bank_url_keys('https://jobs.test/role.'), bank_url_keys('https://jobs.test/role'))
        self.assertIsNone(url_key('https://user:secret@jobs.test/1'))
        self.assertEqual(bank_url_keys('[Job](https://jobs.test/1)'), ['https://jobs.test/1'])

    def test_signed_aggregator_links_are_not_canonicalized_by_company(self):
        row = self.lookup({'url': 'https://englishjobs.pl/clickout/new?sig=x', 'company': 'Example', 'title': 'Senior React'})
        self.assertEqual(row['classification'], 'possible_role_match')
        self.assertNotEqual(url_key('https://board.test/1?sig=a'), url_key('https://board.test/1?sig=b'))

    def test_old_run_url_is_only_a_history_reference(self):
        row = self.lookup({'url': 'https://board.test/123'})
        self.assertEqual(row['classification'], 'history_reference')
        self.assertEqual(row['bankMatches'], [])
        self.assertEqual(row['evidence'][0]['pointer'], '/0/url')

    def test_absence_is_not_a_new_vacancy_decision(self):
        row = self.lookup({'company': 'Never Seen', 'title': 'New Role'})
        self.assertEqual(row['classification'], 'no_match')
        self.assertTrue(row['reviewRequired'])

    def test_company_tokens_do_not_match_substrings(self):
        (self.base / 'pipeline.md').write_text('Checkbox changed; Boxfresh interview\n')
        self.assertEqual(self.lookup({'company': 'Box'})['classification'], 'no_match')

    def test_legal_suffix_is_only_a_company_hint_not_role_identity(self):
        row = self.lookup({'company': 'Example Corporation', 'title': 'Senior React'})
        self.assertEqual(row['classification'], 'company_history')
        self.assertEqual(row['companyMatch'], 'legal_suffix_hint')
        self.assertEqual(row['bankMatches'], [])
        self.assertTrue(row['reviewRequired'])

    def test_changed_added_removed_history_invalidates_index(self):
        for change in ('edit', 'add', 'delete'):
            index = build(self.root)
            file = self.base / 'companies/example.md'
            old = file.read_bytes()
            if change == 'edit':
                file.write_text('updated')
            elif change == 'add':
                file = self.base / 'companies/new.md'
                file.write_text('new')
            else:
                file.unlink()
            with self.assertRaisesRegex(ValueError, 'history_changed'):
                require_fresh(index, self.root)
            if change == 'add':
                file.unlink()
            else:
                file.write_bytes(old)

    def test_read_only_and_outputs_cannot_overwrite_existing_files(self):
        before = manifest(self.root)
        index = build(self.root)
        self.lookup({'company': 'Example'}, index)
        self.assertEqual(manifest(self.root), before)
        destination = self.root / 'evidence/index.json'
        write_new(destination, index)
        self.assertEqual(destination.stat().st_mode & 0o777, 0o600)
        with self.assertRaises(FileExistsError):
            write_new(destination, {})
        self.assertEqual(json.loads(destination.read_text())['version'], index['version'])

    def test_missing_or_malformed_required_history_is_not_an_empty_success(self):
        bank = self.base / 'vacancy-bank.md'
        bank.write_text('| V-0001 | malformed |')
        with self.assertRaisesRegex(ValueError, 'unsupported_vacancy_bank_row'):
            build(self.root)
        bank.unlink()
        with self.assertRaisesRegex(ValueError, 'history_sources_missing'):
            build(self.root)

    def test_wiki_links_code_pipes_and_legacy_tables_preserve_column_identity(self):
        bank = self.base / 'vacancy-bank.md'
        bank.write_text("""| ID | Vacancy | Source URL | Status | Note |
| V-0001 | Example — Senior React | https://jobs.test/1 | skipped | [[path|label]] and `Java | Azure` |
| ID | Vacancy | Result | Batch | Evidence / reason |
| V-0001 | Example — Senior React | rejected | B-01 | historical |
""")
        index = build(self.root)
        self.assertEqual(index['bankRowsWithoutURL'], 1)
        self.assertEqual(index['unparsedBankURLRows'], 0)
        exact = self.lookup({'url': 'https://jobs.test/1'}, index)
        self.assertEqual(exact['bankMatches'][0]['status'], 'skipped')
        ambiguous = self.lookup({'company': 'Example', 'title': 'Senior React'}, index)
        self.assertEqual(ambiguous['bankMatchCount'], 2)

    def test_conflicting_bank_rows_are_retained(self):
        bank = self.base / 'vacancy-bank.md'
        bank.write_text(bank.read_text() + '| V-0001 | Example — Senior React | https://jobs.test/example/req-1 | submission-unknown |\n')
        row = self.lookup({'url': 'https://jobs.test/example/req-1'})
        self.assertEqual(row['bankMatchCount'], 2)
        self.assertEqual({x['status'] for x in row['bankMatches']}, {'submitted', 'submission-unknown'})
        self.assertTrue(row['reviewRequired'])

    def test_limited_evidence_is_explicit_and_current_company_files_win(self):
        for number in range(10):
            (self.base / f'sourcing-runs/{number}.md').write_text('Example\n')
        row = self.lookup({'company': 'Example'})
        self.assertTrue(row['moreEvidence'])
        self.assertEqual(len(row['evidence']), 6)
        self.assertIn('companies/example.md', row['evidence'][0]['path'])


if __name__ == '__main__':
    unittest.main()
