#!/usr/bin/env python3
"""Configure standing site-cookie permission through the owning scheduler only."""
import argparse
import importlib.util
import json
from pathlib import Path
import sys
import uuid

# Bundled resources are signed; importing the sibling must not create bytecode.
sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location('schedule_client', Path(__file__).with_name('schedule-control.py'))
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)


def main():
    parser = argparse.ArgumentParser(description=client.message('Импорт сессии для всех запусков задания', 'Session import for every task run'))
    parser.add_argument('--job-id', required=True)
    parser.add_argument('--chrome-profile')
    parser.add_argument('--site')
    parser.add_argument('--disable', action='store_true')
    args = parser.parse_args()
    if args.disable and (args.chrome_profile or args.site) or not args.disable and not (args.chrome_profile and args.site):
        parser.error(client.message('Укажи --chrome-profile и --site либо только --disable', 'Specify --chrome-profile and --site, or only --disable'))
    job_id = str(uuid.UUID(args.job_id)).upper()
    jobs = client.send({'operation': 'list'})['jobs']
    job = next((j for j in jobs if j['id'].upper() == job_id), None)
    if job is None:
        raise RuntimeError(client.message('Задание не найдено', 'Task not found'))
    request = {'operation': 'browser-import', 'expected': job}
    policy = None if args.disable else {'profile': args.chrome_profile, 'site': args.site.strip().lower()}
    if policy is None:
        request['clearBrowserSessionImport'] = True
    else:
        request['browserSessionImport'] = policy
    # Older apps reject this operation; never fall back to a prompt or ledger edit.
    reply = client.send(request)
    updated = next((j for j in reply['jobs'] if j['id'].upper() == job_id), None)
    if updated is None or updated.get('browserSessionImport') != policy:
        raise RuntimeError(client.message('Разрешение не подтверждено; не повторяй изменение. Проверь receipt.',
                                          'Permission was not confirmed; do not repeat the edit. Check the receipt.'))
    for key in ('prompt', 'engine', 'projectID', 'model', 'effort', 'route', 'schedule', 'enabled', 'source', 'sourceDisabled', 'routine', 'acceptsExternalPolicy'):
        if updated.get(key) != job.get(key):
            raise RuntimeError(client.message('Настройки задания изменились; проверь receipt без повтора.',
                                              'Task settings changed; check the receipt without replay.'))
    print(json.dumps(reply, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
