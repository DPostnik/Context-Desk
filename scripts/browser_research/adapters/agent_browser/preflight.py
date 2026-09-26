#!/usr/bin/env python3
"""Artifact-only C04 E00 preflight; never executes the native binary or Node package."""
from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import subprocess
import sys
import tarfile
import time
import urllib.request
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from evidence import ROOT, private_json, record

VERSION = '0.38.1'
COMMIT = 'aff6125c023b810ea3f2e5deec5379e9a4270bdc'
NPM_URL = 'https://registry.npmjs.org/agent-browser/-/agent-browser-0.38.1.tgz'
NPM_SHA512 = 'k58FCz0yUOCANoNkMiqJe+H2y6r6sUZazqXsWF+MYq1iRC42PjtLcBoag6SSTOD/FRQppvPDvE5HDYEhclvnhw=='
NATIVE = {
    'arm64': ('agent-browser-darwin-arm64', '2e61287259053ea964d39e77002c6a34af0e589e55ccff25e659efae7e892e0d', 15768448),
    'x86_64': ('agent-browser-darwin-x64', '9187f885f7da0a6d880ff6d2e7dea58e17bea490a1fec85bbb6a36067272ea8e', 17378184),
}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def acquire_file(path: Path, url: str, max_size: int, acquire: bool, validate) -> bytes:
    if not path.exists():
        if not acquire:
            raise FileNotFoundError('artifact missing; rerun --acquire')
        with urllib.request.urlopen(url, timeout=45) as stream:
            data = stream.read(max_size + 1)
        if len(data) > max_size:
            raise ValueError('artifact exceeds size cap')
        validate(data)
        with path.open('xb') as output:
            os.chmod(path, 0o600)
            output.write(data)
    return path.read_bytes()


def verify_npm(data: bytes) -> dict:
    if base64.b64encode(hashlib.sha512(data).digest()).decode() != NPM_SHA512:
        raise ValueError('pinned npm SHA-512 mismatch')
    files = {}
    manifest = None
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
        for member in archive:
            path = PurePosixPath(member.name)
            if path.is_absolute() or '..' in path.parts or not path.parts or path.parts[0] != 'package':
                raise ValueError('unsafe npm archive member')
            if member.isdir():
                continue
            if not member.isfile() or member.linkname:
                raise ValueError('unexpected npm archive member type')
            content = archive.extractfile(member).read()
            if member.name in files:
                raise ValueError('duplicate npm member')
            files[member.name] = sha256(content)
            if member.name == 'package/package.json':
                manifest = json.loads(content)
    if not manifest or manifest.get('name') != 'agent-browser' or manifest.get('version') != VERSION:
        raise ValueError('npm package identity mismatch')
    if manifest.get('engines', {}).get('node') != '>=24.0.0':
        raise ValueError('unexpected npm Node engine declaration')
    return {'sha256': sha256(data), 'sha512_integrity': 'sha512-' + NPM_SHA512,
            'file_count': len(files), 'files': files, 'manifest': manifest}


def main(acquire: bool) -> int:
    directory = ROOT / ('agent-browser-checks-' + uuid.uuid4().hex)
    directory.mkdir(parents=True, mode=0o700)
    os.chmod(directory, 0o700)
    cache = ROOT / 'agent-browser-artifacts-0.38.1'
    cache.mkdir(parents=True, mode=0o700, exist_ok=True)
    os.chmod(cache, 0o700)
    report = {'candidate': 'C04', 'version': VERSION, 'tag_commit_source': COMMIT,
              'source_identity_level': 'release metadata, not installed runtime',
              'browser_tool_calls': 0, 'artifacts': {}, 'errors': [],
              'started_wall_ns': time.time_ns()}
    try:
        path = cache / 'agent-browser-0.38.1.tgz'
        data = acquire_file(path, NPM_URL, 150_000_000, acquire, verify_npm)
        report['artifacts']['npm'] = {'url': NPM_URL, 'path': str(path), **verify_npm(data)}
    except Exception as error:
        report['errors'].append(f'npm: {type(error).__name__}: {error}')
    architecture = platform.machine()
    native = NATIVE.get(architecture)
    if native is None:
        report['errors'].append(f'no pinned macOS artifact for {architecture}')
    else:
        filename, expected_hash, expected_size = native
        url = f'https://github.com/vercel-labs/agent-browser/releases/download/v{VERSION}/{filename}'
        try:
            path = cache / filename
            def verify_native(data):
                if len(data) != expected_size or sha256(data) != expected_hash:
                    raise ValueError('GitHub release asset size/SHA-256 mismatch')
            data = acquire_file(path, url, 25_000_000, acquire, verify_native)
            verify_native(data)
            report['artifacts']['native'] = {'url': url, 'path': str(path), 'sha256': expected_hash,
                                             'size': len(data), 'architecture': architecture,
                                             'release_digest_source': 'GitHub v0.38.1 asset metadata'}
        except Exception as error:
            report['errors'].append(f'native: {type(error).__name__}: {error}')
    try:
        node = subprocess.check_output(['which', 'node'], text=True, timeout=5).strip()
        version = subprocess.check_output([node, '--version'], text=True, timeout=5).strip()
        major = int(re.fullmatch(r'v(\d+)\.\d+\.\d+', version).group(1))
        report['node'] = {'path': node, 'version': version, 'sha256': sha256(Path(node).read_bytes()),
                          'npm_route_compatible': major >= 24}
    except Exception as error:
        report['errors'].append(f'Node identity: {type(error).__name__}: {error}')
    report['python'] = platform.python_version()
    report['platform'] = platform.platform()
    report['blockers'] = list(report['errors'])
    if 'node' in report and not report['node']['npm_route_compatible']:
        report['blockers'].append(f"Node {report['node']['version']} below npm engine >=24 for npm/source route")
    elif 'node' not in report:
        report['blockers'].append('Node compatibility with npm engine >=24 unknown')
    else:
        report['blockers'].append('npm route not executed or installed')
    if 'native' in report['artifacts']:
        report['blockers'].append('Native release asset verified but executable/runtime compatibility not executed')
    else:
        report['blockers'].append('Native release artifact not verified')
    report['blockers'] += [
        'Exact CDP endpoint, selected profile/target, app namespace/session and pre-bound --pin-tab attestation absent',
        'Current browser connection consent absent',
    ]
    report['finished_wall_ns'] = time.time_ns()
    private_json(directory / 'environment.json', report)
    evidence = record('E00', 'artifact-only-no-native-or-browser-process', 'blocked',
                      candidate_id='C04', candidate_version=VERSION, evidence_level='artifact preflight',
                      requirement_ids=['BR-20', 'BR-23'], environment_manifest='environment.json',
                      hypothesis='Exact C04 release artifacts can be verified without executing a driver',
                      steps=[{'operation': 'verify npm and platform-native release artifacts',
                              'browser_tool_calls': 0, 'native_binary_executions': 0}],
                      oracle_evidence=['environment.json'], errors=report['blockers'],
                      remaining_target_block='No browser target admitted',
                      interpretation_limits=['Release source/asset identity is not installed binary or runtime pin verification',
                                             'No endpoint, daemon, MCP, browser or cancellation trial'])
    private_json(directory / 'E00.json', evidence)
    print(directory)
    print(json.dumps({'status': evidence['status'], 'errors': report['errors'],
                      'artifacts_verified': list(report['artifacts'])}, indent=2))
    return 1 if report['errors'] else 0


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--acquire', action='store_true')
    args = parser.parse_args()
    raise SystemExit(main(args.acquire))
