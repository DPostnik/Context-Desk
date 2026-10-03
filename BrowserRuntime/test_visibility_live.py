"""Opt-in AppKit/Chrome check with a disposable profile and loopback-only page."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from chrome_host import ChromeHost
from install import ROOT
from server import Browser


@unittest.skipUnless(os.environ.get('CONTEXTDESK_BROWSER_VISIBILITY_LIVE') == '1', 'opt-in live Chrome check')
class BrowserVisibilityTests(unittest.TestCase):
    def test_hidden_navigation_and_manual_visibility_survive_reattachment(self):
        class Page(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'<title>Visibility fixture</title><p>Background browsing works</p>')

            def log_message(self, *_):
                pass

        def control(pid, action='status'):
            script = '''ObjC.import('AppKit');
function run(args) {
    const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(Number(args[0]));
    if (args[1] === 'show') { app.unhide; app.activateWithOptions(0); }
    if (args[1] === 'hide') app.hide;
    return JSON.stringify({hidden: Boolean(app.hidden), terminated: Boolean(app.terminated)});
}'''
            result = subprocess.run(['/usr/bin/osascript', '-l', 'JavaScript', '-e', script, str(pid), action],
                                    capture_output=True, text=True, timeout=10, check=True)
            if action != 'status':
                return control(pid)
            return json.loads(result.stdout)

        http = ThreadingHTTPServer(('127.0.0.1', 0), Page)
        threading.Thread(target=http.serve_forever, daemon=True).start()
        try:
            with tempfile.TemporaryDirectory(prefix='context-desk-visibility-') as directory:
                browser = Browser(Path(directory), installation_root=ROOT)
                try:
                    opened = browser.open(f'http://127.0.0.1:{http.server_port}/')
                    host = browser.chrome
                    pid = host.owner['pid']
                    self.assertEqual(control(pid), {'hidden': True, 'terminated': False})
                    self.assertEqual(browser.evaluate('() => document.title'), 'Visibility fixture')
                    self.assertFalse(control(pid, 'show')['hidden'])
                    adopted = ChromeHost(directory)
                    adopted.ensure()
                    self.assertIsNone(adopted.child)
                    self.assertFalse(control(pid)['hidden'])
                    self.assertTrue(control(pid, 'hide')['hidden'])
                    self.assertEqual(browser.evaluate('() => document.title'), 'Visibility fixture')
                    browser.close_session(opened['session'])
                    opened = browser.open(f'http://127.0.0.1:{http.server_port}/')
                    self.assertTrue(control(pid)['hidden'])
                    browser.close_session(opened['session'])
                    self.assertFalse(control(pid, 'show')['hidden'])
                    opened = browser.open(f'http://127.0.0.1:{http.server_port}/')
                    self.assertFalse(control(pid)['hidden'])
                    browser.close_session(opened['session'])
                finally:
                    browser.stop()
                    if browser.chrome:
                        browser.chrome.close_created_for_test()
        finally:
            http.shutdown()
            http.server_close()
