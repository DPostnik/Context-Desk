#!/usr/bin/env python3
"""Install a verified, self-contained upstream distribution without npm scripts."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
import zipfile

ROOT = Path.home() / 'Library/Application Support/Context Desk/browser'
LOCK = json.loads(Path(__file__).with_name('runtime.lock.json').read_text())


def chrome_platform():
    value = {'arm64': 'mac-arm64', 'x86_64': 'mac-x64'}.get(platform.machine())
    if platform.system() != 'Darwin' or value is None:
        raise ValueError('Нужен macOS ARM64 или x64 / macOS ARM64 or x64 is required')
    return value


def chrome_app():
    # The executable is shared by isolated fixture profiles; user data is not.
    return (ROOT / 'chrome-for-testing' / LOCK['chromeForTesting']['version'] /
            ('chrome-' + chrome_platform()) / 'Google Chrome for Testing.app')


def verify_chrome(app):
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if (info.get('CFBundleIdentifier') != 'com.google.chrome.for.testing' or
            info.get('CFBundleShortVersionString') != LOCK['chromeForTesting']['version']):
        raise ValueError('Неверная версия Chrome for Testing / Unexpected Chrome for Testing version')
    if not os.access(app / 'Contents/MacOS/Google Chrome for Testing', os.X_OK):
        raise ValueError('Chrome for Testing не запускается / Chrome for Testing is not executable')


def install_chrome():
    app = chrome_app()
    destination = app.parent.parent
    if destination.exists():
        verify_chrome(app)
        return
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    release = LOCK['chromeForTesting']
    arch = chrome_platform()
    url = ('https://storage.googleapis.com/chrome-for-testing-public/' +
           release['version'] + '/' + arch + '/chrome-' + arch + '.zip')
    with tempfile.TemporaryDirectory(dir=destination.parent) as temporary:
        staging = Path(temporary)
        archive = staging / 'chrome.zip'
        digest = hashlib.sha256()
        with urllib.request.urlopen(url, timeout=60) as response, archive.open('wb') as output:
            total = 0
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                total += len(chunk)
                if total > 400 * 1024 * 1024:
                    raise ValueError('Архив слишком большой / Archive is too large')
                digest.update(chunk)
                output.write(chunk)
        if digest.hexdigest() != release['sha256'][arch]:
            raise ValueError('Контрольная сумма Chrome не совпала / Chrome checksum mismatch')
        # Only the exact pinned archive reaches ditto (which preserves
        # bundle symlinks and executable modes). Never extract arbitrary input.
        with zipfile.ZipFile(archive) as zipped:
            if any(Path(name).is_absolute() or '..' in Path(name).parts for name in zipped.namelist()):
                raise ValueError('Недопустимый путь в архиве / Unsafe archive path')
        extracted = staging / 'release'
        subprocess.run(['/usr/bin/ditto', '-x', '-k', str(archive), str(extracted)], check=True)
        verify_chrome(extracted / app.relative_to(destination))
        extracted.rename(destination)
    print('Chrome for Testing ' + release['version'] + ': ' + str(app))


def verify(root):
    archive = root / 'upstream.tgz'
    if base64.b64encode(hashlib.sha512(archive.read_bytes()).digest()).decode() != LOCK['sha512']:
        raise ValueError('Artifact integrity mismatch')
    with tarfile.open(archive) as tar:
        expected = set()
        for member in tar.getmembers():
            if member.isdir():
                continue
            if not member.isfile() or not member.name.startswith('package/') or '..' in Path(member.name).parts:
                raise ValueError('Unexpected archive member')
            path = root / member.name
            if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()):
                raise ValueError('Unexpected installed path')
            if hashlib.sha256(path.read_bytes()).digest() != hashlib.sha256(tar.extractfile(member).read()).digest():
                raise ValueError('Installed artifact changed')
            expected.add(member.name)
        actual = {str(p.relative_to(root)) for p in (root / 'package').rglob('*') if p.is_file()}
        if actual != expected:
            raise ValueError('Unexpected installed files')
    return root / 'package/build/src/bin/chrome-devtools-mcp.js'


def install(destination, node):
    node = Path(node).resolve()
    version = subprocess.check_output([str(node), '--version'], text=True).strip()
    parts = tuple(int(p) for p in version.lstrip('v').split('.')[:2])
    if parts < (22, 12):
        raise ValueError('Нужен Node.js 22.12 или новее / Node.js 22.12 or later is required')
    destination.mkdir(parents=True, exist_ok=True, mode=0o700)
    runtime = destination / ('chrome-devtools-' + LOCK['version'])
    if not runtime.exists():
        with tempfile.TemporaryDirectory(dir=destination) as tmp:
            staging = Path(tmp)
            with urllib.request.urlopen(LOCK['url'], timeout=30) as response:
                data = response.read(40 * 1024 * 1024)
            if base64.b64encode(hashlib.sha512(data).digest()).decode() != LOCK['sha512']:
                raise ValueError('Downloaded artifact integrity mismatch')
            (staging / 'upstream.tgz').write_bytes(data)
            with tarfile.open(staging / 'upstream.tgz') as tar:
                for member in tar.getmembers():
                    if not (member.isfile() or member.isdir()) or not member.name.startswith('package/') or '..' in Path(member.name).parts:
                        raise ValueError('Unsafe archive member')
                    if member.isfile():
                        target = staging / member.name
                        target.parent.mkdir(parents=True, exist_ok=True)
                        target.write_bytes(tar.extractfile(member).read())
            verify(staging)
            staging.rename(runtime)
    verify(runtime)
    install_chrome()
    config = destination / 'runtime.json'
    temporary = destination / 'runtime.json.tmp'
    temporary.write_text(json.dumps({'version': LOCK['version'], 'node': str(node)}, indent=2) + '\n')
    os.chmod(temporary, 0o600)
    temporary.replace(config)
    print('Installed Chrome DevTools MCP ' + LOCK['version'] + ' at ' + str(runtime))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, default=ROOT)
    parser.add_argument('--node', default=shutil.which('node'))
    args = parser.parse_args()
    if not args.node:
        parser.error('Node.js is not installed or not on PATH')
    install(args.root, args.node)
