"""Versioned, private research evidence; no browser or Codex state access."""
import hashlib
import json
import os
from pathlib import Path
import time
import uuid

ROOT = Path.home() / 'Library/Application Support/Context Desk/browser-gate/stage3'
STATUSES = {'passed', 'failed', 'not tested', 'blocked', 'not applicable'}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def revision():
    root = Path(__file__).parent
    return digest(b''.join(p.name.encode() + b'\0' + p.read_bytes()
                           for p in sorted(root.iterdir()) if p.suffix in {'.py', '.html', '.js'}))


def private_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with path.open('x', encoding='utf-8') as stream:
        os.chmod(path, 0o600)
        json.dump(value, stream, indent=2, ensure_ascii=False)
        stream.write('\n')


def record(experiment, variant, status, **fields):
    if status not in STATUSES:
        raise ValueError(status)
    value = dict(schema_version=1, run_id=uuid.uuid4().hex,
                 experiment_id=experiment, variant=variant, requirement_ids=[],
                 candidate_id=None, candidate_version=None, evidence_level='fixture self-check',
                 hypothesis='', environment_manifest=None, fixture_revision=revision(),
                 target_generation=None, grants_and_prerequisites=[], steps=[],
                 timestamps_monotonic_ns={k: None for k in (
                     'dispatch', 'stop_received', 'cancel_sent', 'cancel_ack',
                     'last_executor_effect', 'cessation_verified')},
                 clock_correlation={'host_monotonic_ns': time.monotonic_ns(),
                                    'host_wall_ns': time.time_ns(),
                                    'browser_clock': 'not used'},
                 oracle_evidence=[], status=status, cessation_condition=None,
                 outcome_uncertain=False, errors=[], owned_process_cleanup=[],
                 remaining_target_block=None, interpretation_limits=[])
    value.update(fields)
    return value
