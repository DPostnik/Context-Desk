#!/usr/bin/env python3
"""Run the fixed offline research suite and retain private logs for one revision."""
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid

SOURCE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SOURCE))
from evidence import ROOT, private_json, record, revision


def main():
    os.umask(0o077)
    directory = ROOT / ('parallel-validation-' + uuid.uuid4().hex)
    directory.mkdir(parents=True, mode=0o700)
    source_before = revision()
    commands = [
        [sys.executable, str(SOURCE / 'selftest.py')],
        [sys.executable, '-m', 'runner.selfcheck'],
        [sys.executable, str(SOURCE / 'adapters/chrome/test_adapter.py')],
        [sys.executable, str(SOURCE / 'adapters/playwright/test_adapter.py')],
        [sys.executable, str(SOURCE / 'adapters/playwriter/test_adapter.py')],
        [sys.executable, str(SOURCE / 'adapters/agent_browser/test_adapter.py')],
        [sys.executable, '-m', 'unittest', 'discover', '-s', str(SOURCE / 'checks'), '-p', 'test_*.py', '-v'],
        ['node', '--check', str(SOURCE / 'lab.js')],
    ]
    env = {**os.environ, 'PYTHONPATH': str(SOURCE)}
    steps = []
    for index, command in enumerate(commands):
        started = time.monotonic_ns()
        log = directory / f'check-{index + 1}.log'
        error = None
        with log.open('xb') as stream:
            try:
                completed = subprocess.run(command, cwd=SOURCE.parents[1], env=env,
                                           stdout=stream, stderr=subprocess.STDOUT, timeout=60)
                code = completed.returncode
            except (OSError, subprocess.TimeoutExpired) as failure:
                code, error = None, str(failure)
        step = dict(command=command, exit_code=code, error=error,
                    elapsed_seconds=(time.monotonic_ns() - started) / 1e9, log=log.name)
        steps.append(step)
        print(f'{index + 1}/{len(commands)} exit={code} log={log}', flush=True)
    changed = revision() != source_before
    passed = not changed and all(step['exit_code'] == 0 for step in steps)
    value = record('offline-package', 'parallel-runner-and-adapters', 'passed' if passed else 'failed',
        evidence_level='protocol doubles and fixture self-checks', fixture_revision=source_before,
        adapter_contract_version=1, steps=steps,
        errors=['Source changed during validation'] if changed else [],
        interpretation_limits=['No browser runtime, current grants, model pipeline or cessation certification',
                               'App build and Swift checks are separate publication checks'])
    private_json(directory / 'validation.json', value)
    print(directory / 'validation.json', flush=True)
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
