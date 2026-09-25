import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from headroom_server import status_payload


class PluginCopyTests(unittest.TestCase):
    def test_both_languages_and_manifest_version(self):
        manifest = json.loads(Path(__file__).with_name('plugin.json').read_text())
        status = status_payload('test-instance', '0.38.0', SimpleNamespace(
            requests_total=3, requests_failed=1, tokens_saved_total=12))
        self.assertEqual(status['pluginVersion'], manifest['version'])
        self.assertEqual(status['instance'], 'test-instance')
        self.assertEqual([metric['value'] for metric in status['metrics']], [3, 1, 12])
        for text in [manifest['titleTranslations'], manifest['descriptionTranslations'],
                     status['detailTranslations']] + [m['titleTranslations'] for m in status['metrics']]:
            self.assertTrue(text['ru'].strip())
            self.assertTrue(text['en'].strip())
            self.assertNotRegex(text['en'], r'[А-Яа-яЁё]')


if __name__ == '__main__':
    unittest.main()
