#!/usr/bin/env python3
"""Verify C02 npm artifacts without installation, browser launch, or attachment."""
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


VERSION = '0.0.82'
ALPHA = '1.64.0-alpha-1789764292000'
PINS = {
    '@playwright/mcp': ('https://registry.npmjs.org/@playwright/mcp/-/mcp-0.0.82.tgz',
                        'OCqftfb8H4dnqm/njbTBRk3seUvUPttOlJUxCtEzXGETYOlRH5Qt3bbXIjmZIuWAxD9RF+yg1ASrPeXvm0y5cA==', VERSION),
    'playwright': ('https://registry.npmjs.org/playwright/-/playwright-' + ALPHA + '.tgz',
                   '3Ngs4ERGdC912uW3srEDtNVey4u1wSaQ/EFcKhxMpz0by0K6nidaJgM087pLpJc1osytiVnL7ack5gvgPArPNw==', ALPHA),
    'playwright-core': ('https://registry.npmjs.org/playwright-core/-/playwright-core-' + ALPHA + '.tgz',
                        'ZgRaybFv4rRy7QMGnYprEGFdNJnvapNqcaER2w96bDQA+40BWIle1el1Yh9KHD3E6XYmieMB+r+UxFTCauTGGQ==', ALPHA),
}


def _digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def verify_archive(data: bytes, integrity: str, expected_version: str) -> dict:
    if base64.b64encode(hashlib.sha512(data).digest()).decode() != integrity:
        raise ValueError('archive SHA-512 does not match pinned registry integrity')
    files = {}
    manifest = None
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
        for member in archive:
            path = PurePosixPath(member.name)
            if path.is_absolute() or '..' in path.parts or not path.parts or path.parts[0] != 'package':
                raise ValueError('unsafe archive member')
            if member.isdir():
                continue
            if not member.isfile() or member.linkname:
                raise ValueError('non-regular archive member')
            content = archive.extractfile(member).read()
            if member.name in files:
                raise ValueError('duplicate archive member')
            files[member.name] = _digest(content)
            if member.name == 'package/package.json':
                manifest = json.loads(content)
    if not manifest or manifest.get('version') != expected_version:
        raise ValueError('package version mismatch')
    return {'sha256': _digest(data), 'sha512_integrity': 'sha512-' + integrity,
            'files': files, 'package': manifest}


def preflight(acquire: bool) -> int:
    directory = ROOT / ('playwright-checks-' + uuid.uuid4().hex)
    directory.mkdir(parents=True, mode=0o700)
    os.chmod(directory, 0o700)
    cache = ROOT / 'playwright-artifacts-0.0.82'
    cache.mkdir(parents=True, mode=0o700, exist_ok=True)
    os.chmod(cache, 0o700)
    report = {'candidate': 'C02', 'mcp_version': VERSION, 'library_version': ALPHA,
              'source_commit_wrapper': 'f1257a5a67aff872f947fae274759f7d54853862',
              'source_commit_library': '78ff4260d79b924724bdcc4ccd89e463b8f43b0d',
              'extension_source_version': '0.4.0', 'extension_installed_identity': None,
              'profile_selected': False, 'connection_approved': False,
              'browser_tool_calls': 0, 'artifacts': {}, 'errors': [],
              'started_wall_ns': time.time_ns()}
    for name, (url, integrity, version) in PINS.items():
        file = cache / (name.replace('/', '-') + '-' + version + '.tgz')
        try:
            if not file.exists():
                if not acquire:
                    raise FileNotFoundError('artifact absent; rerun with --acquire')
                with urllib.request.urlopen(url, timeout=30) as response:
                    data = response.read(30 * 1024 * 1024 + 1)
                if len(data) > 30 * 1024 * 1024:
                    raise ValueError('archive exceeds size cap')
                verify_archive(data, integrity, version)
                with file.open('xb') as stream:
                    os.chmod(file, 0o600)
                    stream.write(data)
            info = verify_archive(file.read_bytes(), integrity, version)
            report['artifacts'][name] = {'archive': str(file), 'url': url, **info}
        except Exception as error:
            report['errors'].append(f'{name}: {type(error).__name__}: {error}')
    if len(report['artifacts']) == 3:
        mcp = report['artifacts']['@playwright/mcp']['package']
        lib = report['artifacts']['playwright']['package']
        core = report['artifacts']['playwright-core']['package']
        if mcp.get('dependencies') != {'playwright': ALPHA, 'playwright-core': ALPHA}:
            report['errors'].append('wrapper dependency pair differs from exact alpha pins')
        if lib.get('dependencies', {}).get('playwright-core') != ALPHA:
            report['errors'].append('playwright → playwright-core dependency pin mismatch')
        if core.get('dependencies'):
            report['errors'].append('playwright-core declares unexpected runtime dependencies')
    try:
        node = subprocess.check_output(['which', 'node'], text=True, timeout=5).strip()
        version = subprocess.check_output([node, '--version'], text=True, timeout=5).strip()
        major = int(re.fullmatch(r'v(\d+)\.\d+\.\d+', version).group(1))
        report['node'] = {'path': node, 'version': version, 'sha256': _digest(Path(node).read_bytes()),
                          'compatible_with_alpha': major >= 20}
        if major < 20:
            report['errors'].append('pinned Playwright requires Node >=20')
    except Exception as error:
        report['errors'].append(f'Node identity: {type(error).__name__}: {error}')
    report['python'] = {'version': platform.python_version(), 'platform': platform.platform()}
    report['blockers'] = report['errors'] + [
        'Actual installed extension 0.4.0 artifact and compatibility unverified',
        'Current user-selected profile and fixture tab/generation/nonce absent',
        'Current extension connection approval absent; no bypass token used',
    ]
    report['finished_wall_ns'] = time.time_ns()
    private_json(directory / 'environment.json', report)
    evidence = record('E00', 'pinned-artifacts-without-browser-attachment', 'blocked',
                      candidate_id='C02', candidate_version=VERSION,
                      evidence_level='artifact preflight', requirement_ids=['BR-20', 'BR-23'],
                      environment_manifest='environment.json',
                      hypothesis='Pinned C02 wrapper and alpha dependency pair can be verified without browser access',
                      steps=[{'operation': 'verify three npm archives and distributed files',
                              'browser_tool_calls': 0, 'lifecycle_scripts': 0}],
                      oracle_evidence=['environment.json'], errors=report['blockers'],
                      remaining_target_block='No browser target admitted',
                      interpretation_limits=['Installed extension/profile/consent and browser runtime not verified',
                                             'No candidate MCP initialization, attachment, action or cessation tested'])
    private_json(directory / 'E00.json', evidence)
    print(directory)
    print(json.dumps({'status': evidence['status'], 'artifact_errors': report['errors'],
                      'files_verified': {k: len(v['files']) for k, v in report['artifacts'].items()}}, indent=2))
    return 1 if report['errors'] else 0


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--acquire', action='store_true', help='fetch only pinned npm archives into app-owned private storage')
    args = parser.parse_args()
    raise SystemExit(preflight(args.acquire))
