#!/usr/bin/env python3
"""C01 artifact/stdio preflight. Deliberately cannot call browser tools or grant consent."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import selectors
import shutil
import subprocess
import tarfile
import time
import urllib.request
import uuid

from evidence import ROOT, digest, private_json, record

VERSION = '1.10.1'
URL = 'https://registry.npmjs.org/chrome-devtools-mcp/-/chrome-devtools-mcp-1.10.1.tgz'
INTEGRITY = 'Klw6HWDqHC/XS1JwZldd2r49aUhbUJN9m9Mvcx4SEueIPXtzuQX+QelxAViobv8YUkDZ7HWDrmViR6LeYK0wAw=='
PROTOCOL = '2025-11-25'


def acquire(directory):
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    archive = directory / f'chrome-devtools-mcp-{VERSION}.tgz'
    if not archive.exists():
        with urllib.request.urlopen(URL, timeout=30) as response:
            data = response.read(30 * 1024 * 1024)
        if base64.b64encode(hashlib.sha512(data).digest()).decode() != INTEGRITY:
            raise ValueError('published artifact integrity mismatch')
        with archive.open('xb') as stream:
            stream.write(data)
    if base64.b64encode(hashlib.sha512(archive.read_bytes()).digest()).decode() != INTEGRITY:
        raise ValueError('cached artifact integrity mismatch')
    with tarfile.open(archive) as tar:
        if not (directory / 'package').exists():
            tar.extractall(directory, filter='data')
        hashes = {}
        for member in tar.getmembers():
            if member.isfile():
                path = directory / member.name
                if path.is_symlink() or not path.resolve().is_relative_to(directory.resolve()):
                    raise ValueError('unexpected archive path')
                expected = digest(tar.extractfile(member).read())
                if digest(path.read_bytes()) != expected:
                    raise ValueError('extracted file mismatch: ' + member.name)
                hashes[member.name] = expected
        actual = {str(p.relative_to(directory)) for p in (directory / 'package').rglob('*') if p.is_file()}
        if actual != set(hashes):
            raise ValueError('unaccounted extracted files')
    return hashes


def rpc_preflight(command, env, directory):
    transcript = []
    stderr_path = directory / 'stderr.log'
    with stderr_path.open('xb') as stderr:
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=stderr, env=env, start_new_session=True)
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        buffer = b''
        deadline = time.monotonic() + 30

        def send(message):
            transcript.append(dict(direction='request', monotonic_ns=time.monotonic_ns(), message=message))
            process.stdin.write(json.dumps(message).encode() + b'\n'); process.stdin.flush()

        def receive(wanted):
            nonlocal buffer
            while time.monotonic() < deadline:
                if b'\n' not in buffer:
                    if not selector.select(min(1, max(0, deadline-time.monotonic()))):
                        continue
                    chunk = os.read(process.stdout.fileno(), 1024 * 1024)
                    if not chunk:
                        raise RuntimeError('stdio closed before response; no replay')
                    buffer += chunk
                    continue
                line, buffer = buffer.split(b'\n', 1)
                message = json.loads(line)
                transcript.append(dict(direction='response', monotonic_ns=time.monotonic_ns(), message=message))
                if 'method' in message and 'id' in message:
                    send({'jsonrpc': '2.0', 'id': message['id'], 'error': {'code': -32601, 'message': 'No server requests authorized in preflight'}})
                    raise RuntimeError('unexpected server request; denied')
                if message.get('id') == wanted:
                    if 'error' in message:
                        raise RuntimeError(str(message['error']))
                    return message['result']
            raise TimeoutError('30s preflight deadline; no replay')

        try:
            send(dict(jsonrpc='2.0', id=1, method='initialize', params=dict(
                protocolVersion=PROTOCOL, capabilities={}, clientInfo={'name': 'context-desk-research-preflight', 'version': '1'})))
            initialized = receive(1)
            if initialized.get('protocolVersion') != PROTOCOL or initialized.get('serverInfo', {}).get('version') != VERSION:
                raise RuntimeError('protocol or server version mismatch')
            send(dict(jsonrpc='2.0', method='notifications/initialized'))
            send(dict(jsonrpc='2.0', id=2, method='tools/list', params={}))
            catalog = receive(2)
            if not catalog.get('tools') or catalog.get('nextCursor'):
                raise RuntimeError('missing or unexpectedly paginated tool catalog')
            return dict(initialized=initialized, tools=[t['name'] for t in catalog['tools']],
                        owned_pid=process.pid, browser_tool_calls=0)
        finally:
            process.stdin.close()
            try:
                process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                # Only this exact Popen child is owned; never kill browser/shared driver.
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait(timeout=3)
            selector.close(); process.stdout.close()
            private_json(directory / 'rpc.json', transcript)
            private_json(directory / 'cleanup.json', dict(pid=process.pid, exit=process.returncode,
                stdin_closed=True, child_reaped=True, browser_attached=False,
                limit='No connected-browser cleanup tested; no tool call dispatched'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--acquire', action='store_true', help='Download/verify the exact public bundle if absent; no npm scripts')
    args = parser.parse_args()
    os.umask(0o077)
    directory = ROOT / ('c01-preflight-' + uuid.uuid4().hex)
    directory.mkdir(parents=True, mode=0o700)
    package_root = ROOT / ('c01-' + VERSION)
    errors, steps = [], []
    manifest = dict(platform=platform.platform(), machine=platform.machine(), python=platform.python_version(),
                    candidate_version=VERSION, artifact_url=URL, protocol_requested=PROTOCOL,
                    current_browser_profile=None, current_target=None, chrome_debugging_consent='not established',
                    browser_content_read=False, original_codex_state_accessed=False)
    try:
        if not args.acquire and not (package_root / f'chrome-devtools-mcp-{VERSION}.tgz').exists():
            raise RuntimeError('Exact artifact absent; run with --acquire to prepare it')
        hashes = acquire(package_root)
        private_json(directory / 'artifact-files.json', hashes)
        metadata = json.loads((package_root / 'package/package.json').read_text())
        if metadata['version'] != VERSION or metadata.get('dependencies'):
            raise ValueError('unexpected version/runtime dependencies')
        manifest['artifact'] = dict(sha512=INTEGRITY, files=len(hashes), patches=[],
            runtime_dependencies='bundled; every distributed file verified against tarball',
            optional_peers='not installed', dependency_manifest_sha256=hashes['package/package.json'])
        node = shutil.which('node')
        if not node:
            raise RuntimeError('Node unavailable')
        manifest['node'] = dict(path=node, realpath=str(Path(node).resolve()), sha256=digest(Path(node).read_bytes()),
                               version=subprocess.check_output([node, '--version'], timeout=5, text=True).strip())
        with Path('/Applications/Google Chrome.app/Contents/Info.plist').open('rb') as stream:
            info = plistlib.load(stream)
        manifest['chrome'] = dict(version=info['CFBundleShortVersionString'], identifier=info['CFBundleIdentifier'],
            executable_sha256=digest(Path('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome').read_bytes()),
            runtime_version='not attached; installed bundle version only')
        env = dict(os.environ, CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS='1', CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS='1')
        command = [node, str(package_root / 'package/build/src/bin/chrome-devtools-mcp.js'),
                   '--auto-connect', '--channel=stable', '--no-usage-statistics', '--no-performance-crux',
                   '--log-file=' + str(directory / 'driver.log')]
        manifest['command'] = command
        manifest['environment_overrides'] = {k: env[k] for k in ('CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS', 'CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS')}
        for option in ('--version', '--help'):
            probe = subprocess.run(command + [option], env=env, capture_output=True, text=True, timeout=30)
            private_json(directory / (option[2:] + '.json'), dict(command=command+[option], exit=probe.returncode,
                stdout=probe.stdout, stderr=probe.stderr))
            if probe.returncode:
                raise RuntimeError(option + ' failed')
            steps.append({'command': option, 'exit': probe.returncode})
        manifest['stdio'] = rpc_preflight(command, env, directory)
        steps.append({'command': 'initialize → notifications/initialized → tools/list → stdin EOF',
                      'browser_tool_calls': 0})
    except Exception as error:
        errors.append(f'{type(error).__name__}: {error}')
    private_json(directory / 'environment.json', manifest)
    blockers = errors + ['Current user-selected Chrome profile and fixture tab/generation not established',
                         'Chrome remote-debugging enablement and connection consent not established']
    value = record('E00', 'artifact-and-stdio-without-browser-attachment', 'blocked',
        candidate_id='C01', candidate_version=VERSION, evidence_level='runtime preflight',
        requirement_ids=['BR-20', 'BR-23'], environment_manifest='environment.json',
        hypothesis='Pinned bundle can initialize without browser access; attachment requires current identity and consent',
        steps=steps, oracle_evidence=['artifact-files.json', 'rpc.json', 'cleanup.json'] if 'stdio' in manifest else [],
        errors=blockers, owned_process_cleanup=['See cleanup.json for owned stdio child'] if 'stdio' in manifest else [],
        remaining_target_block='No browser target admitted', interpretation_limits=[
            'E01–E09 not tested; protocol discovery is not browser attachment or cessation evidence',
            'Default stable channel is a launch configuration, not verified user profile identity',
            'Disabling telemetry verified by flags/source; no network packet capture performed'])
    private_json(directory / 'E00.json', value)
    print(directory)
    print(json.dumps({'status': value['status'], 'runtime_errors': errors, 'prerequisites': blockers}, indent=2))
    return 1 if errors else 0  # Zero means the preflight report completed, never E00 passed.


if __name__ == '__main__':
    raise SystemExit(main())
