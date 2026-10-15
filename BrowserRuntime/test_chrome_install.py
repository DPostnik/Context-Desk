import io
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

import install


class ChromeInstallTests(unittest.TestCase):
    def test_corrupt_download_is_not_extracted_or_installed(self):
        with tempfile.TemporaryDirectory() as root, patch.object(install, 'ROOT', Path(root)), \
             patch.object(install, 'chrome_platform', return_value='mac-arm64'), \
             patch('install.urllib.request.urlopen', return_value=io.BytesIO(b'corrupt')), \
             patch('install.subprocess.run') as run:
            with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                install.install_chrome()
            self.assertFalse(install.chrome_app().exists())
            run.assert_not_called()

    def test_existing_install_is_verified_without_download_or_overwrite(self):
        with tempfile.TemporaryDirectory() as root, patch.object(install, 'ROOT', Path(root)), \
             patch.object(install, 'chrome_platform', return_value='mac-arm64'), \
             patch('install.urllib.request.urlopen') as download, \
             patch.object(install, 'verify_chrome', side_effect=ValueError('invalid signature')):
            install.chrome_app().mkdir(parents=True)
            marker = install.chrome_app() / 'preserve'
            marker.write_text('existing')
            with self.assertRaisesRegex(ValueError, 'invalid signature'):
                install.install_chrome()
            self.assertEqual(marker.read_text(), 'existing')
            download.assert_not_called()

    def test_regular_chrome_bundle_is_rejected(self):
        with tempfile.TemporaryDirectory() as root, patch('install.subprocess.run') as run:
            app = Path(root)
            (app / 'Contents').mkdir()
            with (app / 'Contents/Info.plist').open('wb') as stream:
                plistlib.dump({'CFBundleIdentifier': 'com.google.Chrome',
                              'CFBundleShortVersionString': install.LOCK['chromeForTesting']['version']}, stream)
            with self.assertRaisesRegex(ValueError, 'Unexpected Chrome for Testing'):
                install.verify_chrome(app)
            run.assert_not_called()


class NodeResolutionTests(unittest.TestCase):
    def node(self, directory, version):
        path = Path(directory) / 'node'
        path.write_text('#!/bin/sh\necho ' + version + '\n')
        path.chmod(0o755)
        return path

    def test_installed_node_is_used_without_searching(self):
        with tempfile.TemporaryDirectory() as root, patch.object(install, 'node_candidates') as candidates:
            node = self.node(root, 'v24.0.0')
            self.assertEqual(install.resolve_node(str(node)), node)
            candidates.assert_not_called()

    def test_removed_node_falls_back_to_first_compatible_candidate(self):
        with tempfile.TemporaryDirectory() as old, tempfile.TemporaryDirectory() as new:
            too_old = self.node(old, 'v20.11.0')
            compatible = self.node(new, 'v24.20.0')
            with patch.object(install, 'node_candidates',
                              return_value=[Path(new) / 'missing', too_old, compatible]):
                self.assertEqual(install.resolve_node('/nonexistent/v23.10.0/bin/node'), compatible.resolve())

    def test_no_compatible_node_returns_none(self):
        with tempfile.TemporaryDirectory() as root:
            with patch.object(install, 'node_candidates', return_value=[self.node(root, 'v18.0.0')]):
                self.assertIsNone(install.resolve_node('/nonexistent/node'))
