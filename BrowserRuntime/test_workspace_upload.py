"""Regression: browser storage is not the host-selected project workspace."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

import server


class WorkspaceUploadTests(unittest.TestCase):
    def test_host_project_is_forwarded_without_expanding_to_parent(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            storage = base / 'browser'
            project = base / 'project with spaces'
            project.mkdir()
            alias = base / 'project-alias'
            alias.symlink_to(project, target_is_directory=True)
            browser = server.Browser(storage, workspace=alias)
            (storage / 'runtime.json').write_text(json.dumps({
                'version': server.LOCK['version'], 'node': '/usr/bin/true'}))
            host = Mock()
            host.ensure.return_value = 'http://127.0.0.1:1234'
            transport = Mock()
            transport.start.return_value = transport
            with patch.object(server, 'verify', return_value=base / 'entry.js'), \
                    patch.object(server, 'ChromeHost', return_value=host), \
                    patch.object(server, 'StdioRPC', return_value=transport) as launch:
                browser.start()
            self.assertEqual(launch.call_args.kwargs['cwd'], str(project.resolve()))
            command = launch.call_args.args[0]
            roots = [arg for arg in command if arg.startswith('--workspace=')]
            self.assertEqual(roots, ['--workspace=' + str(storage),
                                     '--workspace=' + str(project.resolve())])
            self.assertNotIn('--workspace=/', command)
            self.assertNotIn('--allowUnrestrictedPaths', command)
            transport.initialize_mcp.assert_called_once()

    def test_invalid_project_never_launches_transport(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            ordinary_file = base / 'file'
            ordinary_file.write_text('not a project')
            with patch.object(server, 'StdioRPC') as launch:
                for path in [Path('/'), ordinary_file]:
                    with self.assertRaises(server.Rejected):
                        server.Browser(base / 'browser', workspace=path)
                with self.assertRaises(FileNotFoundError):
                    server.Browser(base / 'browser', workspace=base / 'missing')
            launch.assert_not_called()

    def test_storage_only_callers_do_not_inherit_ambient_cwd(self):
        with tempfile.TemporaryDirectory() as temporary:
            self.assertIsNone(server.Browser(Path(temporary)).workspace)


if __name__ == '__main__':
    unittest.main()
