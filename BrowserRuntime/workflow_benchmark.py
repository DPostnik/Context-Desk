#!/usr/bin/env python3
"""Bounded public EnglishJobs pilot, isolated Chrome, no qualification or writes to sites."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time

sys.dont_write_bytecode = True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--resources', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    args.output.mkdir(parents=True, exist_ok=False)
    sys.path.insert(0, str(args.resources.resolve()))
    from server import Browser
    from install import ROOT, LOCK
    workload = json.loads(Path(__file__).with_name('englishjobs-workflow.json').read_text())
    config, url = workload['selectors'], workload['url']
    report = {'startedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'workload': workload, 'runs': [], 'modelTokens': None,
              'resourceSHA256': {name: hashlib.sha256((args.resources / name).read_bytes()).hexdigest()
                                 for name in ('server.py', 'cards.js')}}
    def persist():
        (args.output / 'results.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
    with tempfile.TemporaryDirectory(prefix='context-desk-workflow-pilot-') as tmp:
        root = Path(tmp)
        (root / 'runtime.json').write_bytes((ROOT / 'runtime.json').read_bytes())
        (root / ('chrome-devtools-' + LOCK['version'])).symlink_to(ROOT / ('chrome-devtools-' + LOCK['version']))
        browser = Browser(root)
        try:
            for iteration, fast in enumerate((False, True, True, False)):
                token = browser.open(url)['session']
                started = time.monotonic()
                calls = browser.metrics['calls']
                first = browser.cards(token, config, expected_cards=workload['expectedCards'] if fast else None)
                report['pendingPage'] = {'fast': fast, 'page': first}
                persist()
                assert first['complete'], first['reason']
                size = len(json.dumps(first).encode())
                if fast:
                    second = browser.next(token, f'pilot-next-{iteration}', first['url'], None, config,
                                          next_token=first['nextToken'])
                else:
                    snapshot = browser.native('take_snapshot', {'pageId': browser.page})
                    size += len(json.dumps(snapshot).encode())
                    match = re.search(r'uid=(\S+) link "Goto Next Page, Page 2"', browser.text(snapshot))
                    assert match, 'Next UID unavailable; no navigation dispatched'
                    second = browser.next(token, f'pilot-next-{iteration}', first['url'], match.group(1), config)
                size += len(json.dumps(second).encode())
                assert second['complete'], second['reason']
                run = {'fast': fast, 'seconds': time.monotonic() - started, 'responseBytes': size,
                       'upstreamCalls': browser.metrics['calls'] - calls, 'pages': [first, second]}
                report['runs'].append(run)
                report.pop('pendingPage', None)
                persist()
                print(json.dumps({k: v for k, v in run.items() if k != 'pages'}), flush=True)
                browser.close_session(token)
            fields = ('id', 'title', 'company', 'location', 'date', 'excerpt')
            normalized = [[[{k: c[k] for k in fields} for c in p['cards']] for p in r['pages']] for r in report['runs']]
            report['equalIDsAndMetadata'] = all(r == normalized[0] for r in normalized)
            report['counts'] = [[len(p['cards']) for p in r['pages']] for r in report['runs']]
            report['limits'] = 'Two live pages, two rounds per mode; changing signed URLs excluded from identity comparison. No job-level or token savings claim.'
            print(json.dumps({k: report[k] for k in ('equalIDsAndMetadata', 'counts', 'limits')}), flush=True)
        except Exception as error:
            report['failure'] = type(error).__name__ + ': ' + str(error)
            raise
        finally:
            persist()
            browser.stop()
            if browser.chrome:
                browser.chrome.close_created_for_test()


if __name__ == '__main__':
    main()
