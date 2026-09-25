#!/usr/bin/env python3
"""Prefer SwiftPM; support the locally broken CLT installation without changing it."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / '.build/local-build'


def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def capture(args):
    return run(args, capture_output=True, text=True).stdout.strip()


def sources(folder):
    return sorted((ROOT / folder).rglob('*.swift'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('task', choices=['build', 'test'])
    parser.add_argument('--direct', action='store_true', help='Explicitly exercise the direct compiler fallback')
    args = parser.parse_args()
    os.chdir(ROOT)
    OUT.mkdir(parents=True, exist_ok=True)
    compiler = capture(['xcrun', '--find', 'swiftc'])
    swift = capture(['xcrun', '--find', 'swift'])
    developer = Path(capture(['xcode-select', '-p']))
    version = capture([compiler, '--version'])
    target = platform.machine() + '-apple-macosx14.0'
    candidates = [Path(os.environ.get('CONTEXTDESK_SDK', capture(['xcrun', '--show-sdk-path'])))]
    if 'CONTEXTDESK_SDK' not in os.environ:
        sdk_dirs = [developer / 'SDKs', developer / 'Platforms/MacOSX.platform/Developer/SDKs']
        installed = [p for folder in sdk_dirs for p in folder.glob('MacOSX[0-9]*.sdk')]
        candidates += sorted(installed, key=lambda p: tuple(map(int, re.findall(r'\d+', p.name))), reverse=True)
    seen = set()
    sdk = None
    with tempfile.TemporaryDirectory(prefix='sdk-probe-', dir=OUT) as tmp:
        probe = Path(tmp) / 'Probe.swift'
        probe.write_text('import Foundation\nimport SwiftUI\nimport AppKit\n'
                         'struct SDKProbe: View {\n'
                         '  @State private var value = false\n'
                         '  var body: some View { Text(value ? "yes" : "no") }\n'
                         '}\n')
        for candidate in candidates:
            candidate = candidate.resolve()
            if candidate in seen:
                continue
            seen.add(candidate)
            result = subprocess.run([compiler, '-sdk', str(candidate), '-target', target, '-typecheck', str(probe)], capture_output=True, text=True)
            if result.returncode == 0:
                sdk = candidate
                break
            print(f'SDK incompatible: {candidate}', file=sys.stderr)
            (OUT / 'sdk-probe-error.log').write_text(result.stderr)
    if sdk is None:
        raise RuntimeError('No compatible SDK. See .build/local-build/sdk-probe-error.log. Install a matching Xcode/Command Line Tools release or set CONTEXTDESK_SDK.')
    print(f'Compiler: {version}\nSDK: {sdk}', flush=True)
    health = subprocess.run([swift, 'package', '--version'], capture_output=True, text=True)
    direct = args.direct or health.returncode != 0
    if health.returncode != 0:
        (OUT / 'swiftpm-error.log').write_text(health.stdout + health.stderr)
        print('SwiftPM cannot start; using direct compilation. Diagnostic: .build/local-build/swiftpm-error.log', flush=True)
    frameworks = developer / 'Library/Developer/Frameworks'
    test_flags = []
    if (frameworks / 'Testing.framework').is_dir():
        test_flags = ['-F', str(frameworks), '-Xlinker', '-rpath', '-Xlinker', str(frameworks), '-Xlinker', '-rpath', '-Xlinker', str(developer / 'Library/Developer/usr/lib')]
    macros = Path(compiler).parent.parent / 'lib/swift/host/plugins/testing'
    if macros.is_dir():
        test_flags += ['-plugin-path', str(macros)]
    if args.task == 'test':
        with tempfile.TemporaryDirectory(prefix='testing-probe-', dir=OUT) as tmp:
            probe = Path(tmp) / 'TestingProbe.swift'
            probe.write_text('import Testing\n@Test func toolchainProbe() { #expect(true) }\n')
            result = subprocess.run([compiler, '-sdk', str(sdk), '-target', target, '-typecheck'] + test_flags + [str(probe)], capture_output=True, text=True)
            if result.returncode != 0:
                (OUT / 'testing-probe-error.log').write_text(result.stdout + result.stderr)
                raise RuntimeError('Swift Testing framework/macros are incompatible with this toolchain. Tests did not run. Install a matching Command Line Tools or Xcode release; see docs/building.md and .build/local-build/testing-probe-error.log.')
    if not direct:
        # A source/build/test failure must fail, never trigger a fallback or reuse an old binary.
        if args.task == 'build':
            command = [swift, 'build', '--sdk', sdk, '-c', 'release', '--product', 'ContextDesk', '--force-resolved-versions']
            run(command)
            bin_path = capture([swift, 'build', '--sdk', sdk, '-c', 'release', '--show-bin-path'])
            shutil.copy2(Path(bin_path) / 'ContextDesk', OUT / 'ContextDesk')
        else:
            command = [swift, 'test', '--sdk', sdk, '--disable-xctest', '--force-resolved-versions']
            if macros.is_dir():
                command += ['-Xswiftc', '-plugin-path', '-Xswiftc', macros]
            if test_flags:
                command += ['-Xswiftc', '-F', '-Xswiftc', frameworks, '-Xlinker', '-F', '-Xlinker', frameworks, '-Xlinker', '-rpath', '-Xlinker', frameworks, '-Xlinker', '-rpath', '-Xlinker', developer / 'Library/Developer/usr/lib']
            run(command)
    else:
        resolved = json.loads((ROOT / 'Package.resolved').read_text())
        pins = resolved['pins']
        if len(pins) != 1 or pins[0]['identity'] != 'tomldecoder' or pins[0]['state']['version'] != '0.4.5':
            raise RuntimeError('Dependency graph changed. Update the direct build recipe or repair SwiftPM.')
        dependency = ROOT / '.build/checkouts/TOMLDecoder'
        if not dependency.is_dir():
            raise RuntimeError('Pinned TOMLDecoder checkout missing. Restore SwiftPM and run swift package resolve first.')
        if capture(['git', '-C', dependency, 'rev-parse', 'HEAD']) != pins[0]['state']['revision'] or capture(['git', '-C', dependency, 'status', '--porcelain']):
            raise RuntimeError('TOMLDecoder checkout must be clean and match Package.resolved.')
        # Rebuild all modules in an empty directory so compiler/SDK changes cannot reuse stale objects.
        with tempfile.TemporaryDirectory(prefix='compile-', dir=OUT) as tmp:
            work = Path(tmp)
            base = [compiler, '-sdk', sdk, '-swift-version', '6', '-target', target, '-parse-as-library', '-I', work, '-I', ROOT / 'Sources/CSQLite', '-L', work]
            base += ['-Onone', '-enable-testing'] if args.task == 'test' else ['-O']
            modules = [('TOMLDecoder', '.build/checkouts/TOMLDecoder/Sources/TOMLDecoder'), ('ContextCore', 'Sources/ContextCore'), ('ContextTranscript', 'Sources/ContextTranscript')]
            if args.task == 'test':
                modules.append(('ContextDesk', 'Sources/ContextDesk'))
            for name, folder in modules:
                print(f'Compiling {name}', flush=True)
                flags = ['-Xfrontend', '-entry-point-function-name', '-Xfrontend', 'ContextDesk_main'] if name == 'ContextDesk' else []
                run(base + flags + ['-emit-library', '-static', '-emit-module', '-module-name', name, '-emit-module-path', work / (name + '.swiftmodule'), '-o', work / ('lib' + name + '.a')] + sources(folder))
            libraries = ['-lContextTranscript', '-lContextCore', '-lTOMLDecoder']
            if args.task == 'build':
                run(base + ['-module-name', 'ContextDesk'] + sources('Sources/ContextDesk') + libraries + ['-o', work / 'ContextDesk'])
                shutil.copy2(work / 'ContextDesk', OUT / 'ContextDesk')
            else:
                runner = work / 'Runner.swift'
                runner.write_text('import Testing\n@main struct Runner { static func main() async { await Testing.__swiftPMEntryPoint() } }\n')
                run(base + test_flags + ['-module-name', 'ContextCoreTests'] + sources('Tests/ContextCoreTests') + [runner, '-lContextDesk'] + libraries + ['-o', work / 'Tests'])
                run([work / 'Tests'])
    if args.task == 'build':
        digest = hashlib.sha256()
        for path in sorted([ROOT / 'Package.swift', ROOT / 'Package.resolved'] + list((ROOT / 'Sources').rglob('*'))):
            if path.is_file():
                digest.update(str(path.relative_to(ROOT)).encode() + b'\0' + path.read_bytes())
        (OUT / 'build-info.json').write_text(json.dumps({'builtAt': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'compiler': version, 'sdk': str(sdk), 'backend': 'swiftc' if direct else 'SwiftPM', 'sourceSHA256': digest.hexdigest()}, indent=2) + '\n')


if __name__ == '__main__':
    try:
        main()
    except (subprocess.CalledProcessError, RuntimeError) as error:
        sys.exit(str(error))
