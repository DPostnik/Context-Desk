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
