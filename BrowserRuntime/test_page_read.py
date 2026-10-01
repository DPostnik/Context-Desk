"""Bounded snapshot routing, validation and non-replaying failure behavior."""
import json
import os
import sys
from pathlib import Path
import tempfile
import unittest

sys.dont_write_bytecode = True
RUNTIME = Path(os.environ.get('BROWSER_RUNTIME_UNDER_TEST', Path(__file__).parent)).resolve()
sys.path.insert(0, str(RUNTIME))
import server
from server import Browser, Rejected, dispatch


def envelope(value):
    return {'content': [{'type': 'text', 'text': '```json\n' + json.dumps(value) + '\n```'}]}


class PageReadTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.calls = []
        def rpc(name, args):
            self.calls.append((name, args))
            if name == 'evaluate_script':
                return envelope({'kind': 'page_read', 'text': 'Profile', 'complete': False, 'interactiveUIDs': False})
            return {'content': [{'type': 'text', 'text': 'uid=1_1 button "Fixture"'}]}
        self.browser = Browser(Path(self.directory.name), rpc=rpc)
        self.browser.session, self.browser.page = 'owner', 7
        self.browser.checkpoint = {'state': 'opened'}

    def tearDown(self):
        self.directory.cleanup()

    def test_default_snapshot_is_one_bounded_read_without_stability_wait_or_ax(self):
        result = dispatch(self.browser, 'browser_snapshot', {'session': 'owner'})
        self.assertEqual(result['text'], 'Profile')
        self.assertFalse(result['complete'])
        self.assertFalse(result['interactiveUIDs'])
        self.assertEqual(len(self.calls), 1)
        name, arguments = self.calls[0]
        self.assertEqual(name, 'evaluate_script')
        self.assertEqual(arguments['pageId'], 7)
        self.assertIs(arguments['waitForStableDom'], False)
        self.assertIn(server.PAGE_READ, arguments['function'])

    def test_selector_is_quoted_as_data_and_interactive_is_explicit(self):
        selector = 'main[data-name="x\\\";evil()"]'
        self.browser.snapshot('owner', selector=selector)
        self.assertTrue(self.calls[0][1]['function'].endswith(')(' + json.dumps(selector) + ')'))
        result = self.browser.snapshot('owner', mode='interactive')
        self.assertIn('uid=1_1', Browser.text(result))
        self.assertEqual(self.calls[-1], ('take_snapshot', {'pageId': 7}))

    def test_invalid_scope_or_mode_never_dispatches(self):
        for token, kwargs in [('foreign', {}), ('owner', {'mode': 'other'}),
                              ('owner', {'selector': ''}), ('owner', {'selector': 'x' * 513}),
                              ('owner', {'selector': 7}), ('owner', {'mode': 'interactive', 'selector': 'main'})]:
            with self.assertRaises(Rejected):
                self.browser.snapshot(token, **kwargs)
        self.assertEqual(self.calls, [])

    def test_timeout_never_falls_back_or_resends(self):
        def failed(name, args):
            self.calls.append(name)
            raise TimeoutError('lost read response')
        self.browser.injected = failed
        with self.assertRaises(TimeoutError):
            self.browser.snapshot('owner')
        with self.assertRaises(Rejected):
            self.browser.snapshot('owner')
        self.assertEqual(self.calls, ['evaluate_script'])
        self.assertTrue(self.browser.failed)

    def test_read_format_and_invalid_css_errors_are_determinate(self):
        for value in [{}, {'kind': 'page_read', 'error': 'invalid_selector'}]:
            self.browser.injected = lambda *args: envelope(value)
            with self.assertRaises(Rejected):
                self.browser.snapshot('owner')
            self.assertFalse(self.browser.failed)

    def test_mode_copy_and_schema_in_both_languages(self):
        try:
            for language, phrase in [('ru', 'без uid'), ('en', 'no uids')]:
                server.LANGUAGE = language
                definition = next(t for t in server.catalog() if t['name'] == 'browser_snapshot')
                self.assertIn(phrase, definition['description'])
                self.assertEqual(definition['inputSchema']['properties']['mode']['default'], 'read')
        finally:
            server.LANGUAGE = 'en'


if __name__ == '__main__':
    unittest.main()
