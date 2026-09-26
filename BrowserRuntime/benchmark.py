#!/usr/bin/env python3
"""Matched live read benchmark: direct MCP with reference traversal vs adapter MCP.

Private artifacts only. No model calls, submissions, scheduler or personal profiles.
Both lanes use the same extraction/readiness algorithm to isolate API aggregation.
This is not an end-to-end agent speed comparison.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
import uuid

sys.dont_write_bytecode = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--resources', type=Path, required=True)
    parser.add_argument('--workload', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    sys.path.insert(0, str(args.resources.resolve()))
    from server import Browser
    from transport import StdioRPC
    from chrome_host import ChromeHost
    from install import ROOT, LOCK
    os.umask(0o077)
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    workload = json.loads(args.workload.read_text())
    (out / 'workload.json').write_text(json.dumps(workload, indent=2))
    root = out / 'runtime'
    root.mkdir()
    (root / 'runtime.json').write_bytes((ROOT / 'runtime.json').read_bytes())
    (root / ('chrome-devtools-' + LOCK['version'])).symlink_to(ROOT / ('chrome-devtools-' + LOCK['version']))
    host = ChromeHost(root)
    cases = []
    journal = (out / 'calls.jsonl').open('w')
    samples_file = (out / 'rss.jsonl').open('w')
    measurement = {'active': False, 'driver': None, 'samples': []}
    stopped = threading.Event()

    def sample():
        while not stopped.wait(.2):
            if not measurement['active']:
                continue
            try:
                output = subprocess.run(['/bin/ps', '-axo', 'pid=,ppid=,rss='], capture_output=True,
                                        text=True, timeout=3, check=True).stdout
                table = {int(parts[0]): (int(parts[1]), int(parts[2]))
                         for line in output.splitlines() if len(parts := line.split()) == 3}
                def total(pid):
                    ids = {pid}
                    while True:
                        more = {p for p, (parent, _) in table.items() if parent in ids} - ids
                        if not more:
                            break
                        ids |= more
                    return sum(table.get(p, (0, 0))[1] for p in ids) / 1024
                entry = {'at': time.time(), 'driverMiB': total(measurement['driver']),
                         'chromeMiB': total(host.owner['pid']),
                         'harnessMiB': table.get(os.getpid(), (0, 0))[1] / 1024}
                measurement['samples'].append(entry)
                samples_file.write(json.dumps(entry) + '\n')
            except Exception as error:
                measurement['samples'].append({'error': str(error)})
    sampler = threading.Thread(target=sample, daemon=True)
    client = raw = reference = None
    try:
        host.ensure()
        sampler.start()
        for round_id, lane in enumerate(['direct', 'wrapper', 'wrapper', 'direct'], 1):
            calls = []
            def rpc(transport, name, arguments):
                started = time.perf_counter()
                result = transport.rpc('tools/call', {'name': name, 'arguments': arguments},
                                       uuid.uuid4().hex, time.monotonic_ns() + 90_000_000_000)
                record = {'round': round_id, 'lane': lane, 'name': name,
                          'seconds': time.perf_counter() - started,
                          'responseBytes': len(json.dumps(result, ensure_ascii=False).encode()),
                          'isError': bool(result.get('isError'))}
                calls.append(record)
                journal.write(json.dumps(record) + '\n')
                return result
            if lane == 'wrapper':
                client = StdioRPC([sys.executable, '-B', str(args.resources.resolve() / 'server.py'),
                                   '--root', str(root)], max_line=8_000_000).start()
                client.initialize_mcp(expected_server_version='1.0.0', seconds=20)
                def call(name, arguments):
                    result = rpc(client, name, arguments)
                    if result.get('isError'):
                        raise RuntimeError(result)
                    return json.loads(result['content'][0]['text'])
                driver_pid = client.process.pid
            else:
                raw = Browser(root)
                raw.start()
                reference = Browser(root, rpc=lambda name, arguments: rpc(raw.transport, name, arguments))
                # Reference client reuses traversal code only for matched completeness.
                # Every native result crosses the client boundary in the direct lane.
                def call(name, arguments):
                    if name == 'browser_open':
                        return reference.open(arguments['url'])
                    if name == 'browser_cards':
                        return reference.cards(arguments['session'], arguments['selectors'], arguments['timeout'])
                    if name == 'browser_close':
                        return reference.close_session(arguments['session'])
                    raise ValueError(name)
                driver_pid = raw.transport.process.pid
            # Exclude launch/connect cost, and warm each lane before its timed reads.
            warm = call('browser_open', {'url': workload[0]['url']})
            call('browser_close', {'session': warm['session']})
            for target in workload:
                start_index = len(calls)
                measurement.update(driver=driver_pid, samples=[], active=True)
                started = time.perf_counter()
                opened = call('browser_open', {'url': target['url']})
                result = call('browser_cards', {'session': opened['session'], 'selectors': target['selectors'], 'timeout': 20})
                call('browser_close', {'session': opened['session']})
                elapsed = time.perf_counter() - started
                measurement['active'] = False
                observed = measurement['samples'][:]
                errors = [s for s in observed if 'error' in s]
                samples = [s for s in observed if 'error' not in s]
                measured_calls = calls[start_index:]
                record = {'round': round_id, 'lane': lane, 'target': target['name'], 'seconds': elapsed,
                          'calls': len(measured_calls), 'rpcSeconds': sum(c['seconds'] for c in measured_calls),
                          'responseBytes': sum(c['responseBytes'] for c in measured_calls),
                          'toolErrors': sum(c['isError'] for c in measured_calls),
                          'complete': result['complete'], 'reason': result['reason'], 'truncated': result['truncated'],
                          'count': len(result['cards']), 'cards': result['cards'],
                          'rssSamples': len(samples), 'rssErrors': errors,
                          'peakDriverMiB': max((s['driverMiB'] for s in samples), default=None),
                          'peakChromeMiB': max((s['chromeMiB'] for s in samples), default=None),
                          'peakHarnessMiB': max((s['harnessMiB'] for s in samples), default=None)}
                cases.append(record)
                (out / 'results.json').write_text(json.dumps(cases, indent=2, ensure_ascii=False))
                print(json.dumps({k: v for k, v in record.items() if k != 'cards'}), flush=True)
            if client:
                client.close(); client = None
            if raw:
                raw.stop(); raw = None
    finally:
        measurement['active'] = False
        stopped.set()
        if sampler.is_alive():
            sampler.join(timeout=4)
        if client:
            client.close()
        if raw:
            raw.stop()
        host.close_created_for_test()
        journal.close()
        samples_file.close()


if __name__ == '__main__':
    main()
