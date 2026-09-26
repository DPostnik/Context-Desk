import json
from pathlib import Path
import subprocess
import sys
import tempfile
import tarfile
import hashlib
import base64
from unittest.mock import patch
import time
import unittest

import server
from server import Browser, Rejected, dispatch
from transport import StdioRPC, TransportError
import install


def envelope(value):
    return {'content': [{'type': 'text', 'text': 'Script ran on page and returned:\n```json\n' + json.dumps(value) + '\n```'}]}


class BrowserTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.calls = []

        def rpc(name, args):
            self.calls.append((name, args))
            if name == 'evaluate_script':
                return envelope({'url': 'https://example.test/'})
            return {'content': [{'type': 'text', 'text': 'success'}]}
        self.browser = Browser(Path(self.directory.name), rpc=rpc)
        self.browser.session = 'owner'
        self.browser.page = 7
        self.browser.checkpoint = {'state': 'opened'}

    def tearDown(self):
        self.directory.cleanup()

    def test_scope_and_url_mismatch_prevent_dispatch(self):
        for token, url in [('other', 'https://example.test/'), ('owner', 'https://elsewhere.test/')]:
            with self.assertRaises(Rejected):
                self.browser.action(token, 'operation-01', url, 'click', {'uid': '1_1'})
        self.assertFalse(any(n == 'click' for n, _ in self.calls))
        with self.assertRaises(Rejected):
            self.browser.action('owner', 'operation-01', 'https://example.test/', 'click', {'pageId': 8})

    def test_action_id_is_durable_and_cannot_replay_after_restart(self):
        answer = self.browser.action('owner', 'operation-01', 'https://example.test/', 'click', {'uid': '1_1'})
        self.assertEqual(answer['verification'], 'required')
        original = self.browser.injected
        self.browser = Browser(Path(self.directory.name), rpc=original)
        self.browser.session, self.browser.page = 'owner', 7
        with self.assertRaises(Rejected):
            self.browser.action('owner', 'operation-01', 'https://example.test/', 'click', {'uid': '1_1'})
        self.assertEqual(sum(n == 'click' for n, _ in self.calls), 1)
        self.assertTrue(all(a.get('pageId') == 7 for n, a in self.calls))

    def test_uncertain_dispatch_is_recorded_and_stops_future_calls(self):
        original = self.browser.injected

        def timeout(name, args):
            if name == 'click':
                record = Path(self.directory.name) / 'records/action-operation-02.json'
                self.assertEqual(json.loads(record.read_text())['state'], 'outcome_unknown')
                raise TimeoutError('lost response')
            return original(name, args)
        self.browser.injected = timeout
        with self.assertRaises(TimeoutError):
            self.browser.action('owner', 'operation-02', 'https://example.test/', 'click', {'uid': '1_1'})
        self.assertTrue(self.browser.failed)
        with self.assertRaises(Rejected):
            self.browser.native('click', {'uid': '1_1', 'pageId': 7})

    def observation(self, cards, **extra):
        return {'url': 'https://example.test/', 'cards': cards, 'placeholders': len(cards),
                'truncated': False, 'bottom': True, 'scroll': {'top': 0, 'height': 50, 'total': 50},
                'loading': False, 'empty': False, 'readyState': 'complete', 'next': 'unknown',
                'visibility': 'visible', **extra}

    def test_loading_shell_and_blank_placeholders_are_partial(self):
        for observation in [self.observation([]), self.observation([{'id': '1', 'title': ''}]),
                            self.observation([{'id': '1', 'title': 'Card'}], loading=True)]:
            self.browser.read = lambda *_, **kwargs: observation
            result = self.browser.cards('owner', {'card': '.card'}, 1)
            self.assertFalse(result['complete'])

    def test_delayed_card_metadata_is_not_lost(self):
        observations = [self.observation([{'id': '1', 'title': ''}]),
                        self.observation([{'id': '1', 'title': 'Loaded'}])]
        self.browser.read = lambda *_, **kwargs: observations.pop(0) if len(observations) > 1 else observations[0]
        result = self.browser.cards('owner', {'card': '.card'}, 2)
        self.assertTrue(result['complete'])
        self.assertEqual(result['cards'][0]['title'], 'Loaded')
        saved = json.loads((Path(self.directory.name) / 'records/owner.json').read_text())
        self.assertEqual(saved['state'], 'page_complete')

    def test_explicit_empty_and_truncation_have_distinct_results(self):
        self.browser.read = lambda *_, **kwargs: self.observation([], empty=True)
        self.assertEqual(self.browser.cards('owner', {'card': '.card'}, 1)['reason'], 'explicit_empty')
        self.browser.read = lambda *_, **kwargs: self.observation([{'id': '1', 'title': 'Card'}], truncated=True)
        self.assertFalse(self.browser.cards('owner', {'card': '.card'}, 1)['complete'])

    def test_pagination_noop_clicks_once_and_returns_partial(self):
        self.browser.read = lambda *_, **kwargs: self.observation([{'id': '1', 'title': 'Card'}])
        self.browser.cards('owner', {'card': '.card'}, 1)
        result = self.browser.next('owner', 'next-page-01', 'https://example.test/', '1_5', {'card': '.card'}, 1)
        self.assertFalse(result['complete'])
        self.assertEqual(result['reason'], 'page_transition_not_observed')
        self.assertEqual(sum(n == 'click' for n, _ in self.calls), 1)

    def test_virtualized_subset_is_not_a_new_page(self):
        self.browser.read = lambda *_, **kwargs: self.observation([{'id': '1', 'title': 'Old card'}])
        result = self.browser.cards('owner', {'card': '.card'}, 1, baseline=['1', '2'])
        self.assertFalse(result['complete'])
        self.assertEqual(result['reason'], 'page_transition_not_observed')

    def test_untrusted_arguments_do_not_escape_allowlist(self):
        with self.assertRaises(Rejected):
            dispatch(self.browser, 'evaluate_script', {'function': 'evil()'})
        with self.assertRaises(Rejected):
            dispatch(self.browser, 'browser_snapshot', {'session': 'owner', 'pageId': 1})
        with self.assertRaises(Rejected):
            dispatch(self.browser, 'browser_open', {'url': 'javascript:alert(1)'})
        self.assertFalse(self.calls)

    def test_tool_copy_exists_in_both_languages(self):
        catalogs = []
        for language in ('ru', 'en'):
            server.LANGUAGE = language
            catalogs.append(server.catalog())
        self.assertEqual([x['name'] for x in catalogs[0]], [x['name'] for x in catalogs[1]])
        self.assertTrue(all(a['description'] != b['description'] for a, b in zip(*catalogs)))


class TransportTests(unittest.TestCase):
    def test_install_verification_rejects_changed_and_extra_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / 'package'
            package.mkdir()
            payload = package / 'file.js'
            payload.write_text('original')
            with tarfile.open(root / 'upstream.tgz', 'w:gz') as archive:
                archive.add(payload, arcname='package/file.js')
            checksum = base64.b64encode(hashlib.sha512((root / 'upstream.tgz').read_bytes()).digest()).decode()
            with patch.dict(install.LOCK, {'sha512': checksum}):
                install.verify(root)
                payload.write_text('changed')
                with self.assertRaises(ValueError):
                    install.verify(root)
                payload.write_text('original')
                (package / 'extra.js').write_text('extra')
                with self.assertRaises(ValueError):
                    install.verify(root)

    def test_packaged_server_handshake_and_unknown_request(self):
        with tempfile.TemporaryDirectory() as directory:
            command = [sys.executable, str(Path(__file__).with_name('server.py')), '--root', directory, '--language', 'ru']
            transport = StdioRPC(command).start()
            try:
                info = transport.initialize_mcp(expected_server_version=server.VERSION)
                self.assertIn('browser_cards', info['tools'])
                self.assertIn('browser_next', info['tools'])
                self.assertFalse((Path(directory) / 'profile').exists())
                # A stale/other task cancellation cannot terminate this executor.
                transport.notify('notifications/cancelled', {'requestId': 'already-completed'})
                with self.assertRaises(TransportError):
                    transport.rpc('sampling/createMessage', {}, 'unsupported', time.monotonic_ns() + 1_000_000_000)
                result = transport.rpc('ping', {}, 'ping', time.monotonic_ns() + 1_000_000_000)
                self.assertEqual(result, {})
            finally:
                transport.close()

    def test_timeout_latches_transport_and_does_not_replay(self):
        code = 'import sys,time; sys.stdin.readline(); time.sleep(5)'
        transport = StdioRPC([sys.executable, '-c', code]).start()
        try:
            with self.assertRaises(TimeoutError):
                transport.rpc('tools/call', {}, '1', time.monotonic_ns() + 100_000_000)
            with self.assertRaises(TransportError):
                transport.rpc('tools/call', {}, '2', time.monotonic_ns() + 100_000_000)
        finally:
            transport.close(grace_seconds=0.1)

    def test_unknown_upstream_request_fails_closed(self):
        code = 'import sys,json,time; sys.stdin.readline(); print(json.dumps({"jsonrpc":"2.0","id":"request","method":"sampling/createMessage"}),flush=True); sys.stdin.readline(); time.sleep(1)'
        transport = StdioRPC([sys.executable, '-c', code]).start()
        try:
            with self.assertRaises(TransportError):
                transport.rpc('initialize', {}, '1', time.monotonic_ns() + 1_000_000_000)
            self.assertEqual(transport.denied_server_messages[0]['method'], 'sampling/createMessage')
        finally:
            transport.close(grace_seconds=0.1)


if __name__ == '__main__':
    unittest.main()
